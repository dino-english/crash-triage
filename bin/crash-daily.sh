#!/usr/bin/env bash
# L1 每日数据日报：BigQuery 性能 + BigQuery 崩溃 → 飞书文档 + 群卡片。
#
# 口径（2026-08-18 起，change crash-perf-latest-2-versions）：
#   崩溃 / 性能 / 放量三段**全量按版本过滤**，只统计「最新 VERSION_COUNT 个版本」，
#   每个数字按版本分列，不出跨版本合计值（合计会引入第三套口径）。
#   版本清单唯一源 = firebase_sessions 活表（线上正在跑什么版本），按版本号 sort -V 取最新 N 个。
#   若「会话量 top2」有版本不在最新 N 版内，追加为「主力」补充列（上限 4 列，见 design D11）。
#
# 数据源现状：
#   性能   → BigQuery firebase_performance   （每日批量同步，滞后 ~2 天）
#   崩溃   → BigQuery firebase_crashlytics    （REALTIME 事件级，含已关闭 issue）
#   崩溃率 → firebase_crashlytics / firebase_sessions（事件数/会话数，非 crash-free）
#
# ⚠️ 最新版在性能段常态无数据（批量表滞后），必须显示「该版本无数据」而非「数据未同步」——
#    后者是数据源故障语义，天天误报会让人不再看告警。判定序见 data_state()。
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

if [ -f "$STATE/config.env" ]; then
  # shellcheck disable=SC1091
  . "$STATE/config.env"
else
  PATH="/opt/homebrew/bin:/opt/homebrew/share/google-cloud-sdk/bin:/usr/local/bin:$HOME/.npm-global/bin:/usr/bin:/bin:/usr/sbin:/sbin"
fi
export PATH

TS="$(date +%Y%m%d-%H%M%S)"
DAY="$(date +%Y-%m-%d)"
LOG="$STATE/logs/daily-$TS.log"
RUN_ID="$TS"
AUDIT_DIR="$STATE/audit"
AUDIT_FILE="$AUDIT_DIR/$RUN_ID.events.jsonl"
SEQ=0
SQL_DIR="${SQL_DIR:-$ROOT/bin/sql}"
PROJECT="dino-english-497507"

CHAT_ID="${CRASH_REPORT_CHAT_ID:?未设置 CRASH_REPORT_CHAT_ID}"
DOC_DAILY_ID="${DOC_DAILY_ID:-}"        # 日报文档；固定一份每天 overwrite
DOC_INDEX_ID="${DOC_INDEX_ID:-}"        # 索引页
DOC_LEDGER_ID="${DOC_LEDGER_ID:-}"      # 台账镜像
LEDGER_SRC="${LEDGER_SRC:-$ROOT/reports/LEDGER.md}"
# 报告归档（日报 + 周报统一一份，进 git）：deliver.sh 在文档建成后追加 {type,day,url,...}
ARCHIVE_FILE="${CRASH_REPORT_ARCHIVE:-$ROOT/reports/report-index.jsonl}"
ARCHIVE_DAILY_KEEP="${CRASH_REPORT_ARCHIVE_DAILY_KEEP:-30}"   # 索引页里日报归档表渲染多少行（文件本身不截断）
DRY_RUN="${CRASH_REPORT_DRY_RUN:-0}"
DAYS="${CRASH_REPORT_DAYS:-1}"
# 性能窗口（D3）：firebase_performance 每日批量同步滞后约 2 天，DAYS=1 在每天 07:00 跑必然空表，
# 故独立放宽到 3 天；版本放量保持 DAYS（sessions REALTIME 为实时活源）。
PERF_DAYS="${CRASH_REPORT_PERF_DAYS:-3}"
# 崩溃窗口与 MCP topIssues 的 Firebase 默认 7 天窗一致；日窗口太窄（iOS 样本极少）会误读为「无崩溃」。
CRASH_DAYS="${CRASH_REPORT_CRASH_DAYS:-7}"

# ── 版本口径（change crash-perf-latest-2-versions）───────────────────
VERSION_COUNT="${CRASH_REPORT_VERSION_COUNT:-2}"   # 日报统计的最新版本个数
MIN_SESSIONS="${CRASH_REPORT_MIN_SESSIONS:-5}"     # 版本候选门槛：低于此会话数视为灰度/内测残留
MAX_VERSION_COLS="${CRASH_REPORT_MAX_VERSION_COLS:-4}"  # 最新 N 版 ∪ 主力 2 版后的列数上限

# ── 阈值红绿灯（R3 / D5）：脚本顶部集中可配常量 ────────────────────────
# 红档 = 已拍板；黄/绿 = explore 建议值落地，全部显式标注「待对齐」。
# 判定统一走 traffic_light()（>红=🔴；>黄=🟡；否则🟢），命中红档才出告警，黄档仅注释待对齐。
# 判定对象 = **最新版**（上一版与主力补充列只展示不告警，design D8）。
CRASH_RATE_RED=1.0        # 崩溃率 红 >1%（拍板）；黄 0.5–1%、绿 <0.5%（待对齐）
CRASH_RATE_YELLOW=0.5
NET_ERR_RED=1.0           # 接口错误率 红 >1%（需求对齐）；黄 0.5–1%、绿 <0.5%（待对齐）
NET_ERR_YELLOW=0.5
SLOW_FRAME_RED=50         # 慢帧占比 红 >50%（拍板）；黄 30–50%、绿 ≤30%（待对齐）
SLOW_FRAME_YELLOW=30
FROZEN_RED=1.0            # 冻结率 红 >1%（拍板）；黄 0.5–1%、绿 <0.5%（待对齐）
FROZEN_YELLOW=0.5
START_P95_RED=2000        # 启动 P95 红 >2000ms（拍板）；黄 1500–2000、绿 ≤1500（待对齐）
START_P95_YELLOW=1500
SAMPLE_SESSION_MIN=30     # 小样本会话数阈值：**版本级**会话数 < 30 追加「⚠️ 样本量小，仅供参考」

mkdir -p "$STATE"/{logs,reports}
exec > >(tee -a "$LOG") 2>&1
echo "=== 崩溃 & 性能日报 ${TS}（最新 $VERSION_COUNT 个版本口径）==="

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
  "$ROOT/bin/alert.sh" --source daily --severity error --step "$1" \
    --message "$2" --rc "${3:-1}" --run-id "$RUN_ID" --log "$LOG" >/dev/null 2>&1 || true
}
on_err() { local rc=$?; [ "$rc" -eq 0 ] && return 0
  alert_once "$CURRENT_STEP" "脚本在第 ${1:-?} 行以退出码 $rc 终止（未预期的失败）" "$rc"; }
set -o errtrace
trap 'on_err $LINENO' ERR
fail() { echo "❌ $*"; jq -n --arg t "$TS" --arg e "$*" '{last_run:$t,ok:false,error:$e}' > "$STATE/health-daily.json"; alert_once "$CURRENT_STEP" "$*" 1; exit 1; }

# ── 探活 ──────────────────────────────────────────────
# 飞书投递已改由 Hermes agent 经 lark-mcp 完成（脚本只产出内容、不再直连飞书），此处只探数据源。
bq query --use_legacy_sql=false --format=csv 'SELECT 1' >/dev/null 2>&1 \
  || fail "bq 不可用，检查 gcloud auth 与项目设置"

TMP="$STATE/metrics-$TS"
mkdir -p "$TMP"

# ── 查询助手（全部带版本过滤；{{VERSIONS}} 的值是带引号的逗号列表，谓词写在 SQL 文件里）──
vlist() { printf '"%s"' "$1"; }   # 单版本 → "1.5.4"（多版本形式保留给未来 N>1 的合并查询）

q() { # $1=sql文件 $2=表名 $3=窗口天数 $4=版本 → CSV（无表头）
  sed -e "s|{{TABLE}}|$2|g" -e "s|{{DAYS}}|$3|g" -e "s|{{VERSIONS}}|$(vlist "$4")|g" "$SQL_DIR/$1" \
    | bq query --use_legacy_sql=false --format=csv 2>/dev/null | tail -n +2
}
qc() { # $1=sql文件 $2=crashlytics表 $3=sessions表 $4=窗口天数 $5=版本 → JSON
  # 崩溃查询用 --format=json + jq 渲染：issue 标题是自由文本可能含逗号，CSV+awk 会错列。
  sed -e "s|{{TABLE}}|$2|g" -e "s|{{SESSIONS_TABLE}}|$3|g" -e "s|{{DAYS}}|$4|g" \
      -e "s|{{VERSIONS}}|$(vlist "$5")|g" "$SQL_DIR/$1" \
    | bq query --use_legacy_sql=false --format=json 2>/dev/null
}
q1d() { # $1=sql文件 $2=表名 $3=距今天数 $4=版本 → 单行 JSON 对象（无数据 → {}）
  sed -e "s|{{TABLE}}|$2|g" -e "s|{{DAYS}}|$3|g" -e "s|{{VERSIONS}}|$(vlist "$4")|g" "$SQL_DIR/$1" \
    | bq query --use_legacy_sql=false --format=json 2>/dev/null | jq -c '.[0] // {}' 2>/dev/null || echo '{}'
}
m1() { printf '%s' "${1:-}" | jq -r --arg k "$2" '.[$k] // empty' 2>/dev/null || echo ""; }

# bq show 要 project:dataset.table（冒号），查询里用的是 project.dataset.table（全点号）——
# 只替换第一个点为冒号。踩过：直接传点号格式会永远返回「表不存在」。
# 存在性探测只认 bq 明确返回的「not found」为「不存在」；429/5xx/网络/超时等瞬时错误
# 有界重试（3 次、线性退避 2s/4s），重试耗尽仍未确证「不存在」→ 按「存在」处理（返回真），
# 让后续查询自行失败并触发既有「数据未同步」告警，而不是误回退到停更批量表。
# 注意：bq show 的「Not found」错误信息写 stdout 而非 stderr（实测），须 2>&1 合并捕获，不能只捕 stderr。
table_exists() { # $1=project.dataset.table → 0=存在 / 1=确证不存在
  local tbl="${1/./:}" attempt out
  for attempt in 1 2 3; do
    out="$(bq show --format=none "$tbl" 2>&1)" && return 0
    if printf '%s' "$out" | grep -qi 'not found'; then
      return 1
    fi
    if [ "$attempt" -lt 3 ]; then sleep "$((attempt * 2))"; fi
  done
  return 0
}
# 表最新 event_timestamp。**刻意不带版本过滤**：它服务于「表整体是否停更」的判定（data_state 第 2 态），
# 带上版本过滤会把「新版还没产生数据」误判成「数据源故障」，天天误报（design D6）。
table_max() { [ -n "$1" ] || { echo ""; return 0; }
  bq query --use_legacy_sql=false --format=csv \
    "SELECT FORMAT_TIMESTAMP('%Y-%m-%d %H:%M UTC', MAX(event_timestamp)) AS ts FROM \`$1\`" 2>/dev/null \
    | tail -n +2 | tail -1 || true; }
# 性能表「该版本最新可用单日」距今天数（1=昨日）；无数据 → 空。带版本过滤：不同版本的最新可用日不同。
perf_day_offset() { [ -n "$1" ] && [ -n "$2" ] || { echo ""; return 0; }
  bq query --use_legacy_sql=false --format=csv \
    "SELECT DATE_DIFF(CURRENT_DATE(), MAX(DATE(event_timestamp)), DAY) AS off FROM \`$1\` WHERE app_display_version = '$2'" 2>/dev/null \
    | tail -n +2 | tail -1 || true; }

# ── 三态数据判定（design D6，顺序不可颠倒）────────────────────────
# 1 表不存在 → table_missing；2 表整体窗口内无数据 → stale；3 表有数据但该版本 0 行 → no_version
data_state() { # $1=表 $2=该版本查询是否有行(非空且非0即有) $3=表整体 MAX 时间戳（已缓存，避免重复查）
  if [ -z "$1" ]; then echo table_missing; return 0; fi
  if [ -n "$2" ] && [ "$2" != "0" ]; then echo ok; return 0; fi
  [ -n "$3" ] && echo no_version || echo stale
}
# 崩溃段单独判定：有会话就有分母，「0 条致命事件」是结论本身（0 崩溃），不是缺数。
# 渲染成「该版本无数据」会让「这版没崩过」这个最该被看见的好消息消失。
crash_state() { # $1=crashlytics表 $2=表整体 MAX 时间戳
  [ -n "$1" ] || { echo table_missing; return 0; }
  [ -n "$2" ] && echo ok || echo stale
  return 0
}
state_text() { # $1=state $2=表整体最新时间戳 → 单元格文案
  case "$1" in
    ok)            printf '';;
    table_missing) printf '表未同步';;
    stale)         printf '⚠️ 数据未同步（截至 %s）' "${2:-—}";;
    no_version)    printf '— 该版本无数据';;
  esac
}

# ── 数值格式化 ────────────────────────────────────────
csv() { [ -s "$1" ] && cut -d, -f"$2" "$1" | head -1 || echo ""; }
# BigQuery 的 ROUND 返回浮点（251.0 / 0.00），卡片上要读得快就得去掉无意义小数位
int()  { [ -n "$1" ] && printf '%.0f' "$1" || echo ""; }               # 251.0 → 251
pct()  { [ -n "$1" ] && awk -v v="$1" 'BEGIN{printf (v==int(v)?"%.0f":"%.1f"), v}' || echo ""; }  # 0.00→0 · 73.5→73.5
# 崩溃率天然是千分位量级，固定两位小数（2/1017→0.20），与 pct() 的「整数去零」口径区分
rate_pct() { [ -n "$1" ] && [ -n "$2" ] && [ "$2" != "0" ] \
  && awk -v e="$1" -v s="$2" 'BEGIN{printf "%.2f", e/s*100}' || echo ""; }
daily_rate() { rate_pct "$1" "$2"; }
day_ago() { date -v-"${1:-0}"d +%Y-%m-%d 2>/dev/null; }   # BSD date（macOS）：N 天前日期

# ── 取数区间（双时区）─────────────────────────────────
# 窗口起点 = 本次跑批时刻 − N 天，因为所有滚动窗口 SQL 写的都是
#   WHERE event_timestamp >= TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL {{DAYS}} DAY)
# 即下界锚在**跑批时刻**而非数据最新时刻——直接由 shell 算出，不额外查 BigQuery。
# 终点用各表的 table_max()（实际取到的最新数据），与起点的差 = 数据滞后，缺口本身就是要看见的信息。
# 注意起点是「查询下界」不是「首条数据时间」，故措辞一律用「窗口」不用「数据自」。
RUN_EPOCH="$(date +%s)"
TZ_LABEL="$(date '+%z')"
_fmt() { if [ -n "${2:-}" ]; then TZ="$2" date -r "$1" '+%m-%d %H:%M' 2>/dev/null
         else date -r "$1" '+%m-%d %H:%M' 2>/dev/null; fi; }
# "2026-08-16 06:59 UTC" → epoch；解析失败返回空（调用方原样回退，不炸）
_until_epoch() { local s="${1:-}"; s="${s% UTC}"
  [ -n "$s" ] && [ "$s" != "—" ] || return 0
  TZ=UTC date -j -f '%Y-%m-%d %H:%M' "$s" '+%s' 2>/dev/null || true; }
# 卡片用：08-15 17:22 → 08-16 14:59 (+08) · 08-15 09:22 → 08-16 06:59 UTC
win_compact() {
  local se ue; se=$(( RUN_EPOCH - ${1:-0} * 86400 )); ue="$(_until_epoch "${2:-}")"
  [ -n "$ue" ] || { printf '%s → —' "$(_fmt "$se")"; return 0; }
  printf '%s → %s (%s) · %s → %s UTC' "$(_fmt "$se")" "$(_fmt "$ue")" \
    "${TZ_LABEL%00}" "$(_fmt "$se" UTC)" "$(_fmt "$ue" UTC)"
}
# 文档用：08-15 09:22 UTC / 08-15 17:22 +0800 → 08-16 06:59 UTC / 08-16 14:59 +0800
win_full() {
  local se ue; se=$(( RUN_EPOCH - ${1:-0} * 86400 )); ue="$(_until_epoch "${2:-}")"
  [ -n "$ue" ] || { printf '%s UTC / %s %s → —' "$(_fmt "$se" UTC)" "$(_fmt "$se")" "$TZ_LABEL"; return 0; }
  printf '%s UTC / %s %s → %s UTC / %s %s' \
    "$(_fmt "$se" UTC)" "$(_fmt "$se")" "$TZ_LABEL" \
    "$(_fmt "$ue" UTC)" "$(_fmt "$ue")" "$TZ_LABEL"
}

# 统一阈值红绿灯（R3）：>红 → red（🔴）；>黄 → yellow（🟡，待对齐）；否则 green（🟢）。
# 空值 / 「无法计算」→ 空串（不判定，避免误告警）。
traffic_light() {
  local v="$1" red="$2" yellow="$3"
  [ -n "$v" ] && [ "$v" != "无法计算" ] || { echo ""; return; }
  awk -v v="$v" -v r="$red" -v y="$yellow" 'BEGIN{ if(v>r) print "red"; else if(v>y) print "yellow"; else print "green" }'
}
cell_color() { # $1=判定值 $2=红 $3=黄 $4=单元格内容
  local t; t="$(traffic_light "$1" "$2" "$3")"
  case "$t" in
    red)    printf '<font color=red>%s</font>' "$4";;
    yellow) printf '<font color=orange>%s</font>' "$4";;
    *)      printf '%s' "$4";;
  esac
}
# 告警行：只由**最新版**触发（design D8）。$1=指标名 $2=iOS最新版值 $3=Android最新版值 $4=红 $5=黄 $6=单位
#
# 摘要行必须标版本、且区分「没超阈值」与「没算出来」：
# 卡片表格里缺数有三态（样本不足 / 该版本无数据 / 表未同步），压进摘要行就只剩一个「—」，
# 看起来像故障；再顶着 🔴 更糟——**没有数据不该告警**（2026-08-18 Sir 指出：
# 「🔴 慢帧最差页 iOS — · Android 94.6%」里 iOS 的 — 是新版样本不足，不是出事）。
# 故：有值的端标 `<版本> <值>`，无值的端降级成灰字括注，不参与红黄判定。
alert_side() { # $1=平台名 $2=版本 $3=值 $4=单位 → "iOS 1.5.4 425ms" 或 ""
  [ -n "$3" ] && [ "$3" != "无法计算" ] || { printf ''; return 0; }
  printf '%s %s %s%s' "$1" "${2:-—}" "$3" "$4"
}
# 缺数端的括注：说明为什么没有值，而不是甩一个「—」
alert_missing() { # $1=平台名 $2=版本 $3=值 → "iOS 1.5.4 无数据" 或 ""
  [ -n "$3" ] && [ "$3" != "无法计算" ] && { printf ''; return 0; }
  printf '%s %s %s' "$1" "${2:-—}" "$([ "$3" = "无法计算" ] && echo '无法计算' || echo '无数据')"
}
_alert_body() { # $1=指标名 $2=iOS版本 $3=iOS值 $4=And版本 $5=And值 $6=单位
  local si sa miss="" vals note="" sep
  si="$(alert_side iOS "$2" "$3" "$6")"; sa="$(alert_side Android "$4" "$5" "$6")"
  for m in "$(alert_missing iOS "$2" "$3")" "$(alert_missing Android "$4" "$5")"; do
    [ -n "$m" ] || continue
    if [ -n "$miss" ]; then miss="$miss · $m"; else miss="$m"; fi
  done
  sep=""; { [ -n "$si" ] && [ -n "$sa" ]; } && sep=" · "
  vals="${si}${sep}${sa}"
  # 全角括号与 · 一律用条件赋值拼接，不写 ${var:+（...）}：
  # 多字节字符紧跟变量展开时，bash 在 set -u 下会把后续字节并进变量名（实测 "miss?: unbound variable"）
  [ -n "$miss" ] && note="（${miss}）"
  printf '%s %s%s' "$1" "$vals" "$note"
}
red_line() {
  local li la
  li="$(traffic_light "$2" "$4" "$5")"; la="$(traffic_light "$3" "$4" "$5")"
  if [ "$li" = "red" ] || [ "$la" = "red" ]; then
    printf '🔴 %s' "$(_alert_body "$1" "${IOS_V1:-—}" "$2" "${AND_V1:-—}" "$3" "$6")"
  fi
}
yellow_line() {
  local li la
  li="$(traffic_light "$2" "$4" "$5")"; la="$(traffic_light "$3" "$4" "$5")"
  { [ "$li" = "red" ] || [ "$la" = "red" ]; } && return 0
  if [ "$li" = "yellow" ] || [ "$la" = "yellow" ]; then
    printf '🟡 %s' "$(_alert_body "$1" "${IOS_V1:-—}" "$2" "${AND_V1:-—}" "$3" "$6")"
  fi
}
# 非空才追加（避免空行）；恒返回 0（否则 set -e 在空输入时误炸）
ALERTS=""
add_alert() { [ -n "$1" ] && ALERTS="${ALERTS:+$ALERTS
}$1"; return 0; }

# ── 版本间对比（本次核心可读性诉求）────────────────────────────────
# 「最新版 − 上一版」。方向沿用仓库约定：数值变大 = 变差 = ↑（会话数除外，放量越多越好）。
# 任一端缺数据 → 「—」，绝不拿 0 顶替（0 和「没数据」在这里是完全不同的结论）。
delta_cell() { # $1=最新版值 $2=上一版值 $3=单位(pp|ms|n) $4=方向(lower_better|higher_better|neutral)
  local unit="${3:-n}" dir="${4:-lower_better}" txt worse arrow
  { [ -n "$1" ] && [ -n "$2" ] && [ "$1" != "无法计算" ] && [ "$2" != "无法计算" ]; } || { printf '—'; return 0; }
  txt="$(awk -v c="$1" -v o="$2" -v u="$unit" 'BEGIN{
    d=c-o; sign=(d>0)?"+":"";
    if(u=="ms")      printf "%s%dms", sign, d;
    else if(u=="pp") printf "%s%.2fpp", sign, d;
    else             printf "%s%g", sign, d;
  }')"
  # neutral：只给方向不判好坏（放量进度这类指标，红绿会暗示「新版会话少 = 出问题了」，并不成立）
  worse="$(awk -v c="$1" -v o="$2" -v dir="$dir" 'BEGIN{
    d=c-o;
    if(d==0 || dir=="neutral"){print "flat"}
    else if(dir=="higher_better"){ print (d>0)?"better":"worse" }
    else { print (d>0)?"worse":"better" }
  }')"
  # 箭头跟**数值方向**（涨=↑），颜色跟**好坏**（红=变差）——两者分开表达；
  # 合并会让「会话数 -51」这类「越大越好」的指标渲染成「-51 ↑」，读起来自相矛盾。
  arrow="$(awk -v c="$1" -v o="$2" 'BEGIN{ d=c-o; print (d>0)?"↑":(d<0)?"↓":"" }')"
  [ -n "$arrow" ] && txt="$txt $arrow"
  case "$worse" in
    worse)  printf '<font color=red>%s</font>' "$txt";;
    better) printf '<font color=green>%s</font>' "$txt";;
    *)      printf '%s' "$txt";;
  esac
}

# 环比 DoD/WoW（同版本，进日报文档；卡片只出版本间对比，见 design D7）
_dod_wow() { # $1=今日值 $2=昨日值 $3=D-7值 $4=单位(pp|ms) $5=日期标注(可空)
  local d="" w="" lbl="${5:-}"
  [ -n "$1" ] || { echo ""; return; }
  if [ -n "$2" ]; then
    d="DoD $(awk -v c="$1" -v o="$2" -v m="$4" 'BEGIN{d=c-o; a=(d>0)?"↑":(d<0)?"↓":""; s=(a=="")?"":" "; sign=(d>0)?"+":""; if(m=="ms") printf "%s%dms%s%s", sign, d, s, a; else printf "%s%.2fpp%s%s", sign, d, s, a}')${lbl}"
  else d="DoD 无基准"; fi
  if [ -n "$3" ]; then
    w="WoW $(awk -v c="$1" -v o="$3" -v m="$4" 'BEGIN{d=c-o; a=(d>0)?"↑":(d<0)?"↓":""; s=(a=="")?"":" "; sign=(d>0)?"+":""; if(m=="ms") printf "%s%dms%s%s", sign, d, s, a; else printf "%s%.2fpp%s%s", sign, d, s, a}')"
  else w="WoW 无基准"; fi
  if [ -z "$2" ] && [ -z "$3" ]; then echo ""; else printf '%s · %s' "$d" "$w"; fi
}
# 两端都无基准时 _dod_wow 返回空串（既有约定：不硬算）；文档里要落成「无基准」而不是空行。
dod_wow_pct() { local r; r="$(_dod_wow "$1" "$2" "$3" pp "${4:-}")"; printf '%s' "${r:-无基准}"; }
dod_wow_ms()  { local r; r="$(_dod_wow "$1" "$2" "$3" ms "${4:-}")"; printf '%s' "${r:-无基准}"; }

# 7 日 sparkline：min-max 归一化映射 ▁▂▃▄▅▆▇█（全相等渲染平线 ▄）。
# 冷启动/版本首次出现时历史不足按已有天数渲染，不空值补齐。
sparkline() {
  local seq="$1" out="" idx ch
  [ -n "$seq" ] || { echo ""; return; }
  while IFS= read -r idx; do
    [ -n "$idx" ] || continue
    case "$idx" in 1) ch="▁";; 2) ch="▂";; 3) ch="▃";; 4) ch="▄";; 5) ch="▅";; 6) ch="▆";; 7) ch="▇";; 8) ch="█";; *) ch="";; esac
    out="$out$ch"
  done < <(printf '%s\n' "$seq" | awk '
    { v[NR]=$1 }
    END {
      n=NR; if(n==0) exit
      min=v[1]; max=v[1]
      for(i=1;i<=n;i++){ if(v[i]<min)min=v[i]; if(v[i]>max)max=v[i] }
      for(i=1;i<=n;i++){
        if(max==min) idx=4
        else idx=int((v[i]-min)/(max-min)*7)+1
        if(idx<1)idx=1; if(idx>8)idx=8
        print idx
      }
    }')
  printf '%s' "$out"
}

# ── 数据源表选择 ──────────────────────────────────────
IOS_PERF_TBL="$PROJECT.firebase_performance.com_prime_dino_english_IOS"
AND_PERF_TBL="$PROJECT.firebase_performance.com_prime_dino_english_ANDROID"
IOS_CRASH_TBL="$PROJECT.firebase_crashlytics.com_prime_dino_english_IOS_REALTIME"
AND_CRASH_TBL="$PROJECT.firebase_crashlytics.com_prime_dino_english_ANDROID_REALTIME"
# sessions 优先 REALTIME 活表（批量表 2026-08-11 起停更，REALTIME 才是活源，schema 一致）；缺失回退批量表并标注（D1）。
SESS_IOS_RT="$PROJECT.firebase_sessions.com_prime_dino_english_IOS_REALTIME"
SESS_IOS_BATCH="$PROJECT.firebase_sessions.com_prime_dino_english_IOS"
SESS_AND_RT="$PROJECT.firebase_sessions.com_prime_dino_english_ANDROID_REALTIME"
SESS_AND_BATCH="$PROJECT.firebase_sessions.com_prime_dino_english_ANDROID"

echo "--- 选表 ---"
SESS_IOS_FALLBACK=0
if table_exists "$SESS_IOS_RT"; then SESS_IOS="$SESS_IOS_RT";
elif table_exists "$SESS_IOS_BATCH"; then SESS_IOS="$SESS_IOS_BATCH"; SESS_IOS_FALLBACK=1;
else SESS_IOS=""; fi
SESS_AND_FALLBACK=0
if table_exists "$SESS_AND_RT"; then SESS_AND="$SESS_AND_RT";
elif table_exists "$SESS_AND_BATCH"; then SESS_AND="$SESS_AND_BATCH"; SESS_AND_FALLBACK=1;
else SESS_AND=""; fi
table_exists "$IOS_CRASH_TBL" || IOS_CRASH_TBL=""
table_exists "$AND_CRASH_TBL" || AND_CRASH_TBL=""
table_exists "$IOS_PERF_TBL"  || IOS_PERF_TBL=""
table_exists "$AND_PERF_TBL"  || AND_PERF_TBL=""

# 表整体最新时间戳（不带版本过滤）：data_state 第 2 态判定 + 各段截止时间戳，每表只查一次
IOS_CRASH_MAX="$(table_max "$IOS_CRASH_TBL")"; AND_CRASH_MAX="$(table_max "$AND_CRASH_TBL")"
IOS_PERF_MAX="$(table_max "$IOS_PERF_TBL")";   AND_PERF_MAX="$(table_max "$AND_PERF_TBL")"
IOS_SESS_MAX="$(table_max "$SESS_IOS")";       AND_SESS_MAX="$(table_max "$SESS_AND")"
newest_ts() { printf '%s\n%s\n' "$1" "$2" | grep -v '^$' | sort -r | head -1 || true; }
CRASH_UNTIL="$(newest_ts "$IOS_CRASH_MAX" "$AND_CRASH_MAX")"; [ -n "$CRASH_UNTIL" ] || CRASH_UNTIL="—"
DATA_UNTIL="$(newest_ts "$IOS_PERF_MAX" "$AND_PERF_MAX")";    [ -n "$DATA_UNTIL" ]  || DATA_UNTIL="—"
ADOPTION_UNTIL="$(newest_ts "$IOS_SESS_MAX" "$AND_SESS_MAX")"; [ -n "$ADOPTION_UNTIL" ] || ADOPTION_UNTIL="—"

# ── 版本解析（唯一源 = sessions 活表，design D1）────────────────────
echo "--- 解析版本清单 ---"
resolve_versions() { # $1=sessions表 → CSV「version,sessions,devices」（无表头，未排序）
  [ -n "$1" ] || return 0
  sed -e "s|{{TABLE}}|$1|g" -e "s|{{DAYS}}|$DAYS|g" -e "s|{{MIN_SESSIONS}}|$MIN_SESSIONS|g" \
    "$SQL_DIR/latest-versions.sql" | bq query --use_legacy_sql=false --format=csv 2>/dev/null | tail -n +2 || true
}
# 最新 N 个版本（新→旧）。版本号语义排序交给 sort -V（BigQuery 无原生支持，design D3）。
pick_newest() { printf '%s\n' "$1" | grep -v '^$' | cut -d, -f1 | sort -rV -u | head -"$2" || true; }
# 会话量 top2（主力版本）。与「最新 N 版」不重合时补列，避免大盘版本从日报消失（design D11）。
pick_top_sessions() { printf '%s\n' "$1" | grep -v '^$' | sort -t, -k2,2 -nr | head -2 | cut -d, -f1 || true; }
# 列集合 = 最新 N 版 ∪ 主力 2 版，按版本号新→旧，上限 MAX_VERSION_COLS
union_versions() { printf '%s\n%s\n' "$1" "$2" | grep -v '^$' | sort -rV -u | head -"$MAX_VERSION_COLS" || true; }
# 某版本在 CSV 里的会话数 / 设备数
ver_field() { printf '%s\n' "$1" | grep -v '^$' | awk -F, -v v="$2" -v f="$3" '$1==v{print $f; exit}' || true; }

IOS_VER_CSV="$(resolve_versions "$SESS_IOS")"
AND_VER_CSV="$(resolve_versions "$SESS_AND")"
IOS_NEWEST="$(pick_newest "$IOS_VER_CSV" "$VERSION_COUNT")"
AND_NEWEST="$(pick_newest "$AND_VER_CSV" "$VERSION_COUNT")"
IOS_TOPSESS="$(pick_top_sessions "$IOS_VER_CSV")"
AND_TOPSESS="$(pick_top_sessions "$AND_VER_CSV")"
IOS_COLS="$(union_versions "$IOS_NEWEST" "$IOS_TOPSESS")"
AND_COLS="$(union_versions "$AND_NEWEST" "$AND_TOPSESS")"
# 最新版 / 上一版（告警与版本间对比的两端）
IOS_V1="$(printf '%s\n' "$IOS_NEWEST" | sed -n 1p)"; IOS_V2="$(printf '%s\n' "$IOS_NEWEST" | sed -n 2p)"
AND_V1="$(printf '%s\n' "$AND_NEWEST" | sed -n 1p)"; AND_V2="$(printf '%s\n' "$AND_NEWEST" | sed -n 2p)"
echo "  iOS     最新 $VERSION_COUNT 版：$(printf '%s' "$IOS_NEWEST" | tr '\n' ' ')· 主力：$(printf '%s' "$IOS_TOPSESS" | tr '\n' ' ')· 列：$(printf '%s' "$IOS_COLS" | tr '\n' ' ')"
echo "  Android 最新 $VERSION_COUNT 版：$(printf '%s' "$AND_NEWEST" | tr '\n' ' ')· 主力：$(printf '%s' "$AND_TOPSESS" | tr '\n' ' ')· 列：$(printf '%s' "$AND_COLS" | tr '\n' ' ')"
# 版本解析失败不静默回退全版本（那等于偷偷改口径）：显式标记，各段渲染成「版本解析失败」。
IOS_VER_OK=1; [ -n "$IOS_V1" ] || IOS_VER_OK=0
AND_VER_OK=1; [ -n "$AND_V1" ] || AND_VER_OK=0
[ "$IOS_VER_OK" = 1 ] || echo "  ⚠️ iOS 版本解析失败（sessions 表无满足 >=${MIN_SESSIONS} 会话的版本）"
[ "$AND_VER_OK" = 1 ] || echo "  ⚠️ Android 版本解析失败（sessions 表无满足 >=${MIN_SESSIONS} 会话的版本）"

# ── 逐版本取数（design D5：每版本各跑一次查询，不做 GROUP BY version）──
# 产出 $TMP/m-<plat>-<ver>.json（卡片/文档共用）与三份明细 CSV（文档明细段用）。
collect_window() { # $1=plat键 $2=版本 $3=crash表 $4=sess表 $5=perf表 $6=crashMax $7=perfMax $8=版本CSV
  local p="$1" v="$2" key="$1-$2"
  local issues='[]' rate='[]' n=0 ev=0 latest="" cev="" sess="" aff="" rp="" rfrac="" cstate
  local traces="$TMP/traces-$key.csv" screens="$TMP/screens-$key.csv" net="$TMP/net-$key.csv"
  local p50="" p95="" wscreen="" wslow="" frozen="" neterr="" pstate prows=0
  local vsess vdev

  # 崩溃
  if [ -n "$3" ]; then
    issues="$(qc crash-issues.sql "$3" "" "$CRASH_DAYS" "$v")" || issues='[]'
    [ -n "$issues" ] || issues='[]'
    rate="$(qc crash-rate.sql "$3" "$4" "$CRASH_DAYS" "$v")" || rate='[]'
    [ -n "$rate" ] || rate='[]'
  fi
  printf '%s' "$issues" > "$TMP/issues-$key.json"
  n="$(printf '%s' "$issues"  | jq 'length' 2>/dev/null || echo 0)"
  ev="$(printf '%s' "$issues" | jq '[.[].n | tonumber] | add // 0' 2>/dev/null || echo 0)"
  latest="$(printf '%s' "$issues" | jq -r '[.[].latest] | max // ""' 2>/dev/null || echo "")"
  cev="$(printf '%s' "$rate" | jq -r '(.[0].crash_events // empty) | tostring' 2>/dev/null || echo "")"
  sess="$(printf '%s' "$rate" | jq -r '(.[0].sessions // empty) | tostring' 2>/dev/null || echo "")"
  aff="$(printf '%s' "$rate" | jq -r '(.[0].affected_installs // empty) | tostring' 2>/dev/null || echo "")"
  rp="$(rate_pct "$cev" "$sess")"
  [ -n "$rp" ] && rfrac="$cev/$sess"
  cstate="$(crash_state "$3" "$6")"

  # 性能
  : > "$traces"; : > "$screens"; : > "$net"
  if [ -n "$5" ]; then
    q perf-traces.sql  "$5" "$PERF_DAYS" "$v" > "$traces"  || true
    q perf-screens.sql "$5" "$PERF_DAYS" "$v" > "$screens" || true
    q perf-network.sql "$5" "$PERF_DAYS" "$v" > "$net"     || true
  fi
  prows=$(( $(wc -l < "$traces") + $(wc -l < "$screens") + $(wc -l < "$net") ))
  p50="$(int "$(grep '^_app_start,' "$traces" 2>/dev/null | cut -d, -f3 | head -1)")"
  p95="$(int "$(grep '^_app_start,' "$traces" 2>/dev/null | cut -d, -f4 | head -1)")"
  wscreen="$(csv "$screens" 1)"
  wslow="$(pct "$(csv "$screens" 3)")"
  # 冻结率取「最差慢帧页」同一行的冻结率（沿用既有口径，仅在标签上明确写出「最差页」）
  frozen="$(pct "$(csv "$screens" 4)")"
  neterr="$([ -s "$net" ] && awk -F, '{e+=$5; n+=$2} END{if(n>0) printf "%.2f", e/n*100}' "$net" || echo "")"
  neterr="$(pct "$neterr")"
  pstate="$(data_state "$5" "$prows" "$7")"

  vsess="$(ver_field "$8" "$v" 2)"
  vdev="$(ver_field "$8" "$v" 3)"

  jq -n --arg v "$v" --arg cstate "$cstate" --arg pstate "$pstate" \
    --arg n "$n" --arg ev "$ev" --arg latest "$latest" --arg aff "$aff" \
    --arg cev "$cev" --arg csess "$sess" --arg rp "$rp" --arg rfrac "$rfrac" \
    --arg p50 "$p50" --arg p95 "$p95" --arg wscreen "$wscreen" --arg wslow "$wslow" \
    --arg frozen "$frozen" --arg neterr "$neterr" --arg vsess "$vsess" --arg vdev "$vdev" \
    '{version:$v,
      crash:{state:$cstate, n:$n, events:$ev, latest:$latest, affected:$aff,
             crash_events:$cev, sessions:$csess, rate_pct:$rp, rate_frac:$rfrac},
      perf:{state:$pstate, p50:$p50, p95:$p95, worst_screen:$wscreen, worst_slow:$wslow,
            frozen:$frozen, net_err:$neterr},
      adopt:{sessions:$vsess, devices:$vdev}}' > "$TMP/m-$key.json"
}

# 取值助手：$1=plat $2=版本 $3=jq 路径（如 crash.rate_pct）
mv_() { local f="$TMP/m-$1-$2.json"; [ -s "$f" ] || { echo ""; return 0; }
  jq -r --arg p "$3" 'getpath($p | split(".")) // "" | tostring' "$f" 2>/dev/null || echo ""; }

echo "--- 逐版本取数（窗口值）---"
for v in $IOS_COLS; do
  echo "  iOS $v"
  collect_window ios "$v" "$IOS_CRASH_TBL" "$SESS_IOS" "$IOS_PERF_TBL" "$IOS_CRASH_MAX" "$IOS_PERF_MAX" "$IOS_VER_CSV"
done
for v in $AND_COLS; do
  echo "  Android $v"
  collect_window and "$v" "$AND_CRASH_TBL" "$SESS_AND" "$AND_PERF_TBL" "$AND_CRASH_MAX" "$AND_PERF_MAX" "$AND_VER_CSV"
done

# ── 天级单日值：只跟踪最新 N 版（主力补充列不进 1d/历史，design D11 成本控制）──
echo "--- 天级单日值（DoD/WoW 基准，仅最新 $VERSION_COUNT 版）---"
collect_1d() { # $1=plat键 $2=版本 $3=crash表 $4=sess表 $5=perf表
  local p="$1" v="$2" key="$1-$2" c1d='{}' s1d='{}' pf='{}' pfp='{}' off pday pprev
  [ -n "$3" ] && c1d="$(q1d daily-crash-1d.sql    "$3" 1 "$v")" || true
  [ -n "$4" ] && s1d="$(q1d daily-sessions-1d.sql "$4" 1 "$v")" || true
  # 性能批量表滞后 ~2 天且各版本滞后不同：按「该版本最新可用单日」及其前一日取值，并记录实际日期（D7）
  off="$(perf_day_offset "$5" "$v")"; off="${off:-1}"
  case "$off" in ''|*[!0-9]*) off=1;; esac
  if [ -n "$5" ]; then
    pf="$(q1d  daily-perf-1d.sql "$5" "$off" "$v")" || true
    pfp="$(q1d daily-perf-1d.sql "$5" "$((off + 1))" "$v")" || true
  fi
  pday="$(day_ago "$off")"; pprev="$(day_ago "$((off + 1))")"
  [ -n "$c1d" ] || c1d='{}'; [ -n "$s1d" ] || s1d='{}'
  [ -n "$pf" ]  || pf='{}';  [ -n "$pfp" ] || pfp='{}'
  jq -n --argjson c "$c1d" --argjson s "$s1d" \
        --argjson p "$pf" --argjson pp "$pfp" \
        --arg pday "$pday" --arg pprev "$pprev" \
    '{crash_events_1d:($c.crash_events_1d // null), affected_installs_1d:($c.affected_installs_1d // null),
      sessions_1d:($s.sessions_1d // null),
      start_p50_1d:($p.start_p50_1d // null), start_p95_1d:($p.start_p95_1d // null),
      slow_pct_1d:($p.slow_pct_1d // null), frozen_pct_1d:($p.frozen_pct_1d // null),
      net_err_pct_1d:($p.net_err_pct_1d // null),
      prev:{start_p50_1d:($pp.start_p50_1d // null), start_p95_1d:($pp.start_p95_1d // null),
            slow_pct_1d:($pp.slow_pct_1d // null), frozen_pct_1d:($pp.frozen_pct_1d // null),
            net_err_pct_1d:($pp.net_err_pct_1d // null)},
      perf_day:$pday, perf_prev_day:$pprev}' > "$TMP/d-$key.json"
}
for v in $IOS_NEWEST; do collect_1d ios "$v" "$IOS_CRASH_TBL" "$SESS_IOS" "$IOS_PERF_TBL"; done
for v in $AND_NEWEST; do collect_1d and "$v" "$AND_CRASH_TBL" "$SESS_AND" "$AND_PERF_TBL"; done
dv_() { local f="$TMP/d-$1-$2.json"; [ -s "$f" ] || { echo ""; return 0; }
  jq -r --arg p "$3" '(getpath($p | split(".")) // "") | tostring | select(. != "null")' "$f" 2>/dev/null || echo ""; }

# ── 历史基准（按版本存储；旧口径行自愈丢弃，design D9）──────────────
HISTORY="$STATE/metrics-history.jsonl"
# 保留 90 天而非 7 天：环比只需要昨日与 D-7，但月度回顾、拉长 sparkline 都需要更长的序列，
# 而 90 行 JSONL 也就 25KB——为省这点体积把历史砍掉不划算。
HISTORY_KEEP="${CRASH_REPORT_HISTORY_KEEP:-90}"
SPARK_DAYS="${CRASH_REPORT_SPARK_DAYS:-7}"   # sparkline 只取最近 N 天，别把 90 个方块画出来
YESTERDAY="$(day_ago 1)"; D7="$(day_ago 7)"
HIST_ARR='[]'
if [ -f "$HISTORY" ]; then
  TOTAL_LINES=$(grep -c '' "$HISTORY" 2>/dev/null || echo 0)
  HIST_ARR="$(jq -s '[.[] | select(has("versions"))]' "$HISTORY" 2>/dev/null || echo '[]')"
  KEPT="$(printf '%s' "$HIST_ARR" | jq 'length' 2>/dev/null || echo 0)"
  if [ "$TOTAL_LINES" -gt "$KEPT" ]; then
    echo "  ⚠️ 丢弃 $((TOTAL_LINES - KEPT)) 行旧口径历史（全版本 → 版本级），环比基准重建中"
  fi
fi
# 同版本同指标取历史值：$1=日期 $2=plat $3=版本 $4=字段
hist_val() { jq -r --arg d "$1" --arg p "$2" --arg v "$3" --arg k "$4" \
  '.[] | select(.day == $d) | .[$p][$v][$k] // empty' <<<"$HIST_ARR" 2>/dev/null | head -1 || true; }
# sparkline 序列（按文件顺序旧→新，同版本）
spark_hist() { jq -r --arg p "$1" --arg v "$2" --arg k "$3" --argjson n "$SPARK_DAYS" \
  '.[-$n:][] | .[$p][$v][$k] // empty' <<<"$HIST_ARR" 2>/dev/null || true; }
spark_rate() { jq -r --arg p "$1" --arg v "$2" --argjson n "$SPARK_DAYS" \
  '.[-$n:][] | [.[$p][$v].crash_events_1d // "", .[$p][$v].sessions_1d // ""] | @tsv' <<<"$HIST_ARR" 2>/dev/null \
  | awk -F'\t' '{ if($1!="" && $2!="" && $2!=0) printf "%.2f\n", $1/$2*100 }' || true; }

# ── MCP 对照/回退（全版本口径，与卡片不可比）─────────
# fetch-snapshot.sh light 模式抓 MCP topIssues（OPEN FATAL）+ git 反查，产出 snapshot.json。
# 它不驱动卡片任何数字（已由 BigQuery 版本级接管），只用于：
#   ① 索引页「跟踪中的 issue」与 fix_commit 修复状态反查；② 新增/已修待验告警（全版本口径，已在文案标注）。
echo "--- 抓取 MCP 崩溃对照数据（全版本口径）---"
CRASH_DIR="$STATE/crash-daily-$TS"
CRASH_JSON="$CRASH_DIR/snapshot.json"
if [ -f "$ROOT/bin/lib.sh" ]; then
  # shellcheck disable=SC1091
  . "$ROOT/bin/lib.sh"
else
  run_with_timeout() { local s="$1"; shift; "$@"; }   # 隔离部署/测试环境无 lib.sh 时退化为直接执行
fi
FETCH_TIMEOUT="${FETCH_TIMEOUT:-600}"   # light 模式只取数，10 分钟足够
MCP_OK=0
if [ -x "$ROOT/bin/fetch-snapshot.sh" ] \
   && run_with_timeout "$FETCH_TIMEOUT" "$ROOT/bin/fetch-snapshot.sh" "$CRASH_DIR" 2>/dev/null \
   && [ -s "$CRASH_JSON" ]; then
  MCP_OK=1
  echo "  MCP 对照（OPEN FATAL · 全版本）：iOS $(jq -r '(.ios//[])|length' "$CRASH_JSON") 类 $(jq -r '[(.ios//[])[].events]|add//0' "$CRASH_JSON") 次 · Android $(jq -r '(.android//[])|length' "$CRASH_JSON") 类 $(jq -r '[(.android//[])[].events]|add//0' "$CRASH_JSON") 次"
else
  echo "  ⚠️ MCP 对照数据抓取失败（不影响卡片主口径；索引页「跟踪中的 issue」本轮缺失）"
fi

# ── 异常判定（只由最新版触发，design D8）──────────────
SNAP="$STATE/daily-snapshot.json"
IOS_RATE_PCT="$(mv_ ios "$IOS_V1" crash.rate_pct)"; AND_RATE_PCT="$(mv_ and "$AND_V1" crash.rate_pct)"
IOS_SLOW_V1="$(mv_ ios "$IOS_V1" perf.worst_slow)"; AND_SLOW_V1="$(mv_ and "$AND_V1" perf.worst_slow)"
IOS_FROZEN_V1="$(mv_ ios "$IOS_V1" perf.frozen)";   AND_FROZEN_V1="$(mv_ and "$AND_V1" perf.frozen)"
IOS_P95_V1="$(mv_ ios "$IOS_V1" perf.p95)";         AND_P95_V1="$(mv_ and "$AND_V1" perf.p95)"
IOS_NETERR_V1="$(mv_ ios "$IOS_V1" perf.net_err)";  AND_NETERR_V1="$(mv_ and "$AND_V1" perf.net_err)"

if [ "$MCP_OK" = 1 ] && [ -f "$SNAP" ]; then
  NEW_IOS="$(jq -r --slurpfile s "$SNAP" '[(.ios // [])[] | select(.id as $i | ($s[0].ios_ids // []) | index($i) | not)] | length' "$CRASH_JSON" 2>/dev/null || echo 0)"
  NEW_AND="$(jq -r --slurpfile s "$SNAP" '[(.android // [])[] | select(.id as $i | ($s[0].android_ids // []) | index($i) | not)] | length' "$CRASH_JSON" 2>/dev/null || echo 0)"
  [ "${NEW_IOS:-0}" -gt 0 ] 2>/dev/null && add_alert "🔴 iOS 新增 ${NEW_IOS} 个 issue（全版本口径）"
  [ "${NEW_AND:-0}" -gt 0 ] 2>/dev/null && add_alert "🔴 Android 新增 ${NEW_AND} 个 issue（全版本口径）"
fi
# 代码已修但未发版：最容易被遗忘的状态，必须顶到卡片上。
# 只统计 iOS：Android 无 issue ID 约定，fix_commit 恒 null，计进来无意义。
if [ "$MCP_OK" = 1 ]; then
  FIXED_PENDING="$(jq -r '[(.ios // [])[] | select(.fix_commit != null)] | length' "$CRASH_JSON" 2>/dev/null || echo 0)"
  [ "${FIXED_PENDING:-0}" -gt 0 ] 2>/dev/null && add_alert "🔴 ${FIXED_PENDING} 个 issue 代码已修但未发版（全版本口径）"
fi
add_alert "$(red_line "崩溃率" "$IOS_RATE_PCT" "$AND_RATE_PCT" "$CRASH_RATE_RED" "$CRASH_RATE_YELLOW" "%")"
add_alert "$(red_line "慢帧最差页" "$IOS_SLOW_V1" "$AND_SLOW_V1" "$SLOW_FRAME_RED" "$SLOW_FRAME_YELLOW" "%")"
add_alert "$(red_line "冻结率" "$IOS_FROZEN_V1" "$AND_FROZEN_V1" "$FROZEN_RED" "$FROZEN_YELLOW" "%")"
add_alert "$(red_line "启动 P95" "$IOS_P95_V1" "$AND_P95_V1" "$START_P95_RED" "$START_P95_YELLOW" "ms")"
add_alert "$(red_line "接口错误率" "$IOS_NETERR_V1" "$AND_NETERR_V1" "$NET_ERR_RED" "$NET_ERR_YELLOW" "%")"

SUMMARY_MD="$ALERTS"
add_summary() { [ -n "$1" ] && SUMMARY_MD="${SUMMARY_MD:+$SUMMARY_MD
}$1"; return 0; }
add_summary "$(yellow_line "崩溃率" "$IOS_RATE_PCT" "$AND_RATE_PCT" "$CRASH_RATE_RED" "$CRASH_RATE_YELLOW" "%")"
add_summary "$(yellow_line "慢帧最差页" "$IOS_SLOW_V1" "$AND_SLOW_V1" "$SLOW_FRAME_RED" "$SLOW_FRAME_YELLOW" "%")"
add_summary "$(yellow_line "冻结率" "$IOS_FROZEN_V1" "$AND_FROZEN_V1" "$FROZEN_RED" "$FROZEN_YELLOW" "%")"
add_summary "$(yellow_line "启动 P95" "$IOS_P95_V1" "$AND_P95_V1" "$START_P95_RED" "$START_P95_YELLOW" "ms")"
add_summary "$(yellow_line "接口错误率" "$IOS_NETERR_V1" "$AND_NETERR_V1" "$NET_ERR_RED" "$NET_ERR_YELLOW" "%")"
STATUS_MD="$SUMMARY_MD"; [ -z "$STATUS_MD" ] && STATUS_MD="✅ 无异常"

# ── 单元格渲染 ────────────────────────────────────────
# 版本列头角标：最新 N 版标「最新」，会话量 top2 标「主力」，两者兼具标「最新·主力」
# 角标只在「最新 N 版」与「会话量 top2」不重合时才有意义——重合时每列都标「最新」纯属噪音。
ver_tag() { # $1=版本 $2=最新版本列表 $3=主力版本列表
  local isnew=0 istop=0
  # 两个集合完全一致 → 不标
  [ "$(printf '%s\n' "$2" | sort)" = "$(printf '%s\n' "$3" | sort)" ] && { printf ''; return 0; }
  printf '%s\n' "$2" | grep -qx "$1" && isnew=1
  printf '%s\n' "$3" | grep -qx "$1" && istop=1
  if [ "$isnew" = 1 ] && [ "$istop" = 1 ]; then printf '最新·主力'
  elif [ "$isnew" = 1 ]; then printf '最新'
  elif [ "$istop" = 1 ]; then printf '主力'
  fi
}
# 小样本提示（版本级，取代原平台级口径）
sample_note() { # $1=plat $2=版本
  local s; s="$(mv_ "$1" "$2" adopt.sessions)"
  [ -n "$s" ] || { printf ''; return 0; }
  [ "$(awk -v a="$s" -v b="$SAMPLE_SESSION_MIN" 'BEGIN{print (a<b)}')" = "1" ] && printf ' ⚠️ 样本小'
  return 0
}
cell() { # $1=plat $2=版本 $3=行键
  local st val
  case "$3" in
    crash_count|crash_rate|crash_affected) st="$(mv_ "$1" "$2" crash.state)";;
    sessions) st=ok;;
    *) st="$(mv_ "$1" "$2" perf.state)";;
  esac
  if [ "$st" != "ok" ]; then
    case "$3" in
      crash_count|crash_rate|crash_affected) printf '%s' "$(state_text "$st" "$([ "$1" = ios ] && echo "$IOS_CRASH_MAX" || echo "$AND_CRASH_MAX")")";;
      sessions) printf '—';;
      *) printf '%s' "$(state_text "$st" "$([ "$1" = ios ] && echo "$IOS_PERF_MAX" || echo "$AND_PERF_MAX")")";;
    esac
    return 0
  fi
  case "$3" in
    crash_count)    printf '%s 类 %s 次' "$(mv_ "$1" "$2" crash.n)" "$(mv_ "$1" "$2" crash.events)";;
    crash_rate)     val="$(mv_ "$1" "$2" crash.rate_pct)"
                    if [ -z "$val" ]; then printf '无法计算'
                    else printf '%s%s' "$(cell_color "$val" "$CRASH_RATE_RED" "$CRASH_RATE_YELLOW" "$val% ($(mv_ "$1" "$2" crash.rate_frac))")" "$(sample_note "$1" "$2")"; fi;;
    crash_affected) printf '%s' "$(mv_ "$1" "$2" crash.affected)";;
    start_p50)      val="$(mv_ "$1" "$2" perf.p50)"; [ -n "$val" ] && printf '%sms' "$val" || printf -- '— 样本不足';;
    start_p95)      val="$(mv_ "$1" "$2" perf.p95)"
                    [ -n "$val" ] && cell_color "$val" "$START_P95_RED" "$START_P95_YELLOW" "${val}ms" || printf -- '— 样本不足';;
    slow_worst)     val="$(mv_ "$1" "$2" perf.worst_slow)"
                    [ -n "$val" ] && cell_color "$val" "$SLOW_FRAME_RED" "$SLOW_FRAME_YELLOW" "$(mv_ "$1" "$2" perf.worst_screen) ${val}%" || printf -- '— 样本不足';;
    frozen)         val="$(mv_ "$1" "$2" perf.frozen)"
                    [ -n "$val" ] && cell_color "$val" "$FROZEN_RED" "$FROZEN_YELLOW" "${val}%" || printf -- '— 样本不足';;
    net_err)        val="$(mv_ "$1" "$2" perf.net_err)"
                    [ -n "$val" ] && cell_color "$val" "$NET_ERR_RED" "$NET_ERR_YELLOW" "${val}%" || printf -- '— 样本不足';;
    sessions)       val="$(mv_ "$1" "$2" adopt.sessions)"
                    [ -n "$val" ] && printf '%s（%s 设备）' "$val" "$(mv_ "$1" "$2" adopt.devices)" || printf '—';;
  esac
  return 0
}
# 版本间对比列：最新版 vs 上一版
delta_of() { # $1=plat $2=V1 $3=V2 $4=行键
  local s1 s2
  [ -n "$3" ] || { printf '—'; return 0; }
  case "$4" in
    crash_count)    delta_cell "$(mv_ "$1" "$2" crash.events)"   "$(mv_ "$1" "$3" crash.events)"   n  lower_better;;
    crash_rate)     delta_cell "$(mv_ "$1" "$2" crash.rate_pct)" "$(mv_ "$1" "$3" crash.rate_pct)" pp lower_better;;
    crash_affected) delta_cell "$(mv_ "$1" "$2" crash.affected)" "$(mv_ "$1" "$3" crash.affected)" n  lower_better;;
    start_p50)      delta_cell "$(mv_ "$1" "$2" perf.p50)"       "$(mv_ "$1" "$3" perf.p50)"       ms lower_better;;
    start_p95)      delta_cell "$(mv_ "$1" "$2" perf.p95)"       "$(mv_ "$1" "$3" perf.p95)"       ms lower_better;;
    slow_worst)     # 两版「最差页」未必是同一个页面，直接比百分比会误导，标出来
                    s1="$(mv_ "$1" "$2" perf.worst_screen)"; s2="$(mv_ "$1" "$3" perf.worst_screen)"
                    printf '%s' "$(delta_cell "$(mv_ "$1" "$2" perf.worst_slow)" "$(mv_ "$1" "$3" perf.worst_slow)" pp lower_better)"
                    { [ -n "$s1" ] && [ -n "$s2" ] && [ "$s1" != "$s2" ]; } && printf '（页不同）'
                    ;;
    frozen)         delta_cell "$(mv_ "$1" "$2" perf.frozen)"    "$(mv_ "$1" "$3" perf.frozen)"    pp lower_better;;
    net_err)        delta_cell "$(mv_ "$1" "$2" perf.net_err)"   "$(mv_ "$1" "$3" perf.net_err)"   pp lower_better;;
    sessions)       delta_cell "$(mv_ "$1" "$2" adopt.sessions)" "$(mv_ "$1" "$3" adopt.sessions)" n  neutral;;
  esac
  return 0
}

# ── 卡片：每端一张表，列 = 指标 | 版本列(2–4) | 对比 ──────────────
# 为什么不是原先的「崩溃表 + 性能表（列=iOS/Android）」：版本维度进来后那种排法要么列数翻倍，
# 要么把两端两版塞进一格。改成「每端一表」后，一屏内就能回答「这版比上版好还是差」。
# 行标签带窗口天数：崩溃 7d 与会话数 1d 并排出现时，不标窗口必被读成同一口径。
ROW_DEFS="crash_count|崩溃次数 ${CRASH_DAYS}d
crash_rate|崩溃率 ${CRASH_DAYS}d
crash_affected|受影响安装 ${CRASH_DAYS}d
start_p50|启动 P50 ${PERF_DAYS}d
start_p95|启动 P95 ${PERF_DAYS}d
slow_worst|慢帧最差页 ${PERF_DAYS}d
frozen|冻结率（最差页）${PERF_DAYS}d
net_err|接口错误率 ${PERF_DAYS}d
sessions|会话数 ${DAYS}d"

build_table() { # $1=plat $2=版本列 $3=V1 $4=V2 $5=最新版列表 $6=主力版列表 → table 组件 JSON
  local cols rows i v tag dn key label rowj
  cols='[{"name":"metric","display_name":"指标","data_type":"text","width":"auto","horizontal_align":"left"}]'
  i=0
  for v in $2; do
    i=$((i + 1)); tag="$(ver_tag "$v" "$5" "$6")"; dn="$v"; [ -n "$tag" ] && dn="$v $tag"
    cols="$(printf '%s' "$cols" | jq -c --arg n "v$i" --arg d "$dn" \
      '. + [{name:$n,display_name:$d,data_type:"lark_md",width:"auto",horizontal_align:"left"}]')"
  done
  [ -n "$4" ] && cols="$(printf '%s' "$cols" | jq -c \
    '. + [{name:"delta",display_name:"对比 (新↔上版)",data_type:"lark_md",width:"auto",horizontal_align:"left"}]')"
  rows='[]'
  while IFS='|' read -r key label; do
    [ -n "$key" ] || continue
    rowj="$(jq -cn --arg m "$label" '{metric:$m}')"
    i=0
    for v in $2; do
      i=$((i + 1))
      rowj="$(printf '%s' "$rowj" | jq -c --arg k "v$i" --arg val "$(cell "$1" "$v" "$key")" '. + {($k):$val}')"
    done
    [ -n "$4" ] && rowj="$(printf '%s' "$rowj" | jq -c --arg d "$(delta_of "$1" "$3" "$4" "$key")" '. + {delta:$d}')"
    rows="$(printf '%s' "$rows" | jq -c --argjson r "$rowj" '. + [$r]')"
  done <<< "$ROW_DEFS"
  jq -cn --argjson c "$cols" --argjson r "$rows" \
    '{tag:"table",page_size:10,row_height:"low",
      header_style:{text_align:"left",text_size:"normal",background_style:"grey",text_color:"default",bold:true,lines:1},
      columns:$c,rows:$r}'
}

ver_summary() { # $1=最新版 $2=上一版 $3=版本列 → 「1.5.4 → 1.5.3（+主力 1.5.1）」式摘要
  local extra
  [ -n "$1" ] || { printf '版本解析失败'; return 0; }
  printf '%s' "$1"
  [ -n "$2" ] && printf ' vs %s' "$2"
  extra="$(printf '%s\n' "$3" | grep -vx "$1" | { [ -n "$2" ] && grep -vx "$2" || cat; } | tr '\n' ' ' | sed 's/ *$//')"
  [ -n "$extra" ] && printf '（+主力 %s）' "$extra"
  return 0
}
# 会话量 top2（主力版本）说明：重合时也要明说，否则读者分不清是「重合」还是「没做这件事」
topsess_note() { # $1=主力版本列表 $2=最新版本列表 → 一句话
  local extra t
  [ -n "$1" ] || { printf '会话量 top2：数据不可得'; return 0; }
  extra="$(printf '%s\n' "$1" | while read -r t; do printf '%s\n' "$2" | grep -qx "$t" || printf '%s ' "$t"; done)"
  printf '会话量 top2：%s' "$(printf '%s' "$1" | tr '\n' ' ' | sed 's/ *$//')"
  if [ -n "$extra" ]; then printf '（其中 %s不在最新版内，已补列）' "$extra"
  else printf '（与最新 %s 版重合，无需补列）' "$VERSION_COUNT"; fi
  return 0
}
IOS_TOP_NOTE="$(topsess_note "$IOS_TOPSESS" "$IOS_NEWEST")"
AND_TOP_NOTE="$(topsess_note "$AND_TOPSESS" "$AND_NEWEST")"
IOS_VER_SUM="$(ver_summary "$IOS_V1" "$IOS_V2" "$IOS_COLS")"
AND_VER_SUM="$(ver_summary "$AND_V1" "$AND_V2" "$AND_COLS")"

echo "--- 组装卡片 ---"
IOS_TABLE="$(build_table ios "$IOS_COLS" "$IOS_V1" "$IOS_V2" "$IOS_NEWEST" "$IOS_TOPSESS")"
AND_TABLE="$(build_table and "$AND_COLS" "$AND_V1" "$AND_V2" "$AND_NEWEST" "$AND_TOPSESS")"

HEADER_TITLE="📊 ${DAY:5} 崩溃 & 性能"
HEADER_COLOR="blue"; [ -n "$ALERTS" ] && HEADER_COLOR="red"
SESS_FALLBACK_NOTE=""
{ [ "$SESS_IOS_FALLBACK" = 1 ] || [ "$SESS_AND_FALLBACK" = 1 ]; } && SESS_FALLBACK_NOTE="；⚠️ 放量回退批量表（可能停更）"
NOTE_MD="$(printf '本报告只统计最新 %s 个版本（会话量 top2 不在其中时补「主力」列）；跨版本合计值不再输出。\n取数区间 性能 %sd：%s\n取数区间 放量 %sd：%s\n取数区间 崩溃 %sd：%s%s\n崩溃=BigQuery 事件级（含已关闭 issue）· 崩溃率=事件数/会话数（非 crash-free）· 慢帧>16ms / 冻结>700ms 为帧级占比\n对比列 = 最新版 − 上一版，↑ 红 = 变差；同版本 DoD/WoW 见日报文档' \
  "$VERSION_COUNT" \
  "$PERF_DAYS"  "$(win_compact "$PERF_DAYS"  "$DATA_UNTIL")" \
  "$DAYS"       "$(win_compact "$DAYS"       "$ADOPTION_UNTIL")" \
  "$CRASH_DAYS" "$(win_compact "$CRASH_DAYS" "$CRASH_UNTIL")" "$SESS_FALLBACK_NOTE")"

CARD_JSON="$(jq -n \
  --arg hc "$HEADER_COLOR" --arg ht "$HEADER_TITLE" --arg sm "$STATUS_MD" \
  --arg si "<font color='red'>**📱 iOS**</font> · $IOS_VER_SUM" \
  --arg sa "<font color='blue'>**🤖 Android**</font> · $AND_VER_SUM" \
  --arg nm "$NOTE_MD" \
  --argjson it "$IOS_TABLE" --argjson at "$AND_TABLE" \
  '{schema:"2.0",
    config:{width_mode:"fill"},
    header:{template:$hc,title:{tag:"plain_text",content:$ht}},
    body:{elements:[
      {tag:"markdown",content:$sm},
      {tag:"markdown",content:$si},{tag:"hr"},
      $it,
      {tag:"markdown",content:$sa},{tag:"hr"},
      $at,
      {tag:"div",text:{tag:"plain_text",content:$nm,text_size:"notation",text_color:"grey"}},
      {tag:"markdown",content:"📄 [详情](__DETAIL_URL__) · 🗂 [崩溃跟踪索引](__INDEX_URL__) · 📁 [全部报告](__FOLDER_URL__)"}
    ]}}')"

# markdown 回退视图（调试与 message.md；结构化卡片投递失败时人也能读）
md_table() { # $1=plat $2=版本列 $3=V1 $4=V2
  local key label v line
  printf '| 指标 |'; for v in $2; do printf ' %s |' "$v"; done; [ -n "$4" ] && printf ' 对比 |'; printf '\n'
  printf '|---|'; for v in $2; do printf -- '---|'; done; [ -n "$4" ] && printf -- '---|'; printf '\n'
  while IFS='|' read -r key label; do
    [ -n "$key" ] || continue
    printf '| %s |' "$label"
    for v in $2; do printf ' %s |' "$(cell "$1" "$v" "$key" | sed -e 's|<font color=[a-z]*>||g' -e 's|</font>||g')"; done
    [ -n "$4" ] && printf ' %s |' "$(delta_of "$1" "$3" "$4" "$key" | sed -e 's|<font color=[a-z]*>||g' -e 's|</font>||g')"
    printf '\n'
  done <<< "$ROW_DEFS"
}
CARD="**📊 ${DAY:5} 崩溃 & 性能**
$STATUS_MD

**📱 iOS** · $IOS_VER_SUM
$(md_table ios "$IOS_COLS" "$IOS_V1" "$IOS_V2")
**🤖 Android** · $AND_VER_SUM
$(md_table and "$AND_COLS" "$AND_V1" "$AND_V2")
> $NOTE_MD"

# ── 同版本环比（DoD/WoW，只对最新 N 版；卡片不放，见 design D7）────────
# 环比数据（结构化）：每行「指标|今日|DoD|WoW」。
# 原来一行一句 "启动 P95 DoD +6359ms ↑（对比 A vs B）· WoW 无基准"，
# 五行把同一个对比日期和同一句「WoW 无基准」重复五遍——日期挪到表外说一次，表里只放数值。
dodwow_rows() { # $1=plat $2=版本
  local ce se rate ry r7 lbl
  ce="$(dv_ "$1" "$2" crash_events_1d)"; se="$(dv_ "$1" "$2" sessions_1d)"
  rate="$(daily_rate "$ce" "$se")"
  ry="$(daily_rate "$(hist_val "$YESTERDAY" "$1" "$2" crash_events_1d)" "$(hist_val "$YESTERDAY" "$1" "$2" sessions_1d)")"
  r7="$(daily_rate "$(hist_val "$D7" "$1" "$2" crash_events_1d)" "$(hist_val "$D7" "$1" "$2" sessions_1d)")"
  _row() { # $1=名 $2=今日 $3=昨日/前一日 $4=D-7 $5=单位 $6=今日展示后缀
    local today d w
    # 展示值去掉 BigQuery ROUND 留下的浮点尾巴（437.0ms → 437ms、30.0% → 30%）；
    # 差值计算仍用原始值，避免二次取整误差
    if [ -z "$2" ]; then today="—"
    elif [ "$5" = ms ]; then today="$(int "$2")$6"
    else today="$(pct "$2")$6"; fi
    d="$(delta_cell "$2" "$3" "$5" lower_better)"; w="$(delta_cell "$2" "$4" "$5" lower_better)"
    printf '%s|%s|%s|%s\n' "$1" "$today" "$d" "$w"
  }
  _row "崩溃率" "$rate" "$ry" "$r7" pp "%"
  _row "启动 P50" "$(dv_ "$1" "$2" start_p50_1d)" "$(dv_ "$1" "$2" prev.start_p50_1d)" "$(hist_val "$D7" "$1" "$2" start_p50_1d)" ms "ms"
  _row "启动 P95" "$(dv_ "$1" "$2" start_p95_1d)" "$(dv_ "$1" "$2" prev.start_p95_1d)" "$(hist_val "$D7" "$1" "$2" start_p95_1d)" ms "ms"
  _row "慢帧（平台级）" "$(dv_ "$1" "$2" slow_pct_1d)" "$(dv_ "$1" "$2" prev.slow_pct_1d)" "$(hist_val "$D7" "$1" "$2" slow_pct_1d)" pp "%"
  _row "冻结" "$(dv_ "$1" "$2" frozen_pct_1d)" "$(dv_ "$1" "$2" prev.frozen_pct_1d)" "$(hist_val "$D7" "$1" "$2" frozen_pct_1d)" pp "%"
  _row "接口错误率" "$(dv_ "$1" "$2" net_err_pct_1d)" "$(dv_ "$1" "$2" prev.net_err_pct_1d)" "$(hist_val "$D7" "$1" "$2" net_err_pct_1d)" pp "%"
  return 0
}
# 对比口径说明：一个版本块只说一次
dodwow_note() { # $1=plat $2=版本
  printf '天级单日值 · 崩溃/放量按昨日；性能按最近可用日（%s vs %s）· DoD=日环比 · WoW=周环比' \
    "$(dv_ "$1" "$2" perf_day)" "$(dv_ "$1" "$2" perf_prev_day)"
}
dodwow_block() { # markdown 版
  local name today d w
  printf '| 指标 | 今日 | DoD | WoW |\n|---|---|---|---|\n'
  dodwow_rows "$1" "$2" | while IFS='|' read -r name today d w; do
    printf '| %s | %s | %s | %s |\n' "$name" "$today" \
      "$(printf '%s' "$d" | sed -e 's|<font color=[a-z]*>||g' -e 's|</font>||g')" \
      "$(printf '%s' "$w" | sed -e 's|<font color=[a-z]*>||g' -e 's|</font>||g')"
  done
  printf '\n> %s\n' "$(dodwow_note "$1" "$2")"
  return 0
}

# 「结论」段自动摘要：把版本间对比里变差 / 变好的指标各归一行（不解释原因，那是 triage 的活）
verdict_line() { # $1=plat $2=平台名 $3=V1 $4=V2
  local key label d worse="" better=""
  [ -n "$4" ] || { printf -- '- **%s** %s：无上一版可比\n' "$2" "$3"; return 0; }
  while IFS='|' read -r key label; do
    [ -n "$key" ] || continue
    d="$(delta_of "$1" "$3" "$4" "$key" | sed -e 's|<font color=[a-z]*>||g' -e 's|</font>||g')"
    case "$d" in
      *↑*) worse="${worse:+${worse}、}$label $d";;
      *↓*) better="${better:+${better}、}$label $d";;
    esac
  done <<< "$ROW_DEFS"
  printf -- '- **%s** %s vs %s：' "$2" "$3" "$4"
  [ -n "$worse" ]  && printf '⚠️ 变差 %s' "$worse"
  [ -n "$worse" ] && [ -n "$better" ] && printf '；'
  [ -n "$better" ] && printf '✅ 变好 %s' "$better"
  { [ -z "$worse" ] && [ -z "$better" ]; } && printf '无可比数据'
  printf '\n'
  return 0
}

# 明细段
issues_table() { # $1=plat $2=版本
  local f="$TMP/issues-$1-$2.json"
  if [ ! -s "$f" ] || [ "$(jq 'length' "$f" 2>/dev/null || echo 0)" = "0" ]; then
    printf '（该版本窗口内无致命崩溃事件）\n\n'; return 0
  fi
  printf '| Issue | 标题 | 事件 | 最新 |\n|---|---|---|---|\n'
  jq -r '.[] | "| \(.issue_id[0:8]) | \(.title) | \(.n) | \(.latest) |"' "$f" 2>/dev/null || true
  printf '\n'
}
csv_table() { # $1=文件 $2=表头 $3=awk 格式
  if [ ! -s "$1" ]; then printf '（无数据）\n\n'; return 0; fi
  printf '%s\n' "$2"
  awk -F, "$3" "$1"
  printf '\n'
}

# ── DocxXML 配色（日报 / 索引 / 周报共用，改一处全变）────────────────
XC_HEAD="${CRASH_REPORT_XC_HEAD:-light-blue}"       # 表头背景
XC_ZEBRA="${CRASH_REPORT_XC_ZEBRA:-light-gray}"     # 偶数行背景（单双行区分）
XC_HILITE="${CRASH_REPORT_XC_HILITE:-light-yellow}" # 最新版列表头

# ── DocxXML 渲染（文档要颜色只能走 XML；markdown 导入不支持颜色/高亮框）──
# 复用卡片那套 cell()/delta_of() 的判定与着色，只做标记转换，避免两套阈值逻辑漂移。
x() { sed -e 's|<font color=\([a-z]*\)>|<span text-color="\1">|g' -e 's|</font>|</span>|g'; }
xesc() { python3 -c "import sys,html; sys.stdout.write(html.escape(sys.stdin.read(), quote=False))"; }
x_cell()  { cell "$1" "$2" "$3" | x; }
x_delta() { delta_of "$1" "$2" "$3" "$4" | x; }

# 版本对照表（每端一张）：表头灰底、最新版列蓝底，单元格颜色沿用阈值判定
xml_table() { # $1=plat $2=版本列 $3=V1 $4=V2
  local key label v first=1
  local n=0 bg
  printf '<table>\n<thead><tr><th background-color="%s">指标</th>' "$XC_HEAD"
  for v in $2; do
    if [ "$first" = 1 ]; then printf '<th background-color="%s">%s 最新</th>' "$XC_HILITE" "$v"; first=0
    else printf '<th background-color="%s">%s</th>' "$XC_HEAD" "$v"; fi
  done
  [ -n "$4" ] && printf '<th background-color="%s">对比</th>' "$XC_HEAD"
  printf '</tr></thead>\n<tbody>\n'
  while IFS='|' read -r key label; do
    [ -n "$key" ] || continue
    n=$((n + 1)); bg=""; [ $((n % 2)) -eq 0 ] && bg=" background-color=\"$XC_ZEBRA\""
    printf '<tr><td%s>%s</td>' "$bg" "$label"
    for v in $2; do printf '<td%s>%s</td>' "$bg" "$(x_cell "$1" "$v" "$key")"; done
    [ -n "$4" ] && printf '<td%s>%s</td>' "$bg" "$(x_delta "$1" "$3" "$4" "$key")"
    printf '</tr>\n'
  done <<< "$ROW_DEFS"
  printf '</tbody>\n</table>\n'
}
# 环比表（XML）：日期说明放表外，表内只放数值；DoD/WoW 沿用 delta_cell 的红绿
xml_dodwow() { # $1=plat $2=版本
  local n=0 bg name today d w
  printf '<p><span text-color="gray">%s</span></p>\n' "$(dodwow_note "$1" "$2" | xesc)"
  printf '<table>\n<thead><tr>'
  printf '<th background-color="%s">指标</th><th background-color="%s">今日</th><th background-color="%s">DoD</th><th background-color="%s">WoW</th>' \
    "$XC_HEAD" "$XC_HILITE" "$XC_HEAD" "$XC_HEAD"
  printf '</tr></thead>\n<tbody>\n'
  while IFS='|' read -r name today d w; do
    [ -n "$name" ] || continue
    n=$((n + 1)); bg=""; [ $((n % 2)) -eq 0 ] && bg=" background-color=\"$XC_ZEBRA\""
    printf '<tr><td%s>%s</td><td%s>%s</td><td%s>%s</td><td%s>%s</td></tr>\n' \
      "$bg" "$(printf '%s' "$name" | xesc)" "$bg" "$(printf '%s' "$today" | xesc)" \
      "$bg" "$(printf '%s' "$d" | x)" "$bg" "$(printf '%s' "$w" | x)"
  done < <(dodwow_rows "$1" "$2")
  printf '</tbody>\n</table>\n'
  return 0
}

xml_issues() { # $1=plat $2=版本
  local f="$TMP/issues-$1-$2.json"
  if [ ! -s "$f" ] || [ "$(jq 'length' "$f" 2>/dev/null || echo 0)" = "0" ]; then
    printf '<p><span text-color="gray">该版本窗口内无致命崩溃事件</span></p>\n'; return 0
  fi
  jq -r '.[] | [.issue_id[0:8], .title, (.n|tostring), .latest] | @csv' "$f" 2>/dev/null > "$TMP/iss-$1-$2.csv" || true
  xml_csv_table "$TMP/iss-$1-$2.csv" 'Issue,标题,事件,最新' '1,2,3,4' 
}
# CSV → 彩色表格。**结构标签不能转义、字段值必须转义**——早期版本把整行喂给 xesc，
# 结果 <tr><td> 全变成字面文本，飞书渲染出一张空表（2026-08-18 实测踩到）。
# $1=csv $2=逗号分隔表头 $3=列规格（"列号:后缀"，列号从 1 起）
xml_csv_table() {
  if [ ! -s "$1" ]; then printf '<p><span text-color="gray">（无数据）</span></p>\n'; return 0; fi
  XC_HEAD="$XC_HEAD" XC_ZEBRA="$XC_ZEBRA" python3 - "$1" "$2" "$3" <<'XMLPY'
import sys, csv, html, os
path, heads, spec = sys.argv[1], sys.argv[2].split(','), sys.argv[3].split(',')
head_bg, zebra = os.environ['XC_HEAD'], os.environ['XC_ZEBRA']
cols = []
for sp in spec:
    idx, _, suf = sp.partition(':')
    cols.append((int(idx) - 1, suf))
e = lambda t: html.escape(t, quote=False)
out = ['<table>', '<thead><tr>' + ''.join(
    '<th background-color="%s">%s</th>' % (head_bg, e(h)) for h in heads) + '</tr></thead>', '<tbody>']
n = 0
for row in csv.reader(open(path, newline='')):
    if not row or not any(f.strip() for f in row):
        continue
    n += 1
    bg = ' background-color="%s"' % zebra if n % 2 == 0 else ''
    tds = []
    for i, suf in cols:
        v = row[i].strip() if i < len(row) else ''
        tds.append('<td%s>%s%s</td>' % (bg, e(v), e(suf)))
    out.append('<tr>' + ''.join(tds) + '</tr>')
out += ['</tbody>', '</table>']
print('\n'.join(out))
XMLPY
}

echo "--- 生成日报文档 ---"
REPORT="$STATE/reports/$DAY-daily.md"
{
  printf '# 崩溃 & 性能日报 · %s\n\n' "$DAY"
  printf '> **本报告只统计最新 %s 个版本**：iOS %s · Android %s\n' "$VERSION_COUNT" "$IOS_VER_SUM" "$AND_VER_SUM"
  printf '> 性能 %sd：**%s**\n' "$PERF_DAYS" "$(win_full "$PERF_DAYS" "$DATA_UNTIL")"
  printf '> 放量 %sd：**%s**\n' "$DAYS" "$(win_full "$DAYS" "$ADOPTION_UNTIL")"
  printf '> 崩溃 %sd：**%s**\n' "$CRASH_DAYS" "$(win_full "$CRASH_DAYS" "$CRASH_UNTIL")"
  printf '> iOS %s · Android %s\n' "$IOS_TOP_NOTE" "$AND_TOP_NOTE"
  printf '> 窗口起点 = 本次跑批时刻 − N 天（SQL 下界）；终点 = 该表实际取到的最新数据，两者之差即数据滞后。\n\n'

  printf '## 一、结论\n\n'
  printf '%s\n\n' "$STATUS_MD"
  verdict_line ios "iOS" "$IOS_V1" "$IOS_V2"
  verdict_line and "Android" "$AND_V1" "$AND_V2"
  printf '\n'

  printf '## 二、版本对照\n\n'
  printf '### iOS · %s\n\n' "$IOS_VER_SUM"
  md_table ios "$IOS_COLS" "$IOS_V1" "$IOS_V2"
  printf '\n### Android · %s\n\n' "$AND_VER_SUM"
  md_table and "$AND_COLS" "$AND_V1" "$AND_V2"
  printf '\n'

  printf '## 三、明细\n\n### 崩溃 issue（按版本）\n\n'
  for v in $IOS_COLS; do printf '**iOS %s**\n\n' "$v"; issues_table ios "$v"; done
  for v in $AND_COLS; do printf '**Android %s**\n\n' "$v"; issues_table and "$v"; done
  printf '### 性能（按版本）\n\n'
  for pv in $(printf 'ios %s\n' $IOS_COLS | tr ' ' ':') $(printf 'and %s\n' $AND_COLS | tr ' ' ':'); do
    p="${pv%%:*}"; v="${pv##*:}"
    [ "$p" = ios ] && pn="iOS" || pn="Android"
    printf '**%s %s** · 启动与自定义 trace\n\n' "$pn" "$v"
    csv_table "$TMP/traces-$p-$v.csv" '| trace | 次数 | P50 | P95 |
|---|---|---|---|' '{printf "| %s | %s | %s ms | %s ms |\n",$1,$2,$3,$4}'
    printf '**%s %s** · 页面渲染（慢帧 >16ms · 冻结 >700ms）\n\n' "$pn" "$v"
    csv_table "$TMP/screens-$p-$v.csv" '| 页面 | 样本 | 慢帧率 | 冻结帧率 | P50 停留 |
|---|---|---|---|---|' '{printf "| %s | %s | %s%% | %s%% | %s s |\n",$1,$2,$3,$4,$5}'
    printf '**%s %s** · 自家 API 网络\n\n' "$pn" "$v"
    csv_table "$TMP/net-$p-$v.csv" '| 接口 | 次数 | P50 | P95 | 错误率 |
|---|---|---|---|---|' '{printf "| %s | %s | %s ms | %s ms | %s%% |\n",$1,$2,$3,$4,$6}'
  done

  printf '### 版本放量（**全版本口径**，与上方版本级指标不可比）\n\n'
  printf '> 崩溃数为 0 可能是修好了、也可能是没人用——没有这个分母就分不清。\n'
  printf '> 本表刻意不做版本过滤：要回答「盘子里还剩多少旧版本」。\n\n'
  for ps in "iOS:$SESS_IOS" "Android:$SESS_AND"; do
    pn="${ps%%:*}"; tbl="${ps##*:}"
    printf '**%s**\n\n' "$pn"
    if [ -z "$tbl" ]; then printf '（sessions 表尚未同步）\n\n'; continue; fi
    rows="$(sed -e "s|{{TABLE}}|$tbl|g" -e "s|{{DAYS}}|$DAYS|g" "$SQL_DIR/sessions-by-version.sql" \
      | bq query --use_legacy_sql=false --format=csv 2>/dev/null | tail -n +2)" || true
    if [ -z "$rows" ]; then printf '（⚠️ 数据未同步）\n\n'; else
      printf '| 版本 | 会话 | 设备 | 最新数据 |\n|---|---|---|---|\n'
      printf '%s\n' "$rows" | awk -F, '{printf "| %s | %s | %s | %s |\n",$1,$2,$3,$4}'
      printf '\n'
    fi
  done

  printf '## 四、环比与口径\n\n### 同版本环比（DoD/WoW，天级单日值）\n\n'
  for v in $IOS_NEWEST; do printf '**iOS %s**\n\n' "$v"; dodwow_block ios "$v"; printf '\n'; done
  for v in $AND_NEWEST; do printf '**Android %s**\n\n' "$v"; dodwow_block and "$v"; printf '\n'; done
  printf '### 口径\n\n'
  printf -- '- **版本过滤**：崩溃 / 性能 / 放量核心指标全部只统计最新 %s 个版本；版本清单来自 `firebase_sessions` 活表，按版本号取最新（非会话量）。会话量 top2 不在其中时补「主力」列。\n' "$VERSION_COUNT"
  printf -- '- **崩溃**：BigQuery `firebase_crashlytics` 事件级（含已关闭 issue，不受 issue 开关状态影响）。\n'
  printf -- '- **崩溃率**：事件数 / 会话数，**非 crash-free 精确口径**；分母为 0 显示「无法计算」。\n'
  printf -- '- **慢帧 / 冻结**：帧级占比（单帧 >16ms / >700ms），「最差页」为该窗口内慢帧率最高的页面。\n'
  printf -- '- **数据缺失三态**：`表未同步`（表不存在）/ `数据未同步`（表整体无数据）/ `该版本无数据`（表有数据但该版本 0 行，新版在滞后的性能表里属常态）。\n'
  printf -- '- **环比**：卡片「对比」列 = 最新版 − 上一版；本节 DoD/WoW = 同版本天级单日值。两者口径不同，不可混读。\n'
  printf -- '- **NON_FATAL**：iOS 通路已建但尚未合入发版分支，线上仍为零上报，两端数字暂不可比。\n'
  printf '\n---\n本报告自动生成，不含根因与修复方案。需要定位请跑 `firebase-crash-triage`。\n'
} > "$REPORT"
echo "--- 报告已生成：$REPORT ---"

if [ "$DRY_RUN" = "1" ]; then
  echo; echo "──────── DRY RUN · 卡片预览（不会发送）────────"
  printf '%s\n' "$CARD"
  echo "──────────────────────────────────────────────"
  mkdir -p "$STATE/publish"
  printf '%s\n' "$CARD_JSON" > "$STATE/publish/card.json"
  jq empty "$STATE/publish/card.json" && echo "  ✅ card.json 合法（jq empty 通过）"
  echo "  card.json 字节数：$(wc -c < "$STATE/publish/card.json" | tr -d ' ')"
  echo "（完整报告见 $REPORT · 快照与历史未写入，不影响明日基准）"
  exit 0
fi

# ── 索引页：跟踪表随每日数据变化，整份重建而非局部改块（局部改易错且难回滚）──
# 日报/台账 URL 由 agent 建完文档后回填（__DAILY_URL__ / __LEDGER_URL__ 占位符），
# 周报归档 URL 来自 state/weekly-index.jsonl（L2 每次追加一行，本页倒序渲染）。
build_index() {
  local f="$STATE/index-render.md"
  # 报告归档：日报与周报统一记在一份 JSONL 里（{type,day,url,...}），由 deliver.sh 在文档建成后追加。
  # 不可再生（存的是飞书文档 URL，飞书端无法枚举本 bot 文档），所以放仓库里由 git 兜底。
  # ARCHIVE_LEGACY 是改成统一格式前的周报归档，读时合并进来，避免历史断链。
  local ARCH="$ARCHIVE_FILE" LEGACY="$ROOT/reports/weekly-index.jsonl"
  local ALL="$STATE/archive-merged.jsonl"
  : > "$ALL"
  [ -s "$LEGACY" ] && jq -c '. + {type:"weekly"}' "$LEGACY" >> "$ALL" 2>/dev/null
  [ -s "$ARCH" ] && cat "$ARCH" >> "$ALL"
  local LATEST_WEEKLY_DAY="" LATEST_WEEKLY_URL="" v
  if [ -s "$ALL" ]; then
    LATEST_WEEKLY_DAY="$(jq -rs 'map(select(.type=="weekly")) | last | .day // empty' "$ALL" 2>/dev/null)"
    LATEST_WEEKLY_URL="$(jq -rs 'map(select(.type=="weekly")) | last | .url // empty' "$ALL" 2>/dev/null)"
  fi
  {
    printf '# Dino 崩溃跟踪 · 索引\n\n'
    printf '> 本页自动生成，请勿手工编辑（每日 L1 运行时整份重建）。\n'
    printf '> 判断与处置结论沉淀在仓库 `reports/LEDGER.md`，两者冲突以仓库为准。\n'
    printf '> 最后更新：%s · 日报口径：最新 %s 个版本（iOS %s · Android %s）\n' "$DAY" "$VERSION_COUNT" "$IOS_VER_SUM" "$AND_VER_SUM"
    printf '> iOS %s · Android %s\n\n' "$IOS_TOP_NOTE" "$AND_TOP_NOTE"
    printf '## 📍 文档入口\n\n| 文档 | 说明 | 维护 |\n|---|---|---|\n'
    printf '| 📄 [崩溃 & 性能日报（今日）](__DAILY_URL__) | 每日数据快照（最新 %s 版：崩溃/性能/放量） | 自动 |\n' "$VERSION_COUNT"
    if [ -n "$LATEST_WEEKLY_URL" ]; then
      printf '| 📊 [崩溃周报（%s）](%s) | 每周变化播报 + 主力版本放量 | 自动 |\n' "$LATEST_WEEKLY_DAY" "$LATEST_WEEKLY_URL"
    else
      printf '| 📊 崩溃周报 | 每周变化播报（暂无，L2 首跑后出现） | 自动 |\n'
    fi
    printf '| 📒 [崩溃专项台账 LEDGER](__LEDGER_URL__) | 处置结论、风险分级、事故记录 | **人**（仓库为源，L1 每日同步镜像） |\n\n'
    printf '## 🔥 今日概览（版本级）\n\n| 平台 | 版本 | 崩溃 | 崩溃率 | 启动 P50 | 慢帧最差页 |\n|---|---|---|---|---|---|\n'
    for v in $IOS_COLS; do
      printf '| iOS | %s | %s | %s | %s | %s |\n' "$v" \
        "$(cell ios "$v" crash_count | sed -e 's|<font color=[a-z]*>||g' -e 's|</font>||g')" \
        "$(cell ios "$v" crash_rate  | sed -e 's|<font color=[a-z]*>||g' -e 's|</font>||g')" \
        "$(cell ios "$v" start_p50)" "$(cell ios "$v" slow_worst | sed -e 's|<font color=[a-z]*>||g' -e 's|</font>||g')"
    done
    for v in $AND_COLS; do
      printf '| Android | %s | %s | %s | %s | %s |\n' "$v" \
        "$(cell and "$v" crash_count | sed -e 's|<font color=[a-z]*>||g' -e 's|</font>||g')" \
        "$(cell and "$v" crash_rate  | sed -e 's|<font color=[a-z]*>||g' -e 's|</font>||g')" \
        "$(cell and "$v" start_p50)" "$(cell and "$v" slow_worst | sed -e 's|<font color=[a-z]*>||g' -e 's|</font>||g')"
    done
    printf '\n## 🐞 跟踪中的 issue（**全版本口径**，来自 Firebase MCP OPEN 列表）\n\n'
    printf '> 本段与上方版本级数据口径不同：MCP `topIssues` 无版本过滤能力，且只返回 OPEN issue。\n'
    printf '> 它的用途是修复状态反查（`fix_commit`），不用于判断当前版本质量。\n\n'
    # iOS 有「提交带 Crashlytics issue ID」硬规则（crash-prevention），fix_commit 可信；
    # Android 无此约定（2026-08-07 核实：全仓 0 处 32 位 hex 引用），null 只代表「提交里没写 id」，
    # 渲染成「🔴 未修」会得出错误结论——必须显示为不可判定。
    jq -r '"### iOS\n\n| Issue | 标题 | 事件 | 修复提交 |\n|---|---|---|---|\n" +
           ((.ios // []) | map("| \(.id[0:8]) | \(.title) | \(.events) | \(.fix_commit // "🔴 未修") |") | join("\n")) +
           "\n\n### Android\n\n| Issue | 标题 | 事件 | 修复状态 |\n|---|---|---|---|\n" +
           ((.android // []) | map("| \(.id[0:8]) | \(.title) | \(.events) | — |") | join("\n"))' \
      "$CRASH_JSON" 2>/dev/null || printf '（本次崩溃数据抓取失败）'
    printf '\n\n> Android 未采用「提交信息带 Crashlytics issue ID」的约定，**无法自动判定修复状态**（显示为 —）。\n'
    printf '> 其修复情况以每周 triage 报告的语义分析为准（见下方报告归档）。\n'
    printf '\n\n## 🗂 报告归档\n\n'
    printf '> 日报与周报统一归档在本页。**今天这份的链接在最上方「文档入口」**——归档表记的是已投递过的历史，\n'
    printf '> 今日条目在本轮投递完成后写入，明天出现在这里。\n\n'
    printf '### 日报（最近 %s 天）\n\n' "$ARCHIVE_DAILY_KEEP"
    if [ -s "$ALL" ] && [ "$(jq -rs 'map(select(.type=="daily")) | length' "$ALL" 2>/dev/null)" != "0" ]; then
      printf '| 日期 | 报告 | 版本 |\n|---|---|---|\n'
      jq -rs --argjson k "$ARCHIVE_DAILY_KEEP" \
        'map(select(.type=="daily")) | reverse | .[:$k] | .[] | "| \(.day) | [打开](\(.url)) | \(.versions // "—") |"' "$ALL"
    else
      printf '（暂无归档，本轮投递后出现）\n'
    fi
    printf '\n### 周报\n\n'
    if [ -s "$ALL" ] && [ "$(jq -rs 'map(select(.type=="weekly")) | length' "$ALL" 2>/dev/null)" != "0" ]; then
      printf '| 日期 | 报告 | iOS OPEN | Android OPEN |\n|---|---|---|---|\n'
      jq -rs 'map(select(.type=="weekly")) | reverse | .[] | "| \(.day) | [打开](\(.url)) | \(.ios // "—") | \(.android // "—") |"' "$ALL"
    else
      printf '（暂无归档，L2 首次运行后出现）\n'
    fi
    printf '\n## 📖 修复状态图例\n\n| 标记 | 含义 | 判据（自动推导） |\n|---|---|---|\n'
    printf '| 🔴 未修 | 代码里找不到修复 | `git log --grep=<issueId>` 无结果 |\n'
    printf '| 🛠️ 代码已修·未发版 | 修复已提交，含该修复的版本未上线 | 找到 commit，线上无该版本事件 |\n'
    printf '| 📦 已发版·观察中 | 含修复的版本已上线 | 线上出现该版本事件 |\n'
    printf '| ✅ 已消失 | 发版后无新事件 | 该版本后事件归零 |\n'
    printf '\n---\n数据源：BigQuery Crashlytics（事件级·版本过滤）+ Firebase Crashlytics（OPEN 对照·全版本）+ BigQuery Performance · 由 crash-daily.sh 自动生成\n'
  } > "$f"
  echo "$f"
}

# ── 日报 XML 文档（有颜色的那一份；markdown 版保留作回退与调试）──
build_report_xml() {
  local v p pn tone emoji bg border
  REPORT_XML="$PUBLISH_DIR/docs/daily.xml"
  if [ -n "$ALERTS" ]; then tone="告警"; emoji="🔴"; bg="light-red"; border="red"
  else tone="无异常"; emoji="✅"; bg="light-green"; border="green"; fi
  {
    printf '<title>崩溃 &amp; 性能日报 · %s</title>\n' "$DAY"
    # 结论高亮框：一眼看到今天该不该紧张
    printf '<callout emoji="%s" background-color="%s" border-color="%s">\n' "$emoji" "$bg" "$border"
    if [ -n "$ALERTS" ]; then
      printf '%s\n' "$SUMMARY_MD" | grep -v '^$' | while IFS= read -r line; do
        printf '  <p>%s</p>\n' "$(printf '%s' "$line" | xesc)"
      done
    else
      printf '  <p><b>今日无异常</b>：崩溃率 / 慢帧 / 冻结 / 启动 P95 / 接口错误率 全部在阈值内</p>\n'
    fi
    printf '  <p><span text-color="gray">只统计最新 %s 个版本：iOS %s · Android %s</span></p>\n' \
      "$VERSION_COUNT" "$(printf '%s' "$IOS_VER_SUM" | xesc)" "$(printf '%s' "$AND_VER_SUM" | xesc)"
    printf '  <p><span text-color="gray">iOS %s · Android %s</span></p>\n' \
      "$(printf '%s' "$IOS_TOP_NOTE" | xesc)" "$(printf '%s' "$AND_TOP_NOTE" | xesc)"
    printf '</callout>\n'

    printf '<h1>一、结论</h1>\n'
    printf '%s' "$(verdict_line ios "iOS" "$IOS_V1" "$IOS_V2"; verdict_line and "Android" "$AND_V1" "$AND_V2")" \
      | sed 's/^- //' | while IFS= read -r line; do
        [ -n "$line" ] || continue
        printf '<p>%s</p>\n' "$(printf '%s' "$line" | xesc | sed -e 's/⚠️ 变差/<span text-color="red">⚠️ 变差<\/span>/' -e 's/✅ 变好/<span text-color="green">✅ 变好<\/span>/')"
      done

    printf '<h1>二、版本对照</h1>\n'
    printf '<h2>📱 iOS · %s</h2>\n' "$(printf '%s' "$IOS_VER_SUM" | xesc)"
    xml_table ios "$IOS_COLS" "$IOS_V1" "$IOS_V2"
    printf '<h2>🤖 Android · %s</h2>\n' "$(printf '%s' "$AND_VER_SUM" | xesc)"
    xml_table and "$AND_COLS" "$AND_V1" "$AND_V2"

    printf '<h1>三、明细</h1>\n<h2>崩溃 issue（按版本）</h2>\n'
    for v in $IOS_COLS; do printf '<h3>iOS %s</h3>\n' "$v"; xml_issues ios "$v"; done
    for v in $AND_COLS; do printf '<h3>Android %s</h3>\n' "$v"; xml_issues and "$v"; done
    printf '<h2>性能（按版本）</h2>\n'
    for pv in $(printf 'ios %s\n' $IOS_COLS | tr ' ' ':') $(printf 'and %s\n' $AND_COLS | tr ' ' ':'); do
      p="${pv%%:*}"; v="${pv##*:}"
      [ "$p" = ios ] && pn="iOS" || pn="Android"
      printf '<h3>%s %s</h3>\n' "$pn" "$v"
      printf '<p><b>启动与自定义 trace</b></p>\n'
      xml_csv_table "$TMP/traces-$p-$v.csv" 'trace,次数,P50,P95' '1,2,3: ms,4: ms'
      printf '<p><b>页面渲染（慢帧 &gt;16ms · 冻结 &gt;700ms）</b></p>\n'
      xml_csv_table "$TMP/screens-$p-$v.csv" '页面,样本,慢帧率,冻结帧率,P50 停留' '1,2,3:%,4:%,5: s'
      printf '<p><b>自家 API 网络</b></p>\n'
      xml_csv_table "$TMP/net-$p-$v.csv" '接口,次数,P50,P95,错误率' '1,2,3: ms,4: ms,6:%'
    done

    printf '<h1>四、环比与口径</h1>\n<h2>同版本环比（DoD/WoW，天级单日值）</h2>\n'
    for v in $IOS_NEWEST; do printf '<h3>iOS %s</h3>\n' "$v"; xml_dodwow ios "$v"; done
    for v in $AND_NEWEST; do printf '<h3>Android %s</h3>\n' "$v"; xml_dodwow and "$v"; done
    # 口径收口成一个蓝色高亮框，不再逐段插注释淹没数据
    printf '<callout emoji="📌" background-color="light-blue" border-color="blue">\n'
    printf '  <p><b>口径</b></p>\n'
    printf '  <p>版本过滤：三段只统计最新 %s 个版本；版本清单取自 firebase_sessions 活表，按版本号排序（非会话量）。会话量 top2 不在其中时补「主力」列。</p>\n' "$VERSION_COUNT"
    printf '  <p>崩溃：BigQuery firebase_crashlytics 事件级（含已关闭 issue）。崩溃率 = 事件数 / 会话数，<b>非 crash-free</b>；分母为 0 显示「无法计算」。</p>\n'
    printf '  <p>慢帧 / 冻结：帧级占比（单帧 &gt;16ms / &gt;700ms），「最差页」为窗口内慢帧率最高的页面。</p>\n'
    printf '  <p>缺数三态：表未同步（表不存在）/ 数据未同步（表整体无数据）/ 该版本无数据（表有数据但该版本 0 行，新版在滞后的性能表里属常态）。</p>\n'
    printf '  <p>环比：卡片「对比」列 = 最新版 − 上一版；本节 DoD/WoW = 同版本天级单日值。两者口径不同，不可混读。</p>\n'
    printf '  <p>数据截止：性能 %s · 放量 %s · 崩溃 %s</p>\n' "$DATA_UNTIL" "$ADOPTION_UNTIL" "$CRASH_UNTIL"
    printf '</callout>\n'
    printf '<p><span text-color="gray">本报告自动生成，不含根因与修复方案。需要定位请跑 firebase-crash-triage。</span></p>\n'
  } > "$REPORT_XML"
}

echo "--- 产出投递清单 ---"
PUBLISH_DIR="$STATE/publish"
rm -rf "$PUBLISH_DIR"; mkdir -p "$PUBLISH_DIR/docs"
printf '%s\n' "$CARD" > "$PUBLISH_DIR/message.md"
printf '%s\n' "$CARD_JSON" > "$PUBLISH_DIR/card.json"
[ -s "$REPORT" ] && cp "$REPORT" "$PUBLISH_DIR/docs/daily.md" || true

build_report_xml
INDEX_FILE="$(build_index)"
# 索引页彩色版：与日报/周报/台账同一套配色，走 md2docx.py 通用转换
INDEX_XML=""
if [ -s "$INDEX_FILE" ] && [ -x "$ROOT/bin/md2docx.py" ]; then
  if "$ROOT/bin/md2docx.py" "$INDEX_FILE" --title "Dino 崩溃跟踪 · 索引" \
       --head-bg "$XC_HEAD" --zebra "$XC_ZEBRA" > "$PUBLISH_DIR/docs/index.xml" 2>/dev/null; then
    INDEX_XML="$PUBLISH_DIR/docs/index.xml"
  fi
fi

# 台账镜像：仓库 LEDGER.md 是真相源，镜像顶部加「请勿在此编辑」警告
LEDGER_XML=""
if [ -s "$LEDGER_SRC" ]; then
  {
    printf '> ⚠️ 本页为仓库 `reports/LEDGER.md` 的只读镜像，请勿在此编辑；修改请在仓库提交。\n\n'
    cat "$LEDGER_SRC"
  } > "$PUBLISH_DIR/docs/ledger.md"
  LEDGER_DOC="$PUBLISH_DIR/docs/ledger.md"
  # 彩色版：状态词上色、引用块转高亮框、表格斑马纹（md2docx.py 通用转换器）
  if [ -x "$ROOT/bin/md2docx.py" ] && "$ROOT/bin/md2docx.py" "$LEDGER_SRC" \
       --title "崩溃专项台账 LEDGER（只读镜像）" \
       --head-bg "$XC_HEAD" --zebra "$XC_ZEBRA" \
       --warn "本页为仓库 reports/LEDGER.md 的只读镜像，请勿在此编辑；修改请在仓库提交。" \
       > "$PUBLISH_DIR/docs/ledger.xml" 2>/dev/null; then
    LEDGER_XML="$PUBLISH_DIR/docs/ledger.xml"
  fi
else
  LEDGER_DOC=""
fi

# 投递：日报/台账镜像/索引页三份文档都每次新建（docx.builtin.import），URL 由 agent 回填。
# 卡片两态并存：message.md（纯 markdown 回退/调试视图）+ card.json（结构化 interactive 卡片，agent 原样投递）。
# card.json 末尾的占位符 __DETAIL_URL__ / __INDEX_URL__ 由 agent 建完文档后回填。
jq -n \
  --arg chat "$CHAT_ID" \
  --arg day "$DAY" \
  --arg run "$RUN_ID" \
  --arg msg  "$PUBLISH_DIR/message.md" \
  --arg card "$PUBLISH_DIR/card.json" \
  --arg report "$PUBLISH_DIR/docs/daily.md" \
  --arg reportxml "$REPORT_XML" \
  --arg title "崩溃 & 性能日报 · $DAY" \
  --arg ledger "$LEDGER_DOC" \
  --arg ledgerxml "$LEDGER_XML" \
  --arg index "$INDEX_FILE" \
  --arg indexxml "$INDEX_XML" \
  --arg ledger_id "$DOC_LEDGER_ID" \
  --arg index_id "$DOC_INDEX_ID" \
  --arg arch "$ARCHIVE_FILE" \
  --arg vsum "iOS ${IOS_V1:-—} · Android ${AND_V1:-—}" \
  '{type:"daily", day:$day, run_id:$run, chat_id:$chat, message_file:$msg, card_file:$card,
    create_doc: {file:$report, xml_file:$reportxml, title:$title, label:"日报"},
    ledger_doc: (if $ledger != "" then {file:$ledger, xml_file:$ledgerxml, title:"崩溃专项台账 LEDGER（只读镜像）", label:"台账", doc_id:$ledger_id} else null end),
    index_doc: (if $index != "" then {file:$index, xml_file:$indexxml, title:"Dino 崩溃跟踪 · 索引", label:"索引", doc_id:$index_id} else null end),
    archive_append: {jsonl_file:$arch, type:"daily", day:$day, versions:$vsum}}' \
  > "$PUBLISH_DIR/manifest.json"
echo "  ✅ 投递清单 $PUBLISH_DIR/manifest.json"

# ── 持久化：按版本存储的天级历史（design D9）+ 快照 ──────────────
# 结构：{day, versions:{ios:[…],android:[…]}, ios:{"<ver>":{…}}, android:{…}}
# 按 day upsert（同日重跑覆盖而非追加，根治 DoD 基准静默漂移），保留最近 7 天，原子写。
plat_hist_obj() { # $1=plat键 $2=版本列表 → {"<ver>":{…}}
  local acc='{}' v
  for v in $2; do
    [ -s "$TMP/d-$1-$v.json" ] || continue
    acc="$(printf '%s' "$acc" | jq -c --arg v "$v" --slurpfile d "$TMP/d-$1-$v.json" \
      '. + {($v): ($d[0] | del(.prev))}')"
  done
  printf '%s' "$acc"
}
HISTORY_LINE="$(jq -cn --arg day "$DAY" \
  --argjson vers "$(jq -cn --argjson i "$(printf '%s' "$IOS_NEWEST" | jq -Rsc 'split("\n")|map(select(length>0))')" \
                           --argjson a "$(printf '%s' "$AND_NEWEST" | jq -Rsc 'split("\n")|map(select(length>0))')" '{ios:$i,android:$a}')" \
  --argjson io "$(plat_hist_obj ios "$IOS_NEWEST")" \
  --argjson ao "$(plat_hist_obj and "$AND_NEWEST")" \
  '{day:$day, versions:$vers, ios:$io, android:$ao}')"
{
  printf '%s' "$HIST_ARR" | jq -c --arg d "$DAY" '.[] | select(.day != $d)'
  printf '%s\n' "$HISTORY_LINE"
} | tail -"$HISTORY_KEEP" > "$HISTORY.tmp" && mv "$HISTORY.tmp" "$HISTORY" \
  || echo "  ⚠️ 历史写入失败（不影响日报投递）"

# 快照：供明日「新增 issue」判定（MCP ids）与口径回溯（版本集）
# MCP 抓取失败时 CRASH_JSON 不存在，slurpfile 会整条失败——指到 /dev/null 让 ids 落空数组即可。
[ -s "$CRASH_JSON" ] || CRASH_JSON=/dev/null
jq -n --arg day "$DAY" \
  --argjson vers "$(jq -cn --argjson i "$(printf '%s' "$IOS_COLS" | jq -Rsc 'split("\n")|map(select(length>0))')" \
                           --argjson a "$(printf '%s' "$AND_COLS" | jq -Rsc 'split("\n")|map(select(length>0))')" '{ios:$i,android:$a}')" \
  --slurpfile c "$CRASH_JSON" \
  '{day:$day, versions:$vers,
    ios_ids:[($c[0].ios // [])[].id], android_ids:[($c[0].android // [])[].id]}' \
  > "$SNAP" 2>/dev/null || echo "  ⚠️ 快照写入失败，明日无「新增 issue」基准"

# ── 投递（确定性，无 LLM）──────────────────────────────
# 生成与投递分两个脚本、串行调用：投递失败不改变本脚本的退出码——数据已落盘，
# 重跑 deliver.sh 即可补投（--idempotency-key 保证不会重复发卡片）。
# CRASH_REPORT_NO_DELIVER=1 可只生成不投递。
if [ "${CRASH_REPORT_NO_DELIVER:-0}" != "1" ] && [ -x "$ROOT/bin/deliver.sh" ]; then
  "$ROOT/bin/deliver.sh" "$PUBLISH_DIR/manifest.json" || echo "  ⚠️ 投递失败（数据已落盘，可重跑 deliver.sh 补投）"
fi

jq -n --arg t "$TS" --arg u "$DATA_UNTIL" --arg r "$RUN_ID" \
  --arg iv "$(printf '%s' "$IOS_COLS" | tr '\n' ' ')" --arg av "$(printf '%s' "$AND_COLS" | tr '\n' ' ')" \
  '{last_run:$t,run_id:$r,ok:true,data_until:$u,versions:{ios:$iv,android:$av}}' > "$STATE/health-daily.json"

# 中间产物保留 30 天（每个卡片数字最直接的审计物证），与 crash-daily-* 目录同节奏
find "$STATE" -maxdepth 1 -name 'metrics-*' -mtime +30 -exec rm -rf {} + 2>/dev/null || true
find "$STATE/logs" -name 'daily-*.log' -mtime +60 -delete 2>/dev/null || true
find "$STATE" -maxdepth 1 -name 'crash-daily-*' -mtime +30 -exec rm -rf {} + 2>/dev/null || true
echo "=== 完成 ==="
