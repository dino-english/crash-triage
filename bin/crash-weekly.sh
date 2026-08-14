#!/usr/bin/env bash
# 周频崩溃变化播报（自动档）。
#
# 定位：只报「变了什么」，不做根因、不给修复方案——那是人工跑 firebase-crash-triage skill 的活。
#       理由见 2026-08-06 实例：自动生成的修复方案可能看似合理实则错误，
#       且会被下一轮 git log --grep 误判为「已修复」，错误自我强化。
#
# 变化检测由 jq 做（确定性），模型只负责抓数据 + git 反查。
set -euo pipefail

# Hermes cron 继承 PYTHONPATH=<hermes-agent>，会让 bq 的 `from utils import bq_error`
# 误抓 hermes-agent/utils.py 而崩（2026-08-14 实测）。bq/jq/git/claude 均不需要 PYTHONPATH，先清掉。
unset PYTHONPATH

export CRASH_REPORT_ROOT="${CRASH_REPORT_ROOT:-$HOME/crash-triage}"
ROOT="$CRASH_REPORT_ROOT"
# 本机统一：repos 指向 gitWorkspace（可用 REPOS_ROOT 覆盖；默认 $ROOT/repos 兼容隔离部署）
REPOS_ROOT="${REPOS_ROOT:-$ROOT/repos}"

# PATH 由 setup.sh 探测后写入 config.env——launchd 只给最小 env，硬编码路径在别的机器上必挂。
# 实测教训（2026-08-06）：node 在 /usr/local/bin 而非 /opt/homebrew/bin，漏了它 npx/claude 直接起不来。
if [ -f "$ROOT/bin/config.env" ]; then
  # shellcheck disable=SC1091
  . "$ROOT/bin/config.env"
else
  PATH="/opt/homebrew/bin:/usr/local/bin:$HOME/.npm-global/bin:/usr/bin:/bin:/usr/sbin:/sbin"
fi
export PATH

TS="$(date +%Y%m%d-%H%M%S)"
DAY="$(date +%Y-%m-%d)"
LOG="$ROOT/logs/weekly-$TS.log"
SNAP_NEW="$ROOT/state/snapshot-$TS.json"
SNAP_LAST="$ROOT/state/last-snapshot.json"
HEALTH="$ROOT/state/health.json"

# ── 配置 ───────────────────────────────────────────────
CHAT_ID="${CRASH_REPORT_CHAT_ID:?未设置 CRASH_REPORT_CHAT_ID}"   # 目标群；先用私聊验证再换群
DRY_RUN="${CRASH_REPORT_DRY_RUN:-0}"                              # 1 = 只打印不发送
# ──────────────────────────────────────────────────────

exec > >(tee -a "$LOG") 2>&1
echo "=== 崩溃周报 $TS ==="

fail() { echo "❌ $*"; jq -n --arg t "$TS" --arg e "$*" '{last_run:$t,ok:false,error:$e}' > "$HEALTH"; exit 1; }

# ── 1. 凭证探活（端到端真调，不猜状态字符串）──────────
# 飞书投递已改由 Hermes agent 经 lark-mcp 完成，此处只探 firebase。
echo "--- 凭证探活 ---"
npx -y firebase-tools@latest login:list 2>/dev/null | grep -q '@' \
  || fail "firebase 未登录，在本机跑 npx -y firebase-tools@latest login"

# ── 2. 同步只读 clone ─────────────────────────────────
echo "--- 同步仓库 ---"
for r in dino-english-ios dino-english-android; do
  d="$REPOS_ROOT/$r"
  [ -d "$d/.git" ] || fail "$d 不是 git 仓库"
  git -C "$d" fetch --all --tags --prune --quiet || fail "$r fetch 失败"
  # 只 fetch，不 checkout / reset：repos 指向 gitWorkspace 工作仓库，绝不能破坏未提交状态（只读约束）。
  # 对照分支 = 最近有提交的远程分支（过滤 refs/remotes/origin/HEAD——它的 short 形式是裸 "origin"，会拼出 origin/origin，2026-08-06 踩过）
  br="$(git -C "$d" for-each-ref --sort=-committerdate --format='%(refname:short)' refs/remotes/origin/ \
        | grep -vE '^origin(/HEAD)?$' | head -1 | sed 's|^origin/||')"
  [ -n "$br" ] || fail "$r 未能确定对照分支"
  echo "  $r → 对照 origin/$br @ $(git -C "$d" rev-parse --short "origin/$br")"
done

# ── 3. 抓快照 ─────────────────────────────────────────
echo "--- 跑 firebase-crash-triage（完整流程）---"
OUT_DIR="$ROOT/state/weekly-$TS"
# shellcheck disable=SC1091
. "$ROOT/bin/lib.sh"
# 完整 triage 实测跑 12 分钟以上；给 30 分钟上限防挂死（挂死会导致下周又起一个）。
# 超时不整跑失败——只要 snapshot.json 落了盘就能发变化摘要，报告是加分项。
TRIAGE_TIMEOUT="${TRIAGE_TIMEOUT:-1800}"
run_with_timeout "$TRIAGE_TIMEOUT" "$ROOT/bin/fetch-snapshot.sh" "$OUT_DIR" full
TRIAGE_RC=$?
[ "$TRIAGE_RC" -eq 124 ] && echo "  ⚠️ triage 超时（${TRIAGE_TIMEOUT}s），降级为只发变化摘要"
SNAP_NEW="$OUT_DIR/snapshot.json"
TRIAGE_REPORT="$OUT_DIR/report.md"
# 快照是核心产出，缺了才算真失败；report.md 缺失只降级（prompt 已要求先写快照再写报告）
[ -s "$SNAP_NEW" ] || fail "快照文件为空（triage 退出码 $TRIAGE_RC）"
[ -s "$TRIAGE_REPORT" ] || echo "  ⚠️ 未产出 report.md，本周只发变化摘要"
jq -e '.ios and .android' "$SNAP_NEW" >/dev/null || fail "快照 JSON 结构不符（缺 ios/android）"

# ── 4. 变化检测（纯 jq，不经模型）─────────────────────
echo "--- 变化检测 ---"
# 首跑无基准时不能把全部 issue 当「新增」播报（2026-08-07 实测刷出 26 条）。
# 标记为建立基线，只报总数。
IS_BASELINE=0
if [ ! -f "$SNAP_LAST" ]; then
  IS_BASELINE=1
  echo '{"ios":[],"android":[]}' > "$SNAP_LAST"
fi

DIFF="$(jq -n --slurpfile new "$SNAP_NEW" --slurpfile old "$SNAP_LAST" '
  def bykey: map({key:.id, value:.}) | from_entries;
  def plat($p):
    ($new[0][$p] // []) as $n | ($old[0][$p] // []) as $o
    | ($n | bykey) as $nm | ($o | bykey) as $om
    | {
        total:    ($n | length),
        events:   ($n | map(.events) | add // 0),
        new:      [ $n[] | select($om[.id] == null) ],
        resolved: [ $o[] | select($nm[.id] == null) ],
        spiked:   [ $n[] | select($om[.id] != null and .events >= ($om[.id].events * 2) and .events >= 5) ],
        fixed_pending: [ $n[] | select(.fix_commit != null) ]
      };
  {ios: plat("ios"), android: plat("android")}
')"

if [ "$IS_BASELINE" = "1" ]; then
  CHANGED=0
  echo "  首次运行，建立基线（不报新增）"
else
  CHANGED=$(echo "$DIFF" | jq '[.ios,.android] | map(.new,.resolved,.spiked) | flatten | length')
  echo "  变化项：$CHANGED"
fi

# 收件人既可能是群（oc_）也可能是个人（ou_，首次部署验证用）——投递由 agent 读 manifest 的 chat_id 决定。

# ── 5. 组装播报 ───────────────────────────────────────
sec() { # $1=平台名 $2=json key
  local name="$1" k="$2"
  local total events
  total=$(echo "$DIFF" | jq -r ".$k.total")
  events=$(echo "$DIFF" | jq -r ".$k.events")
  printf '**%s** — OPEN FATAL %s 个 / 近 7 天 %s 事件\n' "$name" "$total" "$events"
  [ "$IS_BASELINE" = "1" ] && { printf '（首次运行，建立基线，不列新增）\n\n'; return; }
  echo "$DIFF" | jq -r ".$k.new[]?     | \"- 🆕 新增 \\(.title) · \\(.events) 事件\"" || true
  echo "$DIFF" | jq -r ".$k.spiked[]?  | \"- 📈 暴涨 \\(.title) · \\(.events) 事件\"" || true
  echo "$DIFF" | jq -r ".$k.resolved[]? | \"- ✅ 消失 \\(.title)\"" || true
  # Android 无 issue ID 提交约定，fix_commit 恒 null，该行只对 iOS 有意义
  [ "$k" = "ios" ] && { echo "$DIFF" | jq -r ".$k.fixed_pending[]? | \"- 🛠️ 代码已修待验 \\(.title) · \\(.fix_commit)\"" || true; }
  echo
}

IOS_BR="$(git -C "$REPOS_ROOT/dino-english-ios" rev-parse --abbrev-ref HEAD)"
AND_BR="$(git -C "$REPOS_ROOT/dino-english-android" rev-parse --abbrev-ref HEAD)"

MSG="$(cat <<MSG_END
**📊 崩溃周报 · $DAY**

$(sec "iOS" ios)
$(sec "Android" android)
---
对照分支：iOS \`$IOS_BR\` · Android \`$AND_BR\`
变化摘要见上；根因与修复方案见完整报告（**未经人工复核**，落地前须验证）

MSG_END
)"

REPORT="$ROOT/reports/$DAY-weekly.md"
printf '%s\n' "$MSG" > "$REPORT"

# ── 6. 产出投递清单（发消息/建文档由 Hermes agent 经 lark-mcp 执行）──
# send 只在「有变化且非 dry-run」时 true；无变化不发（避免播报噪音化）。
SEND_FLAG="false"
[ "$CHANGED" -gt 0 ] && [ "$DRY_RUN" != "1" ] && SEND_FLAG="true"
if [ "$CHANGED" -eq 0 ]; then
  echo "无变化，不发送（避免播报噪音化）"
fi
if [ "$DRY_RUN" = "1" ]; then
  echo "--- DRY RUN，以下内容不会投递 ---"; printf '%s\n' "$MSG"
fi

PUBLISH_DIR="$ROOT/state/publish"
rm -rf "$PUBLISH_DIR"; mkdir -p "$PUBLISH_DIR/docs"
printf '%s\n' "$MSG" > "$PUBLISH_DIR/message.md"
REPORT_FILE=""; [ -s "$TRIAGE_REPORT" ] && cp "$TRIAGE_REPORT" "$PUBLISH_DIR/docs/weekly.md" && REPORT_FILE="$PUBLISH_DIR/docs/weekly.md"

# 周报每次新建独立文档（快照性质，要留痕可跨版本 diff），不像日报覆盖同一份；
# 报告文档的 URL 由 agent 用 docx.builtin.import 创建后回填到消息末尾再发送；
# index_append 由 agent 在文档创建成功后追加一行（url = 刚创建的文档 URL）。
jq -n \
  --arg chat "$CHAT_ID" \
  --arg send "$SEND_FLAG" \
  --arg msg  "$PUBLISH_DIR/message.md" \
  --arg report "$REPORT_FILE" \
  --arg title "崩溃周报 · $DAY" \
  --arg idx "$ROOT/state/weekly-index.jsonl" \
  --arg day "$DAY" \
  --argjson ios "$(echo "$DIFF" | jq '.ios.total')" \
  --argjson and "$(echo "$DIFF" | jq '.android.total')" \
  '{type:"weekly", chat_id:$chat, send:($send=="true"),
    message_file:$msg,
    create_doc:(if $report != "" then {file:$report, title:$title, label:"周报"} else null end),
    index_append:(if $report != "" then {jsonl_file:$idx, day:$day, ios:$ios, android:$and} else null end)}' \
  > "$PUBLISH_DIR/manifest.json"

echo "  ✅ 投递清单 $PUBLISH_DIR/manifest.json（发送=$SEND_FLAG）"

# ── 7. 收尾 ───────────────────────────────────────────
cp "$SNAP_NEW" "$SNAP_LAST"
jq -n --arg t "$TS" --argjson c "$CHANGED" '{last_run:$t,ok:true,changes:$c}' > "$HEALTH"
find "$ROOT/logs" -name 'weekly-*.log' -mtime +60 -delete 2>/dev/null || true
find "$ROOT/state" -name 'snapshot-*.json' -mtime +60 -delete 2>/dev/null || true
echo "=== 完成，报告：$REPORT ==="
