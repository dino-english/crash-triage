#!/usr/bin/env bash
# 一键安装：新机器上把流水线跑起来。幂等，可重复执行。
#
# 分两段：能自动化的（探测路径、生成配置、装 cron、迁移台账）与必须人做的（三个授权，
# 都要浏览器和 TTY，agent 的 shell 做不了）。脚本会检测后者是否完成，没完成就停下来指路。
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(dirname "$SELF_DIR")"
STATE="${CRASH_REPORT_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/crash-triage}"
CHAT_ID="${CRASH_REPORT_CHAT_ID:-}"
PROFILE="${CRASH_REPORT_LARK_PROFILE:-crash-triage}"
HERMES_SCRIPTS="$HOME/.hermes/scripts"
FAIL=0

say()  { printf '\n\033[1m%s\033[0m\n' "$*"; }
ok()   { printf '  ✅ %s\n' "$*"; }
bad()  { printf '  ❌ %s\n' "$*"; FAIL=1; }
warn() { printf '  ⚠️  %s\n' "$*"; }
todo() { printf '  👉 %s\n' "$*"; }

say "崩溃 & 性能流水线 · 安装"
echo "  代码 ROOT  = $ROOT"
echo "  运行 STATE = $STATE"

# ── 1. 前置命令 ────────────────────────────────────────
say "1/7 前置命令"
for c in git jq node python3; do
  command -v "$c" >/dev/null 2>&1 && ok "$c" || bad "$c 缺失"
done
command -v bq >/dev/null 2>&1 && ok "bq" || bad "bq 缺失（装 google-cloud-sdk）"
command -v lark-cli >/dev/null 2>&1 && ok "lark-cli" || bad "lark-cli 缺失（npm i -g @larksuiteoapi/lark-cli）"
command -v hermes >/dev/null 2>&1 && ok "hermes" || bad "hermes 缺失"
command -v claude >/dev/null 2>&1 && claude --version >/dev/null 2>&1 \
  && ok "claude（$(claude --version 2>/dev/null | head -1)）" \
  || warn "claude 不可用 → 周报根因段与日报 MCP 对照段会降级；修复：node \$(npm root -g)/@anthropic-ai/claude-code/install.cjs"
[ "$FAIL" = 1 ] && { say "前置未满足，停止"; exit 1; }

# ── 2. 目录与本机配置 ──────────────────────────────────
say "2/7 目录与本机配置"
bash "$SELF_DIR/setup.sh" >/dev/null 2>&1 && ok "setup.sh（config.env / mcp.json / plist 模板）" || bad "setup.sh 失败"
[ -s "$STATE/config.env" ] && ok "config.env" || bad "config.env 未生成"

# ── 3. 三个授权（必须人做）─────────────────────────────
say "3/7 授权检查（都要浏览器 + TTY，无法自动化）"
# 直接探 bq 本身：ADC 与 bq 用的凭证不是一套，探 ADC 会在 bq 正常时误报未授权
bq query --use_legacy_sql=false --format=csv 'SELECT 1' >/dev/null 2>&1 \
  && ok "bq 可查询" || { bad "bq 不可用"; todo "gcloud auth login && gcloud config set project dino-english-497507"; }
npx -y firebase-tools@latest login:list 2>/dev/null | grep -q '@' \
  && ok "firebase" || { bad "firebase 未登录"; todo "npx firebase-tools login"; }
if lark-cli --profile "$PROFILE" whoami >/dev/null 2>&1; then
  ok "lark-cli profile $PROFILE"
else
  bad "lark-cli profile '$PROFILE' 未配置"
  todo "lark-cli config bind --source hermes --app-id <cli_xxx>   # Agent 环境用 bind，不是 init"
  todo "lark-cli auth login --profile $PROFILE --domain drive,docs,im"
fi
# 钥匙串落地：无 TTY 的定时任务读不到 macOS Keychain
if [ -f "$HOME/Library/Application Support/lark-cli/master.key.file" ]; then
  ok "lark-cli 主密钥已落地（定时任务可读）"
else
  warn "主密钥仍在 Keychain —— 定时任务可能读不到"
  todo "lark-cli config keychain-downgrade   # 交互式终端里跑一次"
fi

# ── 4. 台账迁移（不做会产生重复文档）───────────────────
say "4/7 文档台账"
if [ -s "$STATE/docs.json" ]; then
  ok "docs.json 已存在（$(jq 'length' "$STATE/docs.json" 2>/dev/null) 条）→ 会覆盖已有文档"
else
  warn "docs.json 不存在 —— 首次运行会**新建一整套文档**，与原机器上的重复"
  todo "从原机器拷贝：scp <原机>:$STATE/docs.json $STATE/"
  todo "同时拷 folders.json（目录 token 缓存），否则会重建目录树"
fi

# ── 5. 收件人 ──────────────────────────────────────────
say "5/7 收件人"
if [ -z "$CHAT_ID" ]; then
  bad "未设置 CRASH_REPORT_CHAT_ID"
  todo "首次部署先用私聊验证：export CRASH_REPORT_CHAT_ID=ou_xxxxx"
  todo "验证几轮无误后再换群：oc_655033f1f85fa04f9eac25d56f056fc9"
else
  case "$CHAT_ID" in
    ou_*) ok "私聊 ${CHAT_ID}（验证模式）";;
    oc_*) warn "直接投群 $CHAT_ID —— 建议先用 ou_ 私聊验证几轮";;
    *)    bad "CHAT_ID 格式不对（应为 ou_ 或 oc_ 开头）";;
  esac
fi

# ── 6. hermes cron ────────────────────────────────────
say "6/7 hermes 定时任务"
mkdir -p "$HERMES_SCRIPTS"
for job in daily weekly; do
  w="$HERMES_SCRIPTS/crash-$job.sh"
  cat > "$w" <<WRAP
#!/usr/bin/env bash
# 由 crash-triage 的 install.sh 生成，勿手改；改配置请重跑 install.sh / update.sh。
# stdout 保持为空：hermes --no-agent 会把 stdout 原样投递，而我们自己用 lark-cli 投卡片。
# 失败告警由 bin/alert.sh 负责（它不依赖 agent，agent 挂了也发得出）。
export CRASH_REPORT_ROOT="$ROOT"
export CRASH_REPORT_STATE_DIR="$STATE"
export CRASH_REPORT_CHAT_ID="$CHAT_ID"
export CRASH_REPORT_LARK_PROFILE="$PROFILE"
exec bash "$ROOT/bin/crash-$job.sh" >/dev/null 2>&1
WRAP
  chmod +x "$w"
  ok "wrapper $w"
done
if hermes cron list 2>/dev/null | grep -q 'crash-daily'; then
  ok "cron 已存在（如需改时间用 hermes cron edit）"
else
  todo "创建定时任务（确认上面各项都 ✅ 后执行）："
  echo "     hermes cron create '0 7 * * *'  --name crash-daily  --no-agent --script crash-daily.sh"
  echo "     hermes cron create '30 5 * * 1' --name crash-weekly --no-agent --script crash-weekly.sh"
fi

# ── 7. 验收 ────────────────────────────────────────────
say "7/7 验收"
bash "$SELF_DIR/check-scripts.sh" || FAIL=1
if [ "$FAIL" = 0 ] && [ -n "$CHAT_ID" ]; then
  todo "跑一次 DRY RUN 确认无误："
  echo "     CRASH_REPORT_CHAT_ID=$CHAT_ID CRASH_REPORT_DRY_RUN=1 bash $ROOT/bin/crash-daily.sh"
  todo "再跑一次真实投递（会建文档发卡片）："
  echo "     CRASH_REPORT_CHAT_ID=$CHAT_ID bash $ROOT/bin/crash-daily.sh"
fi

say "$([ "$FAIL" = 0 ] && echo '安装检查通过，按上面的 👉 完成剩余步骤' || echo '存在未满足项，见上方 ❌')"
exit "$FAIL"
