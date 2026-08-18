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

# 运行根 = 本脚本所在 bin/ 的上级目录（即本仓库根）。**不写死任何绝对路径**：
# 仓库 clone 到哪儿都能跑，换机器 / 换用户名 / 换工作区都不用改脚本。
# cron / plist 里显式设的 CRASH_REPORT_ROOT 仍然优先。
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export CRASH_REPORT_ROOT="${CRASH_REPORT_ROOT:-$(dirname "$SELF_DIR")}"
ROOT="$CRASH_REPORT_ROOT"
# 业务仓库：优先用运行根的**同级工作区**（两个仓库通常和本仓库并排 clone，只读 fetch），
# 没有才落到 $ROOT/repos 的隔离 clone——避免同一份仓库在磁盘上存两份（旧安装实测重复占 175M）。
if [ -z "${REPOS_ROOT:-}" ]; then
  if [ -d "$(dirname "$ROOT")/dino-english-ios/.git" ]; then
    REPOS_ROOT="$(dirname "$ROOT")"
  else
    REPOS_ROOT="$ROOT/repos"
  fi
fi
export REPOS_ROOT   # fetch-snapshot.sh 是子进程，不 export 它会退回自己的默认值

# ── 代码与状态分离 ────────────────────────────────────
# ${ROOT}（仓库）只放代码与需要留痕的产物：bin/ · sql/ · reports/LEDGER.md · reports/weekly-index.jsonl，全部由 git 管。
# $STATE 放可变运行数据：logs/ · 每日生成的报告 · 快照 · 历史 · 投递中间产物 · 本机 config.env。
# 分开的理由不是洁癖：`git clean -xfd` / 重新 clone 会连同被忽略的文件一起抹掉，
# 而 last-snapshot.json 丢了会把下周所有 issue 报成新增（2026-08-07 那类事故）。
# 默认走 XDG 约定；cron / plist 可用 CRASH_REPORT_STATE_DIR 指到别处。
STATE="${CRASH_REPORT_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/crash-triage}"

# PATH 由 setup.sh 探测后写入 config.env——launchd 只给最小 env，硬编码路径在别的机器上必挂。
# 实测教训（2026-08-06）：node 在 /usr/local/bin 而非 /opt/homebrew/bin，漏了它 npx/claude 直接起不来。
if [ -f "$STATE/config.env" ]; then
  # shellcheck disable=SC1091
  . "$STATE/config.env"
else
  PATH="/opt/homebrew/bin:/usr/local/bin:$HOME/.npm-global/bin:/usr/bin:/bin:/usr/sbin:/sbin"
fi
export PATH

TS="$(date +%Y%m%d-%H%M%S)"
DAY="$(date +%Y-%m-%d)"
LOG="$STATE/logs/weekly-$TS.log"
SNAP_NEW="$STATE/snapshot-$TS.json"
SNAP_LAST="$STATE/last-snapshot.json"
HEALTH="$STATE/health.json"

# ── 配置 ───────────────────────────────────────────────
CHAT_ID="${CRASH_REPORT_CHAT_ID:?未设置 CRASH_REPORT_CHAT_ID}"   # 目标群；先用私聊验证再换群
DRY_RUN="${CRASH_REPORT_DRY_RUN:-0}"                              # 1 = 只打印不发送
# ──────────────────────────────────────────────────────

mkdir -p "$STATE"/{logs,reports}
exec > >(tee -a "$LOG") 2>&1
echo "=== 崩溃周报 $TS ==="

# ── 故障告警：失败要发出去，不能死在日志里 ─────────────────
# 两条通路：fail() 覆盖已知失败，ERR trap 兜住未预期的非零退出（set -e 直接杀进程那种）。
# ALERTED 防重复：fail() 已发过就不再由 trap 补发。
ALERTED=0
CURRENT_STEP="启动"
step() { CURRENT_STEP="$1"; echo "--- $1 ---"; }
alert_once() { # $1=step $2=message $3=rc
  [ "$ALERTED" = 1 ] && return 0
  ALERTED=1
  [ -x "$ROOT/bin/alert.sh" ] || return 0
  "$ROOT/bin/alert.sh" --source weekly --severity error --step "$1" \
    --message "$2" --rc "${3:-1}" --run-id "$TS" --log "$LOG" >/dev/null 2>&1 || true
}
on_err() { local rc=$?; [ "$rc" -eq 0 ] && return 0
  alert_once "$CURRENT_STEP" "脚本在第 ${1:-?} 行以退出码 $rc 终止（未预期的失败）" "$rc"; }
set -o errtrace
trap 'on_err $LINENO' ERR
fail() { echo "❌ $*"; jq -n --arg t "$TS" --arg e "$*" '{last_run:$t,ok:false,error:$e}' > "$HEALTH"; alert_once "$CURRENT_STEP" "$*" 1; exit 1; }

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
  # 只 fetch，不 checkout / reset：REPOS_ROOT 可能指向你正在用的工作仓库，绝不能破坏未提交状态（只读约束）。
  # 对照分支 = 最近有提交的远程分支（过滤 refs/remotes/origin/HEAD——它的 short 形式是裸 "origin"，会拼出 origin/origin，2026-08-06 踩过）
  br="$(git -C "$d" for-each-ref --sort=-committerdate --format='%(refname:short)' refs/remotes/origin/ \
        | grep -vE '^origin(/HEAD)?$' | head -1 | sed 's|^origin/||')"
  [ -n "$br" ] || fail "$r 未能确定对照分支"
  echo "  $r → 对照 origin/$br @ $(git -C "$d" rev-parse --short "origin/$br")"
done

# ── 3. 抓快照 ─────────────────────────────────────────
echo "--- 跑 firebase-crash-triage（完整流程）---"
OUT_DIR="$STATE/weekly-$TS"
# shellcheck disable=SC1091
. "$ROOT/bin/lib.sh"
# 完整 triage 实测跑 12 分钟以上；给 30 分钟上限防挂死（挂死会导致下周又起一个）。
# 超时不整跑失败——只要 snapshot.json 落了盘就能发变化摘要，报告是加分项。
TRIAGE_TIMEOUT="${TRIAGE_TIMEOUT:-1800}"
# set -e 下 run_with_timeout 超时返回 124 会直接杀死脚本；用 || 捕获退出码让降级路径存活。
run_with_timeout "$TRIAGE_TIMEOUT" "$ROOT/bin/fetch-snapshot.sh" "$OUT_DIR" full || TRIAGE_RC=$?
[ "${TRIAGE_RC:-0}" -eq 124 ] && echo "  ⚠️ triage 超时（${TRIAGE_TIMEOUT}s），降级为只发变化摘要"
SNAP_NEW="$OUT_DIR/snapshot.json"
TRIAGE_REPORT="$OUT_DIR/report.md"
# 快照是核心产出，缺了才算真失败；report.md 缺失只降级（prompt 已要求先写快照再写报告）
[ -s "$SNAP_NEW" ] || fail "快照文件为空（triage 退出码 ${TRIAGE_RC:-?}）"
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

# ── 5. 主力版本放量（与日报口径互补）────────────────────
# 日报看「版本号最新的 2 个版本」——新版发得怎么样；
# 周报看「会话量 top2 的主力版本」——盘子里承载用户的大头是什么。
# 两者常常不是同一批版本（新版刚放量时尤其），并列着看才完整（change crash-perf-latest-2-versions）。
# 本段依赖 bq；bq 不可用时整段降级（周报核心是 MCP 变化摘要，不因放量段失败而不发）。
SQL_DIR="${SQL_DIR:-$ROOT/bin/sql}"
PROJECT="dino-english-497507"
MIN_SESSIONS="${CRASH_REPORT_MIN_SESSIONS:-5}"
WEEK_DAYS="${CRASH_REPORT_WEEK_DAYS:-7}"
ADOPT_ROWS=""          # TSV：平台 \t 版本 \t 会话 \t 设备 \t 崩溃事件 \t 崩溃率
ADOPT_OK=0

if command -v bq >/dev/null 2>&1 && bq query --use_legacy_sql=false --format=csv 'SELECT 1' >/dev/null 2>&1; then
  ADOPT_OK=1
  echo "--- 主力版本放量（bq）---"
  top2_versions() { # $1=sessions表 → 「版本,会话,设备」前两行（按会话量降序）
    sed -e "s|{{TABLE}}|$1|g" -e "s|{{DAYS}}|$WEEK_DAYS|g" -e "s|{{MIN_SESSIONS}}|$MIN_SESSIONS|g" \
      "$SQL_DIR/latest-versions.sql" | bq query --use_legacy_sql=false --format=csv 2>/dev/null \
      | tail -n +2 | sort -t, -k2,2 -nr | head -2 || true
  }
  ver_crash() { # $1=crashlytics表 $2=sessions表 $3=版本 → 「事件数,会话数」
    sed -e "s|{{TABLE}}|$1|g" -e "s|{{SESSIONS_TABLE}}|$2|g" -e "s|{{DAYS}}|$WEEK_DAYS|g" \
        -e "s|{{VERSIONS}}|\"$3\"|g" "$SQL_DIR/crash-rate.sql" \
      | bq query --use_legacy_sql=false --format=csv 2>/dev/null | tail -n +2 | head -1 || true
  }
  for entry in "iOS|$PROJECT.firebase_sessions.com_prime_dino_english_IOS_REALTIME|$PROJECT.firebase_crashlytics.com_prime_dino_english_IOS_REALTIME" \
               "Android|$PROJECT.firebase_sessions.com_prime_dino_english_ANDROID_REALTIME|$PROJECT.firebase_crashlytics.com_prime_dino_english_ANDROID_REALTIME"; do
    IFS='|' read -r pname stbl ctbl <<< "$entry"
    while IFS=, read -r ver sess dev; do
      [ -n "$ver" ] || continue
      cr="$(ver_crash "$ctbl" "$stbl" "$ver")"
      cev="$(printf '%s' "$cr" | cut -d, -f1)"; csess="$(printf '%s' "$cr" | cut -d, -f2)"
      rate="—"
      if [ -n "$cev" ] && [ -n "$csess" ] && [ "$csess" != "0" ]; then
        rate="$(awk -v e="$cev" -v s="$csess" 'BEGIN{printf "%.2f%%", e/s*100}')"
      fi
      ADOPT_ROWS="${ADOPT_ROWS}${pname}	${ver}	${sess}	${dev}	${cev:-—}	${rate}
"
      echo "  ${pname} ${ver}：${sess} 会话 / ${dev} 设备 / 崩溃 ${cev:-—} 次 ${rate}"
    done <<< "$(top2_versions "$stbl")"
  done
else
  echo "--- ⚠️ bq 不可用，跳过主力版本放量段（不影响变化摘要）---"
fi

# ── 取数区间（双时区）─────────────────────────────────
# 与日报同一套口径：起点 = 本次跑批时刻 − WEEK_DAYS 天（latest-versions.sql / crash-rate.sql
# 里都是 TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL {{DAYS}} DAY)，下界锚在跑批时刻）；
# 终点 = sessions 活表实际取到的最新事件时间。起点是「查询下界」不是「首条数据时间」。
# bq 不可用时整段降级为空字符串，周报照发（核心是 MCP 变化摘要）。
RUN_EPOCH="$(date +%s)"
TZ_LABEL="$(date '+%z')"
_fmt() { if [ -n "${2:-}" ]; then TZ="$2" date -r "$1" '+%m-%d %H:%M' 2>/dev/null
         else date -r "$1" '+%m-%d %H:%M' 2>/dev/null; fi; }
_until_epoch() { local s="${1:-}"; s="${s% UTC}"
  [ -n "$s" ] && [ "$s" != "—" ] || return 0
  TZ=UTC date -j -f '%Y-%m-%d %H:%M' "$s" '+%s' 2>/dev/null || true; }
win_compact() {
  local se ue; se=$(( RUN_EPOCH - ${1:-0} * 86400 )); ue="$(_until_epoch "${2:-}")"
  [ -n "$ue" ] || { printf '%s → —' "$(_fmt "$se")"; return 0; }
  printf '%s → %s (%s) · %s → %s UTC' "$(_fmt "$se")" "$(_fmt "$ue")" \
    "${TZ_LABEL%00}" "$(_fmt "$se" UTC)" "$(_fmt "$ue" UTC)"
}
win_full() {
  local se ue; se=$(( RUN_EPOCH - ${1:-0} * 86400 )); ue="$(_until_epoch "${2:-}")"
  [ -n "$ue" ] || { printf '%s UTC / %s %s → —' "$(_fmt "$se" UTC)" "$(_fmt "$se")" "$TZ_LABEL"; return 0; }
  printf '%s UTC / %s %s → %s UTC / %s %s' \
    "$(_fmt "$se" UTC)" "$(_fmt "$se")" "$TZ_LABEL" \
    "$(_fmt "$ue" UTC)" "$(_fmt "$ue")" "$TZ_LABEL"
}
DATA_UNTIL="—"
if [ "$ADOPT_OK" = "1" ]; then
  tbl_max() { [ -n "$1" ] || { echo ""; return 0; }
    bq query --use_legacy_sql=false --format=csv \
      "SELECT FORMAT_TIMESTAMP('%Y-%m-%d %H:%M UTC', MAX(event_timestamp)) AS ts FROM \`$1\`" 2>/dev/null \
      | tail -n +2 | tail -1 || true; }
  _MI="$(tbl_max "$PROJECT.firebase_sessions.com_prime_dino_english_IOS_REALTIME")"
  _MA="$(tbl_max "$PROJECT.firebase_sessions.com_prime_dino_english_ANDROID_REALTIME")"
  DATA_UNTIL="$(printf '%s\n%s\n' "$_MI" "$_MA" | grep -v '^$' | sort -r | head -1 || true)"
  [ -n "$DATA_UNTIL" ] || DATA_UNTIL="—"
fi
WIN_COMPACT="$(win_compact "$WEEK_DAYS" "$DATA_UNTIL")"
WIN_FULL="$(win_full "$WEEK_DAYS" "$DATA_UNTIL")"
echo "  取数区间 ${WEEK_DAYS}d：$WIN_COMPACT"

# ── 6. 组装播报 ───────────────────────────────────────
sec() { # $1=平台名 $2=json key → markdown 变化摘要
  local name="$1" k="$2"
  local total events
  total=$(echo "$DIFF" | jq -r ".$k.total")
  events=$(echo "$DIFF" | jq -r ".$k.events")
  printf '**%s** — OPEN FATAL %s 个 / 近 7 天 %s 事件\n' "$name" "$total" "$events"
  [ "$IS_BASELINE" = "1" ] && { printf '（首次运行，建立基线，不列新增）\n'; return; }
  echo "$DIFF" | jq -r ".$k.new[]?     | \"- 🆕 新增 \\(.title) · \\(.events) 事件\"" || true
  echo "$DIFF" | jq -r ".$k.spiked[]?  | \"- 📈 暴涨 \\(.title) · \\(.events) 事件\"" || true
  echo "$DIFF" | jq -r ".$k.resolved[]? | \"- ✅ 消失 \\(.title)\"" || true
  # Android 无 issue ID 提交约定，fix_commit 恒 null，该行只对 iOS 有意义
  [ "$k" = "ios" ] && { echo "$DIFF" | jq -r ".$k.fixed_pending[]? | \"- 🛠️ 代码已修待验 \\(.title) · \\(.fix_commit)\"" || true; }
  # 必须显式 return 0：末行的 [ ] && {...} 在 Android 分支上求值为假会让函数返回 1，
  # 而 CHANGES_MD="$(sec ...)" 在 set -e 下会因此整脚本退出（旧版嵌在 heredoc 里侥幸没暴露）。
  return 0
}
CHANGES_MD="$(sec "iOS" ios; printf '\n'; sec "Android" android)"

# ── 发送策略（三态，2026-08-18 修订）──────────────────────
# 旧实现把「首跑不列新增」和「无变化不发」合成了一条，结果首跑连总数都发不出去，
# 而 spec 原文写的是首跑「只报总数」——是发，不是不发。
# 另外周报现在带主力版本放量段，每周都有实打实的数值：平稳的一周什么都不发，
# 看的人无法区分「这周很好」和「流水线挂了」——监控系统最忌讳的沉默。
if [ "$IS_BASELINE" = "1" ]; then
  WEEK_STATE="baseline"; WEEK_TAG="· 建立基线"
elif [ "$CHANGED" -gt 0 ]; then
  WEEK_STATE="changed";  WEEK_TAG=""
else
  WEEK_STATE="quiet";    WEEK_TAG="· ✅ 本周无新增"
  CHANGES_MD="$(printf '**✅ 本周无新增 / 暴涨 / 消失的 issue**\n\niOS OPEN FATAL %s 个 · Android OPEN FATAL %s 个（近 7 天）' \
    "$(echo "$DIFF" | jq -r '.ios.total')" "$(echo "$DIFF" | jq -r '.android.total')")"
fi

IOS_BR="$(git -C "$REPOS_ROOT/dino-english-ios" rev-parse --abbrev-ref HEAD)"
AND_BR="$(git -C "$REPOS_ROOT/dino-english-android" rev-parse --abbrev-ref HEAD)"
NOTE_MD="$(printf '变化摘要口径：Firebase MCP topIssues（**只含 OPEN issue**，全版本），近 7 天窗。\n取数区间 %sd：%s\n主力版本 = 近 %s 天会话量 top2（日报看的是「版本号最新的 2 个版本」，两者互补，不可混比）。\n崩溃率 = 事件数/会话数（非 crash-free）· 对照分支：iOS %s · Android %s\n根因与修复方案见完整报告（**未经人工复核**，落地前须验证）' \
  "$WEEK_DAYS" "$WIN_COMPACT" "$WEEK_DAYS" "$IOS_BR" "$AND_BR")"

# 主力版本表（markdown 与卡片共用同一批数据）
adopt_md() {
  [ -n "$ADOPT_ROWS" ] || { printf '（本次未取到放量数据）\n'; return 0; }
  printf '| 平台 | 版本 | 会话 | 设备 | 崩溃事件 | 崩溃率 |\n|---|---|---|---|---|---|\n'
  printf '%s' "$ADOPT_ROWS" | awk -F'\t' 'NF>=6{printf "| %s | %s | %s | %s | %s | %s |\n",$1,$2,$3,$4,$5,$6}'
}

MSG="$(cat <<MSG_END
**📊 崩溃周报 · ${DAY}${WEEK_TAG:+ $WEEK_TAG}**

$CHANGES_MD

**🚀 主力版本（近 ${WEEK_DAYS} 天会话量 top2）**

$(adopt_md)
> $NOTE_MD
MSG_END
)"

# 结构化卡片（CardKit v2，与日报同款；agent 原样投递，仅回填 __REPORT_URL__）
ADOPT_JSON="$(printf '%s' "$ADOPT_ROWS" | awk -F'\t' 'NF>=6{printf "%s\t%s\t%s\t%s\t%s\t%s\n",$1,$2,$3,$4,$5,$6}' \
  | jq -Rsc 'split("\n") | map(select(length>0) | split("\t")
      | {plat:.[0], ver:.[1], sess:.[2], dev:.[3], crash:.[4], rate:.[5]})')"
# 只有真出现变化才红；基线与平稳周都是蓝——红色要留给「需要看一眼」的场合
HEADER_COLOR="blue"; [ "$WEEK_STATE" = changed ] && HEADER_COLOR="red"
CARD_JSON="$(jq -n \
  --arg hc "$HEADER_COLOR" --arg ht "📊 崩溃周报 · ${DAY}${WEEK_TAG:+ $WEEK_TAG}" \
  --arg ch "$CHANGES_MD" --arg nm "$NOTE_MD" \
  --argjson rows "${ADOPT_JSON:-[]}" \
  '{schema:"2.0",
    config:{width_mode:"fill"},
    header:{template:$hc,title:{tag:"plain_text",content:$ht}},
    body:{elements:([
      {tag:"markdown",content:"<font color=\u0027red\u0027>**🔁 本周变化**</font>"},{tag:"hr"},
      {tag:"markdown",content:$ch},
      {tag:"markdown",content:"<font color=\u0027green\u0027>**🚀 主力版本**</font>"},{tag:"hr"}]
      + (if ($rows | length) > 0 then [
          {tag:"table",page_size:10,row_height:"low",
           header_style:{text_align:"left",text_size:"normal",background_style:"grey",text_color:"default",bold:true,lines:1},
           columns:[{name:"plat",display_name:"平台",data_type:"text",width:"auto",horizontal_align:"left"},
                    {name:"ver",display_name:"版本",data_type:"text",width:"auto",horizontal_align:"left"},
                    {name:"sess",display_name:"会话",data_type:"text",width:"auto",horizontal_align:"left"},
                    {name:"dev",display_name:"设备",data_type:"text",width:"auto",horizontal_align:"left"},
                    {name:"crash",display_name:"崩溃",data_type:"text",width:"auto",horizontal_align:"left"},
                    {name:"rate",display_name:"崩溃率",data_type:"lark_md",width:"auto",horizontal_align:"left"}],
           rows:$rows}]
         else [{tag:"markdown",content:"（本次未取到放量数据）"}] end)
      + [{tag:"div",text:{tag:"plain_text",content:$nm,text_size:"notation",text_color:"grey"}},
         {tag:"markdown",content:"📄 [完整报告](__REPORT_URL__) · 📁 [全部报告](__FOLDER_URL__)"}])}}')"

REPORT="$STATE/reports/$DAY-weekly.md"
{
  printf '# 崩溃周报 · %s %s\n\n' "$DAY" "$WEEK_TAG"
  printf '> 取数区间 %sd：**%s**\n' "$WEEK_DAYS" "$WIN_FULL"
  printf '> 窗口起点 = 本次跑批时刻 − %s 天（SQL 下界）；终点 = sessions 活表实际取到的最新数据。\n\n' "$WEEK_DAYS"
  printf '## 一、本周变化\n\n%s\n\n' "$CHANGES_MD"
  printf '## 二、主力版本（近 %s 天会话量 top2）\n\n' "$WEEK_DAYS"
  adopt_md
  printf '\n> 日报盯的是「版本号最新的 2 个版本」（新版发得怎么样），本段盯的是「承载用户最多的版本」（盘子里的大头）。\n'
  printf '> 两段版本集常常不同，各自回答不同的问题，**不可混比**。\n\n'
  printf '## 三、口径\n\n%s\n' "$NOTE_MD"
} > "$REPORT"

# ── 7. 产出投递清单（发消息/建文档由 Hermes agent 经 lark-mcp 执行）──
# send 只在「有变化且非 dry-run」时 true；无变化不发（避免播报噪音化）。
SEND_FLAG="true"; [ "$DRY_RUN" = "1" ] && SEND_FLAG="false"
echo "  本周状态：${WEEK_STATE}（发送=${SEND_FLAG}）"
if [ "$DRY_RUN" = "1" ]; then
  echo "--- DRY RUN，以下内容不会投递 ---"; printf '%s\n' "$MSG"
fi

# 基线提升必须在写 manifest **之前**：manifest 一旦落盘就可能被 agent 读走投递，
# 若此时基线还没提升而进程被杀，下周会把本周已播报的 issue 全部再报一遍新增
# （2026-08-07 事故类型）。顺序 = 先提升基线，再产出投递物。
cp "$SNAP_NEW" "$SNAP_LAST"

PUBLISH_DIR="$STATE/publish"
rm -rf "$PUBLISH_DIR"; mkdir -p "$PUBLISH_DIR/docs"
printf '%s\n' "$MSG" > "$PUBLISH_DIR/message.md"
printf '%s\n' "$CARD_JSON" > "$PUBLISH_DIR/card.json"
REPORT_XML=""
REPORT_FILE=""
if [ -s "$TRIAGE_REPORT" ]; then
  cp "$TRIAGE_REPORT" "$PUBLISH_DIR/docs/weekly.md"; REPORT_FILE="$PUBLISH_DIR/docs/weekly.md"
elif [ "$WEEK_STATE" = quiet ]; then
  echo "  平稳周且无根因报告：只发卡片不建文档（内容与卡片完全重复）"
elif [ -s "$REPORT" ]; then
  # triage 超时/失败时仍投递变化摘要 + 主力版本（周报本体），只是没有根因分析
  cp "$REPORT" "$PUBLISH_DIR/docs/weekly.md"; REPORT_FILE="$PUBLISH_DIR/docs/weekly.md"
fi

# 彩色版：与日报同一套配色（表头蓝底、偶数行灰底、状态词按语义上色）。
# 周报正文是 triage 产出的 markdown，走 md2docx.py 通用转换，不单独写渲染器。
if [ -n "$REPORT_FILE" ] && [ -x "$ROOT/bin/md2docx.py" ]; then
  if "$ROOT/bin/md2docx.py" "$REPORT_FILE" --title "崩溃周报 · $DAY" \
       --head-bg "${CRASH_REPORT_XC_HEAD:-light-blue}" --zebra "${CRASH_REPORT_XC_ZEBRA:-light-gray}" \
       > "$PUBLISH_DIR/docs/weekly.xml" 2>/dev/null; then
    REPORT_XML="$PUBLISH_DIR/docs/weekly.xml"
  fi
fi

# 周报每次新建独立文档（快照性质，要留痕可跨版本 diff），不像日报覆盖同一份；
# 报告文档的 URL 由 agent 用 docx.builtin.import 创建后回填到卡片 __REPORT_URL__ 再发送；
# index_append 由 agent 在文档创建成功后追加一行（url = 刚创建的文档 URL）。
jq -n \
  --arg chat "$CHAT_ID" \
  --arg day2 "$DAY" \
  --arg run "$TS" \
  --arg send "$SEND_FLAG" \
  --arg msg  "$PUBLISH_DIR/message.md" \
  --arg card "$PUBLISH_DIR/card.json" \
  --arg report "$REPORT_FILE" \
  --arg reportxml "$REPORT_XML" \
  --arg title "崩溃周报 · $DAY" \
  --arg idx "${CRASH_REPORT_ARCHIVE:-$ROOT/reports/report-index.jsonl}" \
  --arg day "$DAY" \
  --argjson ios "$(echo "$DIFF" | jq '.ios.total')" \
  --argjson and "$(echo "$DIFF" | jq '.android.total')" \
  '{type:"weekly", day:$day2, run_id:$run, chat_id:$chat, send:($send=="true"),
    message_file:$msg, card_file:$card,
    create_doc:(if $report != "" then {file:$report, xml_file:$reportxml, title:$title, label:"周报"} else null end),
    archive_append:(if $report != "" then {jsonl_file:$idx, type:"weekly", day:$day, ios:$ios, android:$and} else null end)}' \
  > "$PUBLISH_DIR/manifest.json"

echo "  ✅ 投递清单 $PUBLISH_DIR/manifest.json（发送=${SEND_FLAG}）"

# ── 投递（确定性，无 LLM）──────────────────────────────
# 生成与投递分两个脚本、串行调用：投递失败不改变本脚本的退出码——数据已落盘，
# 重跑 deliver.sh 即可补投（--idempotency-key 保证不会重复发卡片）。
# CRASH_REPORT_NO_DELIVER=1 可只生成不投递。
if [ "${CRASH_REPORT_NO_DELIVER:-0}" != "1" ] && [ -x "$ROOT/bin/deliver.sh" ]; then
  "$ROOT/bin/deliver.sh" "$PUBLISH_DIR/manifest.json" || echo "  ⚠️ 投递失败（数据已落盘，可重跑 deliver.sh 补投）"
fi

# ── 8. 收尾 ───────────────────────────────────────────
jq -n --arg t "$TS" --argjson c "$CHANGED" '{last_run:$t,ok:true,changes:$c}' > "$HEALTH"
find "$STATE/logs" -name 'weekly-*.log' -mtime +60 -delete 2>/dev/null || true
find "$STATE" -name 'snapshot-*.json' -mtime +60 -delete 2>/dev/null || true
echo "=== 完成，报告：$REPORT ==="
