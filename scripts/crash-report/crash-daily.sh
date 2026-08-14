#!/usr/bin/env bash
# L1 每日数据日报：BigQuery 性能 + Crashlytics 崩溃 → 飞书文档 + 群卡片。
#
# 数据源现状（2026-08-07）：
#   性能  → BigQuery firebase_performance  ✅ 已就绪
#   崩溃  → Firebase MCP（临时）           ⚠️ BigQuery firebase_crashlytics 出表后应换掉
#   崩溃率 → 需 firebase_sessions          ❌ 表未就绪，暂缺
#
# ⚠️ MCP 的 topIssues 只返回 OPEN issue：被误关的 issue 会从统计中消失并显示为「0 崩溃」。
#    换成 BigQuery 事件级统计后此问题自动消失。在此之前卡片须标注该口径限制。
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
SQL_DIR="${SQL_DIR:-$ROOT/bin/sql}"
PROJECT="dino-english-497507"

CHAT_ID="${CRASH_REPORT_CHAT_ID:?未设置 CRASH_REPORT_CHAT_ID}"
DOC_DAILY_ID="${DOC_DAILY_ID:-}"        # 日报文档；固定一份每天 overwrite
DOC_INDEX_ID="${DOC_INDEX_ID:-}"        # 索引页
DOC_LEDGER_ID="${DOC_LEDGER_ID:-}"      # 台账镜像
LEDGER_SRC="${LEDGER_SRC:-$ROOT/reports/LEDGER.md}"
DRY_RUN="${CRASH_REPORT_DRY_RUN:-0}"
DAYS="${CRASH_REPORT_DAYS:-1}"

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
q() { # $1=sql文件 $2=表名
  sed -e "s|{{TABLE}}|$2|g" -e "s|{{DAYS}}|$DAYS|g" "$SQL_DIR/$1" \
    | bq query --use_legacy_sql=false --format=csv 2>/dev/null | tail -n +2
}
# bq show 要 project:dataset.table（冒号），查询里用的是 project.dataset.table（全点号）——
# 只替换第一个点为冒号。踩过：直接传点号格式会永远返回「表不存在」。
table_exists() { bq show --format=none "${1/./:}" >/dev/null 2>&1; }

perf_section() { # $1=平台名 $2=表名
  local name="$1" tbl="$2"
  if ! table_exists "$tbl"; then
    printf '### %s\n\n> 性能表尚未同步，本次无数据。\n\n' "$name"; return
  fi
  printf '### %s\n\n' "$name"

  printf '**启动与自定义 trace**\n\n| trace | 次数 | P50 | P95 |\n|---|---|---|---|\n'
  q perf-traces.sql "$tbl" | awk -F, '{printf "| %s | %s | %s ms | %s ms |\n",$1,$2,$3,$4}'

  printf '\n**页面渲染（慢帧 >16ms · 冻结 >700ms）**\n\n| 页面 | 样本 | 慢帧率 | 冻结帧率 | P50 停留 |\n|---|---|---|---|---|\n'
  q perf-screens.sql "$tbl" | awk -F, '{printf "| %s | %s | %s%% | %s%% | %s s |\n",$1,$2,$3,$4,$5}'

  printf '\n**自家 API 网络**\n\n| 接口 | 次数 | P50 | P95 | 错误率 |\n|---|---|---|---|---|\n'
  q perf-network.sql "$tbl" | awk -F, '{printf "| %s | %s | %s ms | %s ms | %s%% |\n",$1,$2,$3,$4,$6}'
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
  q perf-traces.sql  "$2" | grep '^_app_start,' > "$TMP/start-$1.csv"  || true
  q perf-screens.sql "$2" | head -1             > "$TMP/screen-$1.csv" || true
  q perf-network.sql "$2"                       > "$TMP/net-$1.csv"    || true
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
SESS_IOS="$PROJECT.firebase_sessions.com_prime_dino_english_IOS"
SESS_AND="$PROJECT.firebase_sessions.com_prime_dino_english_ANDROID"
adoption_section() { # $1=平台名 $2=表名
  table_exists "$2" || { printf '### %s\n\n> sessions 表尚未同步。\n\n' "$1"; return; }
  printf '### %s\n\n| 版本 | 会话 | 设备 | 最新数据 |\n|---|---|---|---|\n' "$1"
  sed -e "s|{{TABLE}}|$2|g" -e "s|{{DAYS}}|$DAYS|g" "$SQL_DIR/sessions-by-version.sql" \
    | bq query --use_legacy_sql=false --format=csv 2>/dev/null | tail -n +2 \
    | awk -F, '{printf "| %s | %s | %s | %s |\n",$1,$2,$3,$4}'
  printf '\n'
}
echo "--- 查询版本放量 ---"
ADOPTION="$(adoption_section "iOS" "$SESS_IOS"; adoption_section "Android" "$SESS_AND")"

# 卡片只出「最新版本」的放量——判断新版样本够不够下结论，是看日报时最常问的一句
topver() { # $1=表名 → "版本 会话 设备"（按会话数排第一的**非最高版本**无意义，故取版本号最大者）
  table_exists "$1" || return 0
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

# 数据实际截止时间：BigQuery 是每日批量同步，不保证含昨天数据。
# 必须显示真实时间戳，不能假设「截至昨天」。
DATA_UNTIL="$(bq query --use_legacy_sql=false --format=csv \
  "SELECT FORMAT_TIMESTAMP('%Y-%m-%d %H:%M UTC', MAX(event_timestamp)) FROM \`$PROJECT.firebase_performance.com_prime_dino_english_IOS\`" \
  2>/dev/null | tail -1)"

# ── 崩溃数据（临时走 MCP）─────────────────────────────
echo "--- 抓取崩溃数据 ---"
# fetch-snapshot.sh 接收「输出目录」，产出 snapshot.json + report.md（L2 用后者，L1 只要前者）
CRASH_DIR="$ROOT/state/crash-daily-$TS"
CRASH_JSON="$CRASH_DIR/snapshot.json"
# shellcheck disable=SC1091
. "$ROOT/bin/lib.sh"
FETCH_TIMEOUT="${FETCH_TIMEOUT:-600}"   # light 模式只取数，10 分钟足够
if [ -x "$ROOT/bin/fetch-snapshot.sh" ] \
   && run_with_timeout "$FETCH_TIMEOUT" "$ROOT/bin/fetch-snapshot.sh" "$CRASH_DIR" 2>/dev/null \
   && [ -s "$CRASH_JSON" ]; then
  CRASH="$(jq -r '
    def sec($p; $n):
      "### " + $n + "\n\n| Issue | 标题 | 事件 | 修复提交 |\n|---|---|---|---|\n" +
      ((.[$p] // []) | map("| \(.id[0:8]) | \(.title) | \(.events) | \(if $p == "android" then "—" else (.fix_commit // "🔴 未修") end) |") | join("\n")) + "\n\n";
    sec("ios";"iOS") + sec("android";"Android")' "$CRASH_JSON")"
else
  CRASH="> ⚠️ 崩溃数据抓取失败或未配置，本次仅含性能数据。"
fi

# ── 组装 ──────────────────────────────────────────────
REPORT="$ROOT/reports/$DAY-daily.md"
cat > "$REPORT" <<MD
# 崩溃 & 性能日报 · $DAY

> 数据实际截止：**$DATA_UNTIL**（BigQuery 每日批量同步，非实时）
> 窗口：近 $DAYS 天

## 崩溃

$CRASH

> ⚠️ 当前崩溃数据来自 Crashlytics topIssues，**只统计 OPEN 状态的 issue**。
> 被关闭的 issue 即使仍有事件也不会出现在此。BigQuery 崩溃表就绪后将改为事件级统计。
> 崩溃率待 \`firebase_sessions\` 表就绪后补充。

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
IOS_N="$(jq -r '(.ios // []) | length' "$CRASH_JSON" 2>/dev/null || echo 0)"
IOS_EV="$(jq -r '[(.ios // [])[].events] | add // 0' "$CRASH_JSON" 2>/dev/null || echo 0)"
AND_N="$(jq -r '(.android // []) | length' "$CRASH_JSON" 2>/dev/null || echo 0)"
AND_EV="$(jq -r '[(.android // [])[].events] | add // 0' "$CRASH_JSON" 2>/dev/null || echo 0)"

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
[ -f "$SNAP" ] && [ "${NEW_IOS:-0}" -gt 0 ] 2>/dev/null && ALERTS="$ALERTS
🔴 iOS 新增 ${NEW_IOS} 个 issue"
[ -f "$SNAP" ] && [ "${NEW_AND:-0}" -gt 0 ] 2>/dev/null && ALERTS="$ALERTS
🔴 Android 新增 ${NEW_AND} 个 issue"
# 代码已修但未发版：最容易被遗忘的状态，必须顶到卡片上
# 只统计 iOS：Android 无 issue ID 约定，fix_commit 恒 null，计进来无意义
FIXED_PENDING="$(jq -r '[(.ios // [])[] | select(.fix_commit != null)] | length' "$CRASH_JSON" 2>/dev/null || echo 0)"
[ "${FIXED_PENDING:-0}" -gt 0 ] 2>/dev/null && ALERTS="$ALERTS
🔴 ${FIXED_PENDING} 个 issue 代码已修但未发版"
awk -v e="${NET_ERR:-0}" 'BEGIN{exit !(e>0)}' && ALERTS="$ALERTS
🔴 接口错误率 ${NET_ERR}%"

STATUS_TAG=""
[ -z "$ALERTS" ] && STATUS_TAG=" · ✅ 无异常"
[ -n "$ALERTS" ] && ALERTS="$ALERTS
"

CARD="**📊 ${DAY:5} 崩溃 & 性能**$STATUS_TAG · 数据截至 $DATA_UNTIL
$ALERTS
崩溃 iOS **${IOS_N}** 类 **${IOS_EV}** 次$(arrow "$IOS_EV" ios_events) · Android **${AND_N}** 类 **${AND_EV}** 次$(arrow "$AND_EV" android_events)
启动 iOS **${IOS_START_P50:-—}**ms$(arrow "${IOS_START_P50:-}" start_p50) · Android **${AND_START_P50:-—}**ms（P95 ${IOS_START_P95:-—} / ${AND_START_P95:-—}）
卡顿 iOS ${IOS_WORST_SCREEN:-—} **${IOS_WORST_SLOW:-—}%** · Android ${AND_WORST_SCREEN:-—} **${AND_WORST_SLOW:-—}%**（慢帧最差页）
冻结 iOS **${IOS_FROZEN:-0}%** · Android **${AND_FROZEN:-0}%**（>700ms 单帧，用户可感知的卡死）
接口 错误 iOS **${IOS_NET_ERR:-0}%** · Android **${AND_NET_ERR:-0}%**
放量 最新版 iOS ${IOS_TOP_VER:-—} **${IOS_TOP_SESS:-0}** 会话 · Android ${AND_TOP_VER:-—} **${AND_TOP_SESS:-0}** 会话"

if [ "$DRY_RUN" = "1" ]; then
  echo; echo "──────── DRY RUN · 卡片预览（不会发送）────────"
  printf '%s\n' "$CARD"
  echo "──────────────────────────────────────────────"
  echo "（完整报告见 $REPORT · 快照未写入，不影响明日基准）"
  exit 0
fi

# 索引页：跟踪表随每日数据变化，整份重建而非局部改块（局部改易错且难回滚）
build_index() {
  local f="$ROOT/state/index-render.md"
  {
    printf '# Dino 崩溃跟踪 · 索引\n\n'
    printf '> **本页自动生成，请勿手工编辑**（每日 L1 运行时整份覆盖）。\n'
    printf '> 判断与处置结论沉淀在仓库 `reports/LEDGER.md`，两者冲突以仓库为准。\n'
    printf '> 最后更新：%s · 数据截至 %s\n\n' "$DAY" "$DATA_UNTIL"
    printf '## 今日概览\n\n'
    printf '📄 **[崩溃 & 性能日报](%s/%s)** — 固定链接，每天覆盖更新\n\n' "$DOC_URL_BASE" "$DOC_DAILY_ID"
    printf '崩溃 iOS **%s** 类 **%s** 次 · Android **%s** 类 **%s** 次\n\n' "$IOS_N" "$IOS_EV" "$AND_N" "$AND_EV"
    printf '启动 P50 iOS **%sms** · Android **%sms**　|　慢帧最差页 iOS %s **%s%%** · Android %s **%s%%**\n\n' \
      "${IOS_START_P50:-—}" "${AND_START_P50:-—}" "${IOS_WORST_SCREEN:-—}" "${IOS_WORST_SLOW:-—}" "${AND_WORST_SCREEN:-—}" "${AND_WORST_SLOW:-—}"
    printf '## 常用入口\n\n| 文档 | 内容 | 谁维护 |\n|---|---|---|\n'
    printf '| [崩溃专项台账 LEDGER](%s/%s) | 处置结论、风险分级、事故记录 | **人**（仓库为源，L1 每日同步镜像） |\n\n' "$DOC_URL_BASE" "$DOC_LEDGER_ID"
    printf '> 装机步骤见仓库 `scripts/crash-report/INSTALL.md`；提审体检报告存 `reports/`，均不做在线副本以免漂移。\n\n'
    printf '## 修复状态说明\n\n| 标记 | 含义 | 判据（自动推导） |\n|---|---|---|\n'
    printf '| 🔴 未修 | 代码里找不到修复 | `git log --grep=<issueId>` 无结果 |\n'
    printf '| 🛠️ 代码已修·未发版 | 修复已提交，含该修复的版本未上线 | 找到 commit，线上无该版本事件 |\n'
    printf '| 📦 已发版·观察中 | 含修复的版本已上线 | 线上出现该版本事件 |\n'
    printf '| ✅ 已消失 | 发版后无新事件 | 该版本后事件归零 |\n\n'
    printf '## 跟踪中的 issue\n\n'
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
    printf '\n\n## 报告归档\n\n'
    WI="$ROOT/state/weekly-index.jsonl"
    if [ -s "$WI" ]; then
      printf '| 日期 | 报告 | iOS OPEN | Android OPEN |\n|---|---|---|---|\n'
      # macOS 无 tac，用 tail -r
      tail -r "$WI" | jq -r '"| \(.day) | [打开](\(.url)) | \(.ios) | \(.android) |"'
    else
      printf '（暂无归档，L2 首次运行后出现）\n'
    fi
    printf '\n---\n数据源：Firebase Crashlytics + BigQuery Performance · 由 crash-daily.sh 自动生成\n'
  } > "$f"
  echo "$f"
}

echo "--- 产出投递清单 ---"
PUBLISH_DIR="$ROOT/state/publish"
rm -rf "$PUBLISH_DIR"; mkdir -p "$PUBLISH_DIR/docs"
printf '%s\n' "$CARD" > "$PUBLISH_DIR/message.md"
[ -s "$REPORT" ] && cp "$REPORT" "$PUBLISH_DIR/docs/daily.md" || true

# v1 投递：日报每次新建（docx.builtin.import），索引/台账的「固定 ID 覆盖」后续再做。
# 卡片末尾的「详情」链接由 agent 建完文档后回填。
jq -n \
  --arg chat "$CHAT_ID" \
  --arg msg  "$PUBLISH_DIR/message.md" \
  --arg report "$PUBLISH_DIR/docs/daily.md" \
  --arg title "崩溃 & 性能日报 · $DAY" \
  '{type:"daily", chat_id:$chat, message_file:$msg,
    create_doc: {file:$report, title:$title, label:"日报"}}' \
  > "$PUBLISH_DIR/manifest.json"

echo "  ✅ 投递清单 $PUBLISH_DIR/manifest.json"

# 存今日快照供明天算箭头与「新增 issue」判定
jq -n \
  --argjson ie "${IOS_EV:-0}" --argjson ae "${AND_EV:-0}" \
  --arg sp "${START_P50:-}" --arg day "$DAY" \
  --slurpfile c "$CRASH_JSON" \
  '{day:$day, ios_events:$ie, android_events:$ae, start_p50:($sp|tonumber? // null),
    ios_ids:[($c[0].ios // [])[].id], android_ids:[($c[0].android // [])[].id]}' \
  > "$SNAP" 2>/dev/null || echo "  ⚠️ 快照写入失败，明日无趋势基准"

jq -n --arg t "$TS" --arg u "$DATA_UNTIL" '{last_run:$t,ok:true,data_until:$u}' > "$ROOT/state/health-daily.json"
rm -rf "$TMP"
find "$ROOT/logs" -name 'daily-*.log' -mtime +60 -delete 2>/dev/null || true
find "$ROOT/state" -maxdepth 1 -name 'crash-daily-*' -mtime +30 -exec rm -rf {} + 2>/dev/null || true
echo "=== 完成 ==="
