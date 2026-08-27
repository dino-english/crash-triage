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
# ${ROOT}（仓库）只放代码：bin/ · sql/。运行产物一律落 ${STATE}（归档 2026-08-20 起也移了过去）。
# $STATE 放可变运行数据：logs/ · 每日生成的报告 · 快照 · 历史 · 投递中间产物 · 本机 path.env / local.env。
# 分开的理由不是洁癖：`git clean -xfd` / 重新 clone 会连同被忽略的文件一起抹掉，
# 而 last-snapshot.json 丢了会把下周所有 issue 报成新增（2026-08-07 那类事故）。
# 默认走 XDG 约定；cron / plist 可用 CRASH_REPORT_STATE_DIR 指到别处。
STATE="${CRASH_REPORT_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/crash-triage}"

# PATH 由 setup.sh 探测后写入 path.env——launchd / cron 只给最小 env，硬编码路径在别的机器上必挂。
if [ -f "$STATE/path.env" ]; then
  # shellcheck disable=SC1091
  . "$STATE/path.env"
else
  PATH="/opt/homebrew/bin:/opt/homebrew/share/google-cloud-sdk/bin:/usr/local/bin:$HOME/.npm-global/bin:/usr/bin:/bin:/usr/sbin:/sbin"
fi

# 机器本地配置（CRASH_REPORT_CHAT_ID 等）。与 path.env 分家的理由：setup.sh 每次重跑都用 `>`
# 整个覆写 path.env（只留探测出的 PATH 一行），配置写那儿会被 install.sh / update.sh 抹掉。
# local.env 由人手写、setup.sh 永不触碰，且**在此处 source 会盖掉命令行传入的同名环境变量**——
# 这正是要的：本机身份由机器决定，不由手打的命令决定（2026-08-20 测试差点把卡片发进正式群）。
[ -f "$STATE/local.env" ] && . "$STATE/local.env"   # shellcheck disable=SC1091
# 必须 export：alert.sh / deliver.sh 是**子进程**，local.env 里的普通赋值它们看不见。
# 2026-08-20 实测：只靠 local.env 的机器，失败告警被 alert.sh 当成「未设置 CHAT_ID」静默跳过。
# （生产机因 wrapper 里已 export、普通赋值保留 export 属性而侥幸没中招。）
export CRASH_REPORT_CHAT_ID
export PATH

TS="$(date +%Y%m%d-%H%M%S)"
# 文档标题带时分：同日多次跑批会覆盖 docs.json 里同一份文档（键 daily-<日期>），
# 但飞书文档列表里只看标题分不清是哪一次的产物，排障时尤其难受（2026-08-20 Sir 反馈）。
# 键保持 daily-<日期> 不变——覆盖语义是对的，改的只是标题可读性。
TS_HM="$(date +%H:%M)"
DAY="$(date +%Y-%m-%d)"
LOG="$STATE/logs/daily-$TS.log"
RUN_ID="$TS"
# 审计事件流（change crash-perf-execution-audit-log）：每 run 一个 JSONL，
# 只记录不 gating。文件名带 daily-/weekly- 前缀（同 logs/ 命名）——两条链路共用
# audit/ 目录，不带前缀会让同日重复 run 检测把对方误判成重复。
AUDIT_DIR="$STATE/audit"
AUDIT_FILE="$AUDIT_DIR/daily-$RUN_ID.events.jsonl"
mkdir -p "$AUDIT_DIR"
SQL_DIR="${SQL_DIR:-$ROOT/bin/sql}"
PROJECT="dino-english-497507"

CHAT_ID="${CRASH_REPORT_CHAT_ID:?未设置 CRASH_REPORT_CHAT_ID}"
DOC_DAILY_ID="${DOC_DAILY_ID:-}"        # 日报文档；固定一份每天 overwrite
DOC_INDEX_ID="${DOC_INDEX_ID:-}"        # 索引页
# 台账移交 L2 独占产出（change crash-ledger-l2-ownership D1），L1 不再持有 LEDGER_SRC / DOC_LEDGER_ID，
# 索引页台账入口改为固定 URL 直链，见 build_index() 与下方 CLAUDE.md 固定文档表。
LEDGER_URL="${LEDGER_URL:-https://qjphu5vphyf4.jp.larksuite.com/docx/TtpwdhgKroMH1DxJumojTflrppz}"
# 报告归档（日报 + 周报统一一份）：deliver.sh 在文档建成后追加 {type,day,url,...}。
# 落 $STATE 而不是仓库：它由无人值守的生产机追加，而那台机器推不了 git（无凭证），
# 条目只会永远躺在工作区——一次 git clean / 重新 clone 就没了，还会让 update.sh 的
# git pull --ff-only 卡住、两台机器各写各的必然分叉（2026-08-20 三样全踩到）。
# 现与 docs.json / last-snapshot.json 同级：同样不可再生，同样靠"别删 $STATE"保底。
# 仓库里的 reports/report-index.jsonl 保留为历史存档，运行时不再写入。
ARCHIVE_FILE="${CRASH_REPORT_ARCHIVE:-$STATE/report-index.jsonl}"
ARCHIVE_DAILY_KEEP="${CRASH_REPORT_ARCHIVE_DAILY_KEEP:-30}"   # 索引页里日报归档表渲染多少行（文件本身不截断）
DRY_RUN="${CRASH_REPORT_DRY_RUN:-0}"
DAYS="${CRASH_REPORT_DAYS:-1}"
# 性能窗口（D3）：firebase_performance 每日批量同步滞后约 2 天，DAYS=1 在每天 07:00 跑必然空表，
# 故独立放宽到 3 天；版本放量保持 DAYS（sessions REALTIME 为实时活源）。
PERF_DAYS="${CRASH_REPORT_PERF_DAYS:-3}"
# 崩溃窗口与 MCP topIssues 的 Firebase 默认 7 天窗一致；日窗口太窄（iOS 样本极少）会误读为「无崩溃」。
CRASH_DAYS="${CRASH_REPORT_CRASH_DAYS:-7}"
# 前后台摘要行的出现条件（change crash-fg-bg-split）：样本 >= N 且后台占比 >= P%。
# ⚠️ 这两个值只控制「要不要多说一句」，**不参与任何红黄绿判定**——后台占比高不是告警。
FGBG_MIN_EVENTS="${CRASH_REPORT_FGBG_MIN_EVENTS:-20}"
FGBG_BG_NOTE_PCT="${CRASH_REPORT_FGBG_BG_NOTE_PCT:-80}"

# ── 版本口径（change crash-perf-latest-2-versions）───────────────────
VERSION_COUNT="${CRASH_REPORT_VERSION_COUNT:-2}"   # 日报统计的最新版本个数
# ⚠️ 版本候选门槛**已废弃**（2026-08-22）：`latest-versions.sql` 不再按会话数过滤——
# 门槛会把刚放量或已被叫停的新版静默剔除，而那是最该盯的时刻。小样本改由
# SAMPLE_SESSION_MIN 在单元格上打「⚠️」标出来。此常量仅为兼容占位符替换而保留。
MIN_SESSIONS="${CRASH_REPORT_MIN_SESSIONS:-1}"
MAX_VERSION_COLS="${CRASH_REPORT_MAX_VERSION_COLS:-4}"  # 最新 N 版 ∪ 主力 2 版后的列数上限
# 卡片列上限（change crash-data-completeness B 组）：卡片列集合 = 最新 N 版 ∪ 性能可得 2 版，
# ⚠️ **不含主力补充列**（那是文档的事，卡片一向只放 V1/V2）。
# ⚠️ 3 是版面上限不是口径：CardKit 表格列宽由内容撑开，列多了桌面端会截断
#    （实测长文案已经被截成「⚠️ 数据未同步（截至...」），故单元格一律走 CELL_BREVITY 短文案。
CARD_VERSION_COLS="${CRASH_REPORT_CARD_VERSION_COLS:-3}"

# ── 阈值红绿灯（R3 / D5）：脚本顶部集中可配常量 ────────────────────────
# 红档 = 已拍板；黄/绿 = explore 建议值落地，全部显式标注「待对齐」。
# 判定统一走 traffic_light()（>红=🔴；>黄=🟡；否则🟢），命中红档才出告警，黄档仅注释待对齐。
# 判定对象 = **最新版**（上一版与主力补充列只展示不告警，design D8）。
CRASH_RATE_RED=1.0        # 崩溃率 红 >1%（拍板）；黄 0.5–1%、绿 <0.5%（待对齐）
CRASH_RATE_YELLOW=0.5
# ANR 率（仅 Android；iOS 系统层无此概念，数据源不产出该 error_type）。
# ⚠️ 0.47 参考 Google Play 的 Bad Behaviour 门槛，但**口径不同**：
#    Play 用「用户感知 ANR 率」（日活用户分母），我们用「ANR 事件数 / 会话数」。
#    取此值只因没有更好的锚且宁可偏严，**不是对齐后的数值**——报告上必须标注不可直接对照。
ANR_RATE_RED=0.47
ANR_RATE_YELLOW=0.24
# crash-free 会话率：**方向与其它指标相反，越大越好**。
# ⚠️ `traffic_light()` 的语义是「大于红线 → red」，直接套用会把 100% 判成红档且**不会报错**，
#    只会安静地把最健康的版本标红。因此判定时用「崩溃会话率」（100 − crash-free）这个坏方向值，
#    与其余指标保持同一套判定语义；展示时才换回 crash-free。
CRASH_FREE_RED=99.0       # 低于此 → 红（等价：崩溃会话率 > 1.0%）
CRASH_FREE_YELLOW=99.5    # 低于此 → 黄（等价：崩溃会话率 > 0.5%）
NET_ERR_RED=1.0           # 接口错误率 红 >1%（需求对齐）；黄 0.5–1%、绿 <0.5%（待对齐）
NET_ERR_YELLOW=0.5
SLOW_FRAME_RED=50         # 慢帧占比 红 >50%（拍板）；黄 30–50%、绿 ≤30%（待对齐）
SLOW_FRAME_YELLOW=30
FROZEN_RED=1.0            # 冻结率 红 >1%（拍板）；黄 0.5–1%、绿 <0.5%（待对齐）
FROZEN_YELLOW=0.5
START_P95_RED=2000        # 启动 P95 红 >2000ms（拍板）；黄 1500–2000、绿 ≤1500（待对齐）
START_P95_YELLOW=1500
# 小样本会话数阈值：**版本级**会话数低于此值 → 单元格追加「⚠️」，
# 且**告警判定回退到会话量最大的版本**（change crash-alert-sample-fallback）。
# 改为可配是为了能验证「稳态等价性」——调低它即可模拟「最新版样本充足」的常态。
SAMPLE_SESSION_MIN="${CRASH_REPORT_SAMPLE_SESSION_MIN:-30}"
# 维度级样本门槛：**只用于决定要不要显示率**，不用于过滤行（过滤掉就看不见影响面了）。
# ⚠️ Android 机型碎片化到无法给率：实测某版本 7 天内最大机型桶只有 75 个会话，
#    门槛设 50 只剩 1 行、设 100 一行不剩。故机型维度一律不显示率，只有系统版本维度显示。
DIM_MIN_SESSIONS="${CRASH_REPORT_DIM_MIN_SESSIONS:-200}"
DIM_TOP="${CRASH_REPORT_DIM_TOP:-3}"       # 每维度每版本取前 N（拆版本后条目翻倍，收紧到 3）

mkdir -p "$STATE"/{logs,reports}
exec > >(tee -a "$LOG") 2>&1
echo "=== 崩溃 & 性能日报 ${TS}（最新 $VERSION_COUNT 个版本口径）==="

# ── 故障告警：失败要发出去，不能死在日志里 ─────────────────
# 两条通路：fail() 覆盖已知失败，ERR trap 兜住未预期的非零退出（set -e 直接杀进程那种）。
# ALERTED 防重复：fail() 已发过就不再由 trap 补发。
# ⚠️ ALERTED 只在主进程有效：命令替换 / 管道都在子 shell 里跑，那里的 ALERTED=1 传不回来。
# 2026-08-21 实测一次 grep 无匹配就在群里连发 8 张卡。去重改用文件标记，跑批开始时清一次。
# 五个共享函数（step / alert_once / err_stack / on_err / fail）已收口到 bin/lib/common.sh。
# 两条链路仅有的差异用下面四个变量表达——此前为这三处不同，整整 5 个函数各存了一份。
ALERT_FLAG="$STATE/.alerted-daily"
ALERT_SOURCE="daily"
ALERT_RUN_ID="$RUN_ID"
HEALTH_FILE="$STATE/health-daily.json"
rm -f "$ALERT_FLAG"
if [ -f "$ROOT/bin/lib/common.sh" ]; then
  # shellcheck disable=SC1091
  . "$ROOT/bin/lib/common.sh"
else
  # 与 lib.sh 同样的回落：文件缺失不阻塞主流程，退化成最小实现
  ALERTED=0; CURRENT_STEP="启动"
  step() { CURRENT_STEP="$1"; echo "--- $1 ---"; }
  alert_once() { :; }
  err_stack() { printf 'main()'; }
  on_err() { :; }
  fail() { echo "❌ $*"; exit 1; }
fi
set -o errtrace
trap 'on_err' ERR   # 不传 ${LINENO}：bash 3.2 下它不准，位置改由 err_stack 的函数链给

# ── bq 超时护栏（2026-08-19 事故修复）─────────────────
# 事故：07:00 那次 L1 卡在「逐版本取数」，日志 07:06 起再无输出，3600s 后被 cron 判超时，
# 群里当天没有收到日报。当时 8 处 bq 调用一处都没有超时保护——一条查询挂住就吊死整个 job。
#
# ⚠️ 三条铁律（都是实测踩出来的）：
# ① **SQL 不能作为位置参数传给 bq**。SQL 文件以 `--` 注释开头，bq 的 flag 解析器会把它当
#    命令行开关，直接 `FATAL Flags parsing error`；`--` 分隔符与 `--query=` 都无效。只能走 stdin。
# ② **重定向必须写在子 shell 内部**。run_with_timeout 以 `&` 起后台任务，POSIX 规定异步列表的
#    stdin 在显式重定向之前被指定为 /dev/null——`run_with_timeout N bq ... < f` 会读到空。
#    故包一层 `bash -c 'exec bq ... < "$1"'`，让重定向在子进程里生效。
# ③ **stderr 不能丢给 /dev/null**。今早正是因为 `2>/dev/null` 连 bq 报错一起吞了，
#    事后无法回溯「哪条查询卡住」。改为落盘到 ${BQ_ERRLOG}，超时另打一行可见提示。
. "$ROOT/bin/lib/csv.sh"   # bq CSV 解析唯一入口（csv2tsv / csv_field1），L1/L2 共用
. "$ROOT/bin/lib/query.sh" # SQL 占位符替换唯一入口（q_render），漏传占位符当场失败
if [ -f "$ROOT/bin/lib.sh" ]; then
  # shellcheck disable=SC1091
  . "$ROOT/bin/lib.sh"
else
  run_with_timeout() { local s="$1"; shift; "$@"; }   # 无 lib.sh 时退化为直接执行
  cleanup_old_runs() { :; }                            # 无 lib.sh 时跳过清理，不阻塞主流程
  day_ago() { date -v-"${1:-0}"d +%Y-%m-%d 2>/dev/null; }   # 同上：保留期清理要用，缺了会整跑失败
fi
# 核心层（纯函数）。不依赖任何全局，加载顺序任意；缺失则整跑失败——
# 这些是阈值判定与格式化的唯一实现，退化版本会静默产出错误数字，比直接失败危险得多。
for _c in format verdict version cache; do
  # shellcheck disable=SC1090
  . "$ROOT/bin/lib/core/${_c}.sh" || { echo "❌ 核心层缺失：bin/lib/core/${_c}.sh" >&2; exit 1; }
done

# bq 查询唯一通道已收口到 bin/lib/bq.sh（findings F1/F5：直连绕过等价性缓存，
# 冻结面出洞）。缓存与超时的说明见该文件顶部。缺失直接失败不退化——
# bqq 是取数唯一通道，退化实现会静默丢掉超时与缓存。
# shellcheck disable=SC1091
. "$ROOT/bin/lib/bq.sh" || { echo "❌ 外壳层缺失：bin/lib/bq.sh" >&2; exit 1; }
bq_init
# ⛔ EXIT trap 用**完成哨兵**判定成败，⚠️ 不能靠 `$?`——bash 3.2 在 `set -u` 未定义变量
#    这条致命路径上，**进 trap 时 `$?` 已经是 0**（实测；普通命令失败时才是 1）。
#    而 unbound variable 恰是本仓库最常见的失败模式（多字节首字节被并进变量名）。
#    不修则三重静默：退出码 0 + ERR trap 不触发（shell 错误不是命令失败）+ health
#    停在上一轮的 ok:true——cron 看到成功、无告警、群里却收不到报告（2026-08-24 实测）。
#    ⚠️ 任何提前 `exit 0` 的合法路径都必须先置 RUN_COMPLETED=1。
trap 'rm -f "$BQ_SQLTMP"; [ "${RUN_COMPLETED:-0}" = 1 ] || exit 1' EXIT

# run.start 与同日重复 run 检测（design D5：只记录不中止——同日重跑常是人工补救）
audit run.start "" "$(jq -cn --arg day "$DAY" --arg sha "$(git -C "$ROOT" rev-parse --short HEAD 2>/dev/null || echo '?')" '{day:$day,git:$sha}')"
_PRIOR_RUNS="$(find "$AUDIT_DIR" -maxdepth 1 -name "daily-${RUN_ID%%-*}-*.events.jsonl" ! -name "daily-${RUN_ID}.events.jsonl" 2>/dev/null | sed 's|.*/||; s|\.events\.jsonl$||' | sort | paste -sd, - || true)"
[ -z "$_PRIOR_RUNS" ] || audit duplicate_run "" "$(jq -cn --arg p "$_PRIOR_RUNS" '{prior_runs:$p}')"

# ── 探活 ──────────────────────────────────────────────
# 飞书投递已改由 Hermes agent 经 lark-mcp 完成（脚本只产出内容、不再直连飞书），此处只探数据源。
bqq csv 'SELECT 1' >/dev/null 2>&1 \
  || fail "bq 不可用或超时，检查 gcloud auth 与项目设置"

TMP="$STATE/runs/$DAY/L1/$TS"
mkdir -p "$TMP"

# ── 查询助手（全部带版本过滤；{{VERSIONS}} 的值是带引号的逗号列表，谓词写在 SQL 文件里）──
vlist() { printf '"%s"' "$1"; }   # 单版本 → "1.5.4"（多版本形式保留给未来 N>1 的合并查询）

# ⚠️ q() 只服务性能三查（perf-traces / perf-screens / perf-network），窗口一律是**完整日闭区间**——
#    故直接收两端日期，不再收「天数」。⛔ 起止由调用方显式算好传入，本函数不设默认值：
#    共享层一旦有默认窗口，漏传时会静默用错窗口（bin/lib/query.sh 顶部同一条纪律）。
q() { # $1=sql文件 $2=表名 $3=起日 $4=止日 $5=版本 → CSV（无表头）
  local _t0=$SECONDS _rc=0 _out
  [ -n "$3" ] && [ -n "$4" ] || { echo "" ; return 0; }
  _out="$(bqq csv "$(q_render "$1" TABLE="$2" LCD_START="$3" LCD_END="$4" VERSIONS="$(vlist "$5")")" \
    | tail -n +2)" || _rc=$?
  audit query q "$(jq -cn --arg sql "$1" --arg tbl "$2" --arg from "$3" --arg to "$4" --arg ver "$5" \
    --argjson rows "$(printf '%s' "$_out" | grep -c . || true)" --argjson secs "$((SECONDS - _t0))" --argjson rc "$_rc" \
    '{fn:"q",sql:$sql,table:$tbl,from:$from,to:$to,version:$ver,rows:$rows,secs:$secs,rc:$rc}')"
  [ -n "$_out" ] && printf '%s\n' "$_out"
  return 0
}
qc() { # $1=sql文件 $2=crashlytics表 $3=sessions表 $4=窗口天数 $5=版本 → JSON
  # 崩溃查询用 --format=json + jq 渲染：issue 标题是自由文本可能含逗号，CSV+awk 会错列。
  local _t0=$SECONDS _rc=0 _out
  _out="$(bqq json "$(q_render "$1" TABLE="$2" SESSIONS_TABLE="$3" DAYS="$4" \
                  VERSIONS="$(vlist "$5")" LIMIT="${ISSUE_LIMIT:-20}" FG_NORM="${SQL_FG_NORM}")")" || _rc=$?
  audit query qc "$(jq -cn --arg sql "$1" --arg tbl "$2" --arg days "$4" --arg ver "$5" \
    --argjson rows "$(printf '%s' "$_out" | jq 'length' 2>/dev/null || echo -1)" --argjson secs "$((SECONDS - _t0))" --argjson rc "$_rc" \
    '{fn:"qc",sql:$sql,table:$tbl,days:$days,version:$ver,rows:$rows,secs:$secs,rc:$rc}')"
  [ -n "$_out" ] && printf '%s\n' "$_out"
  return 0
}
# 维度查询：crash-dimensions.sql 需要额外的 {{DIM}} / {{SESS_DIM}} / {{SESSIONS_TABLE}} / {{MIN_SESSIONS}}，
# 与 q()/qc() 的占位符集合不同，单独一个助手，不把 q() 撑成万能函数。
qdim() { # $1=crash表 $2=sessions表 $3=版本 $4=维度表达式 $5=取几条 → CSV（无表头）
  local _t0=$SECONDS _rc=0 _out
  _out="$(bqq csv "$(q_render crash-dimensions.sql TABLE="$1" SESSIONS_TABLE="$2" DAYS="$CRASH_DAYS" \
                 VERSIONS="$(vlist "$3")" DIM="$4" SESS_DIM="$4" LIMIT="$5" MIN_SESSIONS="$DIM_MIN_SESSIONS")" \
                 | tail -n +2)" || _rc=$?
  audit query qdim "$(jq -cn --arg tbl "$1" --arg ver "$3" --arg dim "$4" \
    --argjson rows "$(printf '%s' "$_out" | grep -c . || true)" --argjson secs "$((SECONDS - _t0))" --argjson rc "$_rc" \
    '{fn:"qdim",sql:"crash-dimensions.sql",table:$tbl,version:$ver,dim:$dim,rows:$rows,secs:$secs,rc:$rc}')"
  [ -n "$_out" ] && printf '%s\n' "$_out"
  return 0
}
# 无分母维度取数（change crash-screen-dimension）。
# ⚠️ 与 qdim 的三点不同，任一处套错都不报错只出坏数：
#   ① 不 JOIN sessions、**没有率**（sessions 表无 screen 字段，页面级会话分母不存在）
#   ② **列序不同**：本份第 4 列是集中度，qdim 那份第 4/5 列是 sessions / rate_pct
#   ③ 错误类型由调用方给——iOS 须传 'NON_FATAL'（实测 iOS 60 天仅 5 次致命崩溃，
#      按致命口径出来是空表，而「表里只有一行」与「iOS 很健康」在版面上长得一样）
qdim_nd() { # $1=crash表 $2=版本 $3=维度表达式 $4=取几条 $5=错误类型白名单 → CSV（无表头）
  local _t0=$SECONDS _rc=0 _out
  _out="$(bqq csv "$(q_render crash-dimensions-nodenom.sql TABLE="$1" DAYS="$CRASH_DAYS" \
                 VERSIONS="$(vlist "$2")" DIM="$3" LIMIT="$4" ERROR_TYPES="$5")" | tail -n +2)" || _rc=$?
  audit query qdim_nd "$(jq -cn --arg tbl "$1" --arg ver "$2" --arg dim "$3" --arg et "$5" \
    --argjson rows "$(printf '%s' "$_out" | grep -c . || true)" --argjson secs "$((SECONDS - _t0))" --argjson rc "$_rc" \
    '{fn:"qdim_nd",sql:"crash-dimensions-nodenom.sql",table:$tbl,version:$ver,dim:$dim,error_types:$et,rows:$rows,secs:$secs,rc:$rc}')"
  [ -n "$_out" ] && printf '%s\n' "$_out"
  return 0
}
qhours() { # $1=crash表 $2=版本 → CSV（无表头）
  local _t0=$SECONDS _rc=0 _out
  _out="$(bqq csv "$(q_render crash-hours.sql TABLE="$1" DAYS="$CRASH_DAYS" \
                 VERSIONS="$(vlist "$2")")" | tail -n +2)" || _rc=$?
  audit query qhours "$(jq -cn --arg tbl "$1" --arg ver "$2" \
    --argjson rows "$(printf '%s' "$_out" | grep -c . || true)" --argjson secs "$((SECONDS - _t0))" --argjson rc "$_rc" \
    '{fn:"qhours",sql:"crash-hours.sql",table:$tbl,version:$ver,rows:$rows,secs:$secs,rc:$rc}')"
  [ -n "$_out" ] && printf '%s\n' "$_out"
  return 0
}
# ⚠️ 第三参是「窗口参数」不是固定语义：daily-crash-1d / daily-sessions-1d 用 {{DAYS}}（距今天数），
#    daily-perf-1d 用 {{DAY}}（完整日日期 YYYY-MM-DD）。两个占位符都喂进去，各 SQL 各取所需——
#    q_render 对**多传**不报错（那是通用包装的常态），只对漏传当场失败。
q1d() { # $1=sql文件 $2=表名 $3=窗口参数（天数 或 YYYY-MM-DD）$4=版本 → 单行 JSON 对象（无数据/超时 → {}）
  local _t0=$SECONDS _rc=0 _out
  _out="$(bqq json "$(q_render "$1" TABLE="$2" DAYS="$3" DAY="$3" VERSIONS="$(vlist "$4")")" \
    | jq -c '.[0] // {}' 2>/dev/null)" || _rc=$?
  [ -n "$_out" ] || _out='{}'
  audit query q1d "$(jq -cn --arg sql "$1" --arg tbl "$2" --arg days "$3" --arg ver "$4" \
    --argjson empty "$([ "$_out" = "{}" ] && echo true || echo false)" --argjson secs "$((SECONDS - _t0))" --argjson rc "$_rc" \
    '{fn:"q1d",sql:$sql,table:$tbl,days:$days,version:$ver,empty:$empty,secs:$secs,rc:$rc}')"
  printf '%s\n' "$_out"
  return 0
}
m1() { printf '%s' "${1:-}" | jq -r --arg k "$2" '.[$k] // empty' 2>/dev/null || echo ""; }

# bq show 要 project:dataset.table（冒号），查询里用的是 project.dataset.table（全点号）——
# 只替换第一个点为冒号。踩过：直接传点号格式会永远返回「表不存在」。
# 存在性探测只认 bq 明确返回的「not found」为「不存在」；429/5xx/网络/超时等瞬时错误
# 有界重试（3 次、线性退避 2s/4s），重试耗尽仍未确证「不存在」→ 按「存在」处理（返回真），
# 让后续查询自行失败并触发既有「数据未同步」告警，而不是误回退到停更批量表。
# 注意：bq show 的「Not found」错误信息写 stdout 而非 stderr（实测），须 2>&1 合并捕获，不能只捕 stderr。
table_exists() { # $1=project.dataset.table → 0=存在 / 1=确证不存在
  local tbl="${1/./:}" attempt out rc
  for attempt in 1 2 3; do
    rc=0
    out="$(run_with_timeout "$BQ_TIMEOUT" bq show --format=none "$tbl" 2>&1)" || rc=$?
    if [ "$rc" -eq 0 ]; then
      audit query table_exists "$(jq -cn --arg t "$1" --argjson a "$attempt" '{fn:"table_exists",table:$t,attempt:$a,verdict:"exists"}')"
      return 0
    fi
    if printf '%s' "$out" | grep -qi 'not found'; then
      audit query table_exists "$(jq -cn --arg t "$1" --argjson a "$attempt" '{fn:"table_exists",table:$t,attempt:$a,verdict:"not_found"}')"
      return 1
    fi
    audit query table_exists "$(jq -cn --arg t "$1" --argjson a "$attempt" --argjson rc "$rc" '{fn:"table_exists",table:$t,attempt:$a,rc:$rc,verdict:"transient_retry"}')"
    if [ "$attempt" -lt 3 ]; then sleep "$((attempt * 2))"; fi
  done
  audit query table_exists "$(jq -cn --arg t "$1" '{fn:"table_exists",table:$t,verdict:"assumed_exists"}')"
  return 0
}
# 表最新 event_timestamp。**刻意不带版本过滤**：它服务于「表整体是否停更」的判定（data_state 第 2 态），
# 带上版本过滤会把「新版还没产生数据」误判成「数据源故障」，天天误报（design D6）。
table_max() { [ -n "$1" ] || { echo ""; return 0; }
  local _t0=$SECONDS _rc=0 _out
  _out="$(bqq csv "SELECT FORMAT_TIMESTAMP('%Y-%m-%d %H:%M UTC', MAX(event_timestamp)) AS ts FROM \`$1\`" \
    | tail -n +2 | tail -1)" || _rc=$?
  audit query table_max "$(jq -cn --arg tbl "$1" --arg max "$_out" --argjson secs "$((SECONDS - _t0))" --argjson rc "$_rc" \
    '{fn:"table_max",table:$tbl,max:$max,secs:$secs,rc:$rc}')"
  [ -n "$_out" ] && printf '%s\n' "$_out"
  return 0; }
# 性能表在完整日窗口内**有数据的版本清单**（change crash-data-completeness B 组）。
# ⛔ 判据只有一条：该版本在窗口内有没有行。**MUST NOT 引入任何会话量门槛**——
#    `MIN_SESSIONS` 由 5 中和为 1 是 2026-08-22 的实测决定（Android 1.5.4 被叫停后从卡片上完全消失），
#    用「性能数据有没有」绕回一个等价的会话量门槛同样是禁止的（Non-goal）。
# ⚠️ tasks 2.2 原文是「逐个查该版本有没有值」（每候选一条，最多 4 条 × 2 端）。
#    改为**一次 DISTINCT 查全窗口**：判据完全相同，查询数从最多 8 条降到 2 条。
# ⚠️ 同一条查询顺带把**残日**（> LCD，即那 7 小时未完整的尾巴）也数出来：
#    某版本「窗口内 0 行、残日有行」⇒ 明天 LCD 推进一天它就有数据了，第 3 态细分据此说出
#    「预计 X 到位」而不是空口承诺（change crash-data-completeness C 组）。多一列不多一条查询。
perf_version_scan() { # $1=perf表 $2=起日 $3=止日(LCD) → TSV「版本 窗口内行数 残日行数」
  [ -n "$1" ] && [ -n "$2" ] && [ -n "$3" ] || { echo ""; return 0; }
  local _t0=$SECONDS _rc=0 _out
  _out="$(bqq csv "SELECT app_display_version AS v,
      COUNTIF(DATE(event_timestamp) BETWEEN '$2' AND '$3') AS in_win,
      COUNTIF(DATE(event_timestamp) > '$3') AS in_tail
    FROM \`$1\` WHERE DATE(event_timestamp) >= '$2' GROUP BY v" \
    | tail -n +2 | grep -v '^$' | csv2tsv || true)" || _rc=$?
  audit query perf_version_scan "$(jq -cn --arg tbl "$1" --arg from "$2" --arg to "$3" \
    --argjson n "$(printf '%s' "$_out" | grep -c . || true)" --argjson secs "$((SECONDS - _t0))" --argjson rc "$_rc" \
    '{fn:"perf_version_scan",table:$tbl,from:$from,to:$to,versions:$n,secs:$secs,rc:$rc}')"
  [ -n "$_out" ] && printf '%s\n' "$_out"
  return 0
}
# 从 perf_version_scan 的 TSV 里取某一列非零的版本清单。⛔ 走 csv2tsv 的产物按制表符切，
#    不裸 cut -d,（版本号不含逗号，但这条纪律不因「这次碰巧安全」而破例）。
scan_vers() { # $1=scan TSV $2=列号(2=窗口内 3=残日) → 该列 > 0 的版本
  printf '%s\n' "$1" | awk -F'\t' -v c="$2" 'NF>=3 && $c+0 > 0 {print $1}' || true
}

# ── 三态数据判定（design D6，顺序不可颠倒）────────────────────────
# 1 表不存在 → table_missing；2 表整体窗口内无数据 → stale；3 表有数据但该版本 0 行 → no_version
data_state() { # $1=表 $2=该版本查询是否有行(非空且非0即有) $3=表整体 MAX 时间戳 $4=停更天数（空=未停更）
  if [ -z "$1" ]; then echo table_missing; return 0; fi
  if [ -n "$2" ] && [ "$2" != "0" ]; then echo ok; return 0; fi
  # 第 2 态不能只判「MAX 为空」：表里存着 08-17 的数据、导出却已断更 4 天时，MAX 非空，
  # 判定就会掉进第 3 态「该版本无数据」——那是「新版刚发」的常态噪音，没人会追。
  # 2026-08-21 实测：firebase_performance 断更 4 天，日报每天照出，没有任何信号（stale_days()）。
  if [ -z "$3" ] || [ -n "${4:-}" ]; then echo stale; return 0; fi
  echo no_version
}
# 崩溃段单独判定：有会话就有分母，「0 条致命事件」是结论本身（0 崩溃），不是缺数。
# 渲染成「该版本无数据」会让「这版没崩过」这个最该被看见的好消息消失。
crash_state() { # $1=crashlytics表 $2=表整体 MAX 时间戳
  [ -n "$1" ] || { echo table_missing; return 0; }
  [ -n "$2" ] && echo ok || echo stale
  return 0
}
# CELL_BREVITY=1 时用短文案（卡片用）。
# ⚠️ 起因：性能停更时，「⚠️ 数据未同步（截至 2026-08-18 06:59 UTC）」这一句会在
# 8 个格子里各重复一遍，把 CardKit 表格的列宽整个撑爆——实测桌面端就已经截断成
# 「⚠️ 数据未同步（截至...」，信息量归零。而**截止时刻在卡片顶部的黄色摘要行里已经说过了**，
# 格子里重复 8 遍纯属浪费。文档不受此限（有的是宽度），仍给完整文案。
CELL_BREVITY=0
state_text() { # $1=state $2=表整体最新时间戳 → 单元格文案
  case "$1" in
    ok)            printf '';;
    table_missing) [ "$CELL_BREVITY" = 1 ] && printf '表未同步' || printf '表未同步';;
    stale)         if [ "$CELL_BREVITY" = 1 ]; then printf '⚠️ 停更'
                   else printf '⚠️ 数据未同步（截至 %s）' "${2:-—}"; fi;;
    no_version)    [ "$CELL_BREVITY" = 1 ] && printf -- '— 无数据' || printf -- '— 该版本无数据';;
  esac
}

# ── 数值格式化 ────────────────────────────────────────
csv() { csv_field1 "$1" "$2"; }   # bq CSV 取列一律走 bin/lib/csv.sh，⛔ 不得裸 cut -d,
daily_rate() { rate_pct "$1" "$2"; }

# ── 取数区间（双时区）─────────────────────────────────
# 窗口起点 = 本次跑批时刻 − N 天，因为所有滚动窗口 SQL 写的都是
#   WHERE event_timestamp >= TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL {{DAYS}} DAY)
# 即下界锚在**跑批时刻**而非数据最新时刻——直接由 shell 算出，不额外查 BigQuery。
# 终点用各表的 table_max()（实际取到的最新数据），与起点的差 = 数据滞后，缺口本身就是要看见的信息。
# 注意起点是「查询下界」不是「首条数据时间」，故措辞一律用「窗口」不用「数据自」。
RUN_EPOCH="$(date +%s)"
TZ_LABEL="$(date '+%z')"

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
    printf '🔴 %s' "$(_alert_body "$1" "${IOS_ALERT_VER:-—}" "$2" "${AND_ALERT_VER:-—}" "$3" "$6")"
  fi
}
yellow_line() {
  local li la
  li="$(traffic_light "$2" "$4" "$5")"; la="$(traffic_light "$3" "$4" "$5")"
  { [ "$li" = "red" ] || [ "$la" = "red" ]; } && return 0
  if [ "$li" = "yellow" ] || [ "$la" = "yellow" ]; then
    printf '🟡 %s' "$(_alert_body "$1" "${IOS_ALERT_VER:-—}" "$2" "${AND_ALERT_VER:-—}" "$3" "$6")"
  fi
}
# 单端摘要行：某指标只在一端存在时用它，**不给另一端补占位值**。
# ANR 属于这种：iOS 系统层无此概念，走 _alert_body 会渲染成「（iOS 1.5.4 无数据）」——
# 而「无数据」的语义是「该取到却没取到」，与「这类事件不存在」是两回事，混用会误导。
red_line_one() { # $1=指标名 $2=平台名 $3=版本 $4=值 $5=红 $6=黄 $7=单位
  [ "$(traffic_light "$4" "$5" "$6")" = "red" ] || return 0
  printf '🔴 %s %s' "$1" "$(alert_side "$2" "$3" "$4" "$7")"
}
yellow_line_one() { # 同上；红档已出则不重复出黄档
  [ "$(traffic_light "$4" "$5" "$6")" = "yellow" ] || return 0
  printf '🟡 %s %s' "$1" "$(alert_side "$2" "$3" "$4" "$7")"
}
# 非空才追加（避免空行）；恒返回 0（否则 set -e 在空输入时误炸）
ALERTS=""
add_alert() { [ -n "$1" ] && ALERTS="${ALERTS:+$ALERTS
}$1"; return 0; }


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

step "选表"
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
IOS_PERF_STALE="$(stale_days "$RUN_EPOCH" "$IOS_PERF_MAX" "$PERF_DAYS")"
AND_PERF_STALE="$(stale_days "$RUN_EPOCH" "$AND_PERF_MAX" "$PERF_DAYS")"
perf_stale_of() { [ "$1" = ios ] && printf '%s' "$IOS_PERF_STALE" || printf '%s' "$AND_PERF_STALE"; }
perf_max_of()   { [ "$1" = ios ] && printf '%s' "$IOS_PERF_MAX"   || printf '%s' "$AND_PERF_MAX"; }
newest_ts() { printf '%s\n%s\n' "$1" "$2" | grep -v '^$' | sort -r | head -1 || true; }
CRASH_UNTIL="$(newest_ts "$IOS_CRASH_MAX" "$AND_CRASH_MAX")"; [ -n "$CRASH_UNTIL" ] || CRASH_UNTIL="—"
DATA_UNTIL="$(newest_ts "$IOS_PERF_MAX" "$AND_PERF_MAX")";    [ -n "$DATA_UNTIL" ]  || DATA_UNTIL="—"
ADOPTION_UNTIL="$(newest_ts "$IOS_SESS_MAX" "$AND_SESS_MAX")"; [ -n "$ADOPTION_UNTIL" ] || ADOPTION_UNTIL="—"

# ── 性能窗口：完整日（change crash-data-completeness，design D1/D2）──────
# LCD = DATE(DATA_UNTIL) − 1，性能段取整日闭区间 [LCD−(PERF_DAYS−1), LCD]，DoD 取 LCD vs LCD−1。
# ⚠️ **只动性能段**：崩溃段（crashlytics 当日可见）与放量段（sessions 走 REALTIME 活表）
#    数据源新鲜度不同，完整日切分对它们没必要且平白损失新鲜度（Non-goal）。
# ⚠️ LCD 取**两端合并后**的 DATA_UNTIL（与既有各段截止标注同源，全报告一个窗口）；
#    某端滞后更多时，它在窗口尾部自然没有行——那由既有的 per-platform stale_days() 告警负责，
#    ⛔ 不在这里按端各算一个窗口（两端两套日期会让同一张表的两列不可比）。
PERF_LCD="$(last_complete_day "$DATA_UNTIL")"
PERF_WIN_START="$(day_shift "$PERF_LCD" "-$((PERF_DAYS - 1))")"
PERF_PREV_DAY="$(day_shift "$PERF_LCD" -1)"
if [ -n "$PERF_LCD" ]; then
  echo "  性能完整日窗口：${PERF_WIN_START} ~ ${PERF_LCD}（DoD ${PERF_LCD} vs ${PERF_PREV_DAY}）"
else
  echo "  ⚠️ 性能表无最新时间戳，完整日窗口无法确定——性能段走既有缺数三态第 2 态"
fi

# ── 版本解析（唯一源 = sessions 活表，design D1）────────────────────
step "解析版本清单"
resolve_versions() { # $1=sessions表 → CSV「version,sessions,devices」（无表头，未排序）
  [ -n "$1" ] || return 0
  bqq csv "$(q_render latest-versions.sql TABLE="$1" DAYS="$DAYS" MIN_SESSIONS="$MIN_SESSIONS")" \
    | tail -n +2 || true
}

IOS_VER_CSV="$(resolve_versions "$SESS_IOS")"
AND_VER_CSV="$(resolve_versions "$SESS_AND")"
IOS_NEWEST="$(pick_newest "$IOS_VER_CSV" "$VERSION_COUNT")"
AND_NEWEST="$(pick_newest "$AND_VER_CSV" "$VERSION_COUNT")"
IOS_TOPSESS="$(pick_top_sessions "$IOS_VER_CSV")"
AND_TOPSESS="$(pick_top_sessions "$AND_VER_CSV")"
# 性能段分域选版（B 组）：候选 = 该端最新 4 版（想要 2 + 回溯上限 2，design D4）
IOS_PERF_SCAN="$(perf_version_scan "$IOS_PERF_TBL" "$PERF_WIN_START" "$PERF_LCD")"
AND_PERF_SCAN="$(perf_version_scan "$AND_PERF_TBL" "$PERF_WIN_START" "$PERF_LCD")"
IOS_PERF_AVAIL="$(scan_vers "$IOS_PERF_SCAN" 2)"; IOS_PERF_TAIL="$(scan_vers "$IOS_PERF_SCAN" 3)"
AND_PERF_AVAIL="$(scan_vers "$AND_PERF_SCAN" 2)"; AND_PERF_TAIL="$(scan_vers "$AND_PERF_SCAN" 3)"
IOS_PERF_VERS="$(pick_versions_perf "$(pick_newest "$IOS_VER_CSV" $((VERSION_COUNT + 2)))" "$IOS_PERF_AVAIL" "$VERSION_COUNT" 2)"
AND_PERF_VERS="$(pick_versions_perf "$(pick_newest "$AND_VER_CSV" $((VERSION_COUNT + 2)))" "$AND_PERF_AVAIL" "$VERSION_COUNT" 2)"
# ⚠️ 4 个候选全无性能数据、而性能表本身有行 → 不是「新版还没同步」而是导出退化，必须说出来
#    （design D4：不继续往下翻，转既有「数据未同步」口径的告警文案）。
PERF_VER_WARN=""
for _pv in "iOS:$IOS_PERF_VERS:$IOS_PERF_AVAIL" "Android:$AND_PERF_VERS:$AND_PERF_AVAIL"; do
  _pn="${_pv%%:*}"; _rest="${_pv#*:}"; _sel="${_rest%%:*}"; _av="${_rest#*:}"
  if [ -z "$_sel" ] && [ -n "$_av" ]; then
    PERF_VER_WARN="${PERF_VER_WARN}${PERF_VER_WARN:+；}${_pn} 最新 $((VERSION_COUNT + 2)) 版在性能窗口内均无数据"
  fi
done
[ -n "$PERF_VER_WARN" ] && echo "  ⚠️ 数据未同步：${PERF_VER_WARN}——性能表有行但都不属于这些版本，疑似导出退化"
# 文档列集合 = 最新 N 版 ∪ 主力 2 版 ∪ 性能可得 2 版（上限 MAX_VERSION_COLS）
IOS_COLS="$(union_versions "$(printf '%s\n%s\n' "$IOS_NEWEST" "$IOS_PERF_VERS")" "$IOS_TOPSESS" "$MAX_VERSION_COLS")"
AND_COLS="$(union_versions "$(printf '%s\n%s\n' "$AND_NEWEST" "$AND_PERF_VERS")" "$AND_TOPSESS" "$MAX_VERSION_COLS")"
# 卡片列集合：最新 N 版 ∪ 性能可得 2 版（不含主力）
IOS_CARD_COLS="$(union_versions "$IOS_NEWEST" "$IOS_PERF_VERS" "$CARD_VERSION_COLS")"
AND_CARD_COLS="$(union_versions "$AND_NEWEST" "$AND_PERF_VERS" "$CARD_VERSION_COLS")"
ver_newest_of() { [ "$1" = ios ] && printf '%s' "$IOS_NEWEST" || printf '%s' "$AND_NEWEST"; }
# 该版本列是不是「只因为性能才进来的」——卡片与文档表头都要解释一个旧版本为什么占着一列。
# ⚠️ 只标这一种：最新 N 版里的列本来就该在，标了反而每列都是噪音。
# ⚠️ 卡片用短角标：6 列下表头也吃宽度，实发验证「iOS 1.5.3 性能兜底」这种长表头会被截。
#    ⛔ 短到只剩「·性能」是有代价的——它不再自解释，故卡片说明段必须留着那句完整解释。
perf_only_tag() { # $1=plat $2=版本 → 角标或空
  if printf '%s\n' "$(ver_newest_of "$1")" | grep -qx -- "$2"; then printf ''; return 0; fi
  if [ "$CELL_BREVITY" = 1 ]; then printf -- '·性能'; else printf ' 性能兜底'; fi
}
# 最新版 / 上一版（告警与版本间对比的两端）
IOS_V1="$(printf '%s\n' "$IOS_NEWEST" | sed -n 1p)"; IOS_V2="$(printf '%s\n' "$IOS_NEWEST" | sed -n 2p)"
AND_V1="$(printf '%s\n' "$AND_NEWEST" | sed -n 1p)"; AND_V2="$(printf '%s\n' "$AND_NEWEST" | sed -n 2p)"
echo "  iOS     最新 $VERSION_COUNT 版：$(printf '%s' "$IOS_NEWEST" | tr '\n' ' ')· 主力：$(printf '%s' "$IOS_TOPSESS" | tr '\n' ' ')· 性能可得：$(printf '%s' "$IOS_PERF_VERS" | tr '\n' ' ')· 文档列：$(printf '%s' "$IOS_COLS" | tr '\n' ' ')· 卡片列：$(printf '%s' "$IOS_CARD_COLS" | tr '\n' ' ')"
echo "  Android 最新 $VERSION_COUNT 版：$(printf '%s' "$AND_NEWEST" | tr '\n' ' ')· 主力：$(printf '%s' "$AND_TOPSESS" | tr '\n' ' ')· 性能可得：$(printf '%s' "$AND_PERF_VERS" | tr '\n' ' ')· 文档列：$(printf '%s' "$AND_COLS" | tr '\n' ' ')· 卡片列：$(printf '%s' "$AND_CARD_COLS" | tr '\n' ' ')"
# 版本解析失败不静默回退全版本（那等于偷偷改口径）：显式标记，各段渲染成「版本解析失败」。
IOS_VER_OK=1; [ -n "$IOS_V1" ] || IOS_VER_OK=0
AND_VER_OK=1; [ -n "$AND_V1" ] || AND_VER_OK=0
[ "$IOS_VER_OK" = 1 ] || echo "  ⚠️ iOS 版本解析失败（sessions 表窗口内无任何版本）"
[ "$AND_VER_OK" = 1 ] || echo "  ⚠️ Android 版本解析失败（sessions 表窗口内无任何版本）"

# ── 逐版本取数（design D5：每版本各跑一次查询，不做 GROUP BY version）──
# 产出 $TMP/m-<plat>-<ver>.json（卡片/文档共用）与三份明细 CSV（文档明细段用）。
collect_window() { # $1=plat键 $2=版本 $3=crash表 $4=sess表 $5=perf表 $6=crashMax $7=perfMax $8=版本CSV $9=perf停更天数
  local p="$1" v="$2" key="$1-$2"
  local issues='[]' rate='[]' n=0 ev=0 latest="" cev="" sess="" aff="" rp="" rfrac="" cstate
  local traces="$TMP/traces-$key.csv" screens="$TMP/screens-$key.csv" net="$TMP/net-$key.csv"
  local p50="" p95="" wscreen="" wslow="" frozen="" neterr="" pstate prows=0
  local wsamples="" wnet="" wnet_pct=""
  local vsess vdev
  # ANR 与 NON_FATAL：两者的 is_fatal 均为 FALSE，**不能复用上面的崩溃查询**
  local etypes='[]' nf='[]' anr_ev="" anr_inst="" nf_ev="" nf_inst="" anr_rp="" anr_rfrac=""
  local aff_users=""   # 受影响用户数（仅 iOS 有值，见 crash-rate.sql 注释）
  # 前后台（change crash-fg-bg-split）：三类各三个数，未知单独一列——
  # `0 前台` 是结论（确实没有前台事件），`未知` 是缺数，⛔ 两者不可合并。
  local fat_fg="" fat_bg="" fat_unk="" anr_fg="" anr_bg="" anr_unk="" nf_fg="" nf_bg="" nf_unk=""
  local csess_crash="" cfree="" cfree_bad="" cfree_frac=""

  # 崩溃
  if [ -n "$3" ]; then
    issues="$(qc crash-issues.sql "$3" "" "$CRASH_DAYS" "$v")" || issues='[]'
    [ -n "$issues" ] || issues='[]'
    rate="$(qc crash-rate.sql "$3" "$4" "$CRASH_DAYS" "$v")" || rate='[]'
    [ -n "$rate" ] || rate='[]'
    etypes="$(qc crash-error-types.sql "$3" "" "$CRASH_DAYS" "$v")" || etypes='[]'
    [ -n "$etypes" ] || etypes='[]'
    nf="$(qc crash-nonfatal-issues.sql "$3" "" "$CRASH_DAYS" "$v")" || nf='[]'
    [ -n "$nf" ] || nf='[]'
  fi
  printf '%s' "$nf" > "$TMP/nonfatal-$key.json"
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
  anr_ev="$(printf '%s' "$etypes"   | jq -r '(.[0].anr_events // empty) | tostring'       2>/dev/null || echo "")"
  anr_inst="$(printf '%s' "$etypes" | jq -r '(.[0].anr_installs // empty) | tostring'     2>/dev/null || echo "")"
  nf_ev="$(printf '%s' "$etypes"    | jq -r '(.[0].nonfatal_events // empty) | tostring'  2>/dev/null || echo "")"
  nf_inst="$(printf '%s' "$etypes"  | jq -r '(.[0].nonfatal_installs // empty) | tostring' 2>/dev/null || echo "")"
  for _fld in fatal_fg fatal_bg fatal_unknown anr_fg anr_bg anr_unknown nonfatal_fg nonfatal_bg nonfatal_unknown; do
    _v="$(printf '%s' "$etypes" | jq -r --arg f "$_fld" '(.[0][$f] // empty) | tostring' 2>/dev/null || echo "")"
    case "$_fld" in
      (fatal_fg) fat_fg="$_v";; (fatal_bg) fat_bg="$_v";; (fatal_unknown) fat_unk="$_v";;
      (anr_fg) anr_fg="$_v";;   (anr_bg) anr_bg="$_v";;   (anr_unknown) anr_unk="$_v";;
      (nonfatal_fg) nf_fg="$_v";; (nonfatal_bg) nf_bg="$_v";; (nonfatal_unknown) nf_unk="$_v";;
    esac
  done
  # ANR 率与崩溃率同分母（会话数），两者内部可比；与 Play 的日活口径不可比，标注在口径段。
  anr_rp="$(rate_pct "$anr_ev" "$sess")"
  [ -n "$anr_rp" ] && anr_rfrac="$anr_ev/$sess"
  # crash-free 会话率 = 1 − 崩溃会话数 / 会话数。分母为 0 时两个值都留空 →
  # 渲染成「无法计算」，⛔ **绝不能渲染成 100%**（零崩溃除以零会话不是「完全干净」）。
  csess_crash="$(printf '%s' "$rate" | jq -r '(.[0].crash_sessions // empty) | tostring' 2>/dev/null || echo "")"
  aff_users="$(printf '%s' "$rate" | jq -r '(.[0].affected_users // empty) | tostring' 2>/dev/null || echo "")"
  cfree_bad="$(rate_pct "$csess_crash" "$sess")"        # 崩溃会话率（判定用，坏方向）
  if [ -n "$cfree_bad" ]; then
    cfree="$(awk -v b="$cfree_bad" 'BEGIN{printf "%.2f", 100 - b}')"
    cfree_frac="$csess_crash/$sess"
  fi

  # 性能
  : > "$traces"; : > "$screens"; : > "$net"
  if [ -n "$5" ]; then
    q perf-traces.sql  "$5" "$PERF_WIN_START" "$PERF_LCD" "$v" > "$traces"  || true
    q perf-screens.sql "$5" "$PERF_WIN_START" "$PERF_LCD" "$v" > "$screens" || true
    q perf-network.sql "$5" "$PERF_WIN_START" "$PERF_LCD" "$v" > "$net"     || true
  fi
  prows=$(( $(wc -l < "$traces") + $(wc -l < "$screens") + $(wc -l < "$net") ))
  # `|| true` 不是防御性冗余：性能表停更时 traces 为空，grep 无匹配返回 1，pipefail 把整条
  # 管道判成失败；命令替换的子 shell 继承 set -e + errtrace，于是良性的「没这行」被 ERR trap
  # 当成故障告警发出去（2026-08-21 07:00：4 个版本 × 2 处 = 群里连发 8 张误报卡）。
  p50="$(int "$(grep '^_app_start,' "$traces" 2>/dev/null | cut -d, -f3 | head -1 || true)")"
  p95="$(int "$(grep '^_app_start,' "$traces" 2>/dev/null | cut -d, -f4 | head -1 || true)")"
  wscreen="$(csv "$screens" 1)"
  wslow="$(pct "$(csv "$screens" 3)")"
  # 冻结率取「最差慢帧页」同一行的冻结率（沿用既有口径，仅在标签上明确写出「最差页」）
  frozen="$(pct "$(csv "$screens" 4)")"
  neterr="$([ -s "$net" ] && csv2tsv < "$net" | awk -F'\t' '{e+=$5; n+=$2} END{if(n>0) printf "%.2f", e/n*100}' || echo "")"
  neterr="$(pct "$neterr")"
  # 最差页的样本量：94% 慢帧率在 3 次打开和 3000 次打开上是完全不同的结论（决策 D5）
  wsamples="$(csv "$screens" 2)"
  # 最差接口 = 错误率最高的那条。崩溃给了最差 issue、慢帧给了最差页面，接口只给总数，三者不对称（决策 D7）
  if [ -s "$net" ]; then
    wnet="$(csv2tsv < "$net" | awk -F'\t' 'NF>=6 && $6+0 > mx {mx=$6+0; n=$1} END{print n}')"
    wnet_pct="$(pct "$(csv2tsv < "$net" | awk -F'\t' 'NF>=6 && $6+0 > mx {mx=$6+0} END{if(mx>0) print mx}')")"
  fi
  pstate="$(data_state "$5" "$prows" "$7" "${9:-}")"

  vsess="$(ver_field "$8" "$v" 2)"
  vdev="$(ver_field "$8" "$v" 3)"

  jq -n --arg v "$v" --arg cstate "$cstate" --arg pstate "$pstate" \
    --arg n "$n" --arg ev "$ev" --arg latest "$latest" --arg aff "$aff" \
    --arg cev "$cev" --arg csess "$sess" --arg rp "$rp" --arg rfrac "$rfrac" \
    --arg p50 "$p50" --arg p95 "$p95" --arg wscreen "$wscreen" --arg wslow "$wslow" \
    --arg frozen "$frozen" --arg neterr "$neterr" --arg vsess "$vsess" --arg vdev "$vdev" \
    --arg wsamp "$wsamples" --arg wnet "$wnet" --arg wnetp "$wnet_pct" \
    --arg anrev "$anr_ev" --arg anrinst "$anr_inst" --arg anrrp "$anr_rp" --arg anrfrac "$anr_rfrac" \
    --arg nfev "$nf_ev" --arg nfinst "$nf_inst" \
    --arg fatfg "$fat_fg" --arg fatbg "$fat_bg" --arg fatunk "$fat_unk" \
    --arg anrfg "$anr_fg" --arg anrbg "$anr_bg" --arg anrunk "$anr_unk" \
    --arg nffg "$nf_fg" --arg nfbg "$nf_bg" --arg nfunk "$nf_unk" \
    --arg cfree "$cfree" --arg cfreebad "$cfree_bad" --arg cfreefrac "$cfree_frac" \
    --arg affu "$aff_users" \
    '{version:$v,
      crash:{state:$cstate, n:$n, events:$ev, latest:$latest, affected:$aff,
             crash_events:$cev, sessions:$csess, rate_pct:$rp, rate_frac:$rfrac,
             crash_free_pct:$cfree, crash_free_bad:$cfreebad, crash_free_frac:$cfreefrac,
             affected_users:$affu},
      perf:{state:$pstate, p50:$p50, p95:$p95, worst_screen:$wscreen, worst_slow:$wslow,
            frozen:$frozen, net_err:$neterr,
            worst_samples:$wsamp, worst_net:$wnet, worst_net_pct:$wnetp},
      errtype:{anr_events:$anrev, anr_installs:$anrinst, anr_rate_pct:$anrrp, anr_rate_frac:$anrfrac,
               nonfatal_events:$nfev, nonfatal_installs:$nfinst,
               fatal_fg:$fatfg, fatal_bg:$fatbg, fatal_unknown:$fatunk,
               anr_fg:$anrfg, anr_bg:$anrbg, anr_unknown:$anrunk,
               nonfatal_fg:$nffg, nonfatal_bg:$nfbg, nonfatal_unknown:$nfunk},
      adopt:{sessions:$vsess, devices:$vdev}}' > "$TMP/m-$key.json"
}

# 取值助手：$1=plat $2=版本 $3=jq 路径（如 crash.rate_pct）
mv_() { local f="$TMP/m-$1-$2.json"; [ -s "$f" ] || { echo ""; return 0; }
  jq -r --arg p "$3" 'getpath($p | split(".")) // "" | tostring' "$f" 2>/dev/null || echo ""; }

# 影响面维度（汇总段用）。**按版本拆**（已拍板）：同一维度两版并排才能看出
# 「新版是否引入了新机型问题」——四段平铺就丢掉了这个唯一价值。
DIM_MODEL_EXPR="CONCAT(device.manufacturer,' ',device.model)"
DIM_OS_EXPR="operating_system.display_version"
# 页面：custom_keys 是 REPEATED RECORD，取值必须走标量子查询（不能当普通字段路径）
DIM_SCREEN_EXPR="(SELECT value FROM UNNEST(custom_keys) WHERE key = 'current_screen' LIMIT 1)"
collect_dims() { # $1=plat键 $2=版本 $3=crash表 $4=sess表
  local key="$1-$2"
  : > "$TMP/dim-model-$key.csv"; : > "$TMP/dim-os-$key.csv"; : > "$TMP/hours-$key.csv"
  : > "$TMP/dim-screen-$key.csv"
  [ -n "$3" ] && [ -n "$4" ] || return 0
  qdim "$3" "$4" "$2" "$DIM_MODEL_EXPR" "$DIM_TOP" > "$TMP/dim-model-$key.csv" || true
  qdim "$3" "$4" "$2" "$DIM_OS_EXPR"    "$DIM_TOP" > "$TMP/dim-os-$key.csv"    || true
  # 页面维度的错误类型口径按端分叉（见 qdim_nd 注释 ③）
  local _screen_et="'FATAL','ANR'"
  [ "$1" = ios ] && _screen_et="'NON_FATAL'"
  qdim_nd "$3" "$2" "$DIM_SCREEN_EXPR" "$DIM_TOP" "$_screen_et" > "$TMP/dim-screen-$key.csv" || true
  qhours "$3" "$2" > "$TMP/hours-$key.csv" || true
  bqq csv "$(q_render crash-blame.sql TABLE="$3" DAYS="$CRASH_DAYS" \
                 VERSIONS="$(vlist "$2")" LIMIT="$DIM_TOP")" | tail -n +2 > "$TMP/blame-$key.csv" || true
  return 0
}

step "逐版本取数（窗口值）"
for v in $IOS_COLS; do
  echo "  iOS $v"
  collect_window ios "$v" "$IOS_CRASH_TBL" "$SESS_IOS" "$IOS_PERF_TBL" "$IOS_CRASH_MAX" "$IOS_PERF_MAX" "$IOS_VER_CSV" "$IOS_PERF_STALE"
done
for v in $AND_COLS; do
  echo "  Android $v"
  collect_window and "$v" "$AND_CRASH_TBL" "$SESS_AND" "$AND_PERF_TBL" "$AND_CRASH_MAX" "$AND_PERF_MAX" "$AND_VER_CSV" "$AND_PERF_STALE"
done

# 影响面维度：**只对最新 N 版取**（主力补充列不下钻）。与 1d 同一条成本控制思路——
# 每版本每端 3 次额外查询，全列铺开会让整跑时间显著上升，而旧版的维度分布变化慢。
# 全版本 crash-free：回答「整体健不健康」。最新版那个回答「新版发得怎么样」——
# 实测最新版 94.29% 基于 35 个会话，**没有统计意义**，却是卡片上唯一的 crash-free 数字。
# 两个并列，各自标口径（design D4）。
allver_crashfree() { # $1=crash表 $2=sessions表 → 「99.28」或空
  local sql out cs se
  [ -n "$1" ] && [ -n "$2" ] || { printf ''; return 0; }
  # 版本过滤改成恒真，其余照用 crash-rate.sql（同一份 SQL，口径不会漂）。
  # ⛔ **不能整行删掉**：sessions 子查询里那行就是 `WHERE ...`，删了会留下 `FROM ... AND` 语法错误。
  # ⚠️ 版本过滤改成恒真：先渲染其余占位符，再把版本谓词整段替换掉。
  #    ⛔ 不能让 {{VERSIONS}} 留到 q_render 的缺项检查——那会被当成漏传而失败，
  #    故先替换谓词、再补一个不会被用到的 VERSIONS 值。
  sql="$(q_render crash-rate.sql TABLE="$1" SESSIONS_TABLE="$2" DAYS="$CRASH_DAYS" VERSIONS="''" \
         | sed -e 's|application.display_version IN (.*)|TRUE|g')"
  out="$(bqq csv "$sql" | tail -n +2 | head -1)" || return 0
  cs="$(printf '%s' "$out" | cut -d, -f4)"; se="$(printf '%s' "$out" | cut -d, -f2)"
  { [ -n "$cs" ] && [ -n "$se" ] && [ "$se" != "0" ]; } || { printf ''; return 0; }
  awk -v c="$cs" -v s="$se" 'BEGIN{printf "%.2f", 100 - c/s*100}'
}

step "影响面维度（机型 / 系统版本 / 时段，仅最新 $VERSION_COUNT 版）"
for v in $IOS_NEWEST; do collect_dims ios "$v" "$IOS_CRASH_TBL" "$SESS_IOS"; done
for v in $AND_NEWEST; do collect_dims and "$v" "$AND_CRASH_TBL" "$SESS_AND"; done
IOS_CF_ALL="$(allver_crashfree "$IOS_CRASH_TBL" "$SESS_IOS")"
AND_CF_ALL="$(allver_crashfree "$AND_CRASH_TBL" "$SESS_AND")"
echo "  全版本 crash-free：iOS ${IOS_CF_ALL:-—}% · Android ${AND_CF_ALL:-—}%"

# ── 天级单日值：只跟踪最新 N 版（主力补充列不进 1d/历史，design D11 成本控制）──
step "天级单日值（DoD/WoW 基准，仅最新 $VERSION_COUNT 版）"
collect_1d() { # $1=plat键 $2=版本 $3=crash表 $4=sess表 $5=perf表
  local p="$1" v="$2" key="$1-$2" c1d='{}' s1d='{}' pf='{}' pfp='{}' pday pprev
  [ -n "$3" ] && c1d="$(q1d daily-crash-1d.sql    "$3" 1 "$v")" || true
  [ -n "$4" ] && s1d="$(q1d daily-sessions-1d.sql "$4" 1 "$v")" || true
  # DoD 两端都取**完整日**：LCD vs LCD−1（change crash-data-completeness）。
  # ⛔ 不再按「该版本最新可用单日」取（原 perf_day_offset）——表的最后一个日历日恒为 7 小时残日，
  #    MAX(DATE(...)) 正好取中它，于是「今日」是 7 小时切片、「昨日」是完整天，环比两边口径不同，
  #    差值无意义（2026-08-27 实测 iOS 1.5.4：残日 08-26 仅 29 样本 P95 548ms，完整日 08-25 192 样本 P95 1044ms，
  #    照旧口径会渲染成「启动 P95 −496ms ↓」的假改善）。
  # ⚠️ 全平台共用一个 LCD：某版本在 LCD 当天没有行时两端都为 null，走既有缺数渲染，不回退到别的日期。
  if [ -n "$5" ] && [ -n "$PERF_LCD" ]; then
    pf="$(q1d  daily-perf-1d.sql "$5" "$PERF_LCD" "$v")" || true
    pfp="$(q1d daily-perf-1d.sql "$5" "$PERF_PREV_DAY" "$v")" || true
  fi
  pday="$PERF_LCD"; pprev="$PERF_PREV_DAY"
  [ -n "$c1d" ] || c1d='{}'; [ -n "$s1d" ] || s1d='{}'
  [ -n "$pf" ]  || pf='{}';  [ -n "$pfp" ] || pfp='{}'
  jq -n --argjson c "$c1d" --argjson s "$s1d" \
        --argjson p "$pf" --argjson pp "$pfp" \
        --arg pday "$pday" --arg pprev "$pprev" \
    '{crash_events_1d:($c.crash_events_1d // null), affected_installs_1d:($c.affected_installs_1d // null),
      anr_events_1d:($c.anr_events_1d // null), anr_installs_1d:($c.anr_installs_1d // null),
      nonfatal_events_1d:($c.nonfatal_events_1d // null),
      crash_sessions_1d:($c.crash_sessions_1d // null),
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
  jq -r --arg p "$3" '(getpath($p | split(".")) // "") | tostring | select(. != "null")' "$f" 2>/dev/null || echo ""
}

# ── 历史基准（按版本存储；旧口径行自愈丢弃，design D9）──────────────
HISTORY="$STATE/metrics-history.jsonl"
# 保留 90 天而非 7 天：环比只需要昨日与 D-7，但月度回顾、拉长 sparkline 都需要更长的序列，
# 而 90 行 JSONL 也就 25KB——为省这点体积把历史砍掉不划算。
HISTORY_KEEP="${CRASH_REPORT_HISTORY_KEEP:-90}"
# 本轮写进历史的性能窗口口径。⚠️ 只有真的取到了完整日窗口才算 complete_day——
# LCD 为空时性能段整段走缺数，标成 complete_day 会让明天的 WoW 以为两边可比。
HISTORY_WINDOW_MODE=legacy
if [ -n "$PERF_LCD" ]; then HISTORY_WINDOW_MODE=complete_day; fi
SPARK_DAYS="${CRASH_REPORT_SPARK_DAYS:-7}"   # sparkline 只取最近 N 天，别把 90 个方块画出来
YESTERDAY="$(day_ago 1)"; D7="$(day_ago 7)"
# 性能 WoW 的基准日：⚠️ 锚在 LCD 而不是跑批日——性能段两端都必须是完整日（LCD vs LCD−7）。
PERF_D7="$(day_shift "$PERF_LCD" -7)"
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
# 性能 WoW 专用：按**记录里的 perf_day** 取，⛔ 不按跑批日 `.day` 取（change crash-data-completeness）。
# 起因：旧口径每个版本各按自己的「最新可用单日」取值，同一次跑批里 perf_day 能差出 5 天
#（实测 2026-08-22 那轮：iOS 1.5.4 记的是 08-17、1.5.3 记的是 08-18）。
# 按 `.day == 今天−7` 取到的那条，它的 perf_day 与本轮 LCD 相差多少**完全不确定**——
# ⚠️ 「WoW」这个名字会让人以为两边隔 7 天，实际隔几天没人知道，差值不可解释。
# 取最后一条：同一 perf_day 可能有多轮跑批（当天重跑），最后一条是最完整的那次。
hist_val_perfday() { jq -r --arg d "$1" --arg p "$2" --arg v "$3" --arg k "$4" \
  '.[] | select(.[$p][$v].perf_day == $d) | .[$p][$v][$k] // empty' <<<"$HIST_ARR" 2>/dev/null | tail -1 || true; }
# 跨口径标注（design D8 / 5.3）：WoW 基准那一行是旧口径时必须说出来。
# ⚠️ 缺 `window_mode` 的旧行一律读作 legacy——⛔ 不能默认成 complete_day，
#    那等于把「含 7 小时残日的值」和完整天值悄悄放在一起比。
hist_mode_perfday() { # $1=perf_day $2=plat $3=版本 → window_mode；查不到该行 → 空
  jq -r --arg d "$1" --arg p "$2" --arg v "$3" \
    '[.[] | select(.[$p][$v].perf_day == $d) | (.window_mode // "legacy")] | last // ""' \
    <<<"$HIST_ARR" 2>/dev/null || true
}
# 口径切换日 = 历史里第一条 complete_day 记录的日期；一条都没有说明本轮就是切换日。
# ⚠️ 切满 7 天后 LCD-7 自然落在 complete_day 区间里，标注**自动消失**，不需要人工摘。
WINDOW_SWITCH_DAY="$(jq -r '[.[] | select((.window_mode // "legacy") == "complete_day") | .day] | first // ""' <<<"$HIST_ARR" 2>/dev/null || true)"
[ -n "$WINDOW_SWITCH_DAY" ] || WINDOW_SWITCH_DAY="$DAY"
# sparkline 序列（按文件顺序旧→新，同版本）
# ── 第 3 态细分（change crash-data-completeness C 组，design D5/D6/D7）────
# ⛔ **这不是第 4 态**：既有缺数三态的判据、顺序、文案一律不动
#    （表未同步 → ⚠️ 数据未同步（探测不带版本过滤）→ 该版本无数据）。
#    本段只在**第 3 态内部**分两种，且发生在前两态判定之后。文档与注释统一称「第 3 态细分」。
#
# 两种子情况的处置完全不同，旧渲染把它们压成同一句「— 该版本无数据」：
#   ① 尚无数据——这版从来没在性能表里出现过。正常滞后，明天就有，不用查。
#   ② 本轮未取到——历史有值、这轮没有。取数故障或导出退化，**要查**。
#
# ⛔ **只给日期不给数值**（偏离 design D7 的「253ms（沿用 08-25）」写法）：五个性能格子
#    没有一个能搬历史值——启动 P50/P95 格子是 3 天滚动窗、历史是单日；慢帧最差页/冻结是
#    「最差页单页」、历史是「平台级聚合」；接口错误率格子是窗口 top10 端点、历史是全量
#    （daily-perf-1d.sql 顶部自己写着「两套取数人群不同，不可直接混比」）。
#    把历史值放进「3d」标签下的格子，正是 crash-metric-change 核心事实 2 禁的事。
#    ⚠️ 判据仍然读历史——「这版以前有没有产出过性能数据」是个布尔，与口径无关。
# ⚠️ 日期必须给（design D7）：不带日期的「本轮未取到」在连续多轮失败时会一直显示同一句话，
#    看不出已经僵住——latest_event 冻结在历史峰值那天就是这么来的，同一个坑不再踩第二次。
PERF_HIST_KEYS='["start_p50_1d","start_p95_1d","slow_pct_1d","frozen_pct_1d","net_err_pct_1d"]'
# ⛔ 判据必须显式判 `!= null`，**MUST NOT 用真值性判断**：慢帧 / 冻结 / 接口错误率的 `0`
#    是合法且常见的值（2026-08-27 实测 Android 1.5.4 冻结 0.0%），当成缺失就会把
#    「今天确实取到了 0」渲染成「本轮未取到」——把好消息读成故障。
hist_lookup() { # $1=plat $2=版本 $3=指标key → "值<TAB>日期"，历史里全为 null → 空
  jq -r --arg p "$1" --arg v "$2" --arg k "$3" \
    '[.[] | select((.[$p][$v][$k] // null) != null) | "\(.[$p][$v][$k])\t\(.day)"] | last // ""' \
    <<<"$HIST_ARR" 2>/dev/null || true
}
# 该版本最后一次产出**任何**性能值的日期（判据用，不取值）
hist_perf_last_day() { # $1=plat $2=版本 → YYYY-MM-DD 或空
  jq -r --arg p "$1" --arg v "$2" --argjson ks "$PERF_HIST_KEYS" \
    '[.[] | select([.[$p][$v][$ks[]] // null] | map(. != null) | any) | .day] | last // ""' \
    <<<"$HIST_ARR" 2>/dev/null || true
}
# 预计到位日：该版本在**残日**里已有行 ⇒ 明天 LCD 推进一天它就进窗口了。
# ⛔ 残日里也没有就不给日期——空口承诺「明天就有」比不说更糟。
perf_eta_of() { # $1=plat $2=版本 → YYYY-MM-DD 或空
  local tail; [ "$1" = ios ] && tail="$IOS_PERF_TAIL" || tail="$AND_PERF_TAIL"
  if printf '%s\n' "$tail" | grep -qx -- "$2"; then day_shift "$DAY" 1; else printf ''; fi
}
# 第 3 态细分后的性能单元格文案。前两态原样委托给 state_text()，⛔ 一字不改。
state_text_perf() { # $1=state $2=plat $3=版本 $4=表整体最新时间戳
  local d eta
  if [ "$1" != no_version ]; then state_text "$1" "$4"; return 0; fi
  d="$(hist_perf_last_day "$2" "$3")"
  if [ -n "$d" ]; then
    # ⚠️ 短文案也**必须保留日期**：日期才是「僵了多久」的唯一线索，措辞可以砍
    if [ "$CELL_BREVITY" = 1 ]; then printf '⚠️ 未取到 %s' "${d:5}"
    else printf '⚠️ 本轮未取到（上次有值 %s）' "$d"; fi
    return 0
  fi
  eta="$(perf_eta_of "$2" "$3")"
  if [ -n "$eta" ]; then
    if [ "$CELL_BREVITY" = 1 ]; then printf -- '— 预计 %s' "${eta:5}"
    else printf -- '— 尚无数据（预计 %s 到位）' "$eta"; fi
  else
    state_text no_version "$4"
  fi
}

spark_hist() { jq -r --arg p "$1" --arg v "$2" --arg k "$3" --argjson n "$SPARK_DAYS" \
  '.[-$n:][] | .[$p][$v][$k] // empty' <<<"$HIST_ARR" 2>/dev/null || true; }
spark_rate() { jq -r --arg p "$1" --arg v "$2" --argjson n "$SPARK_DAYS" \
  '.[-$n:][] | [.[$p][$v].crash_events_1d // "", .[$p][$v].sessions_1d // ""] | @tsv' <<<"$HIST_ARR" 2>/dev/null \
  | awk -F'\t' '{ if($1!="" && $2!="" && $2!=0) printf "%.2f\n", $1/$2*100 }' || true; }

# ── MCP 对照/回退（全版本口径，与卡片不可比）─────────
# fetch-snapshot.sh light 模式抓 MCP topIssues（OPEN FATAL）+ git 反查，产出 snapshot.json。
# 它不驱动卡片任何数字（已由 BigQuery 版本级接管），只用于：
#   ① 索引页「跟踪中的 issue」与 fix_commit 修复状态反查；② 新增/已修待验告警（全版本口径，已在文案标注）。
step "抓取 MCP 崩溃对照数据（全版本口径）"
CRASH_DIR="$TMP"
CRASH_JSON="$CRASH_DIR/snapshot.json"
# lib.sh 已在脚本开头（bq 超时护栏处）source，run_with_timeout 此处可直接用。
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

# ── 异常判定：告警判定版本（change crash-alert-sample-fallback）────────
# 默认最新版；**最新版会话数低于小样本阈值时回退为该端会话量最大的版本**。
#
# 固定判定最新版的前提是「最新版代表线上」。新版刚放量时这个前提不成立——
# 实测同一次跑批：Android 1.5.4（1 个会话）的崩溃率 8.33%(3/36) 触发了红档误报，
# 而 6600 个会话的 1.5.3 真实超标的 ANR 0.71% 却沉默。**同一条规则，两个方向都错。**
#
# ⚠️ 只影响告警与摘要行的**判定对象**，不改表格呈现——各版本列一列不少。
alert_ver() { # $1=plat键 → 判定版本；同时把是否回退写进 <PLAT>_ALERT_FALLBACK
  local v1 s1 top
  if [ "$1" = ios ]; then v1="$IOS_V1"; top="$(printf '%s\n' "$IOS_TOPSESS" | sed -n 1p)"
  else v1="$AND_V1"; top="$(printf '%s\n' "$AND_TOPSESS" | sed -n 1p)"; fi
  [ -n "$v1" ] || { printf ''; return 0; }
  s1="$(mv_ "$1" "$v1" adopt.sessions)"
  # 会话数取不到时不回退（宁可维持既有行为，也不因取数失败静默换判定对象）
  if [ -n "$s1" ] && [ -n "$top" ] && [ "$top" != "$v1" ] \
     && [ "$(awk -v a="$s1" -v b="$SAMPLE_SESSION_MIN" 'BEGIN{print (a<b)}')" = "1" ]; then
    printf '%s' "$top"; return 0
  fi
  printf '%s' "$v1"
}
IOS_ALERT_VER="$(alert_ver ios)"; AND_ALERT_VER="$(alert_ver and)"
IOS_ALERT_FALLBACK=0; [ -n "$IOS_ALERT_VER" ] && [ "$IOS_ALERT_VER" != "$IOS_V1" ] && IOS_ALERT_FALLBACK=1
AND_ALERT_FALLBACK=0; [ -n "$AND_ALERT_VER" ] && [ "$AND_ALERT_VER" != "$AND_V1" ] && AND_ALERT_FALLBACK=1
{ [ "$IOS_ALERT_FALLBACK" = 1 ] || [ "$AND_ALERT_FALLBACK" = 1 ]; } && \
  echo "  ℹ️ 告警判定回退：iOS→${IOS_ALERT_VER:-—} Android→${AND_ALERT_VER:-—}（最新版会话数 < ${SAMPLE_SESSION_MIN}）"

# ── 异常判定 ──────────────
SNAP="$STATE/daily-snapshot.json"

# ── issue 生命周期（change crash-actionable-signals）──────────────────
# 基准结构 issue_seen: {"<32位id>": "<末次出现日期>"}，保留 90 天。
# ⚠️ 判定基准用 **BigQuery issue id**，不再依赖 MCP——现有 ios_ids/android_ids 来自 MCP
#    且长期为空数组，L1 的新增判定实际已经死了。
SEEN_JSON='{}'; SEEN_PREV_DAY=""; LIFECYCLE_OK=0
if [ -s "$SNAP" ]; then
  SEEN_JSON="$(jq -c '.issue_seen // {}' "$SNAP" 2>/dev/null || echo '{}')"
  # 「上一轮」取基准里的**最大日期**，不是「昨天」——跑批漏跑一天时，
  # 按「昨天」判定会把所有 issue 误判成回归（design 风险表）。
  SEEN_PREV_DAY="$(printf '%s' "$SEEN_JSON" | jq -r '[.[]] | max // ""' 2>/dev/null || echo "")"
  [ "$(printf '%s' "$SEEN_JSON" | jq 'length' 2>/dev/null || echo 0)" -gt 0 ] && LIFECYCLE_OK=1
fi
[ "$LIFECYCLE_OK" = 1 ] || echo "  ℹ️ issue 生命周期：基准为空，本轮只建基线不标新增（首轮刷一屏「新增」与该词要传达的信息相反）"

# 本轮出现的全部 issue id（跨版本并集，来自 BigQuery）
CUR_IDS="$(cat "$TMP"/issues-*.json 2>/dev/null | jq -rs '[.[][]?.issue_id] | unique | .[]' 2>/dev/null || true)"

life_tag() { # $1=完整 issue id → 🆕新增 / 🔁回归 / 长期 / 空（基线轮）
  [ "$LIFECYCLE_OK" = 1 ] || { printf ''; return 0; }
  local last
  last="$(printf '%s' "$SEEN_JSON" | jq -r --arg i "$1" '.[$i] // ""' 2>/dev/null || echo "")"
  if [ -z "$last" ]; then printf '🆕新增'
  elif [ -n "$SEEN_PREV_DAY" ] && [ "$last" = "$SEEN_PREV_DAY" ]; then printf '长期'
  else printf '🔁回归'; fi
}

IOS_RATE_PCT="$(mv_ ios "$IOS_ALERT_VER" crash.rate_pct)"; AND_RATE_PCT="$(mv_ and "$AND_ALERT_VER" crash.rate_pct)"
IOS_SLOW_V1="$(mv_ ios "$IOS_ALERT_VER" perf.worst_slow)"; AND_SLOW_V1="$(mv_ and "$AND_ALERT_VER" perf.worst_slow)"
IOS_FROZEN_V1="$(mv_ ios "$IOS_ALERT_VER" perf.frozen)";   AND_FROZEN_V1="$(mv_ and "$AND_ALERT_VER" perf.frozen)"
IOS_P95_V1="$(mv_ ios "$IOS_ALERT_VER" perf.p95)";         AND_P95_V1="$(mv_ and "$AND_ALERT_VER" perf.p95)"
IOS_NETERR_V1="$(mv_ ios "$IOS_ALERT_VER" perf.net_err)";  AND_NETERR_V1="$(mv_ and "$AND_ALERT_VER" perf.net_err)"
AND_ANR_RATE="$(mv_ and "$AND_ALERT_VER" errtype.anr_rate_pct)"   # iOS 无 ANR，故无对应变量

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
add_alert "$(red_line_one "ANR 率" Android "${AND_ALERT_VER:-—}" "$AND_ANR_RATE" "$ANR_RATE_RED" "$ANR_RATE_YELLOW" "%")"

# ⛔ 回退必须可见：换了判定对象却不说，比漏报更难排查——数字对得上、版本对不上。
# 读者看到的是「最新版是 1.5.4，为什么在报 1.5.3」，必须当场解释。
_fb=""
[ "$IOS_ALERT_FALLBACK" = 1 ] && _fb="iOS ${IOS_ALERT_VER}"
[ "$AND_ALERT_FALLBACK" = 1 ] && _fb="${_fb:+$_fb · }Android ${AND_ALERT_VER}"
[ -n "$_fb" ] && add_alert "ℹ️ 告警判定对象：${_fb}——最新版会话数不足 ${SAMPLE_SESSION_MIN}，其比率无统计意义，故改判会话量最大的版本（表格仍按最新版分列，一列不少）"

SUMMARY_MD="$ALERTS"
add_summary() { [ -n "$1" ] && SUMMARY_MD="${SUMMARY_MD:+$SUMMARY_MD
}$1"; return 0; }
add_summary "$(yellow_line "崩溃率" "$IOS_RATE_PCT" "$AND_RATE_PCT" "$CRASH_RATE_RED" "$CRASH_RATE_YELLOW" "%")"
add_summary "$(yellow_line "慢帧最差页" "$IOS_SLOW_V1" "$AND_SLOW_V1" "$SLOW_FRAME_RED" "$SLOW_FRAME_YELLOW" "%")"
add_summary "$(yellow_line "冻结率" "$IOS_FROZEN_V1" "$AND_FROZEN_V1" "$FROZEN_RED" "$FROZEN_YELLOW" "%")"
add_summary "$(yellow_line "启动 P95" "$IOS_P95_V1" "$AND_P95_V1" "$START_P95_RED" "$START_P95_YELLOW" "ms")"
add_summary "$(yellow_line "接口错误率" "$IOS_NETERR_V1" "$AND_NETERR_V1" "$NET_ERR_RED" "$NET_ERR_YELLOW" "%")"
add_summary "$(yellow_line_one "ANR 率" Android "${AND_ALERT_VER:-—}" "$AND_ANR_RATE" "$ANR_RATE_RED" "$ANR_RATE_YELLOW" "%")"
# 数据源停更要顶到卡片上，但它不是执行失败——只进摘要行（黄），不进 ALERTS、不发故障卡。
perf_stale_line() {
  local d="" src=""
  if [ -n "$IOS_PERF_STALE" ] && [ -n "$AND_PERF_STALE" ]; then
    d="$IOS_PERF_STALE"; [ "$AND_PERF_STALE" -gt "$d" ] && d="$AND_PERF_STALE"
    src="iOS 截至 $IOS_PERF_MAX · Android 截至 $AND_PERF_MAX"
  elif [ -n "$IOS_PERF_STALE" ]; then d="$IOS_PERF_STALE"; src="iOS 截至 $IOS_PERF_MAX"
  elif [ -n "$AND_PERF_STALE" ]; then d="$AND_PERF_STALE"; src="Android 截至 $AND_PERF_MAX"
  else return 0; fi
  printf '🟡 性能数据已停更 %s 天 · %s — Firebase→BigQuery 导出未产出，非流水线故障' "$d" "$src"
}
add_summary "$(perf_stale_line)"
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
  if [ "$(awk -v a="$s" -v b="$SAMPLE_SESSION_MIN" 'BEGIN{print (a<b)}')" = "1" ]; then
    # 卡片里只留一个警告符号——「样本小」三个字在窄列里会把整格挤到截断
    [ "$CELL_BREVITY" = 1 ] && printf ' ⚠️' || printf ' ⚠️ 样本小'
  fi
  return 0
}
cell() { # $1=plat $2=版本 $3=行键
  local st val samp lbl wn wp wscr
  case "$3" in
    anr_brief) [ "$1" = ios ] && st=ok || st="$(mv_ "$1" "$2" crash.state)";;   # iOS 用 perf 数据，状态在分支内自行判定
    crash_free|crash_count|crash_rate|crash_affected|anr_count|anr_rate|nonfatal_count|crash_brief) st="$(mv_ "$1" "$2" crash.state)";;
    sessions) st=ok;;
    *) st="$(mv_ "$1" "$2" perf.state)";;
  esac
  if [ "$st" != "ok" ]; then
    case "$3" in
      crash_free|crash_count|crash_rate|crash_affected|anr_count|anr_rate|nonfatal_count|crash_brief|anr_brief) printf '%s' "$(state_text "$st" "$([ "$1" = ios ] && echo "$IOS_CRASH_MAX" || echo "$AND_CRASH_MAX")")";;
      sessions) printf '—';;
      # ⚠️ 只有性能各行走细分（C 组）；上面崩溃各行仍走原 state_text，判据与文案一字未动
      *) printf '%s' "$(state_text_perf "$st" "$1" "$2" "$([ "$1" = ios ] && echo "$IOS_PERF_MAX" || echo "$AND_PERF_MAX")")";;
    esac
    return 0
  fi
  case "$3" in
    crash_free)     val="$(mv_ "$1" "$2" crash.crash_free_pct)"
                    # 分母为 0 → 「无法计算」并说明原因。⛔ 不得渲染成 100%
                    if [ -z "$val" ]; then printf '无法计算（该版本窗口内无会话）'
                    else
                      # 判定用坏方向值（崩溃会话率），阈值取 100 − crash-free 阈值，
                      # 这样 traffic_light 的「大于红线 → red」语义无需改动
                      printf '%s%s' "$(cell_color "$(mv_ "$1" "$2" crash.crash_free_bad)" \
                        "$(awk -v r="$CRASH_FREE_RED" 'BEGIN{printf "%.2f", 100-r}')" \
                        "$(awk -v y="$CRASH_FREE_YELLOW" 'BEGIN{printf "%.2f", 100-y}')" \
                        "$val% ($(mv_ "$1" "$2" crash.crash_free_frac))")" "$(sample_note "$1" "$2")"
                    fi;;
    crash_count)    printf '%s 类 %s 次' "$(mv_ "$1" "$2" crash.n)" "$(mv_ "$1" "$2" crash.events)";;
    crash_rate)     val="$(mv_ "$1" "$2" crash.rate_pct)"
                    if [ -z "$val" ]; then printf '无法计算'
                    else printf '%s%s' "$(cell_color "$val" "$CRASH_RATE_RED" "$CRASH_RATE_YELLOW" "$val% ($(mv_ "$1" "$2" crash.rate_frac))")" "$(sample_note "$1" "$2")"; fi;;
    crash_affected) printf '%s' "$(mv_ "$1" "$2" crash.affected)";;
    # iOS 无 ANR 概念：不留空、不填 0。前者被读成「数据没取到」，后者被读成「iOS 没有卡死问题」。
    # 指向本流水线已有的近似信号（冻结率 / 慢帧），让读者知道去哪里看。
    anr_count)      if [ "$1" = ios ]; then printf -- '— 无此概念（见冻结率）'
                    else val="$(mv_ "$1" "$2" errtype.anr_events)"
                      # 取数失败但 crash.state 仍是 ok 的边缘情形：空值要渲染成「—」，
                      # 否则会打出「 次 /  人」这种看着像渲染坏了的东西
                      [ -n "$val" ] && printf '%s 次 / %s 人' "$val" "$(mv_ "$1" "$2" errtype.anr_installs)" || printf -- '—'
                    fi;;
    anr_rate)       if [ "$1" = ios ]; then printf -- '— 无此概念'
                    else val="$(mv_ "$1" "$2" errtype.anr_rate_pct)"
                      if [ -z "$val" ]; then printf '无法计算'
                      else printf '%s%s' "$(cell_color "$val" "$ANR_RATE_RED" "$ANR_RATE_YELLOW" "$val% ($(mv_ "$1" "$2" errtype.anr_rate_frac))")" "$(sample_note "$1" "$2")"; fi
                    fi;;
    # 卡片专用紧凑行：草图承诺的是「20 次 / 10 人」与「48 次 0.74%」，
    # 而 crash_count / anr_rate 各自只给一半。文档保留原来的分行形态。
    crash_brief)    val="$(mv_ "$1" "$2" crash.events)"
                    [ -n "$val" ] && printf '%s 次 / %s 人' "$val" "$(mv_ "$1" "$2" crash.affected)" || printf -- '—';;
    # 「卡死信号」行：双端指标不同但语义同源——Android 是 ANR（系统判定主线程无响应），
    # iOS 系统层无 ANR 概念，其可得的近似物是**冻结帧率**（>700ms 单帧，用户直接可感知的卡死）。
    # ⚠️ 旧写法是「— 无此概念（见冻结率）」——**指针指向一个卡片上不存在的行**（冻结率在精简时被砍掉了），
    #    而且对 iOS 是零信息量的占位文字。改为这行直接装 iOS 自己的信号。
    # ⚠️ 两端窗口不同（ANR 7d / 冻结 3d），单元格内各自标注；口径注声明两者不可比。
    anr_brief)      if [ "$1" = ios ]; then
                      if [ "$(mv_ "$1" "$2" perf.state)" != "ok" ]; then
                        # iOS 的「卡死信号」装的是冻结帧率，属性能数据，同样走第 3 态细分
                        printf '%s' "$(state_text_perf "$(mv_ "$1" "$2" perf.state)" "$1" "$2" "$IOS_PERF_MAX")"
                      else
                        val="$(mv_ "$1" "$2" perf.frozen)"
                        if [ -z "$val" ]; then printf -- '— 样本不足'
                        else printf '%s' "$(cell_color "$val" "$FROZEN_RED" "$FROZEN_YELLOW" "冻结帧 ${val}%（${PERF_DAYS}d·最差页）")"; fi
                      fi
                    else val="$(mv_ "$1" "$2" errtype.anr_events)"
                      if [ -z "$val" ]; then printf -- '—'
                      else
                        wp="$(mv_ "$1" "$2" errtype.anr_rate_pct)"
                        lbl="${val} 次"; [ -n "$wp" ] && lbl="${lbl} ${wp}%（${CRASH_DAYS}d）"
                        printf '%s%s' "$(cell_color "${wp:-}" "$ANR_RATE_RED" "$ANR_RATE_YELLOW" "$lbl")" "$(sample_note "$1" "$2")"
                      fi
                    fi;;
    nonfatal_count) val="$(mv_ "$1" "$2" errtype.nonfatal_events)"
                    [ -n "$val" ] && printf '%s 次 / %s 人' "$val" "$(mv_ "$1" "$2" errtype.nonfatal_installs)" || printf -- '—';;
    start_p50)      val="$(mv_ "$1" "$2" perf.p50)"; [ -n "$val" ] && printf '%sms' "$val" || printf -- '— 样本不足';;
    start_p95)      val="$(mv_ "$1" "$2" perf.p95)"
                    [ -n "$val" ] && cell_color "$val" "$START_P95_RED" "$START_P95_YELLOW" "${val}ms" || printf -- '— 样本不足';;
    slow_worst)     val="$(mv_ "$1" "$2" perf.worst_slow)"
                    # 附样本量（决策 D5）：94% 在 3 次打开和 3000 次打开上是完全不同的结论
                    if [ -n "$val" ]; then
                      samp="$(mv_ "$1" "$2" perf.worst_samples)"
                      # ⚠️ 卡片砍页面名、文档保留完整（6 列下实发验证被截断，见 screen_brief 注释）。
                      # ⛔ 样本量那个括注不能砍：94% 在 3 次打开和 3000 次打开上是完全不同的结论（决策 D5）。
                      wscr="$(mv_ "$1" "$2" perf.worst_screen)"
                      [ "$CELL_BREVITY" = 1 ] && wscr="$(screen_brief "$wscr")"
                      lbl="${wscr} ${val}%"
                      [ -n "$samp" ] && lbl="${lbl}（${samp} 次）"
                      cell_color "$val" "$SLOW_FRAME_RED" "$SLOW_FRAME_YELLOW" "$lbl"
                    else printf -- '— 样本不足'; fi;;
    frozen)         val="$(mv_ "$1" "$2" perf.frozen)"
                    [ -n "$val" ] && cell_color "$val" "$FROZEN_RED" "$FROZEN_YELLOW" "${val}%" || printf -- '— 样本不足';;
    net_err)        val="$(mv_ "$1" "$2" perf.net_err)"
                    # 指名最差接口（决策 D7）：崩溃给最差 issue、慢帧给最差页面，接口只给总数则三者不对称
                    if [ -n "$val" ]; then
                      wn="$(mv_ "$1" "$2" perf.worst_net)"; wp="$(mv_ "$1" "$2" perf.worst_net_pct)"
                      lbl="${val}%"
                      { [ -n "$wn" ] && [ -n "$wp" ]; } && lbl="${lbl}（最差 ${wn} ${wp}%）"
                      cell_color "$val" "$NET_ERR_RED" "$NET_ERR_YELLOW" "$lbl"
                    else printf -- '— 样本不足'; fi;;
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
    crash_free) delta_cell "$(mv_ "$1" "$2" crash.crash_free_pct)" "$(mv_ "$1" "$3" crash.crash_free_pct)" pp higher_better;;
    crash_count)    delta_cell "$(mv_ "$1" "$2" crash.events)"   "$(mv_ "$1" "$3" crash.events)"   n  lower_better;;
    crash_rate)     delta_cell "$(mv_ "$1" "$2" crash.rate_pct)" "$(mv_ "$1" "$3" crash.rate_pct)" pp lower_better;;
    crash_affected) delta_cell "$(mv_ "$1" "$2" crash.affected)" "$(mv_ "$1" "$3" crash.affected)" n  lower_better;;
    anr_count)      if [ "$1" = ios ]; then printf -- '—'
                    else delta_cell "$(mv_ "$1" "$2" errtype.anr_events)" "$(mv_ "$1" "$3" errtype.anr_events)" n lower_better; fi;;
    anr_rate)       if [ "$1" = ios ]; then printf -- '—'
                    else delta_cell "$(mv_ "$1" "$2" errtype.anr_rate_pct)" "$(mv_ "$1" "$3" errtype.anr_rate_pct)" pp lower_better; fi;;
    crash_brief)    delta_cell "$(mv_ "$1" "$2" crash.events)" "$(mv_ "$1" "$3" crash.events)" n lower_better;;
    anr_brief)      if [ "$1" = ios ]; then delta_cell "$(mv_ "$1" "$2" perf.frozen)" "$(mv_ "$1" "$3" perf.frozen)" pp lower_better
                    else delta_cell "$(mv_ "$1" "$2" errtype.anr_rate_pct)" "$(mv_ "$1" "$3" errtype.anr_rate_pct)" pp lower_better; fi;;
    nonfatal_count) delta_cell "$(mv_ "$1" "$2" errtype.nonfatal_events)" "$(mv_ "$1" "$3" errtype.nonfatal_events)" n lower_better;;
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
# ⚠️ **卡片与文档的行集合必须分开**（change crash-card-brief D3）：
# 卡片回答「今天要不要管」、文档回答「具体是什么」，两者的完备性要求不同。
# 三个调用点各自指定：build_table()/md_table() 用 CARD，xml_table() 用 DOC。
# 直接改 ROW_DEFS_DOC 会把文档一起砍掉——而文档的完备性正是卡片敢砍的前提。
# 版本分列布局的行集合：crash-free 用单值版（全版本值移到下方 markdown 行），
# 对比不占列——四个版本并排，变化直接横向读得出来。
ROW_DEFS_CARD="crash_free|Crash-free 会话 ${CRASH_DAYS}d
crash_brief|崩溃 ${CRASH_DAYS}d
anr_brief|卡死信号
nonfatal_count|非致命 ${CRASH_DAYS}d
start_p95|启动 P95 ${PERF_DAYS}d
slow_worst|慢帧最差页 ${PERF_DAYS}d"
ROW_DEFS_DOC="crash_free|Crash-free 会话 ${CRASH_DAYS}d
crash_count|崩溃次数 ${CRASH_DAYS}d
crash_rate|崩溃率 ${CRASH_DAYS}d
crash_affected|受影响安装 ${CRASH_DAYS}d
anr_count|ANR ${CRASH_DAYS}d
anr_rate|ANR 率 ${CRASH_DAYS}d
nonfatal_count|非致命 ${CRASH_DAYS}d
start_p50|启动 P50 ${PERF_DAYS}d
start_p95|启动 P95 ${PERF_DAYS}d
slow_worst|慢帧最差页 ${PERF_DAYS}d
frozen|冻结率（最差页）${PERF_DAYS}d
net_err|接口错误率 ${PERF_DAYS}d
sessions|会话数 ${DAYS}d"
ROW_DEFS="$ROW_DEFS_DOC"   # 兼容：verdict_line 等按全量行集合遍历

# ── 卡片：单表、列 = 平台（change crash-card-brief）──────────────────
# 「每端一张表」让行数天然翻倍（N 个指标 = 2N 行），加上 ANR/非致命/crash-free 后要滑很久。
# 改成一张表、列为平台：同样的信息量只占一半高度，且双端对比从「上下翻找」变成「左右对照」。
# 代价是版本维度失去独立列 → 版本进表头、对比进格内（D1/D2/D4）。

# 表头：iOS 1.5.4(832)→1.5.3(2141)。括号内是会话数——放量规模是读其他数字的前提
# （12 台设备上的 0 崩溃说明不了什么），但它本身不值一整行。
# 卡片表格：列 = 平台 × 版本，每格只装一个数（2026-08-22 手机端实测通过后定为唯一布局）。
#
# 为什么不是「列 = 平台、版本挤在格内」：那种排法**只显示最新版的值**，主力版本要从 delta 反推。
# 而新版刚放量时最新版样本极小（实测 Android 1.5.4 只有 1 个会话），于是卡片上唯一可见的数字
# 全是没有统计意义的那个——`Android 1.5.3: 49 次 ANR 0.72%` 这种真正要看的数字**完全不出现**。
#
# 对比靠横向读，不需要 delta 列；放量规模与全版本 crash-free 放在表下的 markdown 行
# （表头是整张表最吃宽度的地方，挂上「(1229/888)」会被 CardKit 截断）。
build_card_table() {
  CELL_BREVITY=1
  local cols='[{"name":"metric","display_name":"指标","data_type":"text","width":"auto","horizontal_align":"left"}]'
  local rows='[]' key label rowj i=0 pk pn v tag
  # ⚠️ 列名必须是 c1…cN：CardKit 把 `ios` / `android` 当**平台变体键**，用它们做列名
  #    在 DRY RUN 里毫无异常，只有真发一张才炸。
  # ⚠️ 列集合由 IOS_CARD_COLS / AND_CARD_COLS 给（最新 N 版 ∪ 性能可得 2 版），
  #    ⛔ 不再硬写 V1/V2——性能可得版本可能不在最新两版里（change crash-data-completeness B 组）。
  for pp in "ios:iOS:$IOS_CARD_COLS" "and:Android:$AND_CARD_COLS"; do
    pk="${pp%%:*}"; rest="${pp#*:}"; pn="${rest%%:*}"
    for v in ${rest#*:}; do
      [ -n "$v" ] || continue
      i=$((i + 1))
      # 只给「因为性能才进来的列」打角标：它在崩溃/放量行里是旧版本，读者需要知道它为什么在这
      tag="$(perf_only_tag "$pk" "$v")"
      cols="$(printf '%s' "$cols" | jq -c --arg n "c$i" --arg d "$pn $v$tag" \
        '. + [{name:$n,display_name:$d,data_type:"lark_md",width:"auto",horizontal_align:"left"}]')"
    done
  done
  while IFS='|' read -r key label; do
    [ -n "$key" ] || continue
    rowj="$(jq -cn --arg m "$label" '{metric:$m}')"; i=0
    for pp in "ios:$IOS_CARD_COLS" "and:$AND_CARD_COLS"; do
      pk="${pp%%:*}"
      for v in ${pp#*:}; do
        [ -n "$v" ] || continue
        i=$((i + 1))
        rowj="$(printf '%s' "$rowj" | jq -c --arg k "c$i" --arg val "$(cell "$pk" "$v" "$key")" '. + {($k):$val}')"
      done
    done
    rows="$(printf '%s' "$rows" | jq -c --argjson r "$rowj" '. + [$r]')"
  done <<< "$ROW_DEFS_CARD"
  jq -cn --argjson c "$cols" --argjson r "$rows" \
    '{tag:"table",page_size:10,row_height:"low",
      header_style:{text_align:"left",text_size:"normal",background_style:"grey",text_color:"default",bold:true,lines:1},
      columns:$c,rows:$r}'
  CELL_BREVITY=0
}

blame_top() { # $1=plat $2=版本 → 「自家代码 12 人 · 三方 SDK 8 人」（卡片用，仅 owner 汇总）
  local f="$TMP/blame-$1-$2.csv"
  [ -s "$f" ] || { printf ''; return 0; }
  csv2tsv < "$f" | awk -F'\t' 'NF>=4 { o=$1
      if (o=="DEVELOPER") o="自家"; else if (o=="THIRD_PARTY") o="三方"; else if (o=="SYSTEM") o="系统"
      u[o]+=$4 }
    END { n=0; for (k in u) { printf "%s%s %s 人", (n++?" · ":""), k, u[k] } }'
}

# 影响集中行：top 3 机型 + 各自受影响人数。突发状况的第一落点，做成表会再加 4 行。
# 数据取自 crash-dimensions.sql（change crash-impact-summary），此处只取一行摘要——
# 汇总段本身仍不进卡片，取一行与搬整段是两回事。
card_focus_line() { # → markdown 若干行（无事件则空）
  local out="" pk pn vers v f seg best bestn n osf osseg bl nnew nreg fid adopt rest pv
  for pp in "ios:iOS:$IOS_NEWEST" "and:Android:$AND_NEWEST"; do
    pk="${pp%%:*}"; rest="${pp#*:}"; pn="${rest%%:*}"; vers="${rest#*:}"
    # 取**事件最多的那个版本**，不是固定取最新版：新版刚放量时事件常是个位数
    # （实测 1.5.4 只有 2 次 → 这行只出得来 1 个机型），而真正有量的是上一版。
    best=""; bestn=0
    for v in $vers; do
      n="$(mv_ "$pk" "$v" crash.events | grep -E '^[0-9]+$' || echo 0)"
      [ "$n" -gt "$bestn" ] 2>/dev/null && { bestn="$n"; best="$v"; }
    done
    [ -n "$best" ] || continue
    f="$TMP/dim-model-$pk-$best.csv"
    [ -s "$f" ] || continue
    seg="$(csv2tsv < "$f" | awk -F'\t' 'NF>=6{printf "%s%s %s 人", (n++?" · ":""), $1, $3}')"
    [ -n "$seg" ] && out="${out:+$out
}🎯 影响集中 ${pn} ${best}：$seg"
    # 系统版本：只给**崩溃率最高**的那个。⚠️ 该维度会话桶足够大（实测 2657/1221/715），率可靠；
    # 机型维度最大桶只有 75 会话，率不可靠——所以上面那行只给人数、这行才给率（design D5）。
    osf="$TMP/dim-os-$pk-$best.csv"
    if [ -s "$osf" ]; then
      osseg="$(csv2tsv < "$osf" | awk -F'\t' 'NF>=6 && $5 != "" && $5+0 > mx {mx=$5+0; d=$1; u=$3} END{if(d!="") printf "%s %s%%（%s 人）", d, mx, u}')"
      [ -n "$osseg" ] && out="${out}
🧩 系统版本最差 ${pn}：${osseg}"
    fi
    # 归因：只给 owner 汇总。⛔ 完整的 owner+library 组合在文档汇总段——
    # 卡片压成一行会丢掉 library，而「系统帧 + 自家包名」那种组合正是靠 library 才看得出来。
    bl="$(blame_top "$pk" "$best")"
    [ -n "$bl" ] && out="${out}
🧭 归因 ${pn}（责任帧归属，非触发者）：${bl}"
  done
  # 版本分列布局下，放量规模从表头挪到这里：表头是整张表最吃宽度的地方，
  # 挂上「(1229/888)」会被 CardKit 截断成「(1236/...」（实测），信息量归零。
  if true; then
    adopt=""
    for pv in "ios:iOS:$IOS_V1" "ios:iOS:$IOS_V2" "and:Android:$AND_V1" "and:Android:$AND_V2"; do
      pk="${pv%%:*}"; rest="${pv#*:}"; pn="${rest%%:*}"; v="${rest#*:}"
      [ -n "$v" ] || continue
      adopt="${adopt:+$adopt · }${pn} ${v} $(mv_ "$pk" "$v" adopt.sessions) 会话/$(mv_ "$pk" "$v" adopt.devices) 设备"
    done
    [ -n "$adopt" ] && out="${out:+$out
}📊 放量（${DAYS}d）：${adopt}"
  fi
  # 前后台摘要（change crash-fg-bg-split）：只在某端后台占比 >= 阈值时出一行。
  # ⚠️ 这一行改写严重度判断——实测 iOS 1.5.3 非致命 981 次里 967 次（98.6%）发生在后台，
  #    用户完全无感；不拆开就会把「iOS 非致命上千条」读成「iOS 问题比 Android 多」。
  # ⛔ 后台崩溃不等于可以不修（会中断上传/推送/预加载），文案只说「用户无感」不说「无需处理」。
  # ⛔ 只给绝对数与占比，**不给率**——sessions 表无 process_state，前后台的会话分母不存在。
  # ⛔ **取事件最多的版本，不是固定取最新版**——与本函数上方维度块同一条教训：
  #    实测 IOS_V1=1.5.4 非致命只有 14 条（低于阈值直接跳过），真正的 981 条在 1.5.3。
  #    2026-08-24 首版就是写死 V1 才没渲染出来。
  if true; then
    local _fgpk _fgpn _fgt _fgv _bestv _bestt _fg _bg _unk _tot _pct _lbl _unknote
    for pv in "ios:iOS:$IOS_V1 $IOS_V2" "and:Android:$AND_V1 $AND_V2"; do
      _fgpk="${pv%%:*}"; rest="${pv#*:}"; _fgpn="${rest%%:*}"; vers="${rest#*:}"
      for _fgt in nonfatal fatal anr; do
        _bestv=""; _bestt=0
        for _fgv in $vers; do
          [ -n "$_fgv" ] || continue
          _fg="$(mv_ "$_fgpk" "$_fgv" "errtype.${_fgt}_fg")"
          _bg="$(mv_ "$_fgpk" "$_fgv" "errtype.${_fgt}_bg")"
          _unk="$(mv_ "$_fgpk" "$_fgv" "errtype.${_fgt}_unknown")"
          [ -n "$_fg" ] && [ -n "$_bg" ] || continue
          _tot=$(( _fg + _bg + ${_unk:-0} ))
          [ "$_tot" -gt "$_bestt" ] && { _bestt=$_tot; _bestv="$_fgv"; }
        done
        [ -n "$_bestv" ] && [ "$_bestt" -ge "$FGBG_MIN_EVENTS" ] || continue
        _fg="$(mv_ "$_fgpk" "$_bestv" "errtype.${_fgt}_fg")"
        _bg="$(mv_ "$_fgpk" "$_bestv" "errtype.${_fgt}_bg")"
        _unk="$(mv_ "$_fgpk" "$_bestv" "errtype.${_fgt}_unknown")"
        _pct="$(awk -v b="$_bg" -v t="$_bestt" 'BEGIN{printf "%.1f", b/t*100}')"
        awk -v p="$_pct" -v th="$FGBG_BG_NOTE_PCT" 'BEGIN{exit !(p+0 >= th+0)}' || continue
        case "$_fgt" in (fatal) _lbl=崩溃;; (anr) _lbl=ANR;; (nonfatal) _lbl=非致命;; (*) _lbl="$_fgt";; esac
        # ⛔ 全角括号必须**先条件赋值再拼接**，禁 `${var:+（…）}`（CLAUDE.md 硬约束，
        #    bash 3.2 会把全角字节并进变量名）。⚠️ check-scripts 的多字节 lint 只查 `$VAR`
        #    紧邻全角，`${VAR:+（…）}` 这个形式它抓不到——2026-08-24 首版就是这么写的。
        # ⚠️ 判空不能用 `:+`：未知数为字符串 "0" 时它非空，会渲染出「（未知 0）」。
        _unknote=""
        [ -n "$_unk" ] && [ "$_unk" != "0" ] && _unknote="（未知 ${_unk}）"
        out="${out:+$out
}ℹ️ ${_fgpn} ${_bestv} ${_lbl} ${_bestt} 次中 ${_bg} 次在后台（${_pct}%），用户无感；前台仅 ${_fg} 次${_unknote}"
      done
    done
  fi
  # 全版本 crash-free 在表里没有归属列（它不是某个版本），放这里
  if true; then
    { [ -n "${IOS_CF_ALL:-}" ] || [ -n "${AND_CF_ALL:-}" ]; } && out="${out:+$out
}💚 全版本 Crash-free：iOS ${IOS_CF_ALL:-—}% · Android ${AND_CF_ALL:-—}%"
  fi
  # 生命周期摘要：本轮有新增或回归才出，平稳时不占版面
  if [ "${LIFECYCLE_OK:-0}" = 1 ] && [ -n "${CUR_IDS:-}" ]; then
    nnew=0; nreg=0
    while IFS= read -r fid; do
      [ -n "$fid" ] || continue
      case "$(life_tag "$fid")" in *新增*) nnew=$((nnew+1));; *回归*) nreg=$((nreg+1));; esac
    done <<< "$CUR_IDS"
    { [ "$nnew" -gt 0 ] || [ "$nreg" -gt 0 ]; } && out="${out:+$out
}🆕 本轮 issue 变化：新增 ${nnew} 个 · 回归 ${nreg} 个"
  fi
  printf '%s' "$out"
}

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

# ⛔ 补充列必须**逐个说明它为什么在这**：原来一律写「+主力」，而 change crash-data-completeness
#    之后补充列还可能是「性能兜底」（那一版会话量可能很小，说成主力是睁眼说瞎话）。
ver_summary() { # $1=最新版 $2=上一版 $3=版本列 $4=主力版列表 $5=性能可得版列表
  local v lbl out=""
  [ -n "$1" ] || { printf '版本解析失败'; return 0; }
  printf '%s' "$1"
  [ -n "$2" ] && printf ' vs %s' "$2"
  for v in $3; do
    if [ "$v" = "$1" ]; then continue; fi
    if [ -n "$2" ] && [ "$v" = "$2" ]; then continue; fi
    # 主力优先：它在会话量上本来就该有一列，性能只是顺带；反过来标会丢掉更重要的那个理由
    if printf '%s\n' "${4:-}" | grep -qx -- "$v"; then lbl="主力"
    elif printf '%s\n' "${5:-}" | grep -qx -- "$v"; then lbl="性能兜底"
    else lbl="补充"; fi
    out="${out}${out:+ · }+${lbl} ${v}"
  done
  [ -n "$out" ] && printf '（%s）' "$out"
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
IOS_VER_SUM="$(ver_summary "$IOS_V1" "$IOS_V2" "$IOS_COLS" "$IOS_TOPSESS" "$IOS_PERF_VERS")"
AND_VER_SUM="$(ver_summary "$AND_V1" "$AND_V2" "$AND_COLS" "$AND_TOPSESS" "$AND_PERF_VERS")"

step "组装卡片"
CARD_TABLE="$(build_card_table)"
CARD_FOCUS="$(card_focus_line)"

HEADER_TITLE="📊 ${DAY:5} $TS_HM 崩溃 & 性能"
HEADER_COLOR="blue"; [ -n "$ALERTS" ] && HEADER_COLOR="red"
SESS_FALLBACK_NOTE=""
{ [ "$SESS_IOS_FALLBACK" = 1 ] || [ "$SESS_AND_FALLBACK" = 1 ]; } && SESS_FALLBACK_NOTE="；⚠️ 放量回退批量表（可能停更）"
NOTE_MD="$(printf '本报告只统计最新 %s 个版本（会话量 top2 不在其中时补「主力」列）；跨版本合计值不再输出。\n带「性能兜底」角标的列是**性能表里可得的最新版本**——性能批量表比崩溃/放量滞后约 2 天，新版在它里面常年零行，那一列的性能值本来就取不到。⛔ 该列的崩溃/放量数字是**这个旧版本自己的**，不是新版的。\n取数区间 性能 %sd：%s\n取数区间 放量 %sd：%s\n取数区间 崩溃 %sd：%s%s\n崩溃=BigQuery 事件级（含已关闭 issue）· 崩溃率=事件数/会话数 · Crash-free=会话口径（**与控制台的用户口径不可比**，且为下界估计）· 卡死信号行**双端指标不同不可比**：Android=ANR 率（%sd，与 Play 门槛口径亦不同），iOS=冻结帧率（%sd，系统层无 ANR 概念）· 非致命双端不可比 · 慢帧>16ms / 冻结>700ms 为帧级占比\n格内对比 = 最新版 − 上一版（箭头跟数值方向、颜色跟好坏）；表头括号内为该版本的 **会话数/设备数**（设备数才是「多少人在用」，会话数会被同一人反复启动放大）；影响集中行取该端事件最多的版本；同版本 DoD/WoW 与完整 13 项指标见日报文档' \
  "$VERSION_COUNT" \
  "$PERF_DAYS"  "$(win_days "$PERF_WIN_START" "$PERF_LCD" "$RUN_EPOCH" "$DATA_UNTIL")" \
  "$DAYS"       "$(win_compact "$RUN_EPOCH" "$TZ_LABEL" "$DAYS" "$ADOPTION_UNTIL")" \
  "$CRASH_DAYS" "$(win_compact "$RUN_EPOCH" "$TZ_LABEL" "$CRASH_DAYS" "$CRASH_UNTIL")" "$SESS_FALLBACK_NOTE" \
  "$CRASH_DAYS" "$PERF_DAYS")"

CARD_JSON="$(jq -n \
  --arg hc "$HEADER_COLOR" --arg ht "$HEADER_TITLE" --arg sm "$STATUS_MD" \
  --arg nm "$NOTE_MD" \
  --argjson ct "$CARD_TABLE" --arg fo "$CARD_FOCUS" \
  '{schema:"2.0",
    config:{width_mode:"fill"},
    header:{template:$hc,title:{tag:"plain_text",content:$ht}},
    body:{elements:([
      {tag:"markdown",content:$sm},
      $ct]
      + (if $fo != "" then [{tag:"markdown",content:$fo}] else [] end)
      + [
      {tag:"div",text:{tag:"plain_text",content:$nm,text_size:"notation",text_color:"grey"}},
      {tag:"markdown",content:"📄 [详情](__DETAIL_URL__) · 🗂 [崩溃跟踪索引](__INDEX_URL__) · 📁 [全部报告](__FOLDER_URL__)"}
    ])}}')"

# markdown 回退视图（调试与 message.md；结构化卡片投递失败时人也能读）
# **文档专用**的 markdown 表：全量行 × 版本列，与 xml_table 同口径。
# ⚠️ 与卡片的 md_table() 是两个函数，别合并——卡片砍到 6 行的前提正是文档保持完备
# （change crash-card-brief D3：ROW_DEFS 必须拆成 _CARD / _DOC，三个调用点各自指定）。
md_table_doc() { # $1=plat $2=版本列 $3=V1 $4=V2
  local key label v
  printf '| 指标 |'; for v in $2; do printf ' %s%s |' "$v" "$(perf_only_tag "$1" "$v")"; done; [ -n "$4" ] && printf ' 对比 |'; printf '\n'
  printf '|---|'; for v in $2; do printf -- '---|'; done; [ -n "$4" ] && printf -- '---|'; printf '\n'
  while IFS='|' read -r key label; do
    [ -n "$key" ] || continue
    printf '| %s |' "$label"
    for v in $2; do printf ' %s |' "$(cell "$1" "$v" "$key" | sed -e 's|<font color=[a-z]*>||g' -e 's|</font>||g')"; done
    [ -n "$4" ] && printf ' %s |' "$(delta_of "$1" "$3" "$4" "$key" | sed -e 's|<font color=[a-z]*>||g' -e 's|</font>||g')"
    printf '\n'
  done <<< "$ROW_DEFS_DOC"
}

# 卡片的 markdown 回退视图：与结构化卡片同形态（列 = 平台×版本），投递失败时人也能读。
# ⚠️ 与 build_card_table() 是**同一张表的两套渲染**（这里出 markdown 预览，那里出 CardKit JSON）：
#    列集合改一处必须改两处，漏一处的表现是「DRY RUN 预览 4 列、真发出去 6 列」——
#    预览与实发不一致，正是这个仓库最难排查的一类。
md_table() { # 无参数：直接用全局的卡片版本列
  local key label pp pk pn v rest
  CELL_BREVITY=1
  printf '| 指标 |'
  for pp in "ios:iOS:$IOS_CARD_COLS" "and:Android:$AND_CARD_COLS"; do
    pk="${pp%%:*}"; rest="${pp#*:}"; pn="${rest%%:*}"
    for v in ${rest#*:}; do
      [ -n "$v" ] && printf ' %s %s%s |' "$pn" "$v" "$(perf_only_tag "$pk" "$v")"
    done
  done
  printf '\n|---|'
  for pp in "ios:$IOS_CARD_COLS" "and:$AND_CARD_COLS"; do
    for v in ${pp#*:}; do [ -n "$v" ] && printf -- '---|'; done
  done
  printf '\n'
  while IFS='|' read -r key label; do
    [ -n "$key" ] || continue
    printf '| %s |' "$label"
    for pp in "ios:$IOS_CARD_COLS" "and:$AND_CARD_COLS"; do
      pk="${pp%%:*}"
      for v in ${pp#*:}; do
        [ -n "$v" ] || continue
        printf ' %s |' "$(cell "$pk" "$v" "$key" | sed -e 's|<font color=[a-z]*>||g' -e 's|</font>||g')"
      done
    done
    printf '\n'
  done <<< "$ROW_DEFS_CARD"
  CELL_BREVITY=0
}

CARD="**📊 ${DAY:5} 崩溃 & 性能**
$STATUS_MD

$(md_table)
$(card_focus_line)

> $NOTE_MD"

# ── 同版本环比（DoD/WoW，只对最新 N 版；卡片不放，见 design D7）────────
# 环比数据（结构化）：每行「指标|今日|DoD|WoW」。
# 原来一行一句 "启动 P95 DoD +6359ms ↑（对比 A vs B）· WoW 无基准"，
# 五行把同一个对比日期和同一句「WoW 无基准」重复五遍——日期挪到表外说一次，表里只放数值。
dodwow_rows() { # $1=plat $2=版本
  local ce se rate ry r7 lbl ae arate ary ar7 cs cf cfy cf7
  ce="$(dv_ "$1" "$2" crash_events_1d)"; se="$(dv_ "$1" "$2" sessions_1d)"
  rate="$(daily_rate "$ce" "$se")"
  ry="$(daily_rate "$(hist_val "$YESTERDAY" "$1" "$2" crash_events_1d)" "$(hist_val "$YESTERDAY" "$1" "$2" sessions_1d)")"
  r7="$(daily_rate "$(hist_val "$D7" "$1" "$2" crash_events_1d)" "$(hist_val "$D7" "$1" "$2" sessions_1d)")"
  # ANR 率与崩溃率同分母（当日会话数），保持同口径可并读
  # crash-free 会话率（天级）。⚠️ `_row` 的 delta 方向是 lower_better，而 crash-free 越大越好，
  # 故单独用 higher_better 渲染，不走 _row。
  cs="$(dv_ "$1" "$2" crash_sessions_1d)"
  cf="$(daily_rate "$cs" "$se")";  [ -n "$cf" ] && cf="$(awk -v b="$cf" 'BEGIN{printf "%.2f", 100-b}')"
  cfy="$(daily_rate "$(hist_val "$YESTERDAY" "$1" "$2" crash_sessions_1d)" "$(hist_val "$YESTERDAY" "$1" "$2" sessions_1d)")"
  [ -n "$cfy" ] && cfy="$(awk -v b="$cfy" 'BEGIN{printf "%.2f", 100-b}')"
  cf7="$(daily_rate "$(hist_val "$D7" "$1" "$2" crash_sessions_1d)" "$(hist_val "$D7" "$1" "$2" sessions_1d)")"
  [ -n "$cf7" ] && cf7="$(awk -v b="$cf7" 'BEGIN{printf "%.2f", 100-b}')"
  ae="$(dv_ "$1" "$2" anr_events_1d)"
  arate="$(daily_rate "$ae" "$se")"
  ary="$(daily_rate "$(hist_val "$YESTERDAY" "$1" "$2" anr_events_1d)" "$(hist_val "$YESTERDAY" "$1" "$2" sessions_1d)")"
  ar7="$(daily_rate "$(hist_val "$D7" "$1" "$2" anr_events_1d)" "$(hist_val "$D7" "$1" "$2" sessions_1d)")"
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
  printf 'Crash-free 会话|%s|%s|%s\n' \
    "$([ -n "$cf" ] && printf '%s%%' "$cf" || printf -- '—')" \
    "$(delta_cell "$cf" "$cfy" pp higher_better)" "$(delta_cell "$cf" "$cf7" pp higher_better)"
  _row "崩溃率" "$rate" "$ry" "$r7" pp "%"
  # iOS 无 ANR：整行不输出，而不是输出一行全「—」——后者会被读成「数据没取到」
  [ "$1" = ios ] || _row "ANR 率" "$arate" "$ary" "$ar7" pp "%"
  # 非致命是**计数**不是百分比：单位必须用 n，否则 delta_cell 会渲染成「+3.00pp」
  _row "非致命" "$(dv_ "$1" "$2" nonfatal_events_1d)" "$(hist_val "$YESTERDAY" "$1" "$2" nonfatal_events_1d)" "$(hist_val "$D7" "$1" "$2" nonfatal_events_1d)" n ""
  _row "启动 P50" "$(dv_ "$1" "$2" start_p50_1d)" "$(dv_ "$1" "$2" prev.start_p50_1d)" "$(hist_val_perfday "$PERF_D7" "$1" "$2" start_p50_1d)" ms "ms"
  _row "启动 P95" "$(dv_ "$1" "$2" start_p95_1d)" "$(dv_ "$1" "$2" prev.start_p95_1d)" "$(hist_val_perfday "$PERF_D7" "$1" "$2" start_p95_1d)" ms "ms"
  _row "慢帧（平台级）" "$(dv_ "$1" "$2" slow_pct_1d)" "$(dv_ "$1" "$2" prev.slow_pct_1d)" "$(hist_val_perfday "$PERF_D7" "$1" "$2" slow_pct_1d)" pp "%"
  _row "冻结" "$(dv_ "$1" "$2" frozen_pct_1d)" "$(dv_ "$1" "$2" prev.frozen_pct_1d)" "$(hist_val_perfday "$PERF_D7" "$1" "$2" frozen_pct_1d)" pp "%"
  _row "接口错误率" "$(dv_ "$1" "$2" net_err_pct_1d)" "$(dv_ "$1" "$2" prev.net_err_pct_1d)" "$(hist_val_perfday "$PERF_D7" "$1" "$2" net_err_pct_1d)" pp "%"
  return 0
}
# 对比口径说明：一个版本块只说一次
dodwow_note() { # $1=plat $2=版本
  printf '天级单日值 · 崩溃/放量按昨日；性能按最近完整日（DoD %s vs %s · WoW 基准 %s）· DoD=日环比 · WoW=周环比' \
    "$(dv_ "$1" "$2" perf_day)" "$(dv_ "$1" "$2" perf_prev_day)" "${PERF_D7:-—}"
  # 跨口径 WoW 必须带标注，⛔ 不能静默给数（design D8；与「两套口径分离存储不可混比」同一条纪律）
  local _m; _m="$(hist_mode_perfday "${PERF_D7:-}" "$1" "$2")"
  if [ -n "$_m" ] && [ "$_m" != complete_day ]; then
    printf '；⚠️ 本行 WoW 跨口径：基准日 %s 取的是旧口径（该版本自己的最新可用单日，可能含 7 小时残日），口径切换于 %s，切满 7 天后此标注自动消失' \
      "$PERF_D7" "$WINDOW_SWITCH_DAY"
  fi
  return 0
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
  local key label draw d worse="" better=""
  [ -n "$4" ] || { printf -- '- **%s** %s：无上一版可比\n' "$2" "$3"; return 0; }
  while IFS='|' read -r key label; do
    [ -n "$key" ] || continue
    draw="$(delta_of "$1" "$3" "$4" "$key")"
    d="$(printf '%s' "$draw" | sed -e 's|<font color=[a-z]*>||g' -e 's|</font>||g')"
    # 好坏判定必须看**颜色**不看箭头：delta_cell 已经把方向与好坏分开编码了
    # （箭头跟数值方向、颜色跟好坏）。按箭头分类等于假设「所有指标都越小越好」，会判错两类：
    #   · higher_better 指标（Crash-free 会话率）——降了会被说成「变好」；
    #   · neutral 指标（会话数）——放量掉一千个会话会被说成「变好」，而它本就不该判好坏。
    # 无色 = neutral 或无可比数据，两栏都不进。
    case "$draw" in
      *'<font color=red>'*)   worse="${worse:+${worse}、}$label $d";;
      *'<font color=green>'*) better="${better:+${better}、}$label $d";;
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
  # 集中度 = 事件 / 受影响安装：9 次影响 1 台（9.0）与 14 次影响 7 台（2.0）严重度完全不同，
  # 而只看事件数两者长得一样。排序已在 SQL 里改成按 users（change crash-impact-summary D3）。
  printf '| Issue | 状态 | 标题 | 事件 | 影响安装 | 集中度 | 最新 |\n|---|---|---|---|---|---|---|\n'
  # 状态列逐行取：life_tag 要完整 id，而表里只显示短 id
  jq -r '.[] | [.issue_id, (if (.title // "") == "" then "—" else .title end), (.n|tostring), (.users|tostring), (((( .n|tonumber ) / (if (.users|tonumber) == 0 then 1 else (.users|tonumber) end) * 10 | round) / 10)|tostring), .latest] | @tsv' "$f" 2>/dev/null \
  | while IFS=$'\t' read -r fid ti n us cc la; do
      [ -n "$fid" ] || continue
      printf '| %s | %s | %s | %s | %s | %s | %s |\n' "${fid:0:8}" "$(life_tag "$fid")" "$ti" "$n" "$us" "$cc" "$la"
    done
  printf '\n'
}
# NON_FATAL 明细。**位置与异常分两列**：iOS 的 issue_title 恒为 Crashlytics SDK 的包装帧
# （FIRCLSNonFatalError.m …），三条 top issue 标题完全相同、零区分度，信息全在 subtitle；
# Android 则两者互补（title=位置、subtitle=异常类型）。故两列都出，不做启发式取舍。
nonfatal_table() { # $1=plat $2=版本
  local f="$TMP/nonfatal-$1-$2.json"
  if [ ! -s "$f" ] || [ "$(jq 'length' "$f" 2>/dev/null || echo 0)" = "0" ]; then
    printf '（该版本窗口内无非致命异常）\n\n'; return 0
  fi
  printf '| Issue | 位置 | 异常 | 事件 | 影响 | 最新 |\n|---|---|---|---|---|---|\n'
  # 空标题也要渲染成「—」：iOS 存在 issue_title 为空的记录（实测 a7cb1856），
  # 空单元格会被读成「渲染坏了」。`// "—"` 挡不住空字符串，必须显式判空。
  jq -r '.[] | "| \(.issue_id[0:8]) | \(if (.title // "") == "" then "—" else .title end) | \(if (.subtitle // "") == "" then "—" else .subtitle end) | \(.n) | \(.users) | \(.latest) |"' "$f" 2>/dev/null || true
  printf '\n'
}
# ── 汇总段（change crash-impact-summary）：只回答三个问题 ──────────────
# 影响多少人 / 集中在哪 / 什么时候。⛔ 不给根因——维度聚合只能显示相关性，
# 与性能段「不出根因」是同一条硬约束。

# 块 A：影响多少人。集中度 = 事件 / 受影响安装。
sum_impact_rows() { # → CSV：平台,版本,受影响安装,受影响用户,崩溃事件,集中度
  local p v pn ev aff c u
  for p in ios and; do
    [ "$p" = ios ] && pn="iOS" || pn="Android"
    for v in $([ "$p" = ios ] && printf '%s' "$IOS_NEWEST" || printf '%s' "$AND_NEWEST"); do
      ev="$(mv_ "$p" "$v" crash.events)"; aff="$(mv_ "$p" "$v" crash.affected)"
      [ -n "$ev" ] || continue
      c="—"
      [ -n "$aff" ] && [ "$aff" != "0" ] && c="$(awk -v e="$ev" -v u="$aff" 'BEGIN{printf "%.1f", e/u}')"
      # 受影响用户数（change crash-affected-users）：⛔ **仅 iOS 有值**，Android 客户端不上报
      # user.id（实测 0/221）。Android 渲染「— 不上报」而**不是 0**——0 会被读成「没人受影响」，
      # 也不是留空——留空会被读成渲染坏了。⚠️ 与 iOS ANR 的「— 无此概念」语义不同，后缀必须区分。
      # ⛔ 与「受影响安装」**不可相加或相减**：两者是交叉的两套群体（实测前台子集出现过
      #    6 安装 / 7 用户，用户数反而更多）。
      u="$(mv_ "$p" "$v" crash.affected_users)"
      if [ "$p" = ios ]; then u="${u:-—}"; else u="— 不上报"; fi
      printf '%s,%s,%s,%s,%s,%s\n' "$pn" "$v" "${aff:-—}" "$u" "$ev" "$c"
    done
  done
}

# 块 B：集中在哪。两版 top N 完全一致时合并成一段并标注——稳态下这是常态，能大幅压缩版面。
# 收集某维度全部平台/版本的行 → CSV（供表格渲染；markdown 与 XML 共用同一份）。
# 用表而不是「小标题 + 项目符号」：内容本来就是表格数据，列对齐才能横向比较；
# 而且文档其余段都是带斑马纹的彩色表，裸 <p> 段落在视觉上也不统一。
dim_csv() { # $1=model|os → stdout: 平台,版本,取值,事件,影响安装,集中度[,崩溃率]
  local pk pn vers v f show_rate=0
  [ "$1" = os ] && show_rate=1
  for pp in "ios:iOS:$IOS_NEWEST" "and:Android:$AND_NEWEST"; do
    pk="${pp%%:*}"; rest="${pp#*:}"; pn="${rest%%:*}"; vers="${rest#*:}"
    plat_has_events "$pk" || continue
    for v in $vers; do
      f="$TMP/dim-$1-$pk-$v.csv"
      [ -s "$f" ] || continue
      csv2tsv < "$f" | awk -F'\t' -v pn="$pn" -v ver="$v" -v sr="$show_rate" -v minS="$DIM_MIN_SESSIONS" '
        NF>=6 {
          # 机型维度不给率（Android 机型碎片化，桶太小率不可靠）；系统版本样本不足时也不给
          rate = ($5 == "" || $4 == "" || $4+0 < minS) ? "—" : $5 "%"
          printf "\"%s\",\"%s\",\"%s\",\"%s\",\"%s\",\"%s\"", pn, ver, $1, $2, $3, $6
          if (sr) printf ",\"%s\"", rate
          printf "\n"
        }'
    done
  done
}
# 无分母维度的汇总行（change crash-screen-dimension）。
# ⛔ **不复用 dim_csv**：那份判 NF>=6 并读第 5 列作率，而无分母 CSV 只有 4 列——
#    套用只会静默拿到空表（NF>=6 不成立），不报错。列序差异见 qdim_nd 注释 ②。
dim_nd_csv() { # $1=维度名(screen) → stdout: "平台","版本","取值","事件","影响安装","集中度"
  local pk pn vers v f
  for pp in "ios:iOS:$IOS_NEWEST" "and:Android:$AND_NEWEST"; do
    pk="${pp%%:*}"; rest="${pp#*:}"; pn="${rest%%:*}"; vers="${rest#*:}"
    plat_has_events "$pk" || continue
    for v in $vers; do
      f="$TMP/dim-$1-$pk-$v.csv"
      [ -s "$f" ] || continue
      csv2tsv < "$f" | awk -F'\t' -v pn="$pn" -v ver="$v" 'NF>=4 {
        printf "\"%s\",\"%s\",\"%s\",\"%s\",\"%s\",\"%s\"\n", pn, ver, $1, $2, $3, $4
      }'
    done
  done
}

blame_csv() { # → 平台,版本,归因方,代码库,事件,影响安装
  local pk pn vers v f
  for pp in "ios:iOS:$IOS_NEWEST" "and:Android:$AND_NEWEST"; do
    pk="${pp%%:*}"; rest="${pp#*:}"; pn="${rest%%:*}"; vers="${rest#*:}"
    plat_has_events "$pk" || continue
    for v in $vers; do
      f="$TMP/blame-$pk-$v.csv"
      [ -s "$f" ] || continue
      csv2tsv < "$f" | awk -F'\t' -v pn="$pn" -v ver="$v" 'NF>=4 {
        o=$1
        if (o=="DEVELOPER") o="自家代码"; else if (o=="THIRD_PARTY") o="三方 SDK"; else if (o=="SYSTEM") o="系统"
        printf "\"%s\",\"%s\",\"%s\",\"%s\",\"%s\",\"%s\"\n", pn, ver, o, $2, $3, $4
      }'
    done
  done
}
# markdown 表渲染：$1=csv文件 $2=表头（逗号分隔）
md_csv_table() {
  if [ ! -s "$1" ]; then printf '（该窗口内无事件）\n\n'; return 0; fi
  printf '| %s |\n' "$(printf '%s' "$2" | sed 's/,/ | /g')"
  printf '|%s\n' "$(printf '%s' "$2" | awk -F, '{for(i=1;i<=NF;i++) printf "---|"}')"
  python3 -c "
import csv,sys
for r in csv.reader(open(sys.argv[1], encoding='utf-8')):
    print('| ' + ' | '.join(r) + ' |')" "$1"
  printf '\n'
}

plat_has_events() { # $1=plat键 → 0=有事件 1=无
  local v t=0
  for v in $([ "$1" = ios ] && printf '%s' "$IOS_NEWEST" || printf '%s' "$AND_NEWEST"); do
    t=$(( t + $(mv_ "$1" "$v" crash.events 2>/dev/null | grep -E '^[0-9]+$' || echo 0) ))
  done
  [ "$t" -gt 0 ]
}


# 块 C：什么时候。峰值（按一天中的第几小时汇总）与聚集（单个绝对小时桶占比）分开呈现——
# 合并会让常态的作息高峰被读成事故。
hours_peak() { # $1=plat $2=版本 → 「14:00 19 次 · 21:00 17 次」
  local f="$TMP/hours-$1-$2.csv"
  [ -s "$f" ] || { printf ''; return 0; }
  awk -F, 'NF>=4 {h[$2]+=$3} END{for(k in h) printf "%s\t%s\n", h[k], k}' "$f" \
    | sort -rn | head -2 | awk -F'\t' '{printf "%s%s:00 %s 次", (NR>1?" · ":""), $2, $1}'
}
hours_cluster() { # $1=plat $2=版本 → 聚集提示（无则空）
  local f="$TMP/hours-$1-$2.csv"
  [ -s "$f" ] || { printf ''; return 0; }
  # 粗糙但稳健：最密集桶事件数 vs 均匀分布期望（总数 / 窗口小时数）。
  # ⛔ 不做统计检验——样本量在两百上下，任何显著性检验都会给出不可靠结论。
  # 双重门槛：既要显著高于期望（4 倍），也要绝对量够（>=5），否则「1 次 vs 期望 0.4 次」也会触发。
  awk -F, -v hrs="$((CRASH_DAYS * 24))" 'NF>=4 {t+=$3; if($3>mx){mx=$3; mb=$1}}
    END{ if(t>0 && mx>=5 && mx > 4*(t/hrs)) printf "⚠️ 存在时间聚集：%s 时段单小时 %d 次（占窗口内 %d 次的 %.0f%%）——集中爆发通常对应一次发版 / 配置推送 / 后端异常，值得回溯当时的变更", mb, mx, t, mx/t*100 }' "$f"
}

csv_table() { # $1=文件 $2=表头 $3=awk 格式
  if [ ! -s "$1" ]; then printf '（无数据）\n\n'; return 0; fi
  printf '%s\n' "$2"
  csv2tsv < "$1" | awk -F'\t' "$3"
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
    else printf '<th background-color="%s">%s%s</th>' "$XC_HEAD" "$v" "$(perf_only_tag "$1" "$v")"; fi
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
  : > "$TMP/iss-$1-$2.csv"
  jq -r '.[] | [.issue_id, (if (.title // "") == "" then "—" else .title end), (.n|tostring), (.users|tostring),
                (((( .n|tonumber ) / (if (.users|tonumber) == 0 then 1 else (.users|tonumber) end) * 10 | round) / 10)|tostring), .latest] | @tsv' \
    "$f" 2>/dev/null \
  | while IFS=$'\t' read -r fid ti n us cc la; do
      [ -n "$fid" ] || continue
      printf '"%s","%s","%s","%s","%s","%s","%s"\n' "${fid:0:8}" "$(life_tag "$fid")" "$ti" "$n" "$us" "$cc" "$la" \
        >> "$TMP/iss-$1-$2.csv"
    done
  xml_csv_table "$TMP/iss-$1-$2.csv" 'Issue,状态,标题,事件,影响安装,集中度,最新' '1,2,3,4,5,6,7' 
}
xml_nonfatal() { # $1=plat $2=版本
  local f="$TMP/nonfatal-$1-$2.json"
  if [ ! -s "$f" ] || [ "$(jq 'length' "$f" 2>/dev/null || echo 0)" = "0" ]; then
    printf '<p><span text-color="gray">该版本窗口内无非致命异常</span></p>\n'; return 0
  fi
  jq -r '.[] | [.issue_id[0:8],
                (if (.title // "") == "" then "—" else .title end),
                (if (.subtitle // "") == "" then "—" else .subtitle end),
                (.n|tostring), (.users|tostring), .latest] | @csv' \
    "$f" 2>/dev/null > "$TMP/nf-$1-$2.csv" || true
  xml_csv_table "$TMP/nf-$1-$2.csv" 'Issue,位置,异常,事件,影响,最新' '1,2,3,4,5,6'
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

step "生成日报文档"
REPORT="$STATE/reports/$DAY-daily.md"
{
  printf '# 崩溃 & 性能日报 · %s\n\n' "$DAY"
  printf '> **本报告只统计最新 %s 个版本**：iOS %s · Android %s\n' "$VERSION_COUNT" "$IOS_VER_SUM" "$AND_VER_SUM"
  # 性能段是完整日闭区间（无时刻），故不走 win_full 的双时区时刻串；崩溃/放量段口径未变仍走原样。
  printf '> 性能 %sd：**%s**（数据截止 %s）\n' "$PERF_DAYS" "$(win_days "$PERF_WIN_START" "$PERF_LCD" "$RUN_EPOCH" "$DATA_UNTIL")" "$DATA_UNTIL"
  printf '> 放量 %sd：**%s**\n' "$DAYS" "$(win_full "$RUN_EPOCH" "$TZ_LABEL" "$DAYS" "$ADOPTION_UNTIL")"
  printf '> 崩溃 %sd：**%s**\n' "$CRASH_DAYS" "$(win_full "$RUN_EPOCH" "$TZ_LABEL" "$CRASH_DAYS" "$CRASH_UNTIL")"
  printf '> iOS %s · Android %s\n' "$IOS_TOP_NOTE" "$AND_TOP_NOTE"
  printf '> 窗口起点 = 本次跑批时刻 − N 天（SQL 下界）；终点 = 该表实际取到的最新数据，两者之差即数据滞后。\n'
  printf '> 本次运行 %s · 审计 $STATE/audit/daily-%s.events.jsonl\n\n' "$RUN_ID" "$RUN_ID"

  printf '## 一、汇总\n\n'
  printf '%s\n\n' "$STATUS_MD"
  verdict_line ios "iOS" "$IOS_V1" "$IOS_V2"
  verdict_line and "Android" "$AND_V1" "$AND_V2"
  printf '\n'

  printf '### 影响多少人\n\n'
  printf '| 平台 | 版本 | 受影响安装 | 受影响用户 | 崩溃事件 | 集中度 |\n|---|---|---|---|---|---|\n'
  sum_impact_rows | awk -F, '{printf "| %s | %s | %s | %s | %s | %s |\n",$1,$2,$3,$4,$5,$6}'
  # ⛔ 字面文本走 `printf '%s\\n' "…"`，**不可放进格式串**——文案里的 `96.6%` / `0%` 会被
  #    printf 当成格式符，报 `invalid format character` 并触发 ERR trap 发告警（2026-08-24 实测）。
  printf '%s\n' '> **受影响用户**（`user.id` 去重）**仅 iOS 可得**——实测 iOS 覆盖 96.6%、**Android 0%**（客户端不上报），故 Android 渲染「— 不上报」。⛔ 与「受影响安装」**不可相加或相减**：两者是交叉的两套群体（实测前台子集出现过 6 安装 / 7 用户，用户数反而更多）。⛔ **无用户崩溃率**——会话表无任何用户标识，用户分母不存在；⚠️ 也**不可与 Firebase 控制台首屏的受影响用户数对照**（口径与窗口均不同）。'
  printf '\n> 集中度 = 事件 / 受影响安装。9 次崩溃影响 1 台设备（9.0）与 14 次影响 7 台（2.0）严重度完全不同，\n'
  printf '> 而只看事件数两者长得一样。\n\n'

  printf '### 集中在哪\n\n'
  printf '> **本节口径 = FATAL + ANR**（影响面需覆盖卡死，ANR 事件量与崩溃持平）——与上表「影响多少人」\n'
  printf '> （仅 FATAL）**不可直接相加对照**；对照控制台需把事件类型勾成「崩溃 + ANR」。\n'
  printf '> **机型只给绝对数**：Android 机型碎片化，单机型会话量太小（实测最大桶 75 会话），率不可靠。\n'
  printf '> **未除以装机量，不代表该机型更易崩。** 系统版本维度桶足够大，给崩溃率。\n'
  printf '> ⛔ 维度分布只显示相关性，**不是根因**——需要钻取确认，见周报。\n\n'
  printf '**机型**\n\n'
  dim_csv model > "$TMP/sum-dim-model.csv"
  md_csv_table "$TMP/sum-dim-model.csv" '平台,版本,机型,事件,影响安装,集中度'
  printf '**系统版本**\n\n'
  dim_csv os > "$TMP/sum-dim-os.csv"
  md_csv_table "$TMP/sum-dim-os.csv" '平台,版本,系统版本,事件,影响安装,集中度,崩溃率'

  printf '**页面**（崩溃发生时所在页面）\n\n'
  dim_nd_csv screen > "$TMP/sum-dim-screen.csv"
  md_csv_table "$TMP/sum-dim-screen.csv" '平台,版本,页面,事件,影响安装,集中度'
  printf '> ⛔ **本维度只给绝对数，不给崩溃率**——`firebase_sessions` 表无页面字段，页面级会话分母**不存在**（不是暂时没做）。事件多的页面通常只是访问量大的页面。\n'
  printf '> ⚠️ 口径按端不同：**Android = FATAL + ANR，iOS = NON_FATAL**。iOS 近 60 天仅 5 次致命崩溃，按致命口径这张表只有一行——**两端此表不可并读为同一指标**。\n'
  printf '> ⚠️ `(未知)` 是取不到页面的事件，**照常参与排序不予丢弃**；ANR 的页面覆盖率最低（应用卡死时 custom key 写入本身也受影响）。\n'
  printf '> ⚠️ iOS 侧存在 UIKit 内部窗口（如 `UITrackingElementWindowController`），**不是业务页面**，埋点取值口径待与客户端确认前照实呈现、不做过滤。\n\n'
  printf '**归因（责任帧属于谁）**\n\n'
  printf '> ⛔ 归因方标识的是崩溃栈中**被判定为责任帧的那一帧属于谁**，**不是「谁触发了这次崩溃」**。\n'
  printf '> 归因方是「系统」或「三方」**不等于非自家问题**——实测存在「系统帧 + 自家包名」的组合，\n'
  printf '> 那是系统帧被自家代码调用。归因方与代码库必须一起读。\n\n'
  blame_csv > "$TMP/sum-blame.csv"
  md_csv_table "$TMP/sum-blame.csv" '平台,版本,归因方,代码库,事件,影响安装'

  printf '### 什么时候\n\n'
  # 遍历最新 N 版而非只看 V1：新版刚放量时事件数可能个位数（实测 1.5.4 只有 2 次），
  # 只看它会漏掉真正有量的主力版本（1.5.3 有 73 次）。
  for pp in "ios:iOS:$IOS_NEWEST" "and:Android:$AND_NEWEST"; do
    pk="${pp%%:*}"; rest="${pp#*:}"; pn="${rest%%:*}"; vers="${rest#*:}"
    for v in $vers; do
      peak="$(hours_peak "$pk" "$v")"; clu="$(hours_cluster "$pk" "$v")"
      [ -n "$peak" ] || continue
      printf -- '- **%s %s** 峰值时段（+08）：%s\n' "$pn" "$v" "$peak"
      [ -n "$clu" ] && printf -- '  - %s\n' "$clu"
    done
    plat_has_events "$pk" || printf -- '- **%s**：窗口内无事件\n' "$pn"
  done
  printf '\n> 峰值是**常态分布**的描述（作息高峰），聚集才是**异常**信号。两者分开呈现——合并会让常态被读成事故。\n\n'

  printf '## 二、版本对照\n\n'
  printf '### iOS · %s\n\n' "$IOS_VER_SUM"
  md_table_doc ios "$IOS_COLS" "$IOS_V1" "$IOS_V2"
  printf '\n### Android · %s\n\n' "$AND_VER_SUM"
  md_table_doc and "$AND_COLS" "$AND_V1" "$AND_V2"
  printf '\n'

  printf '## 三、明细\n\n### 崩溃 issue（按版本）\n\n'
  printf '> **本表已改为按「影响安装」排序**（原按事件数）：事件数相同的两个 issue 影响面可能差一个数量级，\n'
  printf '> 排在第一位的会被当成最该修的。集中度 = 事件 / 影响安装，高集中度往往是单设备或特定环境反复触发。\n\n'
  for v in $IOS_COLS; do printf '**iOS %s**\n\n' "$v"; issues_table ios "$v"; done
  for v in $AND_COLS; do printf '**Android %s**\n\n' "$v"; issues_table and "$v"; done
  printf '### 非致命异常（按版本）\n\n'
  printf '> 两端数量级**不可比**：非致命异常由客户端主动上报（`recordError` / `recordException`），\n'
  printf '> 覆盖多少取决于埋了多少收口点，不代表哪一端更稳。\n'
  printf '> iOS 的「位置」列恒为 Crashlytics SDK 包装帧，判读请看「异常」列。\n\n'
  for v in $IOS_COLS; do printf '**iOS %s**\n\n' "$v"; nonfatal_table ios "$v"; done
  for v in $AND_COLS; do printf '**Android %s**\n\n' "$v"; nonfatal_table and "$v"; done
  printf '### 性能（按版本）\n\n'
  for pv in $(printf 'ios %s\n' $IOS_COLS | tr ' ' ':') $(printf 'and %s\n' $AND_COLS | tr ' ' ':'); do
    p="${pv%%:*}"; v="${pv##*:}"
    [ "$p" = ios ] && pn="iOS" || pn="Android"
    # 停更时三张表全空，逐张打「（无数据）」会被读成「这版没样本」。直接说清是数据源断更。
    if [ -n "$(perf_stale_of "$p")" ]; then
      printf '**%s %s** · ⚠️ 数据未同步：性能表已停更 %s 天（截至 %s）\n\n' \
        "$pn" "$v" "$(perf_stale_of "$p")" "$(perf_max_of "$p")"
      continue
    fi
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
    rows="$(bqq csv "$(q_render sessions-by-version.sql TABLE="$tbl" DAYS="$DAYS")" \
      | tail -n +2)" || true
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
  printf -- '- **崩溃率**：事件数 / 会话数；分母为 0 显示「无法计算」。与 Crash-free 互补——前者答「崩溃有多频繁」，后者答「多少会话是干净的」。\n'
  printf -- '- **Crash-free 会话率**：1 − 崩溃会话数 / 会话数，只计致命崩溃（ANR 与非致命各有自己的行）。同一会话崩多次只计一次。\n'
  printf -- '  - ⚠️ **会话**口径，与 Firebase 控制台首屏、应用商店的**用户**口径**不同，不可直接对照**（用户率通常更低——一个用户在任一会话崩过就算）。\n'
  printf -- '  - ⚠️ 用户口径**当前不可得**：两个数据源的用户标识不同源（`installation_uuid` 64 字符十六进制 vs `instance_id` 22 字符 base64url，实测关联 0 行）。\n'
  printf -- '  - ⚠️ 本值为**下界估计**：分子分母取自两张表，未出现在会话表里的崩溃会话仍计入分子，故真实值**不低于**所示数字。\n'
  printf -- '- **慢帧 / 冻结**：帧级占比（单帧 >16ms / >700ms），「最差页」为该窗口内慢帧率最高的页面。\n'
  printf -- '- **数据缺失三态**：`表未同步`（表不存在）/ `数据未同步`（表整体无数据）/ `该版本无数据`（表有数据但该版本 0 行，新版在滞后的性能表里属常态）。\n'
  printf -- '- **环比**：卡片「对比」列 = 最新版 − 上一版；本节 DoD/WoW = 同版本天级单日值。两者口径不同，不可混读。\n'
  printf -- '- **ANR**：仅 Android（iOS 系统层无此概念，数据源不产出该 `error_type`；iOS 的卡顿信号见冻结率与慢帧）。ANR 率 = ANR 事件数 / 会话数，与崩溃率同分母、内部可比；**与 Google Play 的「用户感知 ANR 率」（日活用户分母）口径不同，不可直接对照商店门槛判定是否达标**。\n'
  printf -- '- **NON_FATAL**：双端数字**不可比**——非致命异常由客户端主动上报（`recordError` / `recordException`），覆盖多少取决于埋了多少收口点，不代表哪一端更稳。\n'
  printf -- '- **error_type 三类**：`is_fatal = TRUE` 等价于 `error_type = FATAL`；ANR 与 NON_FATAL 的 `is_fatal` 均为 FALSE，故崩溃次数 / 崩溃率 / 受影响安装三项**不含**这两类，各自单独成行。\n'
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
  audit run.end "" '{"ok":true,"dry_run":true}'
  RUN_COMPLETED=1; exit 0   # 合法提前退出，必须置哨兵
fi

# ── 索引页：跟踪表随每日数据变化，整份重建而非局部改块（局部改易错且难回滚）──
# 日报 URL 由 agent 建完文档后回填（__DAILY_URL__ 占位符）；台账入口是固定 URL 直链（${LEDGER_URL}），
# 周报归档 URL 来自 $STATE/ledger/weekly-index.jsonl（L2 每次追加一行，本页倒序渲染）。
build_index() {
  # 索引页渲染中间产物落跑批目录（不落 $STATE 顶层）：manifest 把这个路径交给 deliver.sh，
  # 而 $STATE/publish 下次跑批即被 rm -rf，runs/<日期>/ 留 30 天——补投时文件还在。
  local f="$TMP/index-render.md"
  # 报告归档：日报与周报统一记在一份 JSONL 里（{type,day,url,...}），由 deliver.sh 在文档建成后追加。
  # 不可再生（存的是飞书文档 URL，飞书端无法枚举本 bot 文档），所以放仓库里由 git 兜底。
  # ARCHIVE_LEGACY 是改成统一格式前的周报归档，读时合并进来，避免历史断链
  # （2.8 起本地源移入 $STATE/ledger/，与 LEDGER.md 同批迁移，仓库内不再保留）。
  local ARCH="$ARCHIVE_FILE" LEGACY="$STATE/ledger/weekly-index.jsonl"
  local ALL="$TMP/archive-merged.jsonl"
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
    printf '> 崩溃处置结论沉淀在台账（见下方文档入口），台账由 L2 周报独占产出，本页不再同步镜像。\n'
    printf '> 最后更新：%s · 日报口径：最新 %s 个版本（iOS %s · Android %s）\n' "$DAY" "$VERSION_COUNT" "$IOS_VER_SUM" "$AND_VER_SUM"
    printf '> iOS %s · Android %s\n\n' "$IOS_TOP_NOTE" "$AND_TOP_NOTE"
    printf '## 📍 文档入口\n\n| 文档 | 说明 | 维护 |\n|---|---|---|\n'
    printf '| 📄 [崩溃 & 性能日报（今日）](__DAILY_URL__) | 每日数据快照（最新 %s 版：崩溃/性能/放量） | 自动（L1） |\n' "$VERSION_COUNT"
    if [ -n "$LATEST_WEEKLY_URL" ]; then
      printf '| 📊 [崩溃周报（%s）](%s) | 每周变化播报 + 主力版本放量 | 自动（L2） |\n' "$LATEST_WEEKLY_DAY" "$LATEST_WEEKLY_URL"
    else
      printf '| 📊 崩溃周报 | 每周变化播报（暂无，L2 首跑后出现） | 自动（L2） |\n'
    fi
    printf '| 📒 [崩溃专项台账 LEDGER](%s) | 处置结论、风险分级、变更时间线 | 自动（L2 独占产出） |\n\n' "$LEDGER_URL"
    printf '## 🧭 导航\n\n'
    printf '本页所在父目录下有 `L1 日报` / `L2 周报` 两个子目录：按日期查找某天的历史报告去对应子目录翻，\n'
    printf '本页与台账固定在父目录根部（原地覆盖，链接永久不变）。\n\n'
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
        'map(select(.type=="daily")) | reverse | .[:$k] | .[] | "| \(.day)\(if .at then " " + .at else "" end) | [打开](\(.url)) | \(.versions // "—") |"' "$ALL"
    else
      printf '（暂无归档，本轮投递后出现）\n'
    fi
    printf '\n### 周报\n\n'
    if [ -s "$ALL" ] && [ "$(jq -rs 'map(select(.type=="weekly")) | length' "$ALL" 2>/dev/null)" != "0" ]; then
      # 列名不写「OPEN」：数据源 2026-08-20 起是 BigQuery 事件级，含已关闭 issue。
      printf '| 日期 | 报告 | iOS issue | Android issue |\n|---|---|---|---|\n'
      jq -rs 'map(select(.type=="weekly")) | reverse | .[] | "| \(.day)\(if .at then " " + .at else "" end) | [打开](\(.url)) | \(.ios // "—") | \(.android // "—") |"' "$ALL"
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
    printf '<title>崩溃 &amp; 性能日报 · %s %s</title>\n' "$DAY" "$TS_HM"
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
    printf '  <p><span text-color="gray">run %s · 审计 audit/daily-%s.events.jsonl</span></p>\n' "$RUN_ID" "$RUN_ID"
    printf '</callout>\n'

    printf '<h1>一、汇总</h1>\n'
    printf '%s' "$(verdict_line ios "iOS" "$IOS_V1" "$IOS_V2"; verdict_line and "Android" "$AND_V1" "$AND_V2")" \
      | sed 's/^- //' | while IFS= read -r line; do
        [ -n "$line" ] || continue
        printf '<p>%s</p>\n' "$(printf '%s' "$line" | xesc | sed -e 's/⚠️ 变差/<span text-color="red">⚠️ 变差<\/span>/' -e 's/✅ 变好/<span text-color="green">✅ 变好<\/span>/')"
      done

    printf '<h2>影响多少人</h2>\n'
    sum_impact_rows | awk -F, '{printf "\"%s\",\"%s\",\"%s\",\"%s\",\"%s\",\"%s\"\n",$1,$2,$3,$4,$5,$6}' > "$TMP/sum-impact.csv"
    xml_csv_table "$TMP/sum-impact.csv" '平台,版本,受影响安装,受影响用户,崩溃事件,集中度' '1,2,3,4,5,6'
    printf '<callout background-color="light-blue"><p>集中度 = 事件 / 受影响安装。9 次崩溃影响 1 台设备（9.0）与 14 次影响 7 台（2.0）严重度完全不同，而只看事件数两者长得一样。</p></callout>\n'

    printf '<h2>集中在哪</h2>\n'
    printf '<callout background-color="light-yellow"><p><b>本节口径 = FATAL + ANR</b>（影响面需覆盖卡死，ANR 事件量与崩溃持平）——与「影响多少人」表（仅 FATAL）<b>不可直接相加对照</b>。<b>机型只给绝对数</b>：Android 机型碎片化，单机型会话量太小（实测最大桶 75 会话），率不可靠——<b>未除以装机量，不代表该机型更易崩</b>。系统版本维度桶足够大，给崩溃率。维度分布只显示相关性，<b>不是根因</b>。</p></callout>\n'
    printf '<h3>机型</h3>\n'
    xml_csv_table "$TMP/sum-dim-model.csv" '平台,版本,机型,事件,影响安装,集中度' '1,2,3,4,5,6'
    printf '<h3>系统版本</h3>\n'
    xml_csv_table "$TMP/sum-dim-os.csv" '平台,版本,系统版本,事件,影响安装,集中度,崩溃率' '1,2,3,4,5,6,7'
    printf '<h3>页面（崩溃发生时所在页面）</h3>\n'
    printf '<callout background-color="light-yellow"><p>⛔ <b>本维度只给绝对数，不给崩溃率</b>——<code>firebase_sessions</code> 表无页面字段，页面级会话分母<b>不存在</b>（不是暂时没做）。事件多的页面通常只是访问量大的页面。⚠️ 口径按端不同：<b>Android = FATAL + ANR，iOS = NON_FATAL</b>（iOS 近 60 天仅 5 次致命崩溃，按致命口径此表只有一行）——<b>两端此表不可并读为同一指标</b>。⚠️ <code>(未知)</code> 是取不到页面的事件，照常参与排序不予丢弃。⚠️ iOS 侧存在 UIKit 内部窗口（如 <code>UITrackingElementWindowController</code>），<b>不是业务页面</b>。</p></callout>\n'
    xml_csv_table "$TMP/sum-dim-screen.csv" '平台,版本,页面,事件,影响安装,集中度' '1,2,3,4,5,6'
    printf '<h3>归因（责任帧属于谁）</h3>\n'
    printf '<callout background-color="light-yellow"><p>⛔ 归因方标识的是崩溃栈中<b>被判定为责任帧的那一帧属于谁</b>，<b>不是「谁触发了这次崩溃」</b>。归因方是「系统」或「三方」<b>不等于非自家问题</b>——实测存在「系统帧 + 自家包名」的组合，那是系统帧被自家代码调用。归因方与代码库必须一起读。</p></callout>\n'
    xml_csv_table "$TMP/sum-blame.csv" '平台,版本,归因方,代码库,事件,影响安装' '1,2,3,4,5,6'

    printf '<h2>什么时候</h2>\n'
    for pp in "ios:iOS:$IOS_NEWEST" "and:Android:$AND_NEWEST"; do
      pk="${pp%%:*}"; rest="${pp#*:}"; pn="${rest%%:*}"; vers="${rest#*:}"
      for v in $vers; do
        peak="$(hours_peak "$pk" "$v")"; clu="$(hours_cluster "$pk" "$v")"
        [ -n "$peak" ] || continue
        printf '<p><b>%s %s</b> 峰值时段（+08）：%s</p>\n' "$pn" "$v" "$(printf '%s' "$peak" | xesc)"
        [ -n "$clu" ] && printf '<callout background-color="light-red"><p>%s</p></callout>\n' "$(printf '%s' "$clu" | xesc)"
      done
      plat_has_events "$pk" || printf '<p><b>%s</b>：窗口内无事件</p>\n' "$(printf '%s' "$pn" | xesc)"
    done
    printf '<p><span text-color="gray">峰值是常态分布的描述（作息高峰），聚集才是异常信号。两者分开呈现——合并会让常态被读成事故。</span></p>\n'

    printf '<h1>二、版本对照</h1>\n'
    printf '<h2>iOS · %s</h2>\n' "$(printf '%s' "$IOS_VER_SUM" | xesc)"
    xml_table ios "$IOS_COLS" "$IOS_V1" "$IOS_V2"
    printf '<h2>Android · %s</h2>\n' "$(printf '%s' "$AND_VER_SUM" | xesc)"
    xml_table and "$AND_COLS" "$AND_V1" "$AND_V2"

    printf '<h1>三、明细</h1>\n<h2>崩溃 issue（按版本）</h2>\n'
    printf '<callout background-color="light-blue"><p><b>本表已改为按「影响安装」排序</b>（原按事件数）：事件数相同的两个 issue 影响面可能差一个数量级，排在第一位的会被当成最该修的。集中度 = 事件 / 影响安装，高集中度往往是单设备或特定环境反复触发。</p></callout>\n'
    for v in $IOS_COLS; do printf '<h3>iOS %s</h3>\n' "$v"; xml_issues ios "$v"; done
    for v in $AND_COLS; do printf '<h3>Android %s</h3>\n' "$v"; xml_issues and "$v"; done
    printf '<h2>非致命异常（按版本）</h2>\n'
    printf '<callout background-color="light-yellow"><p>两端数量级<b>不可比</b>：非致命异常由客户端主动上报，覆盖多少取决于埋了多少收口点，不代表哪一端更稳。iOS 的「位置」列恒为 Crashlytics SDK 包装帧，判读请看「异常」列。</p></callout>\n'
    for v in $IOS_COLS; do printf '<h3>iOS %s</h3>\n' "$v"; xml_nonfatal ios "$v"; done
    for v in $AND_COLS; do printf '<h3>Android %s</h3>\n' "$v"; xml_nonfatal and "$v"; done
    printf '<h2>性能（按版本）</h2>\n'
    for pv in $(printf 'ios %s\n' $IOS_COLS | tr ' ' ':') $(printf 'and %s\n' $AND_COLS | tr ' ' ':'); do
      p="${pv%%:*}"; v="${pv##*:}"
      [ "$p" = ios ] && pn="iOS" || pn="Android"
      printf '<h3>%s %s</h3>\n' "$pn" "$v"
      if [ -n "$(perf_stale_of "$p")" ]; then
        printf '<p><span text-color="orange">⚠️ 数据未同步：性能表已停更 %s 天（截至 %s）</span></p>\n' \
          "$(perf_stale_of "$p")" "$(perf_max_of "$p")"
        continue
      fi
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
    printf '  <p>崩溃：BigQuery firebase_crashlytics 事件级（含已关闭 issue）。崩溃率 = 事件数 / 会话数；分母为 0 显示「无法计算」。</p>\n'
    printf '  <p>Crash-free 会话率 = 1 − 崩溃会话数 / 会话数，只计致命崩溃。<b>会话口径，与控制台首屏的用户口径不同、不可直接对照</b>（用户口径不可得：两个数据源的用户标识不同源）。本值为<b>下界估计</b>，真实值不低于所示数字。</p>\n'
    printf '  <p>慢帧 / 冻结：帧级占比（单帧 &gt;16ms / &gt;700ms），「最差页」为窗口内慢帧率最高的页面。</p>\n'
    printf '  <p>缺数三态：表未同步（表不存在）/ 数据未同步（表整体无数据）/ 该版本无数据（表有数据但该版本 0 行，新版在滞后的性能表里属常态）。</p>\n'
    printf '  <p>环比：卡片「对比」列 = 最新版 − 上一版；本节 DoD/WoW = 同版本天级单日值。两者口径不同，不可混读。</p>\n'
    printf '  <p>数据截止：性能 %s · 放量 %s · 崩溃 %s</p>\n' "$DATA_UNTIL" "$ADOPTION_UNTIL" "$CRASH_UNTIL"
    printf '</callout>\n'
    printf '<p><span text-color="gray">本报告自动生成，不含根因与修复方案。需要定位请跑 firebase-crash-triage。</span></p>\n'
  } > "$REPORT_XML"
}

step "产出投递清单"
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

# 台账已移交 L2 独占产出（change crash-ledger-l2-ownership D1），L1 不再渲染或投递台账镜像。
# 索引页台账入口是固定 URL 直链（${LEDGER_URL}，见脚本顶部），不依赖本次跑批产出任何台账文件。

# 投递：日报/索引页两份文档每次新建（docx.builtin.import），URL 由 agent 回填。
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
  --arg title "崩溃 & 性能日报 · $DAY $TS_HM" \
  --arg index "$INDEX_FILE" \
  --arg indexxml "$INDEX_XML" \
  --arg index_id "$DOC_INDEX_ID" \
  --arg arch "$ARCHIVE_FILE" \
  --arg vsum "iOS ${IOS_V1:-—} · Android ${AND_V1:-—}" \
  '{type:"daily", day:$day, run_id:$run, chat_id:$chat, message_file:$msg, card_file:$card,
    create_doc: {file:$report, xml_file:$reportxml, title:$title, label:"日报"},
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
# ⚠️ `window_mode` 标记本行的**性能字段**取自哪套窗口口径（change crash-data-completeness，design D8）：
#   legacy       —— 旧口径。perf_day 取「该版本自己的最新可用单日」，⚠️ 那一天**可能是 7 小时的残日**
#   complete_day —— 新口径。perf_day 恒为 LCD，两端都是完整天
# ⛔ **不回填、不重算历史**：原始数据还在 BigQuery，但重跑多天 × 双端 × 多版本成本高，
#    且旧报告已经发出去了，改历史会让报告与历史对不上。缺这个字段的旧行一律按 legacy 读。
# ⚠️ 崩溃/放量字段口径未变，本标记只约束性能那几项——跨口径比较由渲染层标注（5.3）。
HISTORY_LINE="$(jq -cn --arg day "$DAY" --arg wm "$HISTORY_WINDOW_MODE" \
  --argjson vers "$(jq -cn --argjson i "$(printf '%s' "$IOS_NEWEST" | jq -Rsc 'split("\n")|map(select(length>0))')" \
                           --argjson a "$(printf '%s' "$AND_NEWEST" | jq -Rsc 'split("\n")|map(select(length>0))')" '{ios:$i,android:$a}')" \
  --argjson io "$(plat_hist_obj ios "$IOS_NEWEST")" \
  --argjson ao "$(plat_hist_obj and "$AND_NEWEST")" \
  '{day:$day, window_mode:$wm, versions:$vers, ios:$io, android:$ao}')"
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
  --argjson prev "$SEEN_JSON" \
  --argjson cur "$(printf '%s' "$CUR_IDS" | jq -Rsc 'split("\n")|map(select(length>0))')" \
  --arg cut "$(day_ago "$HISTORY_KEEP")" \
  '{day:$day, versions:$vers,
    ios_ids:[($c[0].ios // [])[].id], android_ids:[($c[0].android // [])[].id],
    issue_seen: (
      ($prev | with_entries(select(.value >= $cut)))     # 超期清理：末次出现早于保留期起点即丢弃
      + ($cur | map({key:., value:$day}) | from_entries) # 本轮出现的刷成今天
    )}' \
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

# latest 软链指向本次跑批产物，供 2.4/2.5 回归对比与人工排查使用（ln -sfn 覆盖式，指向相对路径避免机器间路径漂移）
ln -sfn "$TS" "$STATE/runs/$DAY/L1/latest"

# 中间产物保留 30 天（每个卡片数字最直接的审计物证），按 $STATE/runs/<日期>/ 整目录清理（design D7）
cleanup_old_runs "$STATE"
# 日志按文件名前缀分别删，正是漏网的成因：bq-stderr-*.log 既不叫 daily-* 也不叫 weekly-*，
# 从 L1/L2 两张网中间漏过去，永不清理（2026-08-20 盘出 20 个陈年文件）。改成整目录按 mtime 清。
find "$STATE/logs" -type f -mtime +60 -delete 2>/dev/null || true
# 审计事件流 60 天（design D9），与 logs 同步清理
find "$STATE/audit" -type f -mtime +60 -delete 2>/dev/null || true
# 日报/周报 markdown 本地副本与文档台账同寿（deliver.sh 的 DOC_KEEP_DAYS 默认 90 天）
find "$STATE/reports" -type f -name '*.md' -mtime +90 -delete 2>/dev/null || true
# 被 kill 的跑批留下的 SQL 临时文件：上方 bq_init 后挂的 EXIT trap 对 SIGKILL / cron 超时杀进程不生效
find "$STATE" -maxdepth 1 -type f -name '.bq-sql-*.sql' -mtime +1 -delete 2>/dev/null || true
audit run.end "" '{"ok":true}'
echo "=== 完成 ==="
RUN_COMPLETED=1
