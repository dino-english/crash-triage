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
# ${ROOT}（仓库）只放代码：bin/ · sql/。运行产物一律落 ${STATE}（归档 2026-08-20 起也移了过去）。
# $STATE 放可变运行数据：logs/ · 每日生成的报告 · 快照 · 历史 · 投递中间产物 · 本机 path.env / local.env。
# 分开的理由不是洁癖：`git clean -xfd` / 重新 clone 会连同被忽略的文件一起抹掉，
# 而 last-snapshot.json 丢了会把下周所有 issue 报成新增（2026-08-07 那类事故）。
# 默认走 XDG 约定；cron / plist 可用 CRASH_REPORT_STATE_DIR 指到别处。
STATE="${CRASH_REPORT_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/crash-triage}"

# PATH 由 setup.sh 探测后写入 path.env——launchd 只给最小 env，硬编码路径在别的机器上必挂。
# 实测教训（2026-08-06）：node 在 /usr/local/bin 而非 /opt/homebrew/bin，漏了它 npx/claude 直接起不来。
if [ -f "$STATE/path.env" ]; then
  # shellcheck disable=SC1091
  . "$STATE/path.env"
elif [ -f "$STATE/config.env" ]; then
  # shellcheck disable=SC1091
  . "$STATE/config.env"          # 2026-08-20 前的旧名，兼容一轮，见 crash-daily.sh 同处注释
else
  PATH="/opt/homebrew/bin:/usr/local/bin:$HOME/.npm-global/bin:/usr/bin:/bin:/usr/sbin:/sbin"
fi
# 机器本地配置，见 crash-daily.sh 同处注释：setup.sh 会覆写 path.env，配置只能放 local.env
[ -f "$STATE/local.env" ] && . "$STATE/local.env"   # shellcheck disable=SC1091
# 必须 export：alert.sh / deliver.sh 是**子进程**，local.env 里的普通赋值它们看不见。
# 2026-08-20 实测：只靠 local.env 的机器，失败告警被 alert.sh 当成「未设置 CHAT_ID」静默跳过。
# （生产机因 wrapper 里已 export、普通赋值保留 export 属性而侥幸没中招。）
export CRASH_REPORT_CHAT_ID
export PATH

TS="$(date +%Y%m%d-%H%M%S)"
# 文档标题带时分：同日多次跑批会覆盖 docs.json 里同一份文档（键 weekly-<日期>），
# 但飞书文档列表里只看标题分不清是哪一次的产物（2026-08-20 Sir 反馈）。
# 键保持 weekly-<日期> 不变——覆盖语义是对的，改的只是标题可读性。
TS_HM="$(date +%H:%M)"
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
    --message "$2" --rc "${3:-1}" --run-id "$TS" --log "$LOG" 2>&1 || true
}
on_err() { local rc=$?; [ "$rc" -eq 0 ] && return 0
  alert_once "$CURRENT_STEP" "脚本在第 ${1:-?} 行以退出码 $rc 终止（未预期的失败）" "$rc"; }
set -o errtrace
trap 'on_err $LINENO' ERR
fail() { echo "❌ $*"; jq -n --arg t "$TS" --arg e "$*" '{last_run:$t,ok:false,error:$e}' > "$HEALTH"; alert_once "$CURRENT_STEP" "$*" 1; exit 1; }

# ── 1. 凭证探活（端到端真调，不猜状态字符串）──────────
# 飞书投递已改由 Hermes agent 经 lark-mcp 完成，此处只探 firebase。
step "凭证探活"
npx -y firebase-tools@latest login:list 2>/dev/null | grep -q '@' \
  || fail "firebase 未登录，在本机跑 npx -y firebase-tools@latest login"

# ── 2. 同步只读 clone ─────────────────────────────────
step "同步仓库"
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

# ── 3. 数据层：bq 取快照（纯脚本，不调模型）───────────
# 数据与分析分层：数据是确定性聚合，分析才需要模型。
# 旧实现把两者绑在一次 `claude -p` 里，代价是 2026-08-19/20 实测的那次 429——
# 模型额度一挂，snapshot.json 落不了盘，整跑 fail，群里什么都收不到。
# 现在数据走 bq（额度无关），分析层单独跑且失败只降级。
step "L2 数据层：bq 取崩溃快照"
OUT_DIR="$STATE/runs/$DAY/L2/$TS"
mkdir -p "$OUT_DIR"
# shellcheck disable=SC1091
. "$ROOT/bin/lib.sh"

# 反扫提前到取数之前：它是纯 git、不依赖快照，而快照要用它填 fix_commit。
LEDGER_DIR="$STATE/ledger"
LEDGER_LOCAL="$LEDGER_DIR/LEDGER.md"
mkdir -p "$LEDGER_DIR"
FIXMAP_FILE="$OUT_DIR/fixmap.json"
if [ -x "$ROOT/bin/scan-fix-commits.sh" ]; then
  "$ROOT/bin/scan-fix-commits.sh" "$STATE" "$REPOS_ROOT/dino-english-ios" "$REPOS_ROOT/dino-english-android" \
    "${CRASH_REPORT_FIX_SCAN_DAYS:-14}" > "$FIXMAP_FILE" 2>"$OUT_DIR/fixmap-scan.log" \
    || echo "  ⚠️ 修复状态反扫失败，台账现状表本轮不更新处置状态列（详见 fixmap-scan.log）"
else
  echo '{"mapped":{},"ambiguous":[],"platform_unavailable":["ios","android"]}' > "$FIXMAP_FILE"
fi
[ -s "$FIXMAP_FILE" ] || echo '{"mapped":{},"ambiguous":[],"platform_unavailable":["ios","android"]}' > "$FIXMAP_FILE"
AMBIG_N="$(jq '.ambiguous | length' "$FIXMAP_FILE" 2>/dev/null || echo 0)"
[ "$AMBIG_N" -gt 0 ] 2>/dev/null && echo "  ⚠️ 反扫发现 $AMBIG_N 个歧义短标识，未自动更新，详见 fixmap.json"

SNAP_NEW="$OUT_DIR/snapshot.json"
"$ROOT/bin/fetch-snapshot-bq.sh" "$OUT_DIR" "$FIXMAP_FILE"
# 数据层失败 = 真失败：没有快照就没有台账、没有变化摘要，发出去只会是错误信息。
[ -s "$SNAP_NEW" ] || fail "数据层未产出 snapshot.json"
jq -e '.ios and .android' "$SNAP_NEW" >/dev/null || fail "快照 JSON 结构不符（缺 ios/android）"

# ── 3b. 分析层：模型跑深度分析（可选，失败只降级）──────
# 额度耗尽 / 超时 / 模型不可用都只让本周少一章分析，不影响数据、台账与投递。
TRIAGE_REPORT="$OUT_DIR/report.md"
ANALYSIS_OK=0
ANALYSIS_SKIP_REASON=""
if [ "${CRASH_REPORT_SKIP_ANALYSIS:-0}" = "1" ]; then
  ANALYSIS_SKIP_REASON="按 CRASH_REPORT_SKIP_ANALYSIS=1 跳过"
  step "分析层：跳过（${ANALYSIS_SKIP_REASON}）"
else
  step "分析层：firebase-crash-triage（模型）"
  # 完整 triage 实测跑 12 分钟以上；给 30 分钟上限防挂死（挂死会导致下周又起一个）。
  TRIAGE_TIMEOUT="${TRIAGE_TIMEOUT:-1800}"
  # set -e 下 run_with_timeout 超时返回 124 会直接杀死脚本；用 || 捕获退出码让降级路径存活。
  run_with_timeout "$TRIAGE_TIMEOUT" "$ROOT/bin/fetch-snapshot.sh" "$OUT_DIR/analysis" full || TRIAGE_RC=$?
  if [ "${TRIAGE_RC:-0}" -eq 124 ]; then
    ANALYSIS_SKIP_REASON="分析超时（${TRIAGE_TIMEOUT}s）"
  elif [ "${TRIAGE_RC:-0}" -ne 0 ]; then
    # 429 额度耗尽走这条路：退出码非 0 且非超时。
    ANALYSIS_SKIP_REASON="模型不可用（退出码 ${TRIAGE_RC:-?}，常见原因：额度耗尽 429）"
  fi
  if [ -s "$OUT_DIR/analysis/report.md" ]; then
    cp "$OUT_DIR/analysis/report.md" "$TRIAGE_REPORT"
    ANALYSIS_OK=1
    echo "  ✅ 分析报告已产出"
  else
    [ -n "$ANALYSIS_SKIP_REASON" ] || ANALYSIS_SKIP_REASON="未产出 report.md"
    echo "  ⚠️ 本周无深度分析：${ANALYSIS_SKIP_REASON}（数据与台账不受影响）"
  fi
fi

# ── 4. 变化检测（纯 jq，不经模型）─────────────────────
step "变化检测"
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

# ── 4b. 台账渲染（design D1/D2/D11，L2 独占产出，L1 不再碰台账）──────────
# 本地源 $STATE/ledger/LEDGER.md：Issue 现状表在跑批期全量重算，变更时间线只追加真正变化。
# 修复状态由 3. 的反扫驱动（bin/scan-fix-commits.sh），不依赖模型推断——
# 反扫在取数之前跑完，其结果已经填进 snapshot.json 的 fix_commit 字段。
step "台账渲染"

# 从本地台账里抽出既有现状表（两个锚点之间的内容），供 render-ledger.sh 做「保留首次纳入/备注」的合并。
PREV_TABLE_FILE="$OUT_DIR/prev-table.md"
LEDGER_BOOTSTRAPPED=0
if [ -s "$LEDGER_LOCAL" ] && grep -q '<!-- LEDGER:ISSUES:BEGIN -->' "$LEDGER_LOCAL"; then
  LEDGER_BOOTSTRAPPED=1
  awk '/<!-- LEDGER:ISSUES:BEGIN -->/{f=1;next}/<!-- LEDGER:ISSUES:END -->/{f=0}f' "$LEDGER_LOCAL" > "$PREV_TABLE_FILE"
else
  : > "$PREV_TABLE_FILE"
fi

LEDGER_TABLE_FILE="$OUT_DIR/ledger-table.md"
LEDGER_TIMELINE_FILE="$OUT_DIR/ledger-timeline-delta.md"
LEDGER_RENDER_OK=0
if [ -x "$ROOT/bin/render-ledger.sh" ]; then
  # 周报文档 URL 此刻还不存在（由 deliver.sh 建文档后才知道），时间线先写占位符
  # __REPORT_URL__，deliver.sh 拿到 URL_REPORT 后统一回填（与卡片 __REPORT_URL__ 占位符同机制）。
  # 8.8：周报投递失败则占位符永远不会被回填——deliver.sh 只在投递成功分支才 fill，
  # 未回填的占位符不会被当成真链接展示（lark 侧就是一段普通文本），不会挂空链接。
  RENDER_OUT="$("$ROOT/bin/render-ledger.sh" "$SNAP_NEW" "$FIXMAP_FILE" "$PREV_TABLE_FILE" \
    <(echo "$DIFF") "$DAY" "__REPORT_URL__" 2>"$OUT_DIR/render-ledger.log")" \
    && LEDGER_RENDER_OK=1 || echo "  ⚠️ 台账渲染失败，本轮跳过台账更新（详见 render-ledger.log）"
  if [ "$LEDGER_RENDER_OK" = "1" ]; then
    printf '%s' "$RENDER_OUT" | awk 'BEGIN{RS="\x1e"} NR==1' > "$LEDGER_TABLE_FILE"
    printf '%s' "$RENDER_OUT" | awk 'BEGIN{RS="\x1e"} NR==2' > "$LEDGER_TIMELINE_FILE"
  fi
else
  echo "  ⚠️ bin/render-ledger.sh 不存在，跳过台账渲染"
fi

if [ "$LEDGER_RENDER_OK" = "1" ]; then
  # 更新本地源：现状表在两个锚点之间原地替换；时间线增量插到 END 锚点之前（只增不改历史）。
  # 本地源里的 __REPORT_URL__ 占位符同样等 deliver.sh 投递成功后回填（8.8：失败则不追加/不回填）。
  LEDGER_TMP="$(mktemp)"
  awk -v tf="$LEDGER_TABLE_FILE" '
    /<!-- LEDGER:ISSUES:BEGIN -->/ { print; while ((getline line < tf) > 0) print line; skip=1; next }
    /<!-- LEDGER:ISSUES:END -->/ { skip=0 }
    skip { next }
    { print }
  ' "$LEDGER_LOCAL" > "$LEDGER_TMP" 2>/dev/null || cp "$LEDGER_LOCAL" "$LEDGER_TMP"
  if [ -s "$LEDGER_TIMELINE_FILE" ]; then
    LEDGER_TMP2="$(mktemp)"
    awk -v tlf="$LEDGER_TIMELINE_FILE" '
      /<!-- LEDGER:TIMELINE:END -->/ { while ((getline line < tlf) > 0) print line }
      { print }
    ' "$LEDGER_TMP" > "$LEDGER_TMP2" 2>/dev/null && mv "$LEDGER_TMP2" "$LEDGER_TMP"
  fi
  mv "$LEDGER_TMP" "$LEDGER_LOCAL"
  echo "  ✅ 本地台账已更新：${LEDGER_LOCAL}（__REPORT_URL__ 占位符待投递成功后回填）"
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
  step "主力版本放量（bq）"
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
  IOS_TOP2_VERS=""; AND_TOP2_VERS=""   # 供 6. 性能段复用同一批主力版本（不重复解析）
  for entry in "iOS|$PROJECT.firebase_sessions.com_prime_dino_english_IOS_REALTIME|$PROJECT.firebase_crashlytics.com_prime_dino_english_IOS_REALTIME" \
               "Android|$PROJECT.firebase_sessions.com_prime_dino_english_ANDROID_REALTIME|$PROJECT.firebase_crashlytics.com_prime_dino_english_ANDROID_REALTIME"; do
    IFS='|' read -r pname stbl ctbl <<< "$entry"
    while IFS=, read -r ver sess dev; do
      [ -n "$ver" ] || continue
      if [ "$pname" = "iOS" ]; then IOS_TOP2_VERS="${IOS_TOP2_VERS}${ver}
"; else AND_TOP2_VERS="${AND_TOP2_VERS}${ver}
"; fi
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

# ── 5b. 性能段（design D8/D9，L2 独占，不进台账，不出根因）────────────────
# 复用 5. 已解析出的主力版本（会话量 top2），复用 L1 现有 SQL（perf-traces/screens/network.sql），
# 只改窗口天数为 WEEK_DAYS——同一份 SQL 两条链路各自套用不同窗口，口径一致（design D9）。
# 只给趋势 / 可定位对象 / 下一步取证方向，不出根因与修复方案（硬约束，见 CLAUDE.md）。
PERF_OK=0
IOS_PERF_TBL="$PROJECT.firebase_performance.com_prime_dino_english_IOS"
AND_PERF_TBL="$PROJECT.firebase_performance.com_prime_dino_english_ANDROID"
PERF_ROWS=""    # TSV：平台/版本/启动P50/启动P95/慢帧最差页/慢帧率/冻结率/接口错误率（列以制表符分隔）
# 周环比基准（7.4）：按 (平台,版本) 存最近几轮的性能快照，供 WoW 对比；无基准则显式标明而非显示零变化。
PERF_HISTORY="$STATE/perf-history.jsonl"
PERF_HISTORY_KEEP="${CRASH_REPORT_PERF_HISTORY_KEEP:-12}"   # 12 周，约一季度
if [ "$ADOPT_OK" = "1" ]; then
  step "性能段（bq，窗口 ${WEEK_DAYS}d）"
  perf_row() { # $1=平台标签 $2=perf表 $3=版本 → 一行 TSV（失败字段留空，由调用方判定缺数原因）
    local pname="$1" tbl="$2" ver="$3" traces screens net p50 p95 wscreen wslow frozen neterr
    traces="$(sed -e "s|{{TABLE}}|$tbl|g" -e "s|{{DAYS}}|$WEEK_DAYS|g" -e "s|{{VERSIONS}}|\"$ver\"|g" \
      "$SQL_DIR/perf-traces.sql" | bq query --use_legacy_sql=false --format=csv 2>/dev/null | tail -n +2 || true)"
    screens="$(sed -e "s|{{TABLE}}|$tbl|g" -e "s|{{DAYS}}|$WEEK_DAYS|g" -e "s|{{VERSIONS}}|\"$ver\"|g" \
      "$SQL_DIR/perf-screens.sql" | bq query --use_legacy_sql=false --format=csv 2>/dev/null | tail -n +2 || true)"
    net="$(sed -e "s|{{TABLE}}|$tbl|g" -e "s|{{DAYS}}|$WEEK_DAYS|g" -e "s|{{VERSIONS}}|\"$ver\"|g" \
      "$SQL_DIR/perf-network.sql" | bq query --use_legacy_sql=false --format=csv 2>/dev/null | tail -n +2 || true)"
    p50="$(printf '%s\n' "$traces" | grep '^_app_start,' | cut -d, -f3 | head -1)"
    p95="$(printf '%s\n' "$traces" | grep '^_app_start,' | cut -d, -f4 | head -1)"
    wscreen="$(printf '%s\n' "$screens" | head -1 | cut -d, -f1)"
    wslow="$(printf '%s\n' "$screens" | head -1 | cut -d, -f3)"
    frozen="$(printf '%s\n' "$screens" | head -1 | cut -d, -f4)"
    neterr="$(printf '%s\n' "$net" | awk -F, '{e+=$5; n+=$2} END{if(n>0) printf "%.2f", e/n*100}')"
    # 三态缺数判定（design 缺数三态，简化为周报够用的两态）：表不存在/查询失败 → 空值走「⚠️ 数据未同步」；
    # 表存在但该版本无样本（HAVING 阈值过滤掉）→ 空值走「该版本无数据」。两者在渲染时统一显示 —，
    # 性能段不做告警判定（design D8：只给趋势，不触发红黄绿），故不需要像 L1 那样细分三态文案。
    PERF_ROWS="${PERF_ROWS}${pname}	${ver}	${p50:-—}	${p95:-—}	${wscreen:-—}	${wslow:-—}	${frozen:-—}	${neterr:-—}
"
    # WoW（7.4）：查上周同 (平台,版本) 的 P95 基准，有则标变化方向（箭头跟数值、颜色跟好坏，
    # 启动耗时越小越好故数值增大标↑变差），无基准则显式标「本轮建立」而非显示零变化。
    local prev_p95 wow=""
    if [ -s "$PERF_HISTORY" ]; then
      prev_p95="$(jq -rs --arg p "$pname" --arg v "$ver" \
        '[.[] | select(.platform==$p and .version==$v)] | last | .p95 // empty' "$PERF_HISTORY" 2>/dev/null || true)"
    fi
    if [ -n "${prev_p95:-}" ] && [ -n "$p95" ]; then
      local delta; delta="$(awk -v a="$p95" -v b="$prev_p95" 'BEGIN{printf "%.0f", a-b}' 2>/dev/null || true)"
      if [ -n "$delta" ]; then
        if [ "$delta" -gt 0 ] 2>/dev/null; then wow="（WoW P95 +${delta}ms↑ 变差）"
        elif [ "$delta" -lt 0 ] 2>/dev/null; then wow="（WoW P95 ${delta}ms↓ 变好）"
        else wow="（WoW P95 持平）"; fi
      fi
    else
      wow="（无上周基准，本轮建立）"
    fi
    echo "  ${pname} ${ver}：启动 P50 ${p50:-—}ms / P95 ${p95:-—}ms ${wow} · 慢帧最差页 ${wscreen:-—} ${wslow:-—}% · 冻结 ${frozen:-—}% · 接口错误率 ${neterr:-—}%"
    # 落一行到历史（本轮快照，供下周环比），只在拿到值时写，避免用空值污染基准
    if [ -n "$p95" ] || [ -n "$p50" ]; then
      jq -nc --arg p "$pname" --arg v "$ver" --arg d "$DAY" --arg p50 "${p50:-}" --arg p95 "${p95:-}" \
        '{platform:$p, version:$v, day:$d, p50:($p50|tonumber? // null), p95:($p95|tonumber? // null)}' >> "$PERF_HISTORY"
    fi
  }
  PERF_OK=1
  while IFS= read -r v; do [ -n "$v" ] && perf_row "iOS" "$IOS_PERF_TBL" "$v"; done <<< "$IOS_TOP2_VERS"
  while IFS= read -r v; do [ -n "$v" ] && perf_row "Android" "$AND_PERF_TBL" "$v"; done <<< "$AND_TOP2_VERS"
  # 保留最近 N 条同 (platform,version) 记录：避免无限增长
  if [ -s "$PERF_HISTORY" ]; then
    PERF_HIST_TMP="$(mktemp)"
    jq -sc --argjson keep "$PERF_HISTORY_KEEP" \
      'group_by(.platform + "|" + .version) | map(.[-$keep:]) | flatten | .[] ' \
      "$PERF_HISTORY" 2>/dev/null > "$PERF_HIST_TMP" && mv "$PERF_HIST_TMP" "$PERF_HISTORY" || rm -f "$PERF_HIST_TMP"
  fi
else
  echo "--- ⚠️ bq 不可用，跳过性能段（崩溃段变化摘要不受影响，design 缺数不告警）---"
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
  # 口径已从 MCP topIssues（只含 OPEN）换成 BigQuery 事件级（含已关闭 issue），
  # 再写 OPEN 就是错的——已关闭但仍在崩的 issue 正是当初迁移的动机。
  printf '**%s** — FATAL issue %s 个 / 近 7 天 %s 事件\n' "$name" "$total" "$events"
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
  CHANGES_MD="$(printf '**✅ 本周无新增 / 暴涨 / 消失的 issue**\n\niOS FATAL issue %s 个 · Android FATAL issue %s 个（近 7 天）' \
    "$(echo "$DIFF" | jq -r '.ios.total')" "$(echo "$DIFF" | jq -r '.android.total')")"
fi

IOS_BR="$(git -C "$REPOS_ROOT/dino-english-ios" rev-parse --abbrev-ref HEAD)"
AND_BR="$(git -C "$REPOS_ROOT/dino-english-android" rev-parse --abbrev-ref HEAD)"
# 口径行同时承担「本周有没有分析」的告知——卡片读者多数不会点进文档，
# 缺分析必须在卡片上就看得见，否则会被读成「本周无异常」。
ANALYSIS_NOTE="根因与修复方案见完整报告（**未经人工复核**，落地前须验证）"
[ "$ANALYSIS_OK" = "1" ] || ANALYSIS_NOTE="⚠️ **本周无深度分析**（${ANALYSIS_SKIP_REASON}）；数据与台账不受影响"
NOTE_MD="$(printf '变化摘要口径：BigQuery 事件级（含已关闭 issue，全版本），近 %s 天窗，**纯脚本取数不经模型**。\n取数区间 %sd：%s\n主力版本 = 近 %s 天会话量 top2（日报看的是「版本号最新的 2 个版本」，两者互补，不可混比）。\n崩溃率 = 事件数/会话数（非 crash-free）· 对照分支：iOS %s · Android %s\n%s' \
  "$WEEK_DAYS" "$WEEK_DAYS" "$WIN_COMPACT" "$WEEK_DAYS" "$IOS_BR" "$AND_BR" "$ANALYSIS_NOTE")"

# 主力版本表（markdown 与卡片共用同一批数据）
adopt_md() {
  [ -n "$ADOPT_ROWS" ] || { printf '（本次未取到放量数据）\n'; return 0; }
  printf '| 平台 | 版本 | 会话 | 设备 | 崩溃事件 | 崩溃率 |\n|---|---|---|---|---|---|\n'
  printf '%s' "$ADOPT_ROWS" | awk -F'\t' 'NF>=6{printf "| %s | %s | %s | %s | %s | %s |\n",$1,$2,$3,$4,$5,$6}'
}

# 性能段表（design D8/D9：只给趋势与对象，不出根因；不进台账，只在周报文档呈现）
perf_md() {
  if [ "$PERF_OK" != "1" ]; then
    printf '（性能数据源不可用，跳过本段；崩溃段变化摘要不受影响）\n'; return 0
  fi
  [ -n "$PERF_ROWS" ] || { printf '（本次未取到性能数据）\n'; return 0; }
  printf '| 平台 | 版本 | 启动 P50 | 启动 P95 | 慢帧最差页 | 慢帧率 | 冻结率 | 接口错误率 |\n|---|---|---|---|---|---|---|---|\n'
  printf '%s' "$PERF_ROWS" | awk -F'\t' 'NF>=8{printf "| %s | %s | %sms | %sms | %s | %s%% | %s%% | %s%% |\n",$1,$2,$3,$4,$5,$6,$7,$8}'
}

MSG="$(cat <<MSG_END
**📊 崩溃周报 · ${DAY} ${TS_HM}${WEEK_TAG:+ $WEEK_TAG}**

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
  --arg hc "$HEADER_COLOR" --arg ht "📊 崩溃周报 · ${DAY} ${TS_HM}${WEEK_TAG:+ $WEEK_TAG}" \
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
  printf '## 三、性能（近 %s 天，主力版本，双端分列）\n\n' "$WEEK_DAYS"
  printf '> 取数区间 %sd：**%s**（与本文档同一套跑批时刻锚定，与一/二段共用）。\n' "$WEEK_DAYS" "$WIN_FULL"
  printf '> 性能是连续指标、无追踪 ID，**只给趋势、可定位对象与下一步取证方向，不出根因与修复方案**（硬约束）。\n'
  printf '> **本段不写入台账**（design D8：台账只收有唯一标识、可跨周追踪的崩溃 issue）。\n\n'
  perf_md
  printf '\n> 与日报口径互补但不可混比：日报是日维度当期值，本段是周维度趋势快照，窗口天数不同。\n\n'
  printf '## 四、口径\n\n%s\n' "$NOTE_MD"
  # 数据/分析分层的可见化：读者必须能一眼看出「本周没有根因分析」是模型不可用，
  # 而不是「本周没问题」。缺分析和无异常是两件完全不同的事。
  if [ "$ANALYSIS_OK" = "1" ]; then
    printf '\n> 分析层：✅ 本周含深度分析（根因与修复方案**未经人工复核**，落地前须验证）。\n'
  else
    printf '\n> 分析层：⚠️ **本周无深度分析** — %s。\n' "$ANALYSIS_SKIP_REASON"
    printf '> 以上数据、台账与变化检测均由 BigQuery + git 纯脚本产出，**不受影响**；\n'
    printf '> 缺的只是根因与修复方案。额度恢复后重跑本周即可补齐。\n'
  fi
} > "$REPORT"

# ── 7. 产出投递清单（发消息/建文档由 bin/deliver.sh 用 lark-cli 执行）──
# send 只区分「正式跑批」与「DRY RUN」，**与本周有无变化无关**。
# 这里曾写着「无变化不发（避免播报噪音化）」，2026-08-20 实测证伪：代码从来没有
# 判断过 WEEK_STATE，平稳周照样发卡片、照样建文档。注释与 CLAUDE.md 都描述了
# 一个不存在的行为——比代码错更隐蔽，因为下一个人会照着它做判断。
# 平稳周仍然投递是对的：周报正文有卡片装不下的性能趋势与版本明细，
# 而「本周无异常」本身就是要让人看见的结论。
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
# 文档投递条件：只要有周报正文就建文档。
#
# 这里曾有一条「平稳周且无根因报告 → 只发卡片不建文档（内容与卡片完全重复）」的分支，
# 2026-08-20 实测删除：数据/分析分层（D12）之后前提不再成立。周报正文有三样卡片
# 没有的东西——性能段趋势与 WoW、主力版本明细、取数区间双时区标注；卡片受 CardKit
# 表格能力限制装不下。跳过建文档会让「本周平稳」的那几周**永久丢失性能趋势记录**，
# 而平稳周恰恰是趋势最该被留档的时候（异常周反正有人盯）。
if [ -s "$TRIAGE_REPORT" ]; then
  # 有分析报告：用 triage 产出的完整版（含根因与修复方案）
  cp "$TRIAGE_REPORT" "$PUBLISH_DIR/docs/weekly.md"; REPORT_FILE="$PUBLISH_DIR/docs/weekly.md"
elif [ -s "$REPORT" ]; then
  # 无分析报告（额度耗尽 / 超时 / 显式跳过）：投递数据层周报本体，
  # 正文里已由分析层标注说明缺的是什么。
  cp "$REPORT" "$PUBLISH_DIR/docs/weekly.md"; REPORT_FILE="$PUBLISH_DIR/docs/weekly.md"
fi

# 修复清单按平台分组（纯排版，不改条目内容）：模型产出的清单是 iOS/Android 混排，
# 读者分派任务时得逐条辨认平台。改 prompt 不可靠（模型未必照办、每轮结果漂移），
# 排版是确定性问题，交给脚本。失败不影响投递——排版是锦上添花，不能拖垮主链路。
if [ -n "$REPORT_FILE" ] && [ -x "$ROOT/bin/split-fix-list.py" ]; then
  "$ROOT/bin/split-fix-list.py" "$REPORT_FILE" 2>/dev/null \
    && echo "  ✅ 修复清单已按平台分组" \
    || echo "  ⚠️ 修复清单分组跳过（不影响投递）"
fi

# 彩色版：与日报同一套配色（表头蓝底、偶数行灰底、状态词按语义上色）。
# 周报正文是 triage 产出的 markdown，走 md2docx.py 通用转换，不单独写渲染器。
if [ -n "$REPORT_FILE" ] && [ -x "$ROOT/bin/md2docx.py" ]; then
  if "$ROOT/bin/md2docx.py" "$REPORT_FILE" --title "崩溃周报 · $DAY $TS_HM" \
       --head-bg "${CRASH_REPORT_XC_HEAD:-light-blue}" --zebra "${CRASH_REPORT_XC_ZEBRA:-light-gray}" \
       > "$PUBLISH_DIR/docs/weekly.xml" 2>/dev/null; then
    REPORT_XML="$PUBLISH_DIR/docs/weekly.xml"
  fi
fi

# 周报每次新建独立文档（快照性质，要留痕可跨版本 diff），不像日报覆盖同一份；
# 报告文档的 URL 由 agent 用 docx.builtin.import 创建后回填到卡片 __REPORT_URL__ 再发送；
# index_append 由 agent 在文档创建成功后追加一行（url = 刚创建的文档 URL）。
#
# 台账同步产物：现状表 + 时间线增量拷进 publish 目录，供 deliver.sh 走 sync_ledger()
# 定点更新飞书文档（block_replace 现状表 + append 时间线，绝不 overwrite，见 deliver.sh D2/D3）。
LEDGER_TABLE_PUB=""; LEDGER_TIMELINE_PUB=""
if [ "${LEDGER_RENDER_OK:-0}" = "1" ] && [ -s "$LEDGER_TABLE_FILE" ]; then
  cp "$LEDGER_TABLE_FILE" "$PUBLISH_DIR/docs/ledger-table.md"
  LEDGER_TABLE_PUB="$PUBLISH_DIR/docs/ledger-table.md"
  if [ -s "$LEDGER_TIMELINE_FILE" ]; then
    cp "$LEDGER_TIMELINE_FILE" "$PUBLISH_DIR/docs/ledger-timeline-delta.md"
    LEDGER_TIMELINE_PUB="$PUBLISH_DIR/docs/ledger-timeline-delta.md"
  fi
fi

jq -n \
  --arg chat "$CHAT_ID" \
  --arg day2 "$DAY" \
  --arg run "$TS" \
  --arg send "$SEND_FLAG" \
  --arg msg  "$PUBLISH_DIR/message.md" \
  --arg card "$PUBLISH_DIR/card.json" \
  --arg report "$REPORT_FILE" \
  --arg reportxml "$REPORT_XML" \
  --arg title "崩溃周报 · $DAY $TS_HM" \
  --arg idx "${CRASH_REPORT_ARCHIVE:-$STATE/report-index.jsonl}" \
  --arg day "$DAY" \
  --argjson ios "$(echo "$DIFF" | jq '.ios.total')" \
  --argjson and "$(echo "$DIFF" | jq '.android.total')" \
  --arg ledger_table "$LEDGER_TABLE_PUB" \
  --arg ledger_timeline "$LEDGER_TIMELINE_PUB" \
  --arg ledger_local "$LEDGER_LOCAL" \
  '{type:"weekly", day:$day2, run_id:$run, chat_id:$chat, send:($send=="true"),
    message_file:$msg, card_file:$card,
    create_doc:(if $report != "" then {file:$report, xml_file:$reportxml, title:$title, label:"周报"} else null end),
    archive_append:(if $report != "" then {jsonl_file:$idx, type:"weekly", day:$day, ios:$ios, android:$and} else null end),
    ledger_sync:(if $ledger_table != "" then {table_file:$ledger_table, timeline_file:$ledger_timeline, local_file:$ledger_local} else null end)}' \
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

# latest 软链指向本次跑批产物，供 2.4/2.5 回归对比与人工排查使用（ln -sfn 覆盖式，指向相对路径避免机器间路径漂移）
ln -sfn "$TS" "$STATE/runs/$DAY/L2/latest"

# 同 L1：按前缀删会漏掉 bq-stderr-*.log，改整目录按 mtime 清（两边各清一次，幂等）
find "$STATE/logs" -type f -mtime +60 -delete 2>/dev/null || true
# -maxdepth 1 限定顶层：这是旧平铺布局的遗留清理，不带深度会递归进 runs/ 与 backup/ 误删同名文件
find "$STATE" -maxdepth 1 -name 'snapshot-*.json' -mtime +60 -delete 2>/dev/null || true
cleanup_old_runs "$STATE"
echo "=== 完成，报告：$REPORT ==="
