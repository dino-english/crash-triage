#!/usr/bin/env bash
# Mac mini 一次性安装。幂等，可重复跑。
# 前置：已装 brew、node、git；已跑过授权（gcloud auth login + firebase-tools login，见文末清单）。
set -euo pipefail

# 运行根 = 本脚本所在目录的上级（仓库根）。不写死绝对路径，见 crash-daily.sh 同段注释。
SELF_DIR_SETUP="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="${CRASH_REPORT_ROOT:-$(dirname "$SELF_DIR_SETUP")}"
# 状态目录与代码分离（见 crash-daily.sh 同段注释）；默认走 XDG 约定。
STATE="${CRASH_REPORT_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/crash-triage}"
IOS_REMOTE="${IOS_REMOTE:-https://github.com/dino-english/dino-english-ios.git}"
AND_REMOTE="${AND_REMOTE:-https://github.com/dino-english/dino-english-android.git}"

echo "=== 崩溃 & 性能流水线安装 ==="
echo "  代码（git 管） ROOT  = $ROOT"
echo "  运行数据       STATE = $STATE"
mkdir -p "$STATE"/{logs,reports}
chmod +x "$ROOT/bin"/*.sh
# 不再有「把脚本复制到别处」这一步：代码就地跑在仓库里，setup 只负责本机配置与定时。
# （2026-08-18：删掉了 scripts/crash-report 源副本与自装 cp 逻辑，双份同步的分叉风险随之消失）

# ── 1. 探测二进制真实路径，写 path.env ────────────────
# 不硬编码：launchd 只给最小 env，各机器 node / brew 路径不一定相同。
echo "--- 探测工具路径 ---"
MISSING=()
declare -a DIRS=()
# 探测列表 = 脚本真正会调用的每一个命令。漏一个的后果是定时任务在最小 env 下
# 找不到它而失败——2026-08-18 实测：漏了 bq 与 lark-cli，生成的 PATH 不含
# /opt/homebrew/bin，日报在「凭证探活」阶段直接挂掉。
for b in node jq git claude npx bq lark-cli python3; do
  p="$(command -v "$b" 2>/dev/null || true)"
  if [ -z "$p" ]; then MISSING+=("$b"); else
    printf '  %-10s %s\n' "$b" "$p"
    DIRS+=("$(dirname "$p")")
  fi
done
if [ ${#MISSING[@]} -gt 0 ]; then
  echo "❌ 缺少：${MISSING[*]}"
  echo "   node/jq/git/bq 用 brew 装（bq 在 google-cloud-sdk）；claude / lark-cli 用 npm -g 装"
  exit 1
fi
# 去重后拼 PATH，尾部补系统目录兜底
UNIQ="$(printf '%s\n' "${DIRS[@]}" | awk '!seen[$0]++' | paste -sd: -)"
printf 'PATH="%s:/usr/bin:/bin:/usr/sbin:/sbin"\n' "$UNIQ" > "$STATE/path.env"
echo "  → 写入 $STATE/path.env"
# 旧名遗留清理（config.env → path.env，2026-08-20 改名）。读取端的回落分支已移除，
# 留着旧文件只会让人误以为它还有用。保留这行清理，供还没迁过的机器首次 setup 时扫尾。
rm -f "$STATE/config.env" 2>/dev/null || true

# ── 2. MCP 配置（复用本机 firebase login 凭证，不含密钥）──
cat > "$ROOT/bin/mcp.json" <<'JSON'
{
  "mcpServers": {
    "firebase": {
      "command": "npx",
      "args": ["-y", "firebase-tools@latest", "mcp", "--only", "crashlytics"]
    }
  }
}
JSON
echo "--- MCP 配置已写 ---"

# ── 3. 准备仓库：运行根的同级目录里看得到就用，看不到才 clone 到隔离副本 ──
echo "--- 准备仓库 ---"
if [ -z "${REPOS_ROOT:-}" ]; then
  if [ -d "$(dirname "$ROOT")/dino-english-ios/.git" ]; then REPOS_ROOT="$(dirname "$ROOT")"; else REPOS_ROOT="$ROOT/repos"; fi
fi
clone_or_fetch() {
  local url="$1" name="$2"
  # 同级里已有仓库 → 直接用（fetch 保持最新），不重复 clone
  if [ -d "$REPOS_ROOT/$name/.git" ]; then
    echo "  ✅ 同级已有 $REPOS_ROOT/${name}，跳过 clone（fetch 保持最新）"
    git -C "$REPOS_ROOT/$name" fetch --all --tags --prune --quiet
    return 0
  fi
  # 同级看不到 → 隔离 clone 到 $ROOT/repos
  local dir="$ROOT/repos/$name"
  if [ -d "$dir/.git" ]; then
    echo "  已存在，fetch：$dir"; git -C "$dir" fetch --all --tags --prune --quiet
  else
    echo "  clone：$url → $dir"; git clone --quiet "$url" "$dir"
  fi
}
clone_or_fetch "$IOS_REMOTE" "dino-english-ios"
clone_or_fetch "$AND_REMOTE" "dino-english-android"

# ── 4. 探活 ───────────────────────────────────────────
echo "--- 探活 ---"
# shellcheck disable=SC1091
. "$STATE/path.env"; export PATH
npx -y firebase-tools@latest login:list 2>/dev/null | grep -q '@' \
  && echo "  ✅ firebase 已登录" || { echo "  ❌ firebase 未登录，跑 npx -y firebase-tools@latest login"; exit 1; }

echo
echo "=== 安装完成 ==="
echo "先 DRY RUN 验一次（不发消息）："
echo "  CRASH_REPORT_CHAT_ID=<你的 ou_xxx> CRASH_REPORT_DRY_RUN=1 $ROOT/bin/crash-weekly.sh"
echo
# plist 里的 /Users/USER 占位符替换成实际用户（否则 launchd 指向不存在的路径，装机即坑）
if ls "$ROOT"/bin/*.plist >/dev/null 2>&1; then
  # plist 必须是绝对路径（launchd 不展开 $HOME / 变量），但这些绝对路径由这里按**实际目录**生成，
  # 不由人手改——换机器/换目录只要重跑 setup.sh，plist 自动对上。
  # 生成到 ${STATE}（不写回仓库，否则 git 里永远躺着一份带本机路径的脏文件）。
  for tpl in "$ROOT"/bin/*.plist; do
    sed -e "s|__ROOT__|$ROOT|g" -e "s|__STATE__|$STATE|g" "$tpl" > "$STATE/$(basename "$tpl")"
  done
  echo "--- 已生成 plist 到 ${STATE}（ROOT=$ROOT · STATE=${STATE}）---"
fi
echo "确认无误后装定时（每周一 05:30）："
echo "  cp $STATE/com.dino.crash-weekly.plist ~/Library/LaunchAgents/"
echo "  launchctl load ~/Library/LaunchAgents/com.dino.crash-weekly.plist"
