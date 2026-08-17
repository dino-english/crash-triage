#!/usr/bin/env bash
# L1 每日数据日报：BigQuery 性能 + BigQuery 崩溃 → 飞书文档 + 群卡片。
#
# 数据源现状（2026-08-14）：
#   性能   → BigQuery firebase_performance   ✅ 已就绪
#   崩溃   → BigQuery firebase_crashlytics   ✅ 事件级（REALTIME 表，见下）
#   崩溃率 → firebase_crashlytics / firebase_sessions ✅ 事件数/会话数（非 crash-free）
#
# ⚠️ 崩溃改走 BigQuery 事件级统计后，不再受 issue 开关状态影响（closed 的 issue 只要有事件仍计入）。
#    firebase_crashlytics 目前只有 REALTIME 表且行数少（可能仍在回填），卡片须如实标注截止时间戳。
#    MCP topIssues 抓取已降级为「对照/回退」分支（fetch-snapshot.sh light 模式），首验期同跑两套数值
#    人工核对，确认一致后移除 MCP 抓取（见 change crash-source-bigquery-migration 的 D4）。
set -euo pipefail

# Hermes cron 继承 PYTHONPATH=<hermes-agent>，会让 bq 的 `from utils import bq_error`
# 误抓 hermes-agent/utils.py 而崩（2026-08-14 实测）。bq/jq/git/claude 均不需要 PYTHONPATH，先清掉。
unset PYTHONPATH

export CRASH_REPORT_ROOT="${CRASH_REPORT_ROOT:-$HOME/crash-triage}"
ROOT="$CRASH_REPORT_ROOT"
# 本机统一：repos 指向 gitWorkspace（可用 REPOS_ROOT 覆盖；默认 $ROOT/repos 兼容隔离部署）
REPOS_ROOT="${REPOS_ROOT:-$ROOT/repos}"

if [ -f "$ROOT/bin/config.env" ]; then
  # shellcheck disable=SC1091
  . "$ROOT/bin/config.env"
else
  PATH="/opt/homebrew/bin:/opt/homebrew/share/google-cloud-sdk/bin:/usr/local/bin:$HOME/.npm-global/bin:/usr/bin:/bin:/usr/sbin:/sbin"
fi
export PATH

TS="$(date +%Y%m%d-%H%M%S)"
DAY="$(date +%Y-%m-%d)"
LOG="$ROOT/logs/daily-$TS.log"
RUN_ID="$TS"
AUDIT_DIR="$ROOT/state/audit"
AUDIT_FILE="$AUDIT_DIR/$RUN_ID.events.jsonl"
SEQ=0
SQL_DIR="${SQL_DIR:-$ROOT/bin/sql}"
PROJECT="dino-english-497507"

CHAT_ID="${CRASH_REPORT_CHAT_ID:?未设置 CRASH_REPORT_CHAT_ID}"
DOC_DAILY_ID="${DOC_DAILY_ID:-}"        # 日报文档；固定一份每天 overwrite
DOC_INDEX_ID="${DOC_INDEX_ID:-}"        # 索引页
DOC_LEDGER_ID="${DOC_LEDGER_ID:-}"      # 台账镜像
LEDGER_SRC="${LEDGER_SRC:-$ROOT/reports/LEDGER.md}"
DRY_RUN="${CRASH_REPORT_DRY_RUN:-0}"
DAYS="${CRASH_REPORT_DAYS:-1}"
# 性能窗口（D3）：firebase_performance 每日批量同步滞后约 2 天，DAYS=1 在每天 07:00 跑必然空表，
# 故独立放宽到 3 天；版本放量保持 DAYS（sessions REALTIME 为实时活源）。
PERF_DAYS="${CRASH_REPORT_PERF_DAYS:-3}"

# ── 阈值红绿灯（R3 / D5）：脚本顶部集中可配常量 ────────────────────────
# 红档 = 已拍板；黄/绿 = explore 建议值落地，全部显式标注「待对齐」。
# 判定统一走 traffic_light()（>红=🔴；>黄=🟡；否则🟢），命中红档才出告警，黄档仅注释待对齐。
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
SAMPLE_SESSION_MIN=30     # 小样本会话数阈值：平台当日会话数 < 30 追加「⚠️ 样本量小，仅供参考」

mkdir -p "$ROOT"/{logs,reports,state}
exec > >(tee -a "$LOG") 2>&1
echo "=== 崩溃 & 性能日报 $TS ==="

fail() { echo "❌ $*"; jq -n --arg t "$TS" --arg e "$*" '{last_run:$t,ok:false,error:$e}' > "$ROOT/state/health-daily.json"; exit 1; }

# ── 探活 ──────────────────────────────────────────────
# 飞书投递已改由 Hermes agent 经 lark-mcp 完成（脚本只产出内容、不再直连飞书），此处只探数据源。
bq query --use_legacy_sql=false --format=csv 'SELECT 1' >/dev/null 2>&1 \
  || fail "bq 不可用，检查 gcloud auth 与项目设置"

# ── 性能查询 ──────────────────────────────────────────
# 表可能尚未同步（Android 常滞后）；缺表时跳过该平台而非整体失败。
q() { # $1=sql文件 $2=表名 $3=窗口天数(默认 $DAYS)
  sed -e "s|{{TABLE}}|$2|g" -e "s|{{DAYS}}|${3:-$DAYS}|g" "$SQL_DIR/$1" \
    | bq query --use_legacy_sql=false --format=csv 2>/dev/null | tail -n +2
}
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
# 表最新 event_timestamp（分表截止时间戳用）：无数据/空表/空表名时输出空串，恒退出码 0。
table_max() { [ -n "$1" ] || { echo ""; return 0; }
  bq query --use_legacy_sql=false --format=csv \
    "SELECT FORMAT_TIMESTAMP('%Y-%m-%d %H:%M UTC', MAX(event_timestamp)) AS ts FROM \`$1\`" 2>/dev/null \
    | tail -n +2 | tail -1 || true; }

perf_section() { # $1=平台名 $2=表名
  local name="$1" tbl="$2" t s n max
  if ! table_exists "$tbl"; then
    printf '### %s\n\n> 性能表尚未同步，本次无数据。\n\n' "$name"; return
  fi
  printf '### %s\n\n' "$name"

  # 三个子查询先各自取数：任一非空即算有数据；只有三个都 0 行（整体 0 行）才判定「未同步」。
  t="$(q perf-traces.sql  "$tbl" "$PERF_DAYS")" || true
  s="$(q perf-screens.sql "$tbl" "$PERF_DAYS")" || true
  n="$(q perf-network.sql "$tbl" "$PERF_DAYS")" || true
  if [ -z "$t" ] && [ -z "$s" ] && [ -z "$n" ]; then
    max="$(table_max "$tbl")"; [ -n "$max" ] || max="—"
    printf '> ⚠️ 数据未同步，最新截至 %s\n\n' "$max"
    return
  fi

  printf '**启动与自定义 trace**\n\n| trace | 次数 | P50 | P95 |\n|---|---|---|---|\n'
  printf '%s\n' "$t" | awk -F, '{printf "| %s | %s | %s ms | %s ms |\n",$1,$2,$3,$4}'

  printf '\n**页面渲染（慢帧 >16ms · 冻结 >700ms）**\n\n| 页面 | 样本 | 慢帧率 | 冻结帧率 | P50 停留 |\n|---|---|---|---|---|\n'
  printf '%s\n' "$s" | awk -F, '{printf "| %s | %s | %s%% | %s%% | %s s |\n",$1,$2,$3,$4,$5}'

  printf '\n**自家 API 网络**\n\n| 接口 | 次数 | P50 | P95 | 错误率 |\n|---|---|---|---|---|\n'
  printf '%s\n' "$n" | awk -F, '{printf "| %s | %s | %s ms | %s ms | %s%% |\n",$1,$2,$3,$4,$6}'
  printf '\n'
}

echo "--- 查询性能数据 ---"
IOS_TBL="$PROJECT.firebase_performance.com_prime_dino_english_IOS"
AND_TBL="$PROJECT.firebase_performance.com_prime_dino_english_ANDROID"
PERF="$(perf_section "iOS" "$IOS_TBL"; perf_section "Android" "$AND_TBL")"

# ── 提取卡片用的关键指标（单独取，避免解析已格式化的 markdown）──
TMP="$ROOT/state/metrics-$TS"
mkdir -p "$TMP"
# 双端各取一份：Android 性能表 2026-08-10 到位，此前卡片只有 iOS 且标「（仅 iOS）」
extract() { # $1=文件后缀 $2=表名
  table_exists "$2" || return 0
  q perf-traces.sql  "$2" "$PERF_DAYS" | grep '^_app_start,' > "$TMP/start-$1.csv"  || true
  q perf-screens.sql "$2" "$PERF_DAYS" | head -1             > "$TMP/screen-$1.csv" || true
  q perf-network.sql "$2" "$PERF_DAYS"                       > "$TMP/net-$1.csv"    || true
}
extract ios "$IOS_TBL"
extract and "$AND_TBL"
csv() { [ -s "$1" ] && cut -d, -f"$2" "$1" | head -1 || echo ""; }
# BigQuery 的 ROUND 返回浮点（251.0 / 0.00），卡片上要读得快就得去掉无意义小数位
int()  { [ -n "$1" ] && printf '%.0f' "$1" || echo ""; }               # 251.0 → 251
pct()  { [ -n "$1" ] && awk -v v="$1" 'BEGIN{printf (v==int(v)?"%.0f":"%.1f"), v}' || echo "0"; }  # 0.00→0 · 73.5→73.5
ms2s() { # 1268.0 → 1.3s；小于 1 秒保留 ms，避免出现 0.1s 这种失真
  [ -n "$1" ] || { echo ""; return; }
  awk -v v="$1" 'BEGIN{ if(v>=1000) printf "%.1fs", v/1000; else printf "%.0fms", v }'
}

# ── 天级单日值 / 环比 / 阈值红绿灯 助手 ─────────────────────────────
day_ago() { date -v-"${1:-0}"d +%Y-%m-%d 2>/dev/null; }   # BSD date（macOS）：N 天前日期

# 统一阈值红绿灯（R3）：>红 → red（🔴）；>黄 → yellow（🟡，待对齐）；否则 green（🟢）。
# 空值 / 「无法计算」→ 空串（不判定，避免误告警）。
traffic_light() {
  local v="$1" red="$2" yellow="$3"
  [ -n "$v" ] && [ "$v" != "无法计算" ] || { echo ""; return; }
  awk -v v="$v" -v r="$red" -v y="$yellow" 'BEGIN{ if(v>r) print "red"; else if(v>y) print "yellow"; else print "green" }'
}
# 红档告警行：任一端命中红档则输出一行（否则空）。$1=指标名 $2=iOS值 $3=Android值 $4=红 $5=黄 $6=单位后缀
red_line() {
  local li la d2 d3
  li="$(traffic_light "$2" "$4" "$5")"; la="$(traffic_light "$3" "$4" "$5")"
  if [ "$li" = "red" ] || [ "$la" = "red" ]; then
    d2="$2"; d3="$3"
    { [ -z "$d2" ] || [ "$d2" = "无法计算" ]; } && d2="—"
    { [ -z "$d3" ] || [ "$d3" = "无法计算" ]; } && d3="—"
    printf '🔴 %s iOS %s%s · Android %s%s' "$1" "$d2" "$6" "$d3" "$6"
  fi
}
# 黄档摘要行（R5/D6）：任一端命中黄档且两端均未命中红档时输出一行（红档已进 red_line，避免重复）。
# $1=指标名 $2=iOS值 $3=Android值 $4=红 $5=黄 $6=单位后缀
yellow_line() {
  local li la d2 d3
  li="$(traffic_light "$2" "$4" "$5")"; la="$(traffic_light "$3" "$4" "$5")"
  { [ "$li" = "red" ] || [ "$la" = "red" ]; } && return 0
  if [ "$li" = "yellow" ] || [ "$la" = "yellow" ]; then
    d2="$2"; d3="$3"
    { [ -z "$d2" ] || [ "$d2" = "无法计算" ]; } && d2="—"
    { [ -z "$d3" ] || [ "$d3" = "无法计算" ]; } && d3="—"
    printf '🟡 %s iOS %s%s · Android %s%s' "$1" "$d2" "$6" "$d3" "$6"
  fi
}
# 非空才追加（避免空行），ALERTS 用换行拼接；恒返回 0（否则 set -e 在空输入时误炸）
add_alert() { [ -n "$1" ] && ALERTS="${ALERTS:+$ALERTS
}$1"; return 0; }

# 天级单日值查询：返回单行 JSON 对象（无数据 → {}）
q1d() { sed -e "s|{{TABLE}}|$2|g" -e "s|{{DAYS}}|$3|g" "$SQL_DIR/$1" \
  | bq query --use_legacy_sql=false --format=json 2>/dev/null | jq -c '.[0] // {}' 2>/dev/null || echo '{}'; }
# 从 JSON 对象取字段（缺失 → 空）
m1() { printf '%s' "${1:-}" | jq -r --arg k "$2" '.[$k] // empty' 2>/dev/null || echo ""; }
# 性能表「最新可用单日」距今天数（1=昨日）；无数据 → 空
perf_day_offset() { [ -n "$1" ] || { echo ""; return; }
  bq query --use_legacy_sql=false --format=csv \
    "SELECT DATE_DIFF(CURRENT_DATE(), MAX(DATE(event_timestamp)), DAY) AS off FROM \`$1\`" 2>/dev/null \
    | tail -n +2 | tail -1 || true; }
# 天级崩溃率（%）＝分子/分母×100；分母 0/空 → 空（不硬算）
daily_rate() { [ -n "$1" ] && [ -n "$2" ] && [ "$2" != "0" ] \
  && awk -v e="$1" -v s="$2" 'BEGIN{printf "%.2f", e/s*100}' || echo ""; }

# 环比 DoD/WoW（R1 / D6）：百分比指标 pp、耗时 ms；箭头「数值变大 = 变差 = ↑」（与现有 arrow() 约定一致）。
# 无基准（昨日/D-7 缺失）→ 该档「无基准」；两端都无基准 → 整段省略（首日口径，不硬算）。
# 零差值不写正号（0ms/0.00pp，NIT）。$5=DoD 对比日期标注（可空，性能滞后场景标注实际日期）。
_dod_wow() { # $1=今日值 $2=昨日值 $3=D-7值 $4=单位(pp|ms) $5=DoD对比日期标注(可空)
  local d="" w="" lbl="${5:-}"
  [ -n "$1" ] || { echo ""; return; }   # 今日值缺失（数据不可得）→ 整段省略
  if [ -n "$2" ]; then
    d="DoD $(awk -v c="$1" -v o="$2" -v m="$4" 'BEGIN{d=c-o; a=(d>0)?"↑":(d<0)?"↓":""; s=(a=="")?"":" "; sign=(d>0)?"+":""; if(m=="ms") printf "%s%dms%s%s", sign, d, s, a; else printf "%s%.2fpp%s%s", sign, d, s, a}')${lbl}"
  else d="DoD 无基准"; fi
  if [ -n "$3" ]; then
    w="WoW $(awk -v c="$1" -v o="$3" -v m="$4" 'BEGIN{d=c-o; a=(d>0)?"↑":(d<0)?"↓":""; s=(a=="")?"":" "; sign=(d>0)?"+":""; if(m=="ms") printf "%s%dms%s%s", sign, d, s, a; else printf "%s%.2fpp%s%s", sign, d, s, a}')"
  else w="WoW 无基准"; fi
  if [ -z "$2" ] && [ -z "$3" ]; then echo ""; else printf '%s · %s' "$d" "$w"; fi
}
dod_wow_pct() { _dod_wow "$1" "$2" "$3" pp "${4:-}"; }
dod_wow_ms()  { _dod_wow "$1" "$2" "$3" ms "${4:-}"; }

# 7 日 sparkline（R6）：崩溃率/接口错误率/启动 P95 的 Unicode 方块迷你图。
# 输入：换行分隔数值序列（旧→新）。min-max 归一化映射 ▁▂▃▄▅▆▇█（全相等渲染平线 ▄）。
# 冷启动历史不足 7 天按已有天数渲染，不空值补齐（awk 算档位，bash 映射字符，避免 awk 多字节 substr 问题）。
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

IOS_START_P50="$(int "$(csv "$TMP/start-ios.csv" 3)")"
IOS_START_P95="$(int "$(csv "$TMP/start-ios.csv" 4)")"
AND_START_P50="$(int "$(csv "$TMP/start-and.csv" 3)")"
AND_START_P95="$(int "$(csv "$TMP/start-and.csv" 4)")"
IOS_WORST_SCREEN="$(csv "$TMP/screen-ios.csv" 1)"
IOS_WORST_SLOW="$(pct "$(csv "$TMP/screen-ios.csv" 3)")"
AND_WORST_SCREEN="$(csv "$TMP/screen-and.csv" 1)"
AND_WORST_SLOW="$(pct "$(csv "$TMP/screen-and.csv" 3)")"
# 冻结帧（单帧 >700ms）是用户直接可感知的卡死，比慢帧率更该顶到卡片上
IOS_FROZEN="$(pct "$(csv "$TMP/screen-ios.csv" 4)")"
AND_FROZEN="$(pct "$(csv "$TMP/screen-and.csv" 4)")"
neterr() { [ -s "$1" ] && awk -F, '{e+=$5; n+=$2} END{if(n>0) printf "%.2f", e/n*100; else print "0"}' "$1" || echo "0"; }
IOS_NET_ERR="$(pct "$(neterr "$TMP/net-ios.csv")")"
AND_NET_ERR="$(pct "$(neterr "$TMP/net-and.csv")")"
# 快照与趋势仍以 iOS 启动耗时为基准（双端趋势暂不做，避免快照结构大改）
START_P50="$IOS_START_P50"

# ── 版本放量（修复验证的分母）──────────────────────
# 数据源优先 REALTIME 活表（批量表 2026-08-11 起停更，REALTIME 才是活源，schema 一致）；缺失回退批量表并标注（D1）。
SESS_IOS_RT="$PROJECT.firebase_sessions.com_prime_dino_english_IOS_REALTIME"
SESS_IOS_BATCH="$PROJECT.firebase_sessions.com_prime_dino_english_IOS"
SESS_AND_RT="$PROJECT.firebase_sessions.com_prime_dino_english_ANDROID_REALTIME"
SESS_AND_BATCH="$PROJECT.firebase_sessions.com_prime_dino_english_ANDROID"

SESS_IOS_FALLBACK=0
if table_exists "$SESS_IOS_RT"; then SESS_IOS="$SESS_IOS_RT";
elif table_exists "$SESS_IOS_BATCH"; then SESS_IOS="$SESS_IOS_BATCH"; SESS_IOS_FALLBACK=1;
else SESS_IOS=""; fi
SESS_AND_FALLBACK=0
if table_exists "$SESS_AND_RT"; then SESS_AND="$SESS_AND_RT";
elif table_exists "$SESS_AND_BATCH"; then SESS_AND="$SESS_AND_BATCH"; SESS_AND_FALLBACK=1;
else SESS_AND=""; fi

adoption_section() { # $1=平台名 $2=sessions表(已解析) $3=是否回退批量表(0/1)
  local name="$1" tbl="$2" fallback="${3:-0}" rows max
  if [ -z "$tbl" ]; then printf '### %s\n\n> sessions 表尚未同步。\n\n' "$name"; return; fi
  printf '### %s\n\n' "$name"
  [ "$fallback" = 1 ] && printf '> ⚠️ REALTIME 表缺失，回退批量表（批量表可能停更）。\n\n'
  rows="$(sed -e "s|{{TABLE}}|$tbl|g" -e "s|{{DAYS}}|$DAYS|g" "$SQL_DIR/sessions-by-version.sql" \
    | bq query --use_legacy_sql=false --format=csv 2>/dev/null | tail -n +2)" || true
  if [ -z "$rows" ]; then
    max="$(table_max "$tbl")"; [ -n "$max" ] || max="—"
    printf '> ⚠️ 数据未同步，最新截至 %s\n\n' "$max"
    return
  fi
  printf '| 版本 | 会话 | 设备 | 最新数据 |\n|---|---|---|---|\n'
  printf '%s\n' "$rows" | awk -F, '{printf "| %s | %s | %s | %s |\n",$1,$2,$3,$4}'
  printf '\n'
}
echo "--- 查询版本放量 ---"
ADOPTION="$(adoption_section "iOS" "$SESS_IOS" "$SESS_IOS_FALLBACK"; adoption_section "Android" "$SESS_AND" "$SESS_AND_FALLBACK")"

# 卡片只出「最新版本」的放量——判断新版样本够不够下结论，是看日报时最常问的一句
topver() { # $1=sessions表(已解析) → "版本 会话 设备"（按会话数排第一的**非最高版本**无意义，故取版本号最大者）
  [ -n "$1" ] || return 0
  sed -e "s|{{TABLE}}|$1|g" -e "s|{{DAYS}}|$DAYS|g" "$SQL_DIR/sessions-by-version.sql" \
    | bq query --use_legacy_sql=false --format=csv 2>/dev/null | tail -n +2 \
    | sort -t, -k1,1 -V | tail -1
}
IOS_TOP="$(topver "$SESS_IOS")"
AND_TOP="$(topver "$SESS_AND")"
IOS_TOP_VER="$(printf '%s' "$IOS_TOP" | cut -d, -f1)"
IOS_TOP_SESS="$(printf '%s' "$IOS_TOP" | cut -d, -f2)"
AND_TOP_VER="$(printf '%s' "$AND_TOP" | cut -d, -f1)"
AND_TOP_SESS="$(printf '%s' "$AND_TOP" | cut -d, -f2)"

# 数据实际截止时间：各段按各自表分别取 MAX(event_timestamp)，不假设「截至昨天」（D4）。
# 性能/放量/崩溃三张表同步节奏不同（性能批量滞后 ~2 天、sessions REALTIME 实时、crashlytics REALTIME 实时），必须分列。
DATA_UNTIL="$(table_max "$PROJECT.firebase_performance.com_prime_dino_english_IOS")" || true
[ -n "$DATA_UNTIL" ] || DATA_UNTIL="—"
ADOPTION_UNTIL="$(printf '%s\n%s\n' "$(table_max "$SESS_IOS")" "$(table_max "$SESS_AND")" | grep -v '^$' | sort -r | head -1)" || true
[ -n "$ADOPTION_UNTIL" ] || ADOPTION_UNTIL="—"

# ── 崩溃统计（BigQuery 事件级，替代 MCP topIssues）──────
echo "--- 查询崩溃数据 ---"
CRASH_IOS_TBL="$PROJECT.firebase_crashlytics.com_prime_dino_english_IOS_REALTIME"
CRASH_AND_TBL="$PROJECT.firebase_crashlytics.com_prime_dino_english_ANDROID_REALTIME"
# 窗口与 MCP topIssues 的 Firebase 默认 7 天窗一致；日窗口太窄（iOS 样本极少）会误读为「无崩溃」。
CRASH_DAYS="${CRASH_REPORT_CRASH_DAYS:-7}"

# 崩溃查询：{{TABLE}}=crashlytics 表，{{SESSIONS_TABLE}}=sessions 表，{{DAYS}}=CRASH_DAYS。
# 用 --format=json + jq 渲染：issue 标题是自由文本可能含逗号，CSV+awk 会错列。
qc() { sed -e "s|{{TABLE}}|$1|g" -e "s|{{SESSIONS_TABLE}}|$2|g" -e "s|{{DAYS}}|$CRASH_DAYS|g" "$SQL_DIR/$3" \
        | bq query --use_legacy_sql=false --format=json 2>/dev/null; }

crash_section() { # $1=平台名 $2=crashlytics表 → 输出 issue 表 markdown
  local name="$1" tbl="$2" rows max
  if ! table_exists "$tbl"; then
    printf '### %s\n\n> 崩溃表尚未同步，本次无数据。\n\n' "$name"; return
  fi
  rows="$(qc "$tbl" "" crash-issues.sql)" || true
  if [ "$(printf '%s' "$rows" | jq 'length' 2>/dev/null)" = "0" ]; then
    max="$(table_max "$tbl")"; [ -n "$max" ] || max="—"
    printf '### %s\n\n> ⚠️ 数据未同步，最新截至 %s\n\n' "$name" "$max"
    return
  fi
  printf '### %s\n\n| Issue | 标题 | 事件 |\n|---|---|---|\n' "$name"
  printf '%s' "$rows" | jq -r '.[] | "| \(.issue_id[0:8]) | \(.title) | \(.n) |"'
  printf '\n'
}
# 指标单独取（不解析 markdown），写入 $TMP 供卡片/快照/口径标注用。函数保证退出码恒 0，避免 set -e 误炸。
crash_metrics() { # $1=后缀 $2=crashlytics表 → 写 $TMP/crash-$1.json（issue 聚合数组）
  if table_exists "$2" && qc "$2" "" crash-issues.sql > "$TMP/crash-$1.json"; then :; else echo '[]' > "$TMP/crash-$1.json"; fi
}
crash_rate() { # $1=后缀 $2=crashlytics表 $3=sessions表 → 写 $TMP/rate-$1.json（分子/分母）
  if table_exists "$2" && table_exists "$3" && qc "$2" "$3" crash-rate.sql > "$TMP/rate-$1.json"; then :; else echo '[]' > "$TMP/rate-$1.json"; fi
}

CRASH="$(crash_section "iOS" "$CRASH_IOS_TBL"; crash_section "Android" "$CRASH_AND_TBL")"
crash_metrics ios "$CRASH_IOS_TBL"
crash_metrics and "$CRASH_AND_TBL"
crash_rate ios "$CRASH_IOS_TBL" "$SESS_IOS"
crash_rate and "$CRASH_AND_TBL" "$SESS_AND"

# 崩溃指标提取：issue 数 / 事件总数 / 最新时间戳 / 崩溃率
cj() { jq -r "$2" "$TMP/crash-$1.json" 2>/dev/null || echo ""; }
IOS_N="$(cj ios 'length')"
IOS_EV="$(cj ios '[.[].n | tonumber] | add // 0')"
IOS_LATEST="$(cj ios '[.[].latest] | max // ""')"
AND_N="$(cj and 'length')"
AND_EV="$(cj and '[.[].n | tonumber] | add // 0')"
AND_LATEST="$(cj and '[.[].latest] | max // ""')"
rj() { jq -r "$2" "$TMP/rate-$1.json" 2>/dev/null || echo ""; }
IOS_CEV="$(rj ios '(.[0].crash_events // 0) | tonumber')"
IOS_SESS="$(rj ios '(.[0].sessions // 0) | tonumber')"
AND_CEV="$(rj and '(.[0].crash_events // 0) | tonumber')"
AND_SESS="$(rj and '(.[0].sessions // 0) | tonumber')"
# 受影响安装数（R2 / D3）：crashlytics is_fatal=TRUE 窗口内 COUNT(DISTINCT installation_uuid)，与分子同表同窗口
IOS_AFFECTED="$(rj ios '(.[0].affected_installs // 0) | tonumber')"
AND_AFFECTED="$(rj and '(.[0].affected_installs // 0) | tonumber')"
# 崩溃率 = 事件数 / 会话数（非 crash-free 精确口径）；分母为零显示「无法计算」以免误读为「无崩溃」
rate_str() { [ -n "$1" ] && [ -n "$2" ] && [ "$2" != "0" ] && printf '%s/%s' "$1" "$2" || printf '无法计算'; }
IOS_RATE="$(rate_str "$IOS_CEV" "$IOS_SESS")"
AND_RATE="$(rate_str "$AND_CEV" "$AND_SESS")"
# 崩溃率百分比（展示层换算，口径不变：事件数/会话数×100；分母 0/不可得沿用「无法计算」）
# 崩溃率天然是千分位量级，固定两位小数（2/1017→0.20、39/2500→1.56），与 pct() 的「整数去零」口径区分。
rate_pct() { [ -n "$1" ] && [ -n "$2" ] && [ "$2" != "0" ] \
  && awk -v e="$1" -v s="$2" 'BEGIN{printf "%.2f", e/s*100}' || printf '无法计算'; }
IOS_RATE_PCT="$(rate_pct "$IOS_CEV" "$IOS_SESS")"
AND_RATE_PCT="$(rate_pct "$AND_CEV" "$AND_SESS")"
# 崩溃率独立行文本：百分比 + 原始分数（如 0.20% (2/1017)）；无法计算时不带括号
rate_line() { [ "$1" = "无法计算" ] && printf '无法计算' || printf '%s%% (%s)' "$1" "$2"; }
IOS_RATE_LINE="$(rate_line "$IOS_RATE_PCT" "$IOS_RATE")"
AND_RATE_LINE="$(rate_line "$AND_RATE_PCT" "$AND_RATE")"
# 崩溃数据实际截止 = 双端致命事件最新时间戳的较晚者（事件级，非「截至昨天」假设）
CRASH_UNTIL="$(printf '%s\n%s\n' "$IOS_LATEST" "$AND_LATEST" | grep -v '^$' | sort -r | head -1)" || true
[ -n "$CRASH_UNTIL" ] || CRASH_UNTIL="—"

# ═══ 天级单日值 + 7 日滚动历史（DoD/WoW/sparkline 统一基准，R7 / D1 / D2）═══
# 口径（D2）：天级单日值（字段 _1d）按「日历日」锚定，与卡片/报告展示的「滚动窗口值」
# （crash-rate.sql 7 天窗、perf-*.sql 3 天窗）是两套口径，显式区分、不可混比。
#   - 崩溃/放量（REALTIME 活源）严格取「昨日」单日值（{{DAYS}}=1）；
#   - 性能（批量表滞后 ~2 天）取「最新可用单日」及其前一单日，记录实际日期 perf_day（D7）。
echo "--- 查询天级单日值 ---"
HISTORY="$ROOT/state/metrics-history.jsonl"
YESTERDAY="$(day_ago 1)"
D7="$(day_ago 7)"

IOS_CRASH_1D="$(q1d daily-crash-1d.sql "$CRASH_IOS_TBL" 1)"
AND_CRASH_1D="$(q1d daily-crash-1d.sql "$CRASH_AND_TBL" 1)"
IOS_SESS_1D_OBJ="$(q1d daily-sessions-1d.sql "$SESS_IOS" 1)"
AND_SESS_1D_OBJ="$(q1d daily-sessions-1d.sql "$SESS_AND" 1)"
IOS_PERF_OFF="$(perf_day_offset "$IOS_TBL")"; IOS_PERF_OFF="${IOS_PERF_OFF:-1}"
AND_PERF_OFF="$(perf_day_offset "$AND_TBL")"; AND_PERF_OFF="${AND_PERF_OFF:-1}"
IOS_PERF_1D="$(q1d daily-perf-1d.sql "$IOS_TBL" "$IOS_PERF_OFF")"
AND_PERF_1D="$(q1d daily-perf-1d.sql "$AND_TBL" "$AND_PERF_OFF")"
IOS_PERF_1D_PREV="$(q1d daily-perf-1d.sql "$IOS_TBL" "$((IOS_PERF_OFF + 1))")"
AND_PERF_1D_PREV="$(q1d daily-perf-1d.sql "$AND_TBL" "$((AND_PERF_OFF + 1))")"
IOS_PERF_DAY="$(day_ago "$IOS_PERF_OFF")"
AND_PERF_DAY="$(day_ago "$AND_PERF_OFF")"
# DoD 实际对比日期标注（R1 / D7）：性能批量表滞后，DoD 用「最新可用单日 vs 前一单日」的实际日期，
# 不把最新可用日冒充「昨日」；仅在 DoD 可计算（前一单日有值）时由 _dod_wow 拼入展示。
IOS_PERF_PREV_DAY="$(day_ago "$((IOS_PERF_OFF + 1))")"
AND_PERF_PREV_DAY="$(day_ago "$((AND_PERF_OFF + 1))")"
IOS_PERF_DAY_LABEL="（对比 ${IOS_PERF_DAY} vs ${IOS_PERF_PREV_DAY}）"
AND_PERF_DAY_LABEL="（对比 ${AND_PERF_DAY} vs ${AND_PERF_PREV_DAY}）"

# 今日天级单日值（字段带 _1d；缺失 → 空）
IOS_CEV_1D="$(m1 "$IOS_CRASH_1D" crash_events_1d)"
IOS_AFFECTED_1D="$(m1 "$IOS_CRASH_1D" affected_installs_1d)"
IOS_SESS_1D="$(m1 "$IOS_SESS_1D_OBJ" sessions_1d)"
IOS_SLOW_1D="$(m1 "$IOS_PERF_1D" slow_pct_1d)"
IOS_FROZEN_1D="$(m1 "$IOS_PERF_1D" frozen_pct_1d)"
IOS_NETERR_1D="$(m1 "$IOS_PERF_1D" net_err_pct_1d)"
IOS_START_P50_1D="$(m1 "$IOS_PERF_1D" start_p50_1d)"
IOS_START_P95_1D="$(m1 "$IOS_PERF_1D" start_p95_1d)"
AND_CEV_1D="$(m1 "$AND_CRASH_1D" crash_events_1d)"
AND_AFFECTED_1D="$(m1 "$AND_CRASH_1D" affected_installs_1d)"
AND_SESS_1D="$(m1 "$AND_SESS_1D_OBJ" sessions_1d)"
AND_SLOW_1D="$(m1 "$AND_PERF_1D" slow_pct_1d)"
AND_FROZEN_1D="$(m1 "$AND_PERF_1D" frozen_pct_1d)"
AND_NETERR_1D="$(m1 "$AND_PERF_1D" net_err_pct_1d)"
AND_START_P50_1D="$(m1 "$AND_PERF_1D" start_p50_1d)"
AND_START_P95_1D="$(m1 "$AND_PERF_1D" start_p95_1d)"

# 今日天级崩溃率（分子/分母，百分比）
IOS_RATE_1D="$(daily_rate "$IOS_CEV_1D" "$IOS_SESS_1D")"
AND_RATE_1D="$(daily_rate "$AND_CEV_1D" "$AND_SESS_1D")"

# ── 从历史读昨日 / D-7 基准 ──
HIST_ARR="$( [ -f "$HISTORY" ] && jq -s '.' "$HISTORY" 2>/dev/null || echo '[]' )"
hist_val() { jq -r --arg d "$1" --arg p "$2" --arg k "$3" '.[] | select(.day == $d) | .[$p][$k] // empty' <<<"$HIST_ARR" 2>/dev/null | head -1; }

# 崩溃率环比基准（历史：昨日 / D-7 各自分子分母 → 天级率）
IOS_RATE_1D_Y="$(daily_rate "$(hist_val "$YESTERDAY" ios crash_events_1d)" "$(hist_val "$YESTERDAY" ios sessions_1d)")"
IOS_RATE_1D_D7="$(daily_rate "$(hist_val "$D7" ios crash_events_1d)" "$(hist_val "$D7" ios sessions_1d)")"
AND_RATE_1D_Y="$(daily_rate "$(hist_val "$YESTERDAY" android crash_events_1d)" "$(hist_val "$YESTERDAY" android sessions_1d)")"
AND_RATE_1D_D7="$(daily_rate "$(hist_val "$D7" android crash_events_1d)" "$(hist_val "$D7" android sessions_1d)")"

# 性能环比：DoD 用「最新可用 vs 前一单日」直接查（D7，仅一个可用日 → 无基准）；WoW 用历史 D-7
IOS_START_P50_PREV="$(m1 "$IOS_PERF_1D_PREV" start_p50_1d)"
IOS_START_P95_PREV="$(m1 "$IOS_PERF_1D_PREV" start_p95_1d)"
IOS_SLOW_PREV="$(m1 "$IOS_PERF_1D_PREV" slow_pct_1d)"
IOS_FROZEN_PREV="$(m1 "$IOS_PERF_1D_PREV" frozen_pct_1d)"
IOS_NETERR_PREV="$(m1 "$IOS_PERF_1D_PREV" net_err_pct_1d)"
AND_START_P50_PREV="$(m1 "$AND_PERF_1D_PREV" start_p50_1d)"
AND_START_P95_PREV="$(m1 "$AND_PERF_1D_PREV" start_p95_1d)"
AND_SLOW_PREV="$(m1 "$AND_PERF_1D_PREV" slow_pct_1d)"
AND_FROZEN_PREV="$(m1 "$AND_PERF_1D_PREV" frozen_pct_1d)"
AND_NETERR_PREV="$(m1 "$AND_PERF_1D_PREV" net_err_pct_1d)"
IOS_START_P50_D7="$(hist_val "$D7" ios start_p50_1d)"
IOS_START_P95_D7="$(hist_val "$D7" ios start_p95_1d)"
IOS_SLOW_D7="$(hist_val "$D7" ios slow_pct_1d)"
IOS_FROZEN_D7="$(hist_val "$D7" ios frozen_pct_1d)"
IOS_NETERR_D7="$(hist_val "$D7" ios net_err_pct_1d)"
AND_START_P50_D7="$(hist_val "$D7" android start_p50_1d)"
AND_START_P95_D7="$(hist_val "$D7" android start_p95_1d)"
AND_SLOW_D7="$(hist_val "$D7" android slow_pct_1d)"
AND_FROZEN_D7="$(hist_val "$D7" android frozen_pct_1d)"
AND_NETERR_D7="$(hist_val "$D7" android net_err_pct_1d)"

# ── 五指标 DoD/WoW 文案（崩溃率/接口错误率/启动 P50/P95/慢帧/冻结，iOS/Android 分开）──
IOS_CRASH_DODWOW="$(dod_wow_pct "$IOS_RATE_1D" "$IOS_RATE_1D_Y" "$IOS_RATE_1D_D7")"
AND_CRASH_DODWOW="$(dod_wow_pct "$AND_RATE_1D" "$AND_RATE_1D_Y" "$AND_RATE_1D_D7")"
IOS_START_P50_DODWOW="$(dod_wow_ms "$IOS_START_P50_1D" "$IOS_START_P50_PREV" "$IOS_START_P50_D7" "$IOS_PERF_DAY_LABEL")"
IOS_START_P95_DODWOW="$(dod_wow_ms "$IOS_START_P95_1D" "$IOS_START_P95_PREV" "$IOS_START_P95_D7" "$IOS_PERF_DAY_LABEL")"
IOS_SLOW_DODWOW="$(dod_wow_pct "$IOS_SLOW_1D" "$IOS_SLOW_PREV" "$IOS_SLOW_D7" "$IOS_PERF_DAY_LABEL")"
IOS_FROZEN_DODWOW="$(dod_wow_pct "$IOS_FROZEN_1D" "$IOS_FROZEN_PREV" "$IOS_FROZEN_D7" "$IOS_PERF_DAY_LABEL")"
IOS_NETERR_DODWOW="$(dod_wow_pct "$IOS_NETERR_1D" "$IOS_NETERR_PREV" "$IOS_NETERR_D7" "$IOS_PERF_DAY_LABEL")"
AND_START_P50_DODWOW="$(dod_wow_ms "$AND_START_P50_1D" "$AND_START_P50_PREV" "$AND_START_P50_D7" "$AND_PERF_DAY_LABEL")"
AND_START_P95_DODWOW="$(dod_wow_ms "$AND_START_P95_1D" "$AND_START_P95_PREV" "$AND_START_P95_D7" "$AND_PERF_DAY_LABEL")"
AND_SLOW_DODWOW="$(dod_wow_pct "$AND_SLOW_1D" "$AND_SLOW_PREV" "$AND_SLOW_D7" "$AND_PERF_DAY_LABEL")"
AND_FROZEN_DODWOW="$(dod_wow_pct "$AND_FROZEN_1D" "$AND_FROZEN_PREV" "$AND_FROZEN_D7" "$AND_PERF_DAY_LABEL")"
AND_NETERR_DODWOW="$(dod_wow_pct "$AND_NETERR_1D" "$AND_NETERR_PREV" "$AND_NETERR_D7" "$AND_PERF_DAY_LABEL")"

# ── 7 日 sparkline（R6：仅崩溃率/接口错误率/启动 P95；慢帧/冻结/P50 不画）──
# 从历史按文件顺序（旧→新）取序列；冷启动历史不足 7 天按已有天数渲染，空值跳过不补齐。
spark_hist() { jq -r --arg p "$1" --arg k "$2" '.[] | .[$p][$k] // empty' <<<"$HIST_ARR" 2>/dev/null; }
spark_rate() { jq -r --arg p "$1" '.[] | [.[$p].crash_events_1d // "", .[$p].sessions_1d // ""] | @tsv' <<<"$HIST_ARR" 2>/dev/null \
  | awk -F'\t' '{ if($1!="" && $2!="" && $2!=0) printf "%.2f\n", $1/$2*100 }'; }
IOS_SPARK_CRASH="$(sparkline "$(spark_rate ios)")"
AND_SPARK_CRASH="$(sparkline "$(spark_rate android)")"
IOS_SPARK_NETERR="$(sparkline "$(spark_hist ios net_err_pct_1d)")"
AND_SPARK_NETERR="$(sparkline "$(spark_hist android net_err_pct_1d)")"
IOS_SPARK_P95="$(sparkline "$(spark_hist ios start_p95_1d)")"
AND_SPARK_P95="$(sparkline "$(spark_hist android start_p95_1d)")"

# ── 小样本量提示（R4）：平台当日会话数 < SAMPLE_SESSION_MIN → 追加提示（只标注不省略）──
IOS_SAMPLE_NOTE=""; AND_SAMPLE_NOTE=""
[ -n "$IOS_SESS_1D" ] && [ "$(awk -v a="$IOS_SESS_1D" -v b="$SAMPLE_SESSION_MIN" 'BEGIN{print (a<b)}')" = "1" ] \
  && IOS_SAMPLE_NOTE=" ⚠️ 样本量小，仅供参考"
[ -n "$AND_SESS_1D" ] && [ "$(awk -v a="$AND_SESS_1D" -v b="$SAMPLE_SESSION_MIN" 'BEGIN{print (a<b)}')" = "1" ] \
  && AND_SAMPLE_NOTE=" ⚠️ 样本量小，仅供参考"

# ── MCP 对照/回退（首验期同跑，人工核对后移除）─────────
# fetch-snapshot.sh light 模式仍抓 MCP topIssues（OPEN FATAL）+ git 反查，产出 snapshot.json。
# 它不再驱动日报「崩溃」段与卡片计数（已由 BigQuery 接管），只用于：
#   ① 首验期对照两套数值（下面打印 MCP 口径总数供人工核对）；
#   ② 索引页「跟踪中的 issue」、新增/已修待验告警、每日快照（这些仍基于 MCP 的 OPEN 口径 + fix_commit）。
echo "--- 抓取 MCP 崩溃对照数据 ---"
CRASH_DIR="$ROOT/state/crash-daily-$TS"
CRASH_JSON="$CRASH_DIR/snapshot.json"
# shellcheck disable=SC1091
. "$ROOT/bin/lib.sh"
FETCH_TIMEOUT="${FETCH_TIMEOUT:-600}"   # light 模式只取数，10 分钟足够
if [ -x "$ROOT/bin/fetch-snapshot.sh" ] \
   && run_with_timeout "$FETCH_TIMEOUT" "$ROOT/bin/fetch-snapshot.sh" "$CRASH_DIR" 2>/dev/null \
   && [ -s "$CRASH_JSON" ]; then
  # 对照日志：MCP OPEN 口径 vs BigQuery 事件级口径，首验期人工核对用
  echo "  MCP 对照（OPEN FATAL）：iOS $(jq -r '(.ios//[])|length' "$CRASH_JSON") 类 $(jq -r '[(.ios//[])[].events]|add//0' "$CRASH_JSON") 次 · Android $(jq -r '(.android//[])|length' "$CRASH_JSON") 类 $(jq -r '[(.android//[])[].events]|add//0' "$CRASH_JSON") 次"
else
  echo "  ⚠️ MCP 对照数据抓取失败（不影响 BigQuery 主口径；索引页「跟踪中的 issue」本轮缺失）"
fi

# ── 组装 ──────────────────────────────────────────────
REPORT="$ROOT/reports/$DAY-daily.md"
cat > "$REPORT" <<MD
# 崩溃 & 性能日报 · $DAY

> 性能数据截止：**$DATA_UNTIL**（firebase_performance 每日批量同步，非实时）
> 放量数据截止：**$ADOPTION_UNTIL**（firebase_sessions REALTIME）
> 崩溃数据截止：**$CRASH_UNTIL**（firebase_crashlytics 事件级）
> 窗口：性能近 $PERF_DAYS 天 · 放量近 $DAYS 天 · 崩溃近 $CRASH_DAYS 天

## 崩溃

$CRASH

> 崩溃数据来自 BigQuery \`firebase_crashlytics\` **事件级统计**（含已关闭 issue，不受开关状态影响）。
> 崩溃率口径 = **事件数 / 会话数**（非 crash-free 精确口径）：iOS ${IOS_RATE} · Android ${AND_RATE}。
> 受影响安装（is_fatal 事件去重安装数）：iOS ${IOS_AFFECTED:-0} · Android ${AND_AFFECTED:-0}。
> 事件级与旧 MCP「OPEN issue」口径天然不同（事件级含 closed，回填完成后应 ≥ OPEN）。
> ⚠️ firebase_crashlytics 当前仅 REALTIME 表且仍在回填（事件数低于 MCP「OPEN」口径），此段数据暂按「回填中」看待，勿据此判断崩溃变少。
> 崩溃率环比（天级单日值，非窗口值）：iOS ${IOS_CRASH_DODWOW:-无基准} · Android ${AND_CRASH_DODWOW:-无基准}。

### NON_FATAL（非致命）

> 🚧 **iOS 通路建设中，数据不完整——不要按此判断 iOS 比 Android 稳**。
> 收口点已落地（change \`ios-nonfatal-reporting\`）但**尚未合入发版分支**，
> 线上仍为零上报。Android 侧通路早已就绪，两端数字暂不可比。
> 通路发版后此处替换为双端 NON_FATAL 事件量与 TOP issue。

## 版本放量

> 崩溃数为 0 可能是修好了、也可能是没人用——**没有这个分母就分不清**。
> 修复验证的判定线（如「累计 N 会话仍 0 崩溃才算生效」）依赖本表。

$ADOPTION

## 性能

$PERF

> 环比（天级单日值；启动用 ms、慢帧/冻结/接口错误率用 pp）：
> 启动 P50 iOS ${IOS_START_P50_DODWOW:-无基准} · Android ${AND_START_P50_DODWOW:-无基准}
> 启动 P95 iOS ${IOS_START_P95_DODWOW:-无基准} · Android ${AND_START_P95_DODWOW:-无基准}
> 慢帧（平台级聚合）iOS ${IOS_SLOW_DODWOW:-无基准} · Android ${AND_SLOW_DODWOW:-无基准}
> 冻结 iOS ${IOS_FROZEN_DODWOW:-无基准} · Android ${AND_FROZEN_DODWOW:-无基准}
> 接口错误率 iOS ${IOS_NETERR_DODWOW:-无基准} · Android ${AND_NETERR_DODWOW:-无基准}
> 慢帧最差页百分比 = 该页渲染期慢帧(>16ms)帧数 ÷ 全部帧数（帧级占比，非会话占比）；冻结同理(>700ms)。性能批量表滞后，环比按最近可用日对比（实际日期见各指标行）；崩溃/放量（REALTIME）环比严格按昨日。

---
本报告自动生成，不含根因与修复方案。需要定位请跑 \`firebase-crash-triage\`。
MD

echo "--- 报告已生成：$REPORT ---"

# ── 发布（飞书投递已改由 Hermes agent 经 lark-mcp 完成）──
# 脚本只负责把「群卡片 + 各文档」的 markdown 内容产出到 $ROOT/state/publish/ 并生成 manifest.json；
# 实际发消息/写文档由 cron 的 agent 读 manifest 后用 lark-mcp 工具执行（见下方「产出投递清单」段）。

DOC_URL_BASE="https://qjphu5vphyf4.jp.larksuite.com/docx"

# ── 快照与趋势 ────────────────────────────────────────
# 箭头方向按「数值变大 = 变差」定义（崩溃数、耗时、慢帧率、错误率都是越小越好）。
# 首日无基准，不显示箭头——避免给出没有依据的趋势。
SNAP="$ROOT/state/daily-snapshot.json"
# IOS_N/IOS_EV/AND_N/AND_EV 已在「崩溃统计」段由 BigQuery 事件级计算（见上），此处不再从 MCP 快照取。

prev() { [ -f "$SNAP" ] && jq -r --arg k "$1" '.[$k] // empty' "$SNAP" 2>/dev/null || echo ""; }
arrow() { # $1=当前 $2=上次key —— 数值变大标 ↑（变差），变小标 ↓
  local cur="$1" old; old="$(prev "$2")"
  [ -n "$old" ] && [ -n "$cur" ] || { echo ""; return; }
  awk -v c="$cur" -v o="$old" 'BEGIN{ if(c>o) print " ↑"; else if(c<o) print " ↓"; else print "" }'
}

# ── 异常判定（命中任一即出 🔴 块）────────────────────
ALERTS=""
NEW_IOS="$(jq -r --slurpfile s "${SNAP:-/dev/null}" '[(.ios // [])[] | select(.id as $i | ($s[0].ios_ids // []) | index($i) | not)] | length' "$CRASH_JSON" 2>/dev/null || echo 0)"
NEW_AND="$(jq -r --slurpfile s "${SNAP:-/dev/null}" '[(.android // [])[] | select(.id as $i | ($s[0].android_ids // []) | index($i) | not)] | length' "$CRASH_JSON" 2>/dev/null || echo 0)"
[ -f "$SNAP" ] && [ "${NEW_IOS:-0}" -gt 0 ] 2>/dev/null && add_alert "🔴 iOS 新增 ${NEW_IOS} 个 issue"
[ -f "$SNAP" ] && [ "${NEW_AND:-0}" -gt 0 ] 2>/dev/null && add_alert "🔴 Android 新增 ${NEW_AND} 个 issue"
# 代码已修但未发版：最容易被遗忘的状态，必须顶到卡片上
# 只统计 iOS：Android 无 issue ID 约定，fix_commit 恒 null，计进来无意义
FIXED_PENDING="$(jq -r '[(.ios // [])[] | select(.fix_commit != null)] | length' "$CRASH_JSON" 2>/dev/null || echo 0)"
[ "${FIXED_PENDING:-0}" -gt 0 ] 2>/dev/null && add_alert "🔴 ${FIXED_PENDING} 个 issue 代码已修但未发版"
# 统一阈值红绿灯（R3 / D5）：五指标走 traffic_light()，命中红档追加 🔴；黄档待对齐，仅注释不告警。
# 阈值作用于卡片「今日展示值」（崩溃率窗口值、慢帧/冻结最差页、启动 P95、接口错误率），见 design D9。
add_alert "$(red_line "崩溃率" "${IOS_RATE_PCT}" "${AND_RATE_PCT}" "$CRASH_RATE_RED" "$CRASH_RATE_YELLOW" "%")"
add_alert "$(red_line "慢帧最差页" "${IOS_WORST_SLOW}" "${AND_WORST_SLOW}" "$SLOW_FRAME_RED" "$SLOW_FRAME_YELLOW" "%")"
add_alert "$(red_line "冻结率" "${IOS_FROZEN}" "${AND_FROZEN}" "$FROZEN_RED" "$FROZEN_YELLOW" "%")"
add_alert "$(red_line "启动 P95" "${IOS_START_P95}" "${AND_START_P95}" "$START_P95_RED" "$START_P95_YELLOW" "ms")"
add_alert "$(red_line "接口错误率" "${IOS_NET_ERR}" "${AND_NET_ERR}" "$NET_ERR_RED" "$NET_ERR_YELLOW" "%")"

STATUS_TAG=""
[ -z "$ALERTS" ] && STATUS_TAG=" · ✅ 无异常"
[ -n "$ALERTS" ] && ALERTS="$ALERTS
"
# sessions 回退批量表时，卡片显式标注（D1「REALTIME 缺失则回退批量表并标注」）
SESS_FALLBACK_NOTE=""
{ [ "$SESS_IOS_FALLBACK" = 1 ] || [ "$SESS_AND_FALLBACK" = 1 ]; } && SESS_FALLBACK_NOTE=" · ⚠️ 放量回退批量表（可能停更）"

CARD="**📊 ${DAY:5} 崩溃 & 性能**$STATUS_TAG · 性能截至 $DATA_UNTIL · 放量截至 $ADOPTION_UNTIL · 崩溃截至 $CRASH_UNTIL
$ALERTS
崩溃 iOS **${IOS_N}** 类 **${IOS_EV}** 次（率 ${IOS_RATE}）$(arrow "$IOS_EV" ios_events) · Android **${AND_N}** 类 **${AND_EV}** 次（率 ${AND_RATE}）$(arrow "$AND_EV" android_events)
受影响安装 iOS **${IOS_AFFECTED:-0}** · Android **${AND_AFFECTED:-0}**（is_fatal 事件去重安装数）
崩溃率环比 iOS ${IOS_CRASH_DODWOW:-无基准} · Android ${AND_CRASH_DODWOW:-无基准}${IOS_SPARK_CRASH:+ · 7日 $IOS_SPARK_CRASH}
启动 iOS **${IOS_START_P50:-—}**ms$(arrow "${IOS_START_P50:-}" start_p50) · Android **${AND_START_P50:-—}**ms（P95 ${IOS_START_P95:-—} / ${AND_START_P95:-—}）${IOS_SPARK_P95:+ 7日 $IOS_SPARK_P95}
卡顿 iOS ${IOS_WORST_SCREEN:-—} **${IOS_WORST_SLOW:-—}%** · Android ${AND_WORST_SCREEN:-—} **${AND_WORST_SLOW:-—}%**（慢帧最差页）
冻结 iOS **${IOS_FROZEN:-0}%** · Android **${AND_FROZEN:-0}%**（>700ms 单帧，用户可感知的卡死）
接口 错误 iOS **${IOS_NET_ERR:-0}%** · Android **${AND_NET_ERR:-0}%**${IOS_SPARK_NETERR:+ 7日 $IOS_SPARK_NETERR}
环比 启动 iOS ${IOS_START_P50_DODWOW:-无基准} · Android ${AND_START_P50_DODWOW:-无基准}
环比 慢帧 iOS ${IOS_SLOW_DODWOW:-无基准} · Android ${AND_SLOW_DODWOW:-无基准}
环比 冻结 iOS ${IOS_FROZEN_DODWOW:-无基准} · Android ${AND_FROZEN_DODWOW:-无基准}
环比 接口 iOS ${IOS_NETERR_DODWOW:-无基准} · Android ${AND_NETERR_DODWOW:-无基准}
放量 最新版 iOS ${IOS_TOP_VER:-—} **${IOS_TOP_SESS:-0}** 会话 · Android ${AND_TOP_VER:-—} **${AND_TOP_SESS:-0}** 会话${IOS_SAMPLE_NOTE}${AND_SAMPLE_NOTE}
> 崩溃=BigQuery 事件级（含已关闭 issue）· 崩溃率=事件数/会话数（非 crash-free）· 放量=REALTIME 活表$SESS_FALLBACK_NOTE
> 慢帧最差页百分比 = 该页渲染期慢帧(>16ms)帧数 ÷ 全部帧数（帧级占比，非会话占比）；冻结同理(>700ms)。"

# ── 结构化 interactive 卡片 JSON（agent 原样投递，禁止改写）─────────
# header 模板色：有告警 red / 无告警 blue（单一规则，勿改）。
# 崩溃/性能各一张原生 table（行=指标，列=指标|iOS|Android），放量单栏段落，底部 div 收口口径 + 三表截止时间戳。
HEADER_TITLE="📊 ${DAY:5} 崩溃 & 性能"
HEADER_COLOR="blue"; [ -n "$ALERTS" ] && HEADER_COLOR="red"
ALERTS_MD="$(printf '%s' "$ALERTS" | grep -v '^$' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
# 顶部摘要（R5/D6）：仅渲染命中红/黄档的指标行——红档已进 ALERTS（含事件告警），黄档走 yellow_line 追加；无命中显示「✅ 无异常」。
SUMMARY_MD="$ALERTS_MD"
add_summary() { [ -n "$1" ] && SUMMARY_MD="${SUMMARY_MD:+$SUMMARY_MD
}$1"; return 0; }
add_summary "$(yellow_line "崩溃率" "${IOS_RATE_PCT}" "${AND_RATE_PCT}" "$CRASH_RATE_RED" "$CRASH_RATE_YELLOW" "%")"
add_summary "$(yellow_line "慢帧最差页" "${IOS_WORST_SLOW}" "${AND_WORST_SLOW}" "$SLOW_FRAME_RED" "$SLOW_FRAME_YELLOW" "%")"
add_summary "$(yellow_line "冻结率" "${IOS_FROZEN}" "${AND_FROZEN}" "$FROZEN_RED" "$FROZEN_YELLOW" "%")"
add_summary "$(yellow_line "启动 P95" "${IOS_START_P95}" "${AND_START_P95}" "$START_P95_RED" "$START_P95_YELLOW" "ms")"
add_summary "$(yellow_line "接口错误率" "${IOS_NET_ERR}" "${AND_NET_ERR}" "$NET_ERR_RED" "$NET_ERR_YELLOW" "%")"
STATUS_MD="$SUMMARY_MD"; [ -z "$STATUS_MD" ] && STATUS_MD="✅ 无异常"

# ── 展示层单元格助手（红绿灯着色 / 紧凑环比，复用 traffic_light 与 _dod_wow 计算产出，不重算）──
# 单元格红绿灯着色（R3/D3/D7/D8）：红→<font color=red>，黄→<font color=orange>，正常/空值/无法计算→裸值。
cell_color() { # $1=判定值 $2=红阈值 $3=黄阈值 $4=单元格内容
  local t; t="$(traffic_light "$1" "$2" "$3")"
  case "$t" in
    red)    printf '<font color=red>%s</font>' "$4";;
    yellow) printf '<font color=orange>%s</font>' "$4";;
    *)      printf '%s' "$4";;
  esac
}
# 紧凑环比（R4/D5）：复用 _dod_wow 计算产出，仅裁剪「无基准」段与日期标注（不重算）。
cell_dod_wow() { # 输入同 _dod_wow（今日/昨日/D-7/单位/日期标注）
  local s
  s="$(_dod_wow "$1" "$2" "$3" "$4" "")"
  [ -n "$s" ] || { echo ""; return; }
  printf '%s' "$s" \
    | sed -e 's/DoD 无基准 · //' -e 's/ · WoW 无基准//' -e 's/DoD 无基准//' -e 's/WoW 无基准//'
}
# 核心指标单元格：$1=展示值 $2=判定值 $3=红 $4=黄 $5=今日 $6=昨日 $7=D-7 $8=单位 $9=样本提示(可空)
# $3 为空（如启动 P50 无阈值常量）→ 不判定不包色，仅拼「展示值 + 紧凑环比 + 样本提示」。
core_cell() {
  local content="$1" delta
  delta="$(cell_dod_wow "$5" "$6" "$7" "$8")"
  [ -n "$delta" ] && content="$content $delta"
  [ -n "$9" ] && content="$content$9"
  if [ -n "$3" ]; then cell_color "$2" "$3" "$4" "$content"; else printf '%s' "$content"; fi
}

# ── 崩溃表三行（D4）：崩溃次数 / 崩溃率 / 受影响安装（行=指标，列=指标|iOS|Android）──
# 崩溃次数：无红绿灯、无环比；0 类=数据未同步（沿用 crash_section「窗口内 0 行→数据未同步」口径）
if [ -z "$IOS_N" ] || [ "$IOS_N" = "0" ]; then
  crash_count_ios="⚠️ 数据未同步"; crash_rate_ios="—"; crash_affected_ios="—"
else
  crash_count_ios="${IOS_N} 类 ${IOS_EV} 次"
  crash_rate_ios="$(core_cell "$IOS_RATE_LINE" "$IOS_RATE_PCT" "$CRASH_RATE_RED" "$CRASH_RATE_YELLOW" "$IOS_RATE_1D" "$IOS_RATE_1D_Y" "$IOS_RATE_1D_D7" pp "$IOS_SAMPLE_NOTE")"
  crash_affected_ios="${IOS_AFFECTED:-0}"
fi
if [ -z "$AND_N" ] || [ "$AND_N" = "0" ]; then
  crash_count_and="⚠️ 数据未同步"; crash_rate_and="—"; crash_affected_and="—"
else
  crash_count_and="${AND_N} 类 ${AND_EV} 次"
  crash_rate_and="$(core_cell "$AND_RATE_LINE" "$AND_RATE_PCT" "$CRASH_RATE_RED" "$CRASH_RATE_YELLOW" "$AND_RATE_1D" "$AND_RATE_1D_Y" "$AND_RATE_1D_D7" pp "$AND_SAMPLE_NOTE")"
  crash_affected_and="${AND_AFFECTED:-0}"
fi

# ── 性能表五行（D4）：启动 P50 / 启动 P95 / 慢帧最差页 / 冻结率 / 接口错误率 ──
# 启动 P50 缺失 ≈ 无性能数据（perf-traces 无 _app_start 行），整列标「数据未同步」，其余格「—」避免误读 0。
# 启动 P50 无阈值常量（无红绿灯），但保留紧凑环比（D4 核心指标含 P50）。
if [ -z "$IOS_START_P50" ]; then
  perf_p50_ios="⚠️ 数据未同步"; perf_p95_ios="—"; perf_slow_ios="—"; perf_frozen_ios="—"; perf_neterr_ios="—"
else
  perf_p50_ios="$(core_cell "${IOS_START_P50}ms" "" "" "" "$IOS_START_P50_1D" "$IOS_START_P50_PREV" "$IOS_START_P50_D7" ms "")"
  perf_p95_ios="$(core_cell "${IOS_START_P95:-—}ms" "$IOS_START_P95" "$START_P95_RED" "$START_P95_YELLOW" "$IOS_START_P95_1D" "$IOS_START_P95_PREV" "$IOS_START_P95_D7" ms "")"
  perf_slow_ios="$(core_cell "${IOS_WORST_SCREEN:-—} ${IOS_WORST_SLOW:-—}%" "$IOS_WORST_SLOW" "$SLOW_FRAME_RED" "$SLOW_FRAME_YELLOW" "$IOS_SLOW_1D" "$IOS_SLOW_PREV" "$IOS_SLOW_D7" pp "")"
  perf_frozen_ios="$(core_cell "${IOS_FROZEN:-0}%" "$IOS_FROZEN" "$FROZEN_RED" "$FROZEN_YELLOW" "$IOS_FROZEN_1D" "$IOS_FROZEN_PREV" "$IOS_FROZEN_D7" pp "")"
  perf_neterr_ios="$(core_cell "${IOS_NET_ERR:-0}%" "$IOS_NET_ERR" "$NET_ERR_RED" "$NET_ERR_YELLOW" "$IOS_NETERR_1D" "$IOS_NETERR_PREV" "$IOS_NETERR_D7" pp "$IOS_SAMPLE_NOTE")"
fi
if [ -z "$AND_START_P50" ]; then
  perf_p50_and="⚠️ 数据未同步"; perf_p95_and="—"; perf_slow_and="—"; perf_frozen_and="—"; perf_neterr_and="—"
else
  perf_p50_and="$(core_cell "${AND_START_P50}ms" "" "" "" "$AND_START_P50_1D" "$AND_START_P50_PREV" "$AND_START_P50_D7" ms "")"
  perf_p95_and="$(core_cell "${AND_START_P95:-—}ms" "$AND_START_P95" "$START_P95_RED" "$START_P95_YELLOW" "$AND_START_P95_1D" "$AND_START_P95_PREV" "$AND_START_P95_D7" ms "")"
  perf_slow_and="$(core_cell "${AND_WORST_SCREEN:-—} ${AND_WORST_SLOW:-—}%" "$AND_WORST_SLOW" "$SLOW_FRAME_RED" "$SLOW_FRAME_YELLOW" "$AND_SLOW_1D" "$AND_SLOW_PREV" "$AND_SLOW_D7" pp "")"
  perf_frozen_and="$(core_cell "${AND_FROZEN:-0}%" "$AND_FROZEN" "$FROZEN_RED" "$FROZEN_YELLOW" "$AND_FROZEN_1D" "$AND_FROZEN_PREV" "$AND_FROZEN_D7" pp "")"
  perf_neterr_and="$(core_cell "${AND_NET_ERR:-0}%" "$AND_NET_ERR" "$NET_ERR_RED" "$NET_ERR_YELLOW" "$AND_NETERR_1D" "$AND_NETERR_PREV" "$AND_NETERR_D7" pp "$AND_SAMPLE_NOTE")"
fi

# 放量单栏段落（两端各一行最新版 + 会话数）
ADOPT_MD="$(printf 'iOS 最新版 %s · %s 会话\nAndroid 最新版 %s · %s 会话' \
  "${IOS_TOP_VER:-—}" "${IOS_TOP_SESS:-0}" "${AND_TOP_VER:-—}" "${AND_TOP_SESS:-0}")"

# 底部 div（替代废弃 note）：三表截止时间戳 + 口径 + 慢帧定义 + 环比口径（实际对比日期统一写一次，R4 单元格不再重复）
NOTE_MD="$(printf '性能截至 %s · 放量截至 %s · 崩溃截至 %s\n崩溃=BigQuery 事件级（含已关闭 issue）· 崩溃率=事件数/会话数（非 crash-free）· 放量=REALTIME 活表%s\n慢帧最差页百分比=该页渲染期慢帧(>16ms)帧数÷全部帧数（帧级占比，非会话占比）；冻结同理(>700ms)。环比基于天级单日值（_1d）：崩溃/放量（REALTIME）按昨日；性能按最近可用日（iOS %s vs %s · Android %s vs %s）' \
  "$DATA_UNTIL" "$ADOPTION_UNTIL" "$CRASH_UNTIL" "$SESS_FALLBACK_NOTE" \
  "$IOS_PERF_DAY" "$IOS_PERF_PREV_DAY" "$AND_PERF_DAY" "$AND_PERF_PREV_DAY")"

SUBTITLE_CRASH="<font color='red'>**💥 崩溃**</font>"
SUBTITLE_PERF="<font color='blue'>**⚡ 性能**</font>"
SUBTITLE_ADOPT="<font color='green'>**🚀 放量**</font>"

# 末尾「详情」占位符由 agent 建完文档后回填（唯一允许的改写点）
CARD_JSON="$(jq -n \
  --arg hc "$HEADER_COLOR" --arg ht "$HEADER_TITLE" --arg sm "$STATUS_MD" \
  --arg sc "$SUBTITLE_CRASH" --arg sp "$SUBTITLE_PERF" --arg sa "$SUBTITLE_ADOPT" \
  --arg am "$ADOPT_MD" --arg nm "$NOTE_MD" \
  --arg c1i "$crash_count_ios" --arg c1a "$crash_count_and" \
  --arg c2i "$crash_rate_ios" --arg c2a "$crash_rate_and" \
  --arg c3i "$crash_affected_ios" --arg c3a "$crash_affected_and" \
  --arg p1i "$perf_p50_ios" --arg p1a "$perf_p50_and" \
  --arg p2i "$perf_p95_ios" --arg p2a "$perf_p95_and" \
  --arg p3i "$perf_slow_ios" --arg p3a "$perf_slow_and" \
  --arg p4i "$perf_frozen_ios" --arg p4a "$perf_frozen_and" \
  --arg p5i "$perf_neterr_ios" --arg p5a "$perf_neterr_and" \
  '{schema:"2.0",
    config:{width_mode:"fill"},
    header:{template:$hc,title:{tag:"plain_text",content:$ht}},
    body:{elements:[
      {tag:"markdown",content:$sm},
      {tag:"markdown",content:$sc},{tag:"hr"},
      {tag:"table",page_size:10,row_height:"low",
        header_style:{text_align:"left",text_size:"normal",background_style:"grey",text_color:"default",bold:true,lines:1},
        columns:[
          {name:"metric",display_name:"指标",data_type:"text",width:"auto",horizontal_align:"left"},
          {name:"ios",display_name:"iOS",data_type:"lark_md",width:"auto",horizontal_align:"left"},
          {name:"aos",display_name:"Android",data_type:"lark_md",width:"auto",horizontal_align:"left"}],
        rows:[
          {metric:"崩溃次数",ios:$c1i,aos:$c1a},
          {metric:"崩溃率",ios:$c2i,aos:$c2a},
          {metric:"受影响安装",ios:$c3i,aos:$c3a}]},
      {tag:"markdown",content:$sp},{tag:"hr"},
      {tag:"table",page_size:10,row_height:"low",
        header_style:{text_align:"left",text_size:"normal",background_style:"grey",text_color:"default",bold:true,lines:1},
        columns:[
          {name:"metric",display_name:"指标",data_type:"text",width:"auto",horizontal_align:"left"},
          {name:"ios",display_name:"iOS",data_type:"lark_md",width:"auto",horizontal_align:"left"},
          {name:"aos",display_name:"Android",data_type:"lark_md",width:"auto",horizontal_align:"left"}],
        rows:[
          {metric:"启动 P50",ios:$p1i,aos:$p1a},
          {metric:"启动 P95",ios:$p2i,aos:$p2a},
          {metric:"慢帧最差页",ios:$p3i,aos:$p3a},
          {metric:"冻结率",ios:$p4i,aos:$p4a},
          {metric:"接口错误率",ios:$p5i,aos:$p5a}]},
      {tag:"markdown",content:$sa},{tag:"hr"},
      {tag:"markdown",content:$am},
      {tag:"div",text:{tag:"plain_text",content:$nm,text_size:"notation",text_color:"grey"}},
      {tag:"markdown",content:"📄 [详情](__DETAIL_URL__) · 🗂 [崩溃跟踪索引](__INDEX_URL__)"}
    ]}}')"

if [ "$DRY_RUN" = "1" ]; then
  echo; echo "──────── DRY RUN · 卡片预览（不会发送）────────"
  printf '%s\n' "$CARD"
  echo "──────────────────────────────────────────────"
  echo "── 结构化卡片 JSON（card.json）──"
  mkdir -p "$ROOT/state/publish"
  printf '%s\n' "$CARD_JSON" > "$ROOT/state/publish/card.json"
  jq empty "$ROOT/state/publish/card.json" && echo "  ✅ card.json 合法（jq empty 通过）"
  echo "  card.json 字节数：$(wc -c < "$ROOT/state/publish/card.json" | tr -d ' ')"
  printf '%s\n' "$CARD_JSON" | jq .
  echo "（完整报告见 $REPORT · 快照与历史未写入，不影响明日基准）"
  exit 0
fi

# 索引页：跟踪表随每日数据变化，整份重建而非局部改块（局部改易错且难回滚）。
# 日报/台账 URL 由 agent 建完文档后回填（__DAILY_URL__ / __LEDGER_URL__ 占位符），
# 周报归档 URL 来自 state/weekly-index.jsonl（L2 每次追加一行，本页倒序渲染）。
build_index() {
  local f="$ROOT/state/index-render.md"
  local WI="$ROOT/state/weekly-index.jsonl"
  local LATEST_WEEKLY_DAY="" LATEST_WEEKLY_URL=""
  if [ -s "$WI" ]; then
    LATEST_WEEKLY_DAY="$(tail -r "$WI" 2>/dev/null | head -1 | jq -r '.day // empty' 2>/dev/null)"
    LATEST_WEEKLY_URL="$(tail -r "$WI" 2>/dev/null | head -1 | jq -r '.url // empty' 2>/dev/null)"
  fi
  {
    printf '# Dino 崩溃跟踪 · 索引\n\n'
    printf '> 本页自动生成，请勿手工编辑（每日 L1 运行时整份重建）。\n'
    printf '> 判断与处置结论沉淀在仓库 `reports/LEDGER.md`，两者冲突以仓库为准。\n'
    printf '> 最后更新：%s · 数据截至 %s\n\n' "$DAY" "$DATA_UNTIL"
    printf '## 📍 文档入口\n\n| 文档 | 说明 | 维护 |\n|---|---|---|\n'
    printf '| 📄 [崩溃 & 性能日报（今日）](__DAILY_URL__) | 每日数据快照（崩溃/性能/放量） | 自动 |\n'
    if [ -n "$LATEST_WEEKLY_URL" ]; then
      printf '| 📊 [崩溃周报（%s）](%s) | 每周变化播报 | 自动 |\n' "$LATEST_WEEKLY_DAY" "$LATEST_WEEKLY_URL"
    else
      printf '| 📊 崩溃周报 | 每周变化播报（暂无，L2 首跑后出现） | 自动 |\n'
    fi
    printf '| 📒 [崩溃专项台账 LEDGER](__LEDGER_URL__) | 处置结论、风险分级、事故记录 | **人**（仓库为源，L1 每日同步镜像） |\n\n'
    printf '## 🔥 今日概览\n\n'
    printf '崩溃 iOS **%s** 类 **%s** 次 · Android **%s** 类 **%s** 次\n\n' "$IOS_N" "$IOS_EV" "$AND_N" "$AND_EV"
    printf '启动 P50 iOS **%sms** · Android **%sms**　|　慢帧最差页 iOS %s **%s%%** · Android %s **%s%%**\n\n' \
      "${IOS_START_P50:-—}" "${AND_START_P50:-—}" "${IOS_WORST_SCREEN:-—}" "${IOS_WORST_SLOW:-—}" "${AND_WORST_SCREEN:-—}" "${AND_WORST_SLOW:-—}"
    printf '## 🐞 跟踪中的 issue\n\n'
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
    # 报告归档：L2 每周追加一行 JSONL，此处倒序渲染（新的在上）
    printf '\n\n## 🗂 报告归档（周报）\n\n'
    if [ -s "$WI" ]; then
      printf '| 日期 | 报告 | iOS OPEN | Android OPEN |\n|---|---|---|---|\n'
      # macOS 无 tac，用 tail -r
      tail -r "$WI" | jq -r '"| \(.day) | [打开](\(.url)) | \(.ios) | \(.android) |"'
    else
      printf '（暂无归档，L2 首次运行后出现）\n'
    fi
    printf '\n## 📖 修复状态图例\n\n| 标记 | 含义 | 判据（自动推导） |\n|---|---|---|\n'
    printf '| 🔴 未修 | 代码里找不到修复 | `git log --grep=<issueId>` 无结果 |\n'
    printf '| 🛠️ 代码已修·未发版 | 修复已提交，含该修复的版本未上线 | 找到 commit，线上无该版本事件 |\n'
    printf '| 📦 已发版·观察中 | 含修复的版本已上线 | 线上出现该版本事件 |\n'
    printf '| ✅ 已消失 | 发版后无新事件 | 该版本后事件归零 |\n'
    printf '\n---\n数据源：BigQuery Crashlytics（事件级）+ Firebase Crashlytics（OPEN 对照）+ BigQuery Performance · 由 crash-daily.sh 自动生成\n'
  } > "$f"
  echo "$f"
}

echo "--- 产出投递清单 ---"
PUBLISH_DIR="$ROOT/state/publish"
rm -rf "$PUBLISH_DIR"; mkdir -p "$PUBLISH_DIR/docs"
printf '%s\n' "$CARD" > "$PUBLISH_DIR/message.md"
printf '%s\n' "$CARD_JSON" > "$PUBLISH_DIR/card.json"
[ -s "$REPORT" ] && cp "$REPORT" "$PUBLISH_DIR/docs/daily.md" || true

# 索引页重建（含 __DAILY_URL__ / __LEDGER_URL__ 占位符，agent 建完日报/台账镜像后回填）
INDEX_FILE="$(build_index)"

# 台账镜像：仓库 LEDGER.md 是真相源，镜像顶部加「请勿在此编辑」警告
if [ -s "$LEDGER_SRC" ]; then
  {
    printf '> ⚠️ 本页为仓库 `reports/LEDGER.md` 的只读镜像，请勿在此编辑；修改请在仓库提交。\n\n'
    cat "$LEDGER_SRC"
  } > "$PUBLISH_DIR/docs/ledger.md"
  LEDGER_DOC="$PUBLISH_DIR/docs/ledger.md"
else
  LEDGER_DOC=""
fi

# 投递：日报/台账镜像/索引页三份文档都每次新建（docx.builtin.import），URL 由 agent 回填。
# 卡片两态并存：message.md（纯 markdown 回退/调试视图）+ card.json（结构化 interactive 卡片，agent 原样投递）。
# card.json 末尾的占位符 __DETAIL_URL__ / __INDEX_URL__ 由 agent 建完文档后回填。
jq -n \
  --arg chat "$CHAT_ID" \
  --arg msg  "$PUBLISH_DIR/message.md" \
  --arg card "$PUBLISH_DIR/card.json" \
  --arg report "$PUBLISH_DIR/docs/daily.md" \
  --arg title "崩溃 & 性能日报 · $DAY" \
  --arg ledger "$LEDGER_DOC" \
  --arg index "$INDEX_FILE" \
  '{type:"daily", chat_id:$chat, message_file:$msg, card_file:$card,
    create_doc: {file:$report, title:$title, label:"日报"},
    ledger_doc: (if $ledger != "" then {file:$ledger, title:"崩溃专项台账 LEDGER（只读镜像）", label:"台账"} else null end),
    index_doc: (if $index != "" then {file:$index, title:"Dino 崩溃跟踪 · 索引", label:"索引"} else null end)}' \
  > "$PUBLISH_DIR/manifest.json"

echo "  ✅ 投递清单 $PUBLISH_DIR/manifest.json"

# ── 持久化：扩展快照 + 追加 7 日滚动历史（metrics-history.jsonl，原子写）──
# 天级单日值（字段带 _1d）与滚动窗口值（ios_events/start_p50 等）两套口径在此显式分离存储（D2）。
# 数值字段缺数据 → null；perf_day 记录性能类天级值的实际数据日期（D7 滞后标注）。
IOS_1D_OBJ="$(jq -cn \
  --arg cev "$IOS_CEV_1D" --arg sess "$IOS_SESS_1D" --arg aff "$IOS_AFFECTED_1D" \
  --arg net "$IOS_NETERR_1D" --arg slow "$IOS_SLOW_1D" --arg frz "$IOS_FROZEN_1D" \
  --arg p50 "$IOS_START_P50_1D" --arg p95 "$IOS_START_P95_1D" --arg pday "$IOS_PERF_DAY" \
  '{crash_events_1d:($cev|tonumber? // null), sessions_1d:($sess|tonumber? // null),
    affected_installs_1d:($aff|tonumber? // null), net_err_pct_1d:($net|tonumber? // null),
    slow_pct_1d:($slow|tonumber? // null), frozen_pct_1d:($frz|tonumber? // null),
    start_p50_1d:($p50|tonumber? // null), start_p95_1d:($p95|tonumber? // null), perf_day:$pday}')"
AND_1D_OBJ="$(jq -cn \
  --arg cev "$AND_CEV_1D" --arg sess "$AND_SESS_1D" --arg aff "$AND_AFFECTED_1D" \
  --arg net "$AND_NETERR_1D" --arg slow "$AND_SLOW_1D" --arg frz "$AND_FROZEN_1D" \
  --arg p50 "$AND_START_P50_1D" --arg p95 "$AND_START_P95_1D" --arg pday "$AND_PERF_DAY" \
  '{crash_events_1d:($cev|tonumber? // null), sessions_1d:($sess|tonumber? // null),
    affected_installs_1d:($aff|tonumber? // null), net_err_pct_1d:($net|tonumber? // null),
    slow_pct_1d:($slow|tonumber? // null), frozen_pct_1d:($frz|tonumber? // null),
    start_p50_1d:($p50|tonumber? // null), start_p95_1d:($p95|tonumber? // null), perf_day:$pday}')"

# metrics-history.jsonl：追加一行天级单日值，保留最近 7 行，原子写（临时文件 + mv）。
# L1 是唯一写者，冲突风险低，但仍用原子写防止中途崩溃留下半行。
HISTORY_LINE="$(jq -cn --arg day "$DAY" --argjson io "$IOS_1D_OBJ" --argjson ao "$AND_1D_OBJ" \
  '{day:$day, ios:$io, android:$ao}')"
{
  [ -f "$HISTORY" ] && cat "$HISTORY"
  printf '%s\n' "$HISTORY_LINE"
} | tail -7 > "$HISTORY.tmp" && mv "$HISTORY.tmp" "$HISTORY" \
  || echo "  ⚠️ 历史写入失败（不影响日报投递）"

# 存今日快照供明天算箭头与「新增 issue」判定（保留既有窗口字段 + 新增天级单日值，供明日 DoD 基准）
jq -n \
  --argjson ie "${IOS_EV:-0}" --argjson ae "${AND_EV:-0}" \
  --arg sp "${START_P50:-}" --arg day "$DAY" \
  --slurpfile c "$CRASH_JSON" \
  --argjson io "$IOS_1D_OBJ" --argjson ao "$AND_1D_OBJ" \
  '{day:$day, ios_events:$ie, android_events:$ae, start_p50:($sp|tonumber? // null),
    ios_ids:[($c[0].ios // [])[].id], android_ids:[($c[0].android // [])[].id],
    ios:$io, android:$ao}' \
  > "$SNAP" 2>/dev/null || echo "  ⚠️ 快照写入失败，明日无趋势基准"

jq -n --arg t "$TS" --arg u "$DATA_UNTIL" '{last_run:$t,ok:true,data_until:$u}' > "$ROOT/state/health-daily.json"
rm -rf "$TMP"
find "$ROOT/logs" -name 'daily-*.log' -mtime +60 -delete 2>/dev/null || true
find "$ROOT/state" -maxdepth 1 -name 'crash-daily-*' -mtime +30 -exec rm -rf {} + 2>/dev/null || true
echo "=== 完成 ==="
