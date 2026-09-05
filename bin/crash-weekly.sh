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
RUN_ID="$TS"
# 审计事件流（change crash-perf-execution-audit-log）：命名同 logs/ 的 weekly- 前缀，
# 与 L1 共用 audit/ 目录，不带前缀会让同日重复检测把对方误判成重复
AUDIT_DIR="$STATE/audit"
AUDIT_FILE="$AUDIT_DIR/weekly-$RUN_ID.events.jsonl"
mkdir -p "$AUDIT_DIR"
# export：子进程 fetch-snapshot-bq.sh 的 bq.call 事件汇入同一条时间线（父进程等它跑完，
# 无并发写；seq 取文件行数，跨进程天然单调）。函数不跨进程，环境变量跨。
export AUDIT_FILE RUN_ID

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
# ⚠️ ALERTED 只在主进程有效：命令替换 / 管道都在子 shell 里跑，那里的 ALERTED=1 传不回来。
# 去重改用文件标记，跑批开始时清一次（起因见 crash-daily.sh 同处注释）。
# 五个共享函数（step / alert_once / err_stack / on_err / fail）已收口到 bin/lib/common.sh。
# 两条链路仅有的差异用下面四个变量表达——此前为这三处不同，整整 5 个函数各存了一份。
ALERT_FLAG="$STATE/.alerted-weekly"
ALERT_SOURCE="weekly"
ALERT_RUN_ID="$TS"
HEALTH_FILE="$HEALTH"
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
. "$ROOT/bin/lib/csv.sh"   # bq CSV 解析唯一入口（csv2tsv），L1/L2 共用
. "$ROOT/bin/lib/query.sh" # SQL 占位符替换唯一入口（q_render），漏传占位符当场失败
# 核心层（纯函数），与 L1 共用同一份实现——此前 _fmt / _until_epoch / win_* / stale_days
# 在两个脚本里各存了一份，其中 stale_days 逐字节相同。
for _c in format verdict version cache; do
  # shellcheck disable=SC1090
  . "$ROOT/bin/lib/core/${_c}.sh" || { echo "❌ 核心层缺失：bin/lib/core/${_c}.sh" >&2; exit 1; }
done
# bq 查询唯一通道（findings F1/F5 收口）：本文件十处直连全部改走 bqq——
# 直连绕过 CRASH_REPORT_BQ_CACHE，L2 的三层等价性 diff 因此永远不为空。
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
_PRIOR_RUNS="$(find "$AUDIT_DIR" -maxdepth 1 -name "weekly-${RUN_ID%%-*}-*.events.jsonl" ! -name "weekly-${RUN_ID}.events.jsonl" 2>/dev/null | sed 's|.*/||; s|\.events\.jsonl$||' | sort | paste -sd, - || true)"
[ -z "$_PRIOR_RUNS" ] || audit duplicate_run "" "$(jq -cn --arg p "$_PRIOR_RUNS" '{prior_runs:$p}')"

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

# ── 分析层实际执行者（change crash-report-issue-identity，spec crash-perf-data-analysis-split）──
# ⛔ 只写「模型产出」不够：调用可能经本机代理转发到第三方端点，**请求的模型名与实际执行的模型名
#    不必相同**。2026-09-01 实测生产机：ANTHROPIC_BASE_URL 指向本机 cc-switch，上游是
#    azure-foundry，代理日志里 request_model=claude-opus-4-8 实际由 gpt-5.6-terra 执行，
#    且 opus/sonnet/haiku/fable 四档全部映射到同一个模型。而分析层 prompt 与台账的证据分级
#    （✅钻取确认 / ⚠️聚合推断）是按特定模型的行为调校的——读者若默认根因出自被请求的那个模型，
#    「未经人工复核」这句标注就没有起到它该起的作用。
# ⚠️ 只能取**运行环境的声明**，不是上游确认：代理可把请求改写并转发至任意上游，脚本侧无从证实。
# ⛔ 取不到时如实写「无法确定」，**不得回落成请求时用的模型名**，更不得表述为某个厂商的模型。
# ⚠️ 全程不失败：读不到配置只降级为「无法确定」，不得成为整跑失败的原因。
model_provenance() { # stdout: 一行说明
  local _cfg="$HOME/.claude/settings.json" _base _req _act _host
  _base="$(jq -r '.env.ANTHROPIC_BASE_URL // ""'                "$_cfg" 2>/dev/null || true)"
  _req="$(jq  -r '.env.ANTHROPIC_DEFAULT_OPUS_MODEL // ""'      "$_cfg" 2>/dev/null || true)"
  _act="$(jq  -r '.env.ANTHROPIC_DEFAULT_OPUS_MODEL_NAME // ""' "$_cfg" 2>/dev/null || true)"
  if [ -z "$_base" ] && [ -z "$_act" ]; then
    printf '⚠️ **无法确定**（运行环境未声明端点与模型映射）'
    return 0
  fi
  _host="$_base"
  [ -n "$_host" ] || _host="（未声明，按默认端点）"
  if [ -n "$_act" ] && [ -n "$_req" ] && [ "$_act" != "$_req" ]; then
    printf '端点 `%s` · 模型映射 `%s` → `%s`' "$_host" "$_req" "$_act"
  elif [ -n "$_act" ]; then
    printf '端点 `%s` · 模型 `%s`' "$_host" "$_act"
  else
    printf '端点 `%s` · 模型未声明，**无法确定实际执行者**' "$_host"
  fi
  return 0
}

# ── 3b. 分析层：模型跑深度分析（可选，失败只降级）──────
# 额度耗尽 / 超时 / 模型不可用都只让本周少一章分析，不影响数据、台账与投递。
TRIAGE_REPORT="$OUT_DIR/report.md"
ANALYSIS_OK=0
ANALYSIS_SKIP_REASON=""
# ⛔ 补救建议**必须跟着实际原因走**，不能写死。原文案无论何种原因都说「额度恢复后重跑」，
#    而显式跳过与超时都**与额度无关**——2026-08-24 实测产出过自相矛盾的两行：
#    「原因：按 CRASH_REPORT_SKIP_ANALYSIS=1 跳过」+「额度恢复后重跑本周即可补齐」。
#    这与 CLAUDE.md 记的 NON_FATAL「线上仍为零上报」是同一类：**静态文案与实况相反**。
ANALYSIS_FIX_HINT=""
if [ "${CRASH_REPORT_SKIP_ANALYSIS:-0}" = "1" ]; then
  ANALYSIS_SKIP_REASON="按 CRASH_REPORT_SKIP_ANALYSIS=1 跳过"
  ANALYSIS_FIX_HINT="这是显式跳过（调试/验收常用），**与额度无关**；去掉该环境变量重跑即可补齐。"
  step "分析层：跳过（${ANALYSIS_SKIP_REASON}）"
else
  step "分析层：firebase-crash-triage（模型）"
  # 完整 triage 实测跑 12 分钟以上；给 30 分钟上限防挂死（挂死会导致下周又起一个）。
  TRIAGE_TIMEOUT="${TRIAGE_TIMEOUT:-1800}"
  # set -e 下 run_with_timeout 超时返回 124 会直接杀死脚本；用 || 捕获退出码让降级路径存活。
  run_with_timeout "$TRIAGE_TIMEOUT" "$ROOT/bin/fetch-snapshot.sh" "$OUT_DIR/analysis" full || TRIAGE_RC=$?
  if [ "${TRIAGE_RC:-0}" -eq 124 ]; then
    ANALYSIS_SKIP_REASON="分析超时（${TRIAGE_TIMEOUT}s）"
    ANALYSIS_FIX_HINT="**与额度无关**；调大 TRIAGE_TIMEOUT 或减少 issue 数后重跑本周即可补齐。"
  elif [ "${TRIAGE_RC:-0}" -ne 0 ]; then
    # ⛔ **从日志读真实错误码，不按退出码猜**。原文案一律写「常见原因：额度耗尽 429」，
    #    而 2026-08-24 实测真实是 **529 Overloaded**（服务端过载，与额度无关）——
    #    猜错的代价是读者按「等额度恢复」处理，正确动作却是「立刻重试」（失效模式 F29 同源）。
    # ⚠️ 扫**全部**重试日志而不是最新那个：重试进行中时最新文件可能为空，
    #    只看它会把已知的 529 误判成「未能识别」（实测踩到）。
    # ⛔ `|| true` 不可省：grep 无匹配返回 1，而「无匹配」是正常路径（F31）。
    _alog="$OUT_DIR/analysis/agent"
    _atxt="$(cat "${_alog}"*.log 2>/dev/null | tail -c 8000 || true)"
    _acode="$(printf '%s' "$_atxt" | grep -oE 'API Error: [0-9]{3}' | grep -oE '[0-9]{3}' | tail -1 || true)"
    # ⛔ **无 HTTP 码的失败也必须能被识别**。2026-08-28 ~ 09-01 实测：ANTHROPIC_BASE_URL 指向的
    #    本机代理（cc-switch，127.0.0.1:15721）未运行时，日志只有
    #    `API Error: Connection refused …（ConnectionRefused）`，一个数字都没有，
    #    于是落进兜底分支写「未能识别 API 错误码」——而正确动作是「拉起本地代理」，
    #    与「等额度恢复」南辕北辙。与 F29 同源：**猜错原因比不给原因更贵**。
    # ⚠️ 判断放在 `if` 条件位上，grep 无匹配返回 1 不触发 ERR trap（F31 指的是命令位）。
    if printf '%s' "$_atxt" | grep -q 'ConnectionRefused\|Connection refused'; then
      ANALYSIS_SKIP_REASON="模型端点连接被拒（本机代理未运行）"
      ANALYSIS_FIX_HINT="**与额度无关**；检查 ANTHROPIC_BASE_URL 指向的本机代理是否在监听（fetch-snapshot.sh 已尝试自动拉起，仍失败说明拉起也没成功），恢复后重跑本周即可补齐。"
    else
    case "${_acode:-}" in
      (429) ANALYSIS_SKIP_REASON="模型额度耗尽（API 429）"
            ANALYSIS_FIX_HINT="额度恢复后重跑本周即可补齐。" ;;
      (529) ANALYSIS_SKIP_REASON="模型服务端过载（API 529）"
            ANALYSIS_FIX_HINT="**与额度无关**，服务端临时问题；稍后重跑本周即可补齐（可查 status.claude.com）。" ;;
      (5??) ANALYSIS_SKIP_REASON="模型服务端错误（API ${_acode}）"
            ANALYSIS_FIX_HINT="**与额度无关**；稍后重跑本周即可补齐。" ;;
      (4??) ANALYSIS_SKIP_REASON="模型请求被拒（API ${_acode}）"
            ANALYSIS_FIX_HINT="需看 ${_alog}-*.log 定位，⛔ 不要默认当成额度问题。" ;;
      (*)   ANALYSIS_SKIP_REASON="模型不可用（退出码 ${TRIAGE_RC:-?}）"
            ANALYSIS_FIX_HINT="未能从日志识别 API 错误码，需看 ${_alog}-*.log 定位，⛔ 不要默认当成额度问题。" ;;
    esac
    fi
  fi
  if [ -s "$OUT_DIR/analysis/report.md" ]; then
    cp "$OUT_DIR/analysis/report.md" "$TRIAGE_REPORT"
    ANALYSIS_OK=1
    echo "  ✅ 分析报告已产出"
  else
    [ -n "$ANALYSIS_SKIP_REASON" ] || ANALYSIS_SKIP_REASON="未产出 report.md"
    [ -n "${ANALYSIS_FIX_HINT:-}" ] || ANALYSIS_FIX_HINT="退出码为 0 但产物缺失，属未预期情况；看分析日志定位后重跑。"
    echo "  ⚠️ 本周无深度分析：${ANALYSIS_SKIP_REASON}（数据与台账不受影响）"
  fi
fi

# ── 事实层缓存新鲜度断言 ──────────────────────────────────────────
# 取舍与理由见 crash-daily.sh 同名段（只告警不失败 / 只能对落盘产物断言）。
# L2 比 L1 更该说：台账由 L2 独占产出，事实层滞后直接体现在台账的**事件明细**上。
# ⚠️ 判据是快照在不在，不是 ANALYSIS_OK：full 模式下 report.md 缺失但 snapshot.json 已写出
#    是实测存在的组合（2026-08-23），那种情况事实层同样该被断言。
# ⛔ 断言必须放 `if` 条件位（errtrace 会把 ERR trap 传进命令替换的子 shell，`||` 兜不住）——
#    完整解释见 crash-daily.sh 同名段。
FACT_CACHE_NOTE=""
_fc_snap="$OUT_DIR/analysis/snapshot.json"
_fc_log="$OUT_DIR/analysis/fact-cache-assert.log"
if [ -s "$_fc_snap" ] && [ -x "$ROOT/bin/test/assert-fact-cache.sh" ] \
   && ! "$ROOT/bin/test/assert-fact-cache.sh" "$_fc_snap" > "$_fc_log" 2>&1; then
  # ⛔ 「无法判定」≠「判定为陈旧」——完整解释与 2026-09-05 的假告警实例见 crash-daily.sh 同名段。
  # ⚠️ 数去重后的 issue 个数，不是 ❌ 行数；`grep -oE` 无匹配返回 1，先取串再判空避开 pipefail。
  _fc_ids="$(grep -oE '^❌ [0-9a-f]{8} ' "$_fc_log" 2>/dev/null | sort -u || true)"
  _fc_n=0
  [ -n "$_fc_ids" ] && _fc_n="$(printf '%s\n' "$_fc_ids" | wc -l | tr -d ' ')"
  if [ "$_fc_n" -gt 0 ]; then
    _fc_day="$(grep -oE 'last_synced=[0-9]{4}-[0-9]{2}-[0-9]{2}' "$_fc_log" | sort | head -1 | cut -d= -f2 || true)"
    _fc_since=""
    [ -n "$_fc_day" ] && _fc_since="，最早停在 ${_fc_day}"
    FACT_CACHE_NOTE="$(printf '\n🟡 **事实层缓存未刷新** — %s 个 issue 的 last_synced 不是本轮%s；台账的**事件明细**据此滞后（现状表的计数仍来自本轮 BigQuery，不受影响）。补齐：CRASH_REPORT_FORCE_REFETCH=1 重跑本周。' "$_fc_n" "$_fc_since")"
    echo "  ⚠️ 事实层缓存断言未通过（${_fc_n} 个 issue），详情："
  else
    _fc_why="$(sed -n '1s/^❌ *//p' "$_fc_log")"
    [ -n "$_fc_why" ] || _fc_why="断言未产出可识别的原因"
    FACT_CACHE_NOTE="$(printf '\n🟡 **事实层本轮未校验** — %s。⛔ 这是「没查成」不是「已确认陈旧」，缓存新鲜度未知，台账的事件明细本轮无法保证是最新。' "$_fc_why")"
    echo "  ⚠️ 事实层断言无法执行：${_fc_why}"
  fi
  sed 's/^/    /' "$_fc_log"
fi

# ⚠️ 本块原在台账渲染段（第 5 组）内，2026-09-01 上移至此：变化检测要读同一份基准判「回归」，
#    而顶层「先用后定」会被 check-scripts 第 7 项拦下。⛔ 只移动位置，内容与时序语义未变
#    （SEEN_FILE 的提升仍在跑批收尾，见文件末尾）。
# ── 生命周期基准（change crash-report-correctness-fixes，design D4）────────────
# spec crash-perf-issue-lifecycle 要求三态（新增 / 回归 / 长期），台账此前只有两态。
# ⛔ **不复用 L1 的 issue_seen**：L1 取数走 `crash-issues.sql`（**带版本过滤**，只看最新 2 版），
#    L2 走 `crash-issues-all.sql`（**刻意不带**，台账要跨版本追踪）。只在老版本上发生的 issue
#    从不进 L1 基准，复用会让它们每周都被标成「🆕新增」——比现在的「全是遗留」更糟，因为它是错的。
# 结构：{"<32位id>": {"first":"YYYY-MM-DD","last":"YYYY-MM-DD"}}，保留 90 天。
SEEN_FILE="$STATE/issue-seen.json"
SEEN_KEEP_DAYS="${CRASH_REPORT_SEEN_KEEP_DAYS:-90}"
SEEN_NEXT_FILE="$OUT_DIR/issue-seen-next.json"
[ -s "$SEEN_FILE" ] || echo '{}' > "$SEEN_FILE"

# ── 4. 变化检测（纯 jq，不经模型）─────────────────────
step "变化检测"
# 首跑无基准时不能把全部 issue 当「新增」播报（2026-08-07 实测刷出 26 条）。
# 标记为建立基线，只报总数。
IS_BASELINE=0
if [ ! -f "$SNAP_LAST" ]; then
  IS_BASELINE=1
  echo '{"ios":[],"android":[]}' > "$SNAP_LAST"
fi

# ⚠️ 「不在上一轮快照里」有两种情形，此前挤在同一个 new 桶里（change crash-report-issue-identity）：
#    真正的新 issue，和**曾出现过、上一轮消失、本轮回来**的回归。两者处置方式不同——
#    回归意味着修复失效或场景重现。台账用 90 天基准早已能判三态，而段一只跟上一轮快照比，
#    于是同一轮跑批可以自相矛盾（2026-08-31 实测：`2a800b33` 台账标🆕新增、日报标长期）。
# ⛔ 复用台账那份 SEEN_FILE，**不新建第三份基准**：保留期、清理、「上一轮取最大 last」三条规则
#    都已在 spec 里定死并踩过坑，复制一份等于把三个坑重开一次。
# ⛔ 读取必须在基准提升**之前**（提升在跑批收尾）——提升后每条的 last 都是今天，判定恒为「长期」。
# ⚠️ 基准为空（首次建立）时 $sn 恒为 null，自动退回两态，与 render-ledger.sh 的回落一致。
DIFF="$(jq -n --slurpfile new "$SNAP_NEW" --slurpfile old "$SNAP_LAST" --slurpfile seen "$SEEN_FILE" '
  ($seen[0] // {}) as $sn
  | def bykey: map({key:.id, value:.}) | from_entries;
    def plat($p):
      ($new[0][$p] // []) as $n | ($old[0][$p] // []) as $o
      | ($n | bykey) as $nm | ($o | bykey) as $om
      | {
          total:    ($n | length),
          events:   ($n | map(.events) | add // 0),
          new:       [ $n[] | select($om[.id] == null and $sn[.id] == null) ],
          regressed: [ $n[] | select($om[.id] == null and $sn[.id] != null) ],
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
  CHANGED=$(echo "$DIFF" | jq '[.ios,.android] | map(.new,.regressed,.resolved,.spiked) | flatten | length')
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
LEDGER_NF_FILE="$OUT_DIR/ledger-nonfatal-table.md"
LEDGER_RENDER_OK=0

# ⚠️ 基准是否已建立**必须在 render-ledger.sh 之前判**：跑批收尾会把 SEEN_FILE 覆盖成本轮值，
# 之后再判永远是「已建立」。复发率的分母同理——见下方 RECUR_MD。
SEEN_WAS_ESTABLISHED=0
[ "$(jq 'length' "$SEEN_FILE" 2>/dev/null || echo 0)" -gt 0 ] && SEEN_WAS_ESTABLISHED=1
if [ -x "$ROOT/bin/render-ledger.sh" ]; then
  # 周报文档 URL 此刻还不存在（由 deliver.sh 建文档后才知道），时间线先写占位符
  # __REPORT_URL__，deliver.sh 拿到 URL_REPORT 后统一回填（与卡片 __REPORT_URL__ 占位符同机制）。
  # 8.8：周报投递失败则占位符永远不会被回填——deliver.sh 只在投递成功分支才 fill，
  # 未回填的占位符不会被当成真链接展示（lark 侧就是一段普通文本），不会挂空链接。
  RENDER_OUT="$("$ROOT/bin/render-ledger.sh" "$SNAP_NEW" "$FIXMAP_FILE" "$PREV_TABLE_FILE" \
    <(echo "$DIFF") "$DAY" "__REPORT_URL__" "$SEEN_FILE" "$(day_ago "$SEEN_KEEP_DAYS")" \
    2>"$OUT_DIR/render-ledger.log")" \
    && LEDGER_RENDER_OK=1 || echo "  ⚠️ 台账渲染失败，本轮跳过台账更新（详见 render-ledger.log）"
  if [ "$LEDGER_RENDER_OK" = "1" ]; then
    printf '%s' "$RENDER_OUT" | awk 'BEGIN{RS="\x1e"} NR==1' > "$LEDGER_TABLE_FILE"
    printf '%s' "$RENDER_OUT" | awk 'BEGIN{RS="\x1e"} NR==2' > "$LEDGER_TIMELINE_FILE"
    printf '%s' "$RENDER_OUT" | awk 'BEGIN{RS="\x1e"} NR==3' > "$LEDGER_NF_FILE"
    # ④ 更新后的生命周期基准。先落临时文件，**跑批收尾时才覆盖正式基准**——
    # 与 SNAP_LAST 同一时机，中途失败不会留下半提升的基准。
    printf '%s' "$RENDER_OUT" | awk 'BEGIN{RS="\x1e"} NR==4' > "$SEEN_NEXT_FILE"
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
  if [ -s "$LEDGER_NF_FILE" ]; then
    LEDGER_TMPNF="$(mktemp)"
    awk -v nf="$LEDGER_NF_FILE" '
      /<!-- LEDGER:NONFATAL:BEGIN -->/ { print; while ((getline line < nf) > 0) print line; skip=1; next }
      /<!-- LEDGER:NONFATAL:END -->/ { skip=0 }
      skip { next }
      { print }
    ' "$LEDGER_TMP" > "$LEDGER_TMPNF" 2>/dev/null && mv "$LEDGER_TMPNF" "$LEDGER_TMP"
  fi
  if [ -s "$LEDGER_TIMELINE_FILE" ]; then
    # ── 追加前先去重（change crash-report-correctness-fixes，design D2）──
    # ⛔ 时间线是 **append，不幂等**。CLAUDE.md 的「台账同步不需要幂等键」只对现状表成立
    #    （那边是 block_replace）。同周重跑会重新算出同一批增量，原先无条件追加——
    #    实测台账里 2026-08-22 那批 6 条**原样重复了三遍**。
    # 查重键取「 · [周报](」之前的正文：同一条目不同轮次的链接不同（未投递是占位符、
    # 投递后是真 URL），整行比对查不出重复。
    # ⚠️ 只把 `- YYYY-` 开头的行当时间线条目——台账其他段落也有 `- ` 列表项。
    LEDGER_TL_DEDUP="$(mktemp)"
    awk '
      function body(s,   i) { i = index(s, " · [周报](");  return (i > 0 ? substr(s, 1, i - 1) : s) }
      function istl(s)      { return (s ~ /^- [0-9][0-9][0-9][0-9]-/) }
      NR == FNR { if (istl($0)) seen[body($0)] = 1; next }
      istl($0) && (body($0) in seen) { next }
      { print }
    ' "$LEDGER_LOCAL" "$LEDGER_TIMELINE_FILE" > "$LEDGER_TL_DEDUP" 2>/dev/null \
      || cp "$LEDGER_TIMELINE_FILE" "$LEDGER_TL_DEDUP"
    # 本轮不投递（NO_DELIVER / DRY RUN）时去掉链接后缀（design D3）：回填由 deliver.sh 在投递成功后做，
    # 不投递就永远不回填，`__REPORT_URL__` 会作为**死链**永久留在台账里（实测已污染 18 行）。
    # ⛔ 不能改成「不投递就不写台账」——L2 的基线提升无条件发生，跳过写入会让这批变化**永久丢失**。
    if [ "$DRY_RUN" = "1" ] || [ "${CRASH_REPORT_NO_DELIVER:-0}" = "1" ]; then
      # 就地替换走 python，与 deliver.sh 的 fill() 同一套（仓库无 sed -i 先例，BSD/GNU 语法不同）
      python3 - "$LEDGER_TL_DEDUP" <<'FILLPY' 2>/dev/null || true
import sys, pathlib
p = pathlib.Path(sys.argv[1])
p.write_text(p.read_text().replace(" · [周报](__REPORT_URL__)", ""))
FILLPY
    fi
    # 去掉增量尾部空行：每轮追加都会带一行，累积下来时间线里全是空行
    printf '%s\n' "$(cat "$LEDGER_TL_DEDUP")" > "$LEDGER_TL_DEDUP".t && mv "$LEDGER_TL_DEDUP".t "$LEDGER_TL_DEDUP"
    # ⛔ 判据必须是「有没有内容」不是 `[ -s ]`（有没有字节）：上一行的 `printf '%s\n'` 在内容为空时
    #    **仍然写出一个换行**，文件 1 字节 → `[ -s ]` 判非空 → 把那个空行追进台账，而下面那句
    #    「跳过追加（幂等）」永远走不到。2026-08-27 连跑两轮实测：条目数 23 → 23 没增长，
    #    但空行 6 → 7——⚠️ 幂等看起来成立，实际每一轮「无新增条目」的跑批都在往时间线里塞空行。
    #    `$(cat …)` 会剥掉全部尾随换行，故内容只剩空白时这里判空，正是想要的语义。
    if [ -n "$(cat "$LEDGER_TL_DEDUP")" ]; then
      LEDGER_TMP2="$(mktemp)"
      awk -v tlf="$LEDGER_TL_DEDUP" '
        /<!-- LEDGER:TIMELINE:END -->/ { while ((getline line < tlf) > 0) print line }
        { print }
      ' "$LEDGER_TMP" > "$LEDGER_TMP2" 2>/dev/null && mv "$LEDGER_TMP2" "$LEDGER_TMP"
    else
      echo "  ℹ️ 时间线增量全部已存在于台账，跳过追加（幂等）"
    fi
    rm -f "$LEDGER_TL_DEDUP"
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
# WoW / 环比基准的时间下界。⚠️ 必须定义在**所有取数与渲染之前**——4b 崩溃侧环比与
# 5b 性能段都用它，首版定义在 5b 附近，4b 处报 unbound variable（check-scripts 第 9 项已能拦下）。
WOW_CUT="$(day_ago 4)"   # 基准只认至少 4 天前的记录——同日/隔夜重跑不是「上周」
# TOP N 下钻（change crash-issue-drilldown）。⚠️ 常量必须定义在**取数步骤之前**——
# 首版放在渲染函数区（文件后半），取数处引用时报 unbound variable（2026-08-24 实测）。
DD_TOP_N="${CRASH_REPORT_DD_TOP_N:-3}"
DD_MODEL_CONC_PCT="${CRASH_REPORT_DD_MODEL_CONC_PCT:-60}"
DIM_ABSENT=""          # TSV：平台 \t 版本 \t 有无FATAL \t 有无页面事件——供维度段显式说明缺席原因
ADOPT_ROWS=""          # TSV：平台 \t 版本 \t 会话 \t 设备 \t 崩溃事件 \t 崩溃率 \t crash-free \t ANR \t 非致命
# ⛔ 入选理由**另开查找表，不进 ADOPT_ROWS**：后者是 9 列，第 10 列会被 9 变量的 read 吸进
#    最后一个字段；而把理由拼进「版本」列会污染 weekly-metrics.jsonl 的 WoW 匹配键
#    （同一版本这周「窗口主力」、下周「当日主力」就匹配不上，环比静默断档）。
ADOPT_REASONS=""       # TSV：平台 \t 版本 \t 入选理由
ADOPT_OK=0

if command -v bq >/dev/null 2>&1 && bqq csv 'SELECT 1' >/dev/null 2>&1; then
  ADOPT_OK=1
  step "主力版本放量（bq）"
  # 主力版本集合 = 窗口内会话量 top2 ∪ **当日**会话量 top1，上限 3（change crash-report-version-alignment）。
  # ⛔ 单靠「近 N 天累计」是滞后积分量，发版周会系统性选中正在退役的版本：实测 2026-08-31，
  #    Android 1.5.6 当日 855 会话（占 93%），7 天累计 1819 落后 1.5.5 的 2064 而落榜，
  #    于是周报二/三/四段整体在描述当天合计仅 66 个会话的两个版本，1.5.6 上的 3 条 FATAL 一条未呈现。
  # ⛔ **不换判据、只补一列**：窗口累计答「盘子里的大头」，当日答「现在线上跑什么」，
  #    两者分歧本身就是要看见的信息。与日报的「主力版本补列」「性能兜底选版」同构。
  # ⛔ **不得掺任何会话量门槛**：排序取 top1，不筛选——门槛会把刚放量或被叫停的新版静默剔除
  #    （MIN_SESSIONS 早已中和为 1，此处不得绕回来）。小样本由 SAMPLE_SESSION_MIN 标出，不藏起来。
  # ⚠️ 补入版本的会话/设备取**窗口口径**（与其余列同窗），⛔ 不能塞当日数字进来混窗。
  # ⚠️ 当日窗口用 DAYS=1（与日报放量段、告警小样本回退同一个窗口），
  #    ⛔ 不用性能段那个「最后一个完整日」——sessions 是活表，没有残日问题。
  main_versions() { # $1=sessions表 → 「版本,会话,设备,理由」最多 3 行
    local _all _top2 _d1v _row
    _all="$(bqq csv "$(q_render latest-versions.sql TABLE="$1" DAYS="$WEEK_DAYS" MIN_SESSIONS="$MIN_SESSIONS")" \
      | tail -n +2 | sort -t, -k2,2 -nr || true)"
    [ -n "$_all" ] || return 0
    _top2="$(printf '%s\n' "$_all" | head -2)"
    _d1v="$(bqq csv "$(q_render latest-versions.sql TABLE="$1" DAYS=1 MIN_SESSIONS="$MIN_SESSIONS")" \
      | tail -n +2 | sort -t, -k2,2 -nr | head -1 | cut -d, -f1 || true)"
    printf '%s\n' "$_top2" | while IFS= read -r _row; do
      [ -n "$_row" ] || continue
      if [ -n "$_d1v" ] && [ "${_row%%,*}" = "$_d1v" ]; then printf '%s,窗口+当日\n' "$_row"
      else printf '%s,窗口主力\n' "$_row"; fi
    done
    # 当日 top1 不在窗口 top2 内 → 补一行，⚠️ 取它在**窗口**里的会话/设备（同窗不混）
    if [ -n "$_d1v" ] && ! printf '%s\n' "$_top2" | cut -d, -f1 | grep -qx "$_d1v"; then
      _row="$(printf '%s\n' "$_all" | awk -F, -v v="$_d1v" '$1==v{print; exit}')"
      [ -n "$_row" ] && printf '%s,当日主力\n' "$_row"
    fi
    return 0
  }
  # ANR 与 NON_FATAL 计数：两者 is_fatal 均为 FALSE，crash-rate.sql 取不到
  # 影响面维度（change crash-impact-summary）：机型 / 系统版本 top3，用于跨周对比适配面变化。
  # ⚠️ **只有系统版本给率**——Android 机型碎片化，单机型会话桶太小，率不可靠。
  DIM_TOP_W="${CRASH_REPORT_DIM_TOP:-3}"
  DIM_MIN_W="${CRASH_REPORT_DIM_MIN_SESSIONS:-200}"
  ver_dim() { # $1=crash表 $2=sessions表 $3=版本 $4=维度表达式 → CSV（无表头）
    bqq csv "$(q_render crash-dimensions.sql TABLE="$1" SESSIONS_TABLE="$2" DAYS="$WEEK_DAYS" \
        VERSIONS="\"$3\"" DIM="$4" SESS_DIM="$4" LIMIT="$DIM_TOP_W" MIN_SESSIONS="$DIM_MIN_W")" \
      | tail -n +2 || true
  }
  # 页面：custom_keys 是 REPEATED RECORD，取值必须走标量子查询
  DIM_SCREEN_EXPR_W="(SELECT value FROM UNNEST(custom_keys) WHERE key = 'current_screen' LIMIT 1)"
  ver_dim_nd() { # $1=crash表 $2=版本 $3=维度表达式 $4=错误类型 → CSV（无表头，4 列）
    bqq csv "$(q_render crash-dimensions-nodenom.sql TABLE="$1" DAYS="$WEEK_DAYS" \
        VERSIONS="\"$2\"" DIM="$3" LIMIT="$DIM_TOP_W" ERROR_TYPES="$4")" \
      | tail -n +2 || true
  }
  # 归因分布（change crash-actionable-signals 1.5，与日报汇总段同源同 SQL）。
  # ⚠️ 与 ver_dim 不同：crash-blame.sql 不需要 sessions 表——归因不给率，只给绝对数。
  #    给率要除以「该归因方的会话数」，而会话表里根本没有归因维度，除不出来。
  ver_blame() { # $1=crash表 $2=版本 → CSV「归因方,代码库,事件,影响安装」（无表头）
    bqq csv "$(q_render crash-blame.sql TABLE="$1" DAYS="$WEEK_DAYS" \
        VERSIONS="\"$2\"" LIMIT="$DIM_TOP_W")" \
      | tail -n +2 || true
  }
  ver_etypes() { # $1=crashlytics表 $2=版本 → 「anr事件,anr安装,非致命事件,非致命安装」
    bqq csv "$(q_render crash-error-types.sql TABLE="$1" DAYS="$WEEK_DAYS" VERSIONS="\"$2\"" \
        FG_NORM="${SQL_FG_NORM}")" \
      | tail -n +2 | head -1 || true
  }
  ver_crash() { # $1=crashlytics表 $2=sessions表 $3=版本 → 「事件数,会话数,受影响安装,崩溃会话数」
    bqq csv "$(q_render crash-rate.sql TABLE="$1" SESSIONS_TABLE="$2" DAYS="$WEEK_DAYS" \
        VERSIONS="\"$3\"")" \
      | tail -n +2 | head -1 || true
  }
  IOS_TOP2_VERS=""; AND_TOP2_VERS=""   # 供 6. 性能段复用同一批主力版本（不重复解析）
  for entry in "iOS|$PROJECT.firebase_sessions.com_prime_dino_english_IOS_REALTIME|$PROJECT.firebase_crashlytics.com_prime_dino_english_IOS_REALTIME" \
               "Android|$PROJECT.firebase_sessions.com_prime_dino_english_ANDROID_REALTIME|$PROJECT.firebase_crashlytics.com_prime_dino_english_ANDROID_REALTIME"; do
    IFS='|' read -r pname stbl ctbl <<< "$entry"
    while IFS=, read -r ver sess dev why; do
      [ -n "$ver" ] || continue
      if [ "$pname" = "iOS" ]; then IOS_TOP2_VERS="${IOS_TOP2_VERS}${ver}
"; else AND_TOP2_VERS="${AND_TOP2_VERS}${ver}
"; fi
      cr="$(ver_crash "$ctbl" "$stbl" "$ver")"
      cev="$(printf '%s' "$cr" | cut -d, -f1)"; csess="$(printf '%s' "$cr" | cut -d, -f2)"
      ccs="$(printf '%s' "$cr" | cut -d, -f4)"
      rate="—"
      if [ -n "$cev" ] && [ -n "$csess" ] && [ "$csess" != "0" ]; then
        rate="$(awk -v e="$cev" -v s="$csess" 'BEGIN{printf "%.2f%%", e/s*100}')"
      fi
      # crash-free 会话率。分母为 0 → 「无法计算」，⛔ 不得渲染成 100%
      cfree="无法计算"
      if [ -n "$ccs" ] && [ -n "$csess" ] && [ "$csess" != "0" ]; then
        cfree="$(awk -v c="$ccs" -v s="$csess" 'BEGIN{printf "%.2f%%", 100 - c/s*100}')"
      fi
      et="$(ver_etypes "$ctbl" "$ver")"
      anrev="$(printf '%s' "$et" | cut -d, -f1)"; nfev="$(printf '%s' "$et" | cut -d, -f3)"
      # iOS 无 ANR 概念（数据源不产出该 error_type），不填 0——0 会被读成「iOS 没有卡死问题」
      if [ "$pname" = "iOS" ]; then anrcell="— 无此概念"
      else
        anrcell="${anrev:-0} 次"
        if [ -n "$anrev" ] && [ -n "$csess" ] && [ "$csess" != "0" ]; then
          anrcell="$(awk -v e="$anrev" -v s="$csess" 'BEGIN{printf "%d 次 %.2f%%", e, e/s*100}')"
        fi
      fi
      ADOPT_ROWS="${ADOPT_ROWS}${pname}	${ver}	${sess}	${dev}	${cev:-—}	${rate}	${cfree}	${anrcell}	${nfev:-0} 次
"
      ADOPT_REASONS="${ADOPT_REASONS}${pname}	${ver}	${why:-窗口主力}
"
      echo "  ${pname} ${ver}：${sess} 会话 / ${dev} 设备 / 崩溃 ${cev:-—} 次 ${rate} / crash-free ${cfree} / ANR ${anrcell} / 非致命 ${nfev:-0} 次"
      # 维度只在该版本确有事件时才查——零事件的版本查了必然全空，白花查询。
      # ⛔ **闸门必须按各维度自己的 error_type 判**，不能一律用 FATAL 数 ${cev}：
      #    页面维度对 iOS 走 NON_FATAL，而 iOS 主力版本常年 FATAL=0——实测 2026-08-24
      #    iOS 1.5.3 有 **958 条 NON_FATAL、0 条 FATAL**，旧闸门把这 958 条带页面信息的
      #    事件整个挡在门外，`dim-screen-iOS-1.5.3.csv` 根本没生成，而报告里**不留任何痕迹**
      #    （`for f in dim-*.csv` 轮不到不存在的文件）——读者分不清「无事件 / 查询失败 / 被忽略」。
      _has_fatal=0; { [ -n "$cev" ] && [ "$cev" != "0" ] && [ "$cev" != "—" ]; } && _has_fatal=1
      # 页面维度的闸门：iOS 看非致命数，Android 看 FATAL+ANR
      _dim_et="'FATAL','ANR'"; _screen_n="$cev"
      if [ "$pname" = "iOS" ]; then _dim_et="'NON_FATAL'"; _screen_n="$nfev"; fi
      _has_screen=0; { [ -n "$_screen_n" ] && [ "$_screen_n" != "0" ] && [ "$_screen_n" != "—" ]; } && _has_screen=1
      if [ "$_has_fatal" = 1 ]; then
        ver_dim "$ctbl" "$stbl" "$ver" "CONCAT(device.manufacturer,' ',device.model)" > "$OUT_DIR/dim-model-${pname}-${ver}.csv" || true
        ver_dim "$ctbl" "$stbl" "$ver" "operating_system.display_version"             > "$OUT_DIR/dim-os-${pname}-${ver}.csv"    || true
        ver_blame "$ctbl" "$ver"                                                       > "$OUT_DIR/blame-${pname}-${ver}.csv"     || true
      fi
      if [ "$_has_screen" = 1 ]; then
        ver_dim_nd "$ctbl" "$ver" "$DIM_SCREEN_EXPR_W" "$_dim_et" > "$OUT_DIR/dim-screen-${pname}-${ver}.csv" || true
      fi
      # ⛔ **版本缺席必须显式留痕**，不能靠「文件不存在」静默省略（镜头 6：缺失可不可见）
      DIM_ABSENT="${DIM_ABSENT}${pname}\t${ver}\t${_has_fatal}\t${_has_screen}\n"
    done <<< "$(main_versions "$stbl")"
  done
else
  echo "--- ⚠️ bq 不可用，跳过主力版本放量段（不影响变化摘要）---"
fi

# ── 4b. 崩溃侧周度基准（analyst G10：二段全是孤立当期值，metrics-history 是 L1 的
#        天级口径，⛔ 不可混用——L2 自建 7d 快照历史，upsert by (day,平台,版本)）────────
WEEKLY_HIST="$STATE/weekly-metrics.jsonl"
ADOPT_WOW_MD=""
if [ "$ADOPT_OK" = "1" ] && [ -n "$ADOPT_ROWS" ]; then
  while IFS=$'\t' read -r _wp _wv _ws _wd _wc _wr _wf _wa _wn; do
    [ -n "$_wp" ] || continue
    _wa_n="${_wa%% *}"; _wn_n="${_wn%% *}"   # 「45 次 0.67%」→「45」；「— 无此概念」→「—」
    if [ -s "$WEEKLY_HIST" ]; then
      _prev="$(jq -cs --arg p "$_wp" --arg v "$_wv" --arg c "$WOW_CUT" \
        '[.[] | select(.platform==$p and .version==$v and .day <= $c)] | last // empty' "$WEEKLY_HIST" 2>/dev/null || true)"
      if [ -n "$_prev" ]; then
        _pd="$(printf '%s' "$_prev" | jq -r '.day')"
        ADOPT_WOW_MD="${ADOPT_WOW_MD}> 环比 ${_wp} ${_wv}（vs ${_pd}）：崩溃 $(printf '%s' "$_prev" | jq -r '.crash // "—"')→${_wc} · ANR $(printf '%s' "$_prev" | jq -r '.anr // "—"')→${_wa_n} · 非致命 $(printf '%s' "$_prev" | jq -r '.nf // "—"')→${_wn_n} · crash-free $(printf '%s' "$_prev" | jq -r '.cfree // "—"')→${_wf}\n"
      fi
    fi
  done <<< "$ADOPT_ROWS"
  # upsert：删掉今天已有的行再整批追加（同日重跑不膨胀）；保留 120 天
  _wh="$(mktemp)"
  { [ -s "$WEEKLY_HIST" ] && jq -c --arg d "$DAY" --arg cut "$(day_ago 120)" \
      'select(.day != $d and .day >= $cut)' "$WEEKLY_HIST" 2>/dev/null; } > "$_wh" || true
  printf '%s' "$ADOPT_ROWS" | while IFS=$'\t' read -r _wp _wv _ws _wd _wc _wr _wf _wa _wn; do
    [ -n "$_wp" ] || continue
    jq -nc --arg p "$_wp" --arg v "$_wv" --arg d "$DAY" --arg c "$_wc" --arg f "$_wf" \
      --arg a "${_wa%% *}" --arg n "${_wn%% *}" \
      '{platform:$p, version:$v, day:$d, crash:$c, cfree:$f, anr:$a, nf:$n}'
  done >> "$_wh"
  mv "$_wh" "$WEEKLY_HIST"
fi

# ── 5a. TOP N 事件下钻（change crash-issue-drilldown）──────────────────────
# ⚠️ 取数函数**必须定义在这里**（调用点之前）——bash 顺序执行，定义在文件后半的
#    渲染函数区会报 `dd_fetch: command not found`，而 `|| true` 会把 127 吞掉，
#    结果是空产物 + 退出码 0（2026-08-24 实测跑了一轮才发现）。
dd_fetch() { # $1=crashlytics表 $2=版本列表(空格分隔) $3=错误类型 → CSV（无表头）
  local vers="" v
  for v in $2; do [ -n "$v" ] && vers="${vers:+$vers,}\"$v\""; done
  [ -n "$vers" ] || return 0
  bqq csv "$(q_render crash-issue-drilldown.sql TABLE="$1" DAYS="$WEEK_DAYS" VERSIONS="$vers" \
      ERROR_TYPES="$3" TOP_N="$DD_TOP_N" FG_NORM="${SQL_FG_NORM}")" | tail -n +2 || true
}
# 复用 5. 已解析出的主力版本；SQL 自己选 top N（不从快照取 id——快照只有 FATAL，
# 会让按受影响安装排第一的那个 ANR 整个消失）。bq 不可用时整段降级，不阻塞周报。
DD_IOS_CSV="$OUT_DIR/drilldown-ios.csv"; DD_AND_CSV="$OUT_DIR/drilldown-android.csv"
: > "$DD_IOS_CSV"; : > "$DD_AND_CSV"
if [ "$ADOPT_OK" = "1" ]; then
  step "TOP ${DD_TOP_N} 事件下钻（bq，窗口 ${WEEK_DAYS}d）"
  # ⚠️ 记下取数是否成功：空产物有两种成因——「本窗口真的没有 issue」与「取数挂了」，
  #    ⛔ 两者渲染成同一句「无可下钻的 issue」会把故障读成好消息。
  DD_IOS_OK=1; DD_AND_OK=1
  dd_fetch "$PROJECT.firebase_crashlytics.com_prime_dino_english_IOS_REALTIME" \
    "$IOS_TOP2_VERS" "'NON_FATAL'" > "$DD_IOS_CSV" || DD_IOS_OK=0
  dd_fetch "$PROJECT.firebase_crashlytics.com_prime_dino_english_ANDROID_REALTIME" \
    "$AND_TOP2_VERS" "'FATAL','ANR'" > "$DD_AND_CSV" || DD_AND_OK=0
  echo "  iOS $(grep -c . "$DD_IOS_CSV" 2>/dev/null || true) 行（ok=${DD_IOS_OK}） · Android $(grep -c . "$DD_AND_CSV" 2>/dev/null || true) 行（ok=${DD_AND_OK}）"
fi

# ── 5b. 性能段（design D8/D9，L2 独占，不进台账，不出根因）────────────────
# 复用 5. 已解析出的主力版本（会话量 top2），复用 L1 现有 SQL（perf-traces/screens/network.sql），
# 只改窗口天数为 WEEK_DAYS——同一份 SQL 两条链路各自套用不同窗口，口径一致（design D9）。
# 只给趋势 / 可定位对象 / 下一步取证方向，不出根因与修复方案（硬约束，见 CLAUDE.md）。
# 时间助手与 tbl_max 原本定义在下方「取数区间」段，为供本段的停更判定使用而前移（定义唯一，未复制）。
RUN_EPOCH="$(date +%s)"
tbl_max() { [ -n "$1" ] || { echo ""; return 0; }
  bqq csv "SELECT FORMAT_TIMESTAMP('%Y-%m-%d %H:%M UTC', MAX(event_timestamp)) AS ts FROM \`$1\`" \
    | tail -n +2 | tail -1 || true; }
PERF_OK=0
IOS_PERF_STALE=""; AND_PERF_STALE=""; IOS_PERF_MAX=""; AND_PERF_MAX=""   # bq 不可用时也要有定义（set -u）
PERF_UNTIL=""; PERF_LCD=""; PERF_WIN_START=""                          # 同上：完整日窗口三件套
PERF_WINDOW_MODE=legacy   # 本轮性能窗口口径；⚠️ 只有真取到 LCD 才算 complete_day
PERF_WOW_CROSS=0          # 本轮有没有出现「新口径 vs 旧口径」的 WoW（决定表下要不要出那句解释）
IOS_PERF_TBL="$PROJECT.firebase_performance.com_prime_dino_english_IOS"
AND_PERF_TBL="$PROJECT.firebase_performance.com_prime_dino_english_ANDROID"
PERF_ROWS=""    # TSV：平台/版本/启动P50/启动P95/慢帧最差页/慢帧率/冻结率/接口错误率（列以制表符分隔）
# 周环比基准（7.4）：按 (平台,版本) 存最近几轮的性能快照，供 WoW 对比；无基准则显式标明而非显示零变化。
PERF_HISTORY="$STATE/perf-history.jsonl"
PERF_MISSING=""   # TSV「平台 版本 kind 日期」：kind=stale_fetch(本轮未取到) / never(尚无数据)
# 第 3 态细分（change crash-data-completeness C 组，与 L1 同一判据）。
# ⛔ 数据源是 **perf-history.jsonl**（性能侧 p50/p95），⚠️ tasks 3.6 原文写的
#    `weekly-metrics.jsonl` 是**崩溃侧**周度基准（crash/cfree/anr/nf），里面没有任何性能字段。
# ⛔ 也不可混用 L1 的 metrics-history.jsonl——那是天级口径（见本文件 4b 段既有注释）。
# ⛔ 判据必须显式判 `!= null`，MUST NOT 用真值性判断（0 是合法值，见 L1 同名约束）。
perf_hist_last_day() { # $1=平台名(iOS/Android) $2=版本 → 最后一次有值的日期，无则空
  [ -s "$PERF_HISTORY" ] || { echo ""; return 0; }
  jq -rs --arg p "$1" --arg v "$2" \
    '[.[] | select(.platform==$p and .version==$v and ((.p50 != null) or (.p95 != null))) | .day] | last // ""' \
    "$PERF_HISTORY" 2>/dev/null || true
}
PERF_HISTORY_KEEP="${CRASH_REPORT_PERF_HISTORY_KEEP:-12}"   # 12 周，约一季度
if [ "$ADOPT_OK" = "1" ]; then
  step "性能段（bq，窗口 ${WEEK_DAYS}d）"
  perf_row() { # $1=平台标签 $2=perf表 $3=版本 → 一行 TSV（失败字段留空，由调用方判定缺数原因）
    local pname="$1" tbl="$2" ver="$3" traces screens net p50 p95 wscreen wslow frozen neterr _lastd
    # 完整日闭区间 [LCD−(WEEK_DAYS−1), LCD]；窗口两端由调用方算好，⛔ 共享层不设默认值（bin/lib/query.sh）。
    # 无 LCD（性能表连 MAX 都取不到）时不发查询：空日期喂给 BETWEEN 会让 BigQuery 报类型错，
    # 徒增一条失败查询与一段 stderr，而结果与直接留空完全一样。
    if [ -z "$PERF_LCD" ]; then
      # 整行皆空 = 该版本本轮没有任何性能数据 → 分两种情况登记，供表下注解区分
    # 「正常滞后，明天就有」与「取数故障，要查」（design D5 第 3 态细分）。
    if [ -z "${p50}${p95}${wscreen}${frozen}${neterr}" ]; then
      _lastd="$(perf_hist_last_day "$pname" "$ver")"
      if [ -n "$_lastd" ]; then PERF_MISSING="${PERF_MISSING}${pname}	${ver}	stale_fetch	${_lastd}
"
      else PERF_MISSING="${PERF_MISSING}${pname}	${ver}	never	
"
      fi
    fi
    PERF_ROWS="${PERF_ROWS}${pname}	${ver}	—	—	—	—	—	—	—（无基准）
"
      return 0
    fi
    traces="$(bqq csv "$(q_render perf-traces.sql TABLE="$tbl" LCD_START="$PERF_WIN_START" LCD_END="$PERF_LCD" VERSIONS="\"$ver\"")" | tail -n +2 || true)"
    screens="$(bqq csv "$(q_render perf-screens.sql TABLE="$tbl" LCD_START="$PERF_WIN_START" LCD_END="$PERF_LCD" VERSIONS="\"$ver\"")" | tail -n +2 || true)"
    net="$(bqq csv "$(q_render perf-network.sql TABLE="$tbl" LCD_START="$PERF_WIN_START" LCD_END="$PERF_LCD" VERSIONS="\"$ver\"")" | tail -n +2 || true)"
    # `|| true`：性能表停更时 traces 为空，grep 无匹配返回 1，pipefail 让赋值整体失败，
    # set -e 直接杀掉整跑（同源问题在 L1 是误报告警，见 crash-daily.sh collect_window）。
    p50="$(printf '%s\n' "$traces" | grep '^_app_start,' | cut -d, -f3 | head -1 || true)"
    p95="$(printf '%s\n' "$traces" | grep '^_app_start,' | cut -d, -f4 | head -1 || true)"
    wscreen="$(printf '%s\n' "$screens" | head -1 | cut -d, -f1)"
    wslow="$(printf '%s\n' "$screens" | head -1 | cut -d, -f3)"
    frozen="$(printf '%s\n' "$screens" | head -1 | cut -d, -f4)"
    # csv2tsv：NETWORK_REQUEST 的 event_name 是 URL，可能含逗号（见 csv2tsv 处注释）
    neterr="$(printf '%s\n' "$net" | csv2tsv | awk -F'\t' '{e+=$5; n+=$2} END{if(n>0) printf "%.2f", e/n*100}')"
    # 三态缺数判定（design 缺数三态，简化为周报够用的两态）：表不存在/查询失败 → 空值走「⚠️ 数据未同步」；
    # 表存在但该版本无样本（HAVING 阈值过滤掉）→ 空值走「该版本无数据」。两者在渲染时统一显示 —，
    # 性能段不做告警判定（design D8：只给趋势，不触发红黄绿），故不需要像 L1 那样细分三态文案。
    # WoW：基准取同 (平台,版本) 中 day <= 今天−4 的最近一条，⛔ **不是 last**——
    # last 会取到同一天早些时候的跑批（同日重跑各追加一条），实测 2026-08-24 三次跑批后
    # iOS 1.5.3 报「WoW 持平」，而真上周（08-22 578ms → 701ms）应是 +123ms（analyst G9）。
    # 基准日直接写进文案（vs 08-17），读者自己能看出比的是哪天——比隐式假设「上周」诚实。
    local prev_rec prev_p95="" prev_day="" prev_mode="" wow="" wow_cell="—（无基准）"
    if [ -s "$PERF_HISTORY" ]; then
      prev_rec="$(jq -cs --arg p "$pname" --arg v "$ver" --arg c "$WOW_CUT" \
        '[.[] | select(.platform==$p and .version==$v and .day <= $c)] | last // empty' "$PERF_HISTORY" 2>/dev/null || true)"
      if [ -n "$prev_rec" ]; then
        prev_p95="$(printf '%s' "$prev_rec" | jq -r '.p95 // empty' 2>/dev/null || true)"
        prev_day="$(printf '%s' "$prev_rec" | jq -r '.day // empty' 2>/dev/null || true)"
        # ⛔ 基准是旧口径就必须说出来，不能静默给数（design D8）：旧口径的 7 天窗首尾两天残缺，
        #    与完整日窗比出来的差值里混着「窗口形状变了」这一项，读者会当成真实变化。
        prev_mode="$(printf '%s' "$prev_rec" | jq -r '.window_mode // "legacy"' 2>/dev/null || true)"
      fi
    fi
    if [ -n "${prev_p95:-}" ] && [ -n "$p95" ]; then
      local delta; delta="$(awk -v a="$p95" -v b="$prev_p95" 'BEGIN{printf "%.0f", a-b}' 2>/dev/null || true)"
      if [ -n "$delta" ]; then
        if [ "$delta" -gt 0 ] 2>/dev/null; then wow="（WoW P95 +${delta}ms↑ 变差 vs ${prev_day}）"; wow_cell="+${delta}ms↑（vs ${prev_day}）"
        elif [ "$delta" -lt 0 ] 2>/dev/null; then wow="（WoW P95 ${delta}ms↓ 变好 vs ${prev_day}）"; wow_cell="${delta}ms↓（vs ${prev_day}）"
        else wow="（WoW P95 持平 vs ${prev_day}）"; wow_cell="持平（vs ${prev_day}）"; fi
        # 跨口径就在格子里挂个记号，完整解释放表下说一次——⛔ 每格重复一整句会把列宽撑爆
        if [ -n "$prev_mode" ] && [ "$prev_mode" != complete_day ]; then
          wow_cell="${wow_cell} ⚠️跨口径"; wow="${wow}⚠️ 基准为旧窗口口径"; PERF_WOW_CROSS=1
        fi
      fi
    else
      wow="（无近周基准，本轮建立）"
    fi
    PERF_ROWS="${PERF_ROWS}${pname}	${ver}	${p50:-—}	${p95:-—}	${wscreen:-—}	${wslow:-—}	${frozen:-—}	${neterr:-—}	${wow_cell}
"
    echo "  ${pname} ${ver}：启动 P50 ${p50:-—}ms / P95 ${p95:-—}ms ${wow} · 慢帧最差页 ${wscreen:-—} ${wslow:-—}% · 冻结 ${frozen:-—}% · 接口错误率 ${neterr:-—}%"
    # 落一行到历史（本轮快照，供下周环比），只在拿到值时写，避免用空值污染基准
    if [ -n "$p95" ] || [ -n "$p50" ]; then
      # ⛔ 按 (平台,版本,日) upsert 而非裸 append：同日重跑各追一条会把 KEEP=12 的窗口吃光
      #    （实测 Android 1.5.1 的 12 条全在 08-20/08-22 两天里），WoW 基准随之失效。
      if [ -s "$PERF_HISTORY" ]; then
        local _ph; _ph="$(mktemp)"
        jq -c --arg p "$pname" --arg v "$ver" --arg d "$DAY" \
          'select((.platform==$p and .version==$v and .day==$d) | not)' "$PERF_HISTORY" > "$_ph" 2>/dev/null \
          && mv "$_ph" "$PERF_HISTORY" || rm -f "$_ph"
      fi
      # ⚠️ window_mode 标记这条记录取自哪套窗口（change crash-data-completeness，design D8）：
      #   legacy       —— 锚在跑批时刻的 7 天滚动窗，首尾两天都残缺
      #   complete_day —— 完整日闭区间 [LCD-6, LCD]
      # ⛔ 不回填不重算旧行；缺该字段的旧行一律读作 legacy。
      jq -nc --arg p "$pname" --arg v "$ver" --arg d "$DAY" --arg p50 "${p50:-}" --arg p95 "${p95:-}" \
        --arg wm "$PERF_WINDOW_MODE" \
        '{platform:$p, version:$v, day:$d, window_mode:$wm, p50:($p50|tonumber? // null), p95:($p95|tonumber? // null)}' >> "$PERF_HISTORY"
    fi
  }
  PERF_OK=1
  IOS_PERF_MAX="$(tbl_max "$IOS_PERF_TBL")"; AND_PERF_MAX="$(tbl_max "$AND_PERF_TBL")"
  IOS_PERF_STALE="$(stale_days "$RUN_EPOCH" "$IOS_PERF_MAX" "$WEEK_DAYS")"
  AND_PERF_STALE="$(stale_days "$RUN_EPOCH" "$AND_PERF_MAX" "$WEEK_DAYS")"
  [ -n "$IOS_PERF_STALE" ] && echo "  ⚠️ iOS 性能表已停更 ${IOS_PERF_STALE} 天（截至 ${IOS_PERF_MAX}）"
  [ -n "$AND_PERF_STALE" ] && echo "  ⚠️ Android 性能表已停更 ${AND_PERF_STALE} 天（截至 ${AND_PERF_MAX}）"
  # 完整日窗口（change crash-data-completeness，与 L1 同一判据、同一实现）：
  # ⚠️ LCD 必须由**性能表**的 MAX 算出——下方「取数区间」的 DATA_UNTIL 取的是 sessions 活表，
  #    那是实时源、恒为「刚才」，拿它算 LCD 会得到今天，把整个残日全掺进来。⛔ 两者不可混用。
  PERF_UNTIL="$(printf '%s\n%s\n' "$IOS_PERF_MAX" "$AND_PERF_MAX" | grep -v '^$' | sort -r | head -1 || true)"
  PERF_LCD="$(last_complete_day "$PERF_UNTIL")"
  PERF_WIN_START="$(day_shift "$PERF_LCD" "-$((WEEK_DAYS - 1))")"
  if [ -n "$PERF_LCD" ]; then PERF_WINDOW_MODE=complete_day; fi
  if [ -n "$PERF_LCD" ]; then echo "  性能完整日窗口：$PERF_WIN_START ~ $PERF_LCD"
  else echo "  ⚠️ 性能表无最新时间戳，完整日窗口无法确定——性能段各列留空走既有缺数渲染"; fi
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
TZ_LABEL="$(date '+%z')"
DATA_UNTIL="—"
if [ "$ADOPT_OK" = "1" ]; then
  _MI="$(tbl_max "$PROJECT.firebase_sessions.com_prime_dino_english_IOS_REALTIME")"
  _MA="$(tbl_max "$PROJECT.firebase_sessions.com_prime_dino_english_ANDROID_REALTIME")"
  DATA_UNTIL="$(printf '%s\n%s\n' "$_MI" "$_MA" | grep -v '^$' | sort -r | head -1 || true)"
  [ -n "$DATA_UNTIL" ] || DATA_UNTIL="—"
fi
WIN_COMPACT="$(win_compact "$RUN_EPOCH" "$TZ_LABEL" "$WEEK_DAYS" "$DATA_UNTIL")"
WIN_FULL="$(win_full "$RUN_EPOCH" "$TZ_LABEL" "$WEEK_DAYS" "$DATA_UNTIL")"
echo "  取数区间 ${WEEK_DAYS}d：$WIN_COMPACT"

# ── 6. 组装播报 ───────────────────────────────────────
# ⚠️ 段一**同时进卡片与文档**（卡片的 markdown 块 / 文档正文），二者共用本组函数。
#    Firebase 直达链接只能进文档：群卡片一屏十几条变化各挂一个 console URL，版面立刻不能看。
# ⛔ 不为此复制出「卡片版」「文档版」两份渲染——那正是 F35 的形状（卡片表格的列集合有两个
#    定义点，改一处就让预览与实发不一致）。改为**一个定义点、两次调用**，靠参数区分。
_chg_rows() { # $1=平台key $2=桶名 $3=图标与词 $4=是否带事件数(1/0) $5=是否带链接(1/0)
  local k="$1" bucket="$2" mark="$3" with_events="$4" want_link="$5"
  local id title events vers vtxt suffix idtok u
  while IFS=$'\t' read -r id title events vers; do
    [ -n "$id" ] || continue
    # 版本构成：⚠️ **只在跨版本时出括注**——单版本时它与主数字重复，只增噪音。
    # ⛔ 全角括号先条件赋值再拼接，禁 ${var:+（...）}：bash 会把全角字节并进变量名。
    vtxt=""
    if [ -n "$vers" ] && [ "$vers" != "null" ] \
       && [ "$(printf '%s' "$vers" | jq 'length' 2>/dev/null || echo 0)" -gt 1 ]; then
      vtxt="（$(printf '%s' "$vers" | jq -r 'map("\(.version) \(.n)") | join(" · ")')）"
    fi
    suffix=""
    [ "$with_events" = "1" ] && suffix=" · ${events} 事件"
    # ⚠️ 展示用 8 位短 id，链接里用完整 32 位——两者各取所需，不需要反查。
    # ⛔ 链接版**不加反引号**：md2docx.py 的链接正则是 `\[text\](url)`，不处理嵌套行内代码，
    #    `[`id`](url)` 会渲染成字面反引号。聊天侧无链接，用反引号让 id 在正文里可辨。
    idtok="\`${id:0:8}\`"
    if [ "$want_link" = "1" ]; then
      u="$(issue_url "$k" "$id")"
      [ -n "$u" ] && idtok="[${id:0:8}]($u)"
    fi
    printf -- '- %s %s %s%s%s\n' "$mark" "$idtok" "$title" "$suffix" "$vtxt"
  done < <(echo "$DIFF" | jq -r ".$k.${bucket}[]? | [.id, .title, (.events // \"\"), (if .versions == null then \"null\" else (.versions|tojson) end)] | @tsv" 2>/dev/null || true)
  # ⛔ 必须显式 return 0：末尾的条件判断为假会让函数返回 1，而调用方在 set -e 下会整脚本退出。
  return 0
}

sec() { # $1=平台名 $2=json key $3=1 带控制台链接（文档用），0/缺省不带（卡片用）
  local name="$1" k="$2" want_link="${3:-0}"
  local total events
  total=$(echo "$DIFF" | jq -r ".$k.total")
  events=$(echo "$DIFF" | jq -r ".$k.events")
  # 口径已从 MCP topIssues（只含 OPEN）换成 BigQuery 事件级（含已关闭 issue），
  # 再写 OPEN 就是错的——已关闭但仍在崩的 issue 正是当初迁移的动机。
  printf '**%s** — FATAL issue %s 个 / 近 7 天 %s 事件\n' "$name" "$total" "$events"
  [ "$IS_BASELINE" = "1" ] && { printf '（首次运行，建立基线，不列新增）\n'; return 0; }
  # ⚠️ 顺序：新增 → 回归 → 暴涨 → 消失。「回归」与「新增」必须分列——回归意味着修复失效
  #    或场景重现，与全新问题的处置方式不同（spec crash-perf-issue-lifecycle）。
  _chg_rows "$k" new       "🆕 新增" 1 "$want_link"
  _chg_rows "$k" regressed "🔁 回归" 1 "$want_link"
  _chg_rows "$k" spiked    "📈 暴涨" 1 "$want_link"
  _chg_rows "$k" resolved  "✅ 消失" 0 "$want_link"
  # ⛔ 原为 `[ "$k" = "ios" ] && …`，理由是「Android 无 issue ID 提交约定，fix_commit 恒 null」
  #    ——**已订正的过期结论**（2026-09-01 改扫描器、2026-09-05 在生产机业务仓复核）。
  #    ⚠️ L2 的情况比 L1 更严重：它**跑了** scan-fix-commits.sh、**拿到了** Android 命中
  #    （实测 4 条：85c581ed / a34175e5 / ce481263 / fa48b2eb），然后在这里把它们扔掉。
  #    而「代码已修待验」正是本段注释自己写的「最容易被遗忘的状态，必须顶到卡片上」。
  # ⚠️ 双端渲染是安全的：fixed_pending 已经 `select(.fix_commit != null)`，
  #    而**非 null 在两端都无歧义**（提交信息里确实引用了这个 issue）。
  #    有歧义的是 null（Android 无强制规则时 null ≠ 未修），而 null 本就不进这个列表。
  echo "$DIFF" | jq -r ".$k.fixed_pending[]? | \"- 🛠️ 代码已修待验 \`\(.id[0:8])\` \(.title) · \(.fix_commit)\"" || true
  # 必须显式 return 0：本函数末尾若以可能求值为假的语句结尾会返回 1，
  # 而 CHANGES_MD="$(sec ...)" 在 set -e 下会因此整脚本退出（旧版嵌在 heredoc 里侥幸没暴露）。
  return 0
}
# 卡片版不带链接、文档版带链接（design D7）。⛔ 两者出自同一个 sec()，不是两份拷贝。
# ⚠️ 卡片版**也带链接**（change crash-card-issue-links）：段一在卡片里的载体是 markdown 块，
#    2026-09-01 实发实测**可点且列宽无变化**——`[2a800b33](url)` 只显示锚文本，与纯文本一样宽。
#    ⛔ 原先禁掉是把「裸 URL」与「markdown 链接」混为一谈了。卡片是多数人唯一会看的产物，
#    最该能下钻的地方不能只给灰色文本。⛔ 表格单元格另说：实测不渲染链接，那边保持无链接。
CHANGES_MD="$(sec "iOS" ios 1; printf '\n'; sec "Android" android 1)"
# ⚠️ **消费点有三个，别只数两个**（2026-09-01 实施本 change 时就因此改错了地方）：
#   群消息 message.md（MSG heredoc）· 卡片（--arg ch）· 周报文档（printf '## 一、本周变化'）。
#   三者现在**用同一份带链接的内容**（change crash-card-issue-links 实测：卡片的 markdown 块
#   链接可点且不改宽度）。⛔ 但消费点仍是三个——改这里之前照样要数清楚。

# ── 复发率（change crash-recurrence-rate）────────────────────────────────
# ⛔ **给分数不给百分比**：基准实测只有 14 个 key，1 个回归 = 7.1%、2 个 = 14.3%——
#    百分比在这个分母上是伪精度，且周与周之间跳动会被读成趋势。分数形态自带分母。
# ⛔ 三态判定**不在这里重算**，直接数已渲染的现状表——判定只在 render-ledger.sh 实现一次
#    （失效模式 F4：同一个值多来源必然漂移）。
# ⚠️ 「回归」= 该 issue 在上一轮基准日无记录、本轮重新出现。判定窗口是崩溃段的滚动窗口，
#    「消失」的含义是**窗口内无事件**，不是「已修复」。
# ⚠️ 台账取数带 LIMIT 20，issue 总数逼近 20 时掉出榜单再回来会被误计为回归
#    （实测 Android FATAL 7d 唯一 issue 数 13 < 20，暂未咬合）。
RECUR_MD=""
if [ "${LEDGER_RENDER_OK:-0}" = "1" ] && [ -s "$LEDGER_TABLE_FILE" ]; then
  # ⛔ 不能写 `$(grep -c … || echo 0)`：grep -c 零匹配时**既输出 "0" 又返回 1**，
  #    `|| echo 0` 会再追加一个 0，值变成 "0\n0"，后续 `[ … -gt 0 ]` 直接报
  #    「integer expression expected」（2026-08-24 实测踩到）。用 `|| true` 保留 grep 自己的 0。
  _rc_total="$(grep -c '^| \(iOS\|Android\) |' "$LEDGER_TABLE_FILE" 2>/dev/null || true)"; _rc_total="${_rc_total:-0}"
  _rc_regr="$(grep -c '回归' "$LEDGER_TABLE_FILE" 2>/dev/null || true)"; _rc_regr="${_rc_regr:-0}"
  if [ "$SEEN_WAS_ESTABLISHED" != "1" ]; then
    # ⛔ 基准未建立时**不显示 0/0，也不显示 0%**——「没有回归」与「还没法算」必须可分
    RECUR_MD="**本周复发**：本轮建立基准，复发率下轮起可用"
  elif [ "$_rc_regr" -gt 0 ]; then
    RECUR_MD="**本周复发**：${_rc_regr} / ${_rc_total}（${_rc_regr} 个 issue 在上一轮窗口内无事件，本轮重新出现）"
  else
    RECUR_MD="**本周复发**：0 / ${_rc_total}（无 issue 回归）"
  fi
fi

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
# 数据源停更 ≠ 本周性能平稳。缺了这句，导出断更会被读成「没什么变化」（2026-08-21 日报踩到）。
PERF_STALE_NOTE=""
if [ -n "$IOS_PERF_STALE" ] || [ -n "$AND_PERF_STALE" ]; then
  _ist="正常"; [ -n "$IOS_PERF_STALE" ] && _ist="停更 ${IOS_PERF_STALE} 天（截至 ${IOS_PERF_MAX}）"
  _ast="正常"; [ -n "$AND_PERF_STALE" ] && _ast="停更 ${AND_PERF_STALE} 天（截至 ${AND_PERF_MAX}）"
  PERF_STALE_NOTE="$(printf '\n🟡 **性能数据源停更** — iOS %s · Android %s；Firebase→BigQuery 导出未产出，非流水线故障，本周性能段不可读作「平稳」。' "$_ist" "$_ast")"
fi
NOTE_MD="$(printf '变化摘要口径：BigQuery 事件级（含已关闭 issue，全版本），近 %s 天窗，**纯脚本取数不经模型**。\n取数区间 %sd：%s\n主力版本 = 近 %s 天会话量 top2 **∪ 当日会话量 top1**（上限 3，每行标注入选理由）。⚠️ 「当日主力」那一版的窗口累计可能很小——它入选是因为**现在线上跑的是它**，与「盘子里的大头」是两个问题。日报看的是「版本号最新的 2 个版本」，三者互补，不可混比。\n崩溃率 = 事件数/会话数 · 对照分支：iOS %s · Android %s
Crash-free 会话率 = 1 − 崩溃会话数/会话数，**会话口径**。⚠️ 与控制台首屏的**用户**口径不同、**不可直接对照**（用户率通常更低）；用户率不可得——两个数据源的用户标识不同源。本值为**下界估计**，真实值不低于所示数字。
ANR 仅 Android（iOS 系统层无此概念）；ANR 率与崩溃率同分母，**与 Play 的用户感知 ANR 率口径不同，不可对照商店门槛**。非致命双端**不可比**（收口点覆盖不同）。\n%s%s%s' \
  "$WEEK_DAYS" "$WEEK_DAYS" "$WIN_COMPACT" "$WEEK_DAYS" "$IOS_BR" "$AND_BR" "$ANALYSIS_NOTE" "$PERF_STALE_NOTE" "$FACT_CACHE_NOTE")"

# 入选理由查找（bash 3.2 无关联数组，用行匹配）。⚠️ 取不到时回落「窗口主力」而不是空——
# 空单元格会被读成「渲染坏了」，而绝大多数情形本来就是窗口主力。
adopt_reason() { # $1=平台 $2=版本 → stdout: 入选理由
  local _r
  _r="$(printf '%s' "$ADOPT_REASONS" | awk -F'\t' -v p="$1" -v v="$2" '$1==p && $2==v {print $3; exit}')"
  printf '%s' "${_r:-窗口主力}"
}

# 主力版本表（markdown 与卡片共用同一批数据）
adopt_md() {
  [ -n "$ADOPT_ROWS" ] || { printf '（本次未取到放量数据）\n'; return 0; }
  # ⚠️ 列头显式标 FATAL（analyst G5）——同一行并排三类事件，「崩溃」不标口径会被当总数
  # ⛔ 逐列标注入选理由，**不得一律写「主力」**——「当日主力」那一版的窗口累计可能很小，
  #    读者必须能看出这一列的分母基础与其余列不同。
  printf '| 平台 | 版本 | 入选 | 会话 | 设备 | 崩溃(FATAL) | FATAL率 | Crash-free 会话 | ANR | 非致命 |\n|---|---|---|---|---|---|---|---|---|---|\n'
  printf '%s' "$ADOPT_ROWS" | while IFS=$'\t' read -r _p _v _s _d _c _r _f _a _n; do
    [ -n "$_p" ] || continue
    printf '| %s | %s | %s | %s | %s | %s | %s | %s | %s | %s |\n' \
      "$_p" "$_v" "$(adopt_reason "$_p" "$_v")" "$_s" "$_d" "$_c" "$_r" "$_f" "$_a" "$_n"
  done
}

# 影响面维度段（change crash-impact-summary）。⛔ 与性能段同一条硬约束：只给可定位对象，不出根因——
# 维度聚合只显示相关性，某机型崩溃率高仍可能源自该机型用户的网络环境或功能路径。
dims_md() {
  local any=0 f
  for f in "$OUT_DIR"/dim-*.csv; do [ -s "$f" ] && any=1 && break; done
  [ "$any" = 1 ] || { printf '（本周主力版本无崩溃事件，无维度分布）\n'; return 0; }
  # ⛔ 用**表格**不用「加粗维度名 + 斜体平台版本 + 项目符号」三层嵌套：
  #    同一份数据 L1 日报早就是表（md_csv_table），L2 却是列表——同源数据两种排版，
  #    且列表形态的垂直空间约是表格的 3 倍（2026-08-24 实测该段 64 行）。
  #    平台与版本进列，读者才能横向对照「新版是否引入了新机型问题」。
  dim_table model '机型' '**机型**（绝对数，**未除以装机量**，不代表该机型更易崩）'
  dim_table os    '系统版本' '**系统版本**（含 FATAL+ANR 率，该维度会话桶足够大）'
  printf '%s\n\n' '> 表中 `—` = 该桶会话数不足（低于阈值），率不可靠故不展示——与「无此概念」「缺数」不同义（analyst G6）。⚠️ 本表比率为 **FATAL+ANR / 该系统版本会话**，与二段「FATAL率」（FATAL / 全部会话）**不是同一个率**，实测可差 6 倍以上。'
  # 页面维度（change crash-screen-dimension）。⚠️ 无分母 CSV 只有 4 列，走 dim_table_nd，
  # ⛔ 不能套 dim_table（那份判 NF>=6 读第 5 列作率，套用会静默拿空表）。
  dim_table_nd screen '页面' '**页面**（崩溃发生时所在页面）'
  # ⛔ 缺席的主力版本必须点名，⛔ 不能靠「表里没有那行」让读者自己发现——
  #    「该版本无事件」「查询失败」「被闸门忽略」在版面上长得一模一样（镜头 6）。
  if [ -n "${DIM_ABSENT:-}" ]; then
    printf '%b' "$DIM_ABSENT" | awk -F'\t' 'NF>=4 && ($3=="0" || $4=="0") {
      why = ($3=="0" && $4=="0") ? "该口径下本窗口无事件" : (($3=="0") ? "无致命/卡死事件（机型·系统版本·归因三表不适用）" : "无该端主口径事件（页面表不适用）")
      printf "> ⚠️ **%s %s** 未出现在上方维度表中：%s。\n", $1, $2, why }'
    printf '\n'
  fi
  printf '%s\n' '> ⛔ 页面维度**只给绝对数不给崩溃率**——`firebase_sessions` 表无页面字段，页面级会话分母**不存在**。事件多的页面通常只是访问量大的页面。'
  printf '%s\n\n' '> ⚠️ `(未知)` 是取不到页面的事件，**照常参与排序不予丢弃**；ANR 的页面覆盖率最低（应用卡死时 custom key 写入本身也受影响）。⚠️ iOS 侧存在 UIKit 内部窗口（如 `UITrackingElementWindowController`），**不是业务页面**。'
  blame_md
}

# 有分母维度（机型 / 系统版本）→ 表。列序对应 crash-dimensions.sql：
#   $1 dim · $2 events · $3 users · $4 sessions · $5 rate_pct · $6 concentration
dim_table() { # $1=kind $2=列名 $3=段标题
  local f b pname ver rows=""
  printf '%s\n\n' "$3"
  for f in "$OUT_DIR"/dim-$1-*.csv; do
    [ -s "$f" ] || continue
    b="$(basename "$f" .csv)"; b="${b#dim-$1-}"; pname="${b%%-*}"; ver="${b#*-}"
    rows="${rows}$(csv2tsv < "$f" | awk -F'\t' -v pn="$pname" -v v="$ver" -v sr="$([ "$1" = os ] && echo 1 || echo 0)" -v minS="$DIM_MIN_W" '
      NF>=6 { rate = ($5 == "" || $4 == "" || $4+0 < minS) ? "—" : $5 "%"
        printf "| %s | %s | %s | %s | %s | %s%s |\n", pn, v, $1, $2, $3, $6, (sr ? " | " rate : "") }')
"
  done
  if [ -n "$(printf '%s' "$rows" | tr -d '[:space:]')" ]; then
    # ⚠️ 列名写明 FATAL+ANR（analyst G3）：与二段「FATAL率」同名不同义，实测差 6.7 倍（0.42% vs 2.83%）
    if [ "$1" = os ]; then printf '| 平台 | 版本 | %s | 事件 | 影响安装 | 集中度 | FATAL+ANR率 |\n|---|---|---|---|---|---|---|\n' "$2"
    else printf '| 平台 | 版本 | %s | 事件 | 影响安装 | 集中度 |\n|---|---|---|---|---|---|\n' "$2"; fi
    printf '%s' "$rows" | grep -v '^$' || true
  else
    printf '（本周主力版本该维度无数据）\n'
  fi
  printf '\n'
}

# 无分母维度（页面等）→ 表。列序对应 crash-dimensions-nodenom.sql：
#   $1 dim · $2 events · $3 users · $4 concentration（⚠️ 第 4 列不是会话数）
dim_table_nd() { # $1=kind $2=列名 $3=段标题
  local f b pname ver rows=""
  printf '%s\n\n' "$3"
  for f in "$OUT_DIR"/dim-$1-*.csv; do
    [ -s "$f" ] || continue
    b="$(basename "$f" .csv)"; b="${b#dim-$1-}"; pname="${b%%-*}"; ver="${b#*-}"
    rows="${rows}$(csv2tsv < "$f" | awk -F'\t' -v pn="$pname" -v v="$ver" '
      NF>=4 { printf "| %s | %s | %s | %s | %s | %s |\n", pn, v, $1, $2, $3, $4 }')
"
  done
  if [ -n "$(printf '%s' "$rows" | tr -d '[:space:]')" ]; then
    printf '| 平台 | 版本 | %s | 事件 | 影响安装 | 集中度 |\n|---|---|---|---|---|---|\n' "$2"
    printf '%s' "$rows" | grep -v '^$' || true
  else
    printf '（本周主力版本该维度无数据）\n'
  fi
  printf '\n'
}

# 归因块（change crash-actionable-signals 1.5，与日报汇总段同一口径与同一条警告）。
# ⛔ owner 与 library **必须一起呈现**：实测最有信息量的一行是
#    `SYSTEM · com.prime.dino.english`——归因方是系统、库却是自家包名，那是系统帧被自家代码调用。
#    只看 owner 会读成「系统的问题，与我无关」；只看 library 会读成「自家代码崩了」。两者都不对。
# ── TOP N 事件下钻（change crash-issue-drilldown）───────────────────────────
# 每个 top issue 一个块，六个维度按**可行动性**排序（页面最前，责任帧最后）。
# ⛔ 各维度占比的分母是**该 issue 的事件数**，不是该维度的崩溃率——页面/前后台/内存档
#    都没有会话分母。占比高只说明「这个 issue 集中在这里」，不说明「这里更容易崩」。
# ⚠️ 口径按端不同：Android 用 FATAL+ANR（实测按受影响安装排第一的是个 ANR，
#    纯 FATAL 榜会让它整个消失）；iOS 用 NON_FATAL（60 天仅 5 次致命崩溃）。
dd_block() { # $1=CSV文件 $2=平台名 $3=口径说明 $4=取数是否成功 → markdown 表 + 脚注
  if [ ! -s "$1" ]; then
    # ⛔ 缺数与无异常是两件事：取数失败要说「未取到」，别渲染成「没有 issue」
    if [ "${4:-1}" = "1" ]; then printf '（%s 本窗口无可下钻的 issue）\n\n' "$2"
    else printf '⚠️ （%s 下钻取数失败，本段缺失——不代表没有 issue）\n\n' "$2"; fi
    return 0
  fi
  printf '**%s**（口径：%s）\n\n' "$2" "$3"
  # 列序（11 列，⚠️ SQL 加列必须同步这里——套错不报错只出坏数，2026-08-24 已踩）：
  #  $1 issue_id · $2 title · $3 subtitle · $4 dim · $5 value
  #  $6 events · $7 users · $8 n_distinct · $9 total_events · $10 total_users
  # 表列取舍（analyst 审计 2026-08-24）：
  #  · 「场景」列：iOS 用自埋 scene（覆盖 99.7%，把 190 字符标题压到 20 字符）；
  #    Android scene 覆盖仅 52% 且单一取值，改用 title 末段。完整标题进表下脚注。
  #  · ⛔ 机型不进表——per-issue 唯一机型数≈安装数，「top 机型」是随机一台设备；
  #    只有「集中」或「单台设备」两种有信号的判定进脚注，「分散」不占版面。
  #  · ⛔ 内存档不进表——mem_tier 无会话侧分母，「low 50%」与装机基准率无法区分。
  csv2tsv < "$1" | awk -F'\t' -v plat="$2" -v conc="$DD_MODEL_CONC_PCT" '
    function pct(a, b) { return (b+0 > 0) ? sprintf("%.0f", a/b*100) : "0" }
    function fgcn(x) { if (x=="FOREGROUND") return "前台"; if (x=="BACKGROUND") return "后台"; return x }
    function owner_cn(x) { sub(/^SYSTEM/,"系统",x); sub(/^DEVELOPER/,"自家",x); sub(/^THIRD_PARTY/,"三方",x); sub(/^PLATFORM/,"平台层",x); return x }
    function short_title(t,   n, a, tail) {
      # Android：取「 - 」之后再留末两个点段：Native method - android.os.MessageQueue.nativePollOnce
      # → MessageQueue.nativePollOnce；com.….RemoteAnimationSpecKt.sha256Hex → RemoteAnimationSpecKt.sha256Hex
      tail = t; while (index(tail, " - ") > 0) tail = substr(tail, index(tail, " - ") + 3)
      n = split(tail, a, "."); if (n > 2) return a[n-1] "." a[n]
      return tail
    }
    function flush(   sc, row) {
      if (last == "") return
      if (plat == "iOS" && val["scene"] != "" && val["scene"] != "(未知)") sc = val["scene"]
      else sc = short_title(title)
      row = sprintf("| %s | %s | %s / %s（%.1f） | %s %s%% | %s %s%% | %s · %s%% | %s |", \
        substr(last,1,8), sc, tev, tus, (tus+0>0 ? tev/tus : 0), \
        val["screen"], p["screen"], fgcn(val["fgbg"]), p["fgbg"], val["os"], p["os"], owner_cn(val["blame"]))
      rows = rows row "\n"
      fn = fn "> `" substr(last,1,8) "`：" title ((sub2 != "" && sub2 != title) ? " · " sub2 : "") "\n"
      if (tus+0 <= 1)
        fn = fn "> `" substr(last,1,8) "` 机型：单台设备（" tev " 次）——⛔ 样本仅 1 台判不了机型特异性，需复现\n"
      else if (p["model"]+0 >= conc+0 && nd["model"]+0 <= tus/2)
        fn = fn "> `" substr(last,1,8) "` 机型：⚠️ 集中于 " val["model"] "（" p["model"] "%；共 " nd["model"] " 种机型 / " tus " 台设备）\n"
      delete val; delete p; delete nd
    }
    $1 != last { flush(); last = $1; title = $2; sub2 = $3; tev = $9; tus = $10 }
    { val[$4] = $5; p[$4] = pct($6, $9); nd[$4] = $8 }
    END {
      flush()
      print "| Issue | 场景 | 事件/安装（集中度） | 页面 | 前后台 | 系统版本 | 责任帧 |"
      print "|---|---|---|---|---|---|---|"
      printf "%s\n", rows
      printf "%s", fn
    }'
  printf '\n'
}

blame_md() {
  local any=0 f b pname ver rows=""
  for f in "$OUT_DIR"/blame-*.csv; do [ -s "$f" ] && any=1 && break; done
  [ "$any" = 1 ] || return 0
  printf '**归因**（责任帧属于谁，绝对数）\n\n'
  printf '%s\n' '> ⛔ 归因方标识的是崩溃栈中**被判定为责任帧的那一帧属于谁**，**不是「谁触发了这次崩溃」**。'
  printf '%s\n\n' '> 归因方是「系统」或「三方」**不等于非自家问题**——实测存在「系统帧 + 自家包名」的组合，那是系统帧被自家代码调用。归因方与代码库必须一起读。'
  for f in "$OUT_DIR"/blame-*.csv; do
    [ -s "$f" ] || continue
    b="$(basename "$f" .csv)"; b="${b#blame-}"; pname="${b%%-*}"; ver="${b#*-}"
    rows="${rows}$(csv2tsv < "$f" | awk -F'\t' -v pn="$pname" -v v="$ver" 'NF>=4 {
      o=$1
      if (o=="DEVELOPER") o="自家代码"; else if (o=="THIRD_PARTY") o="三方 SDK"
      else if (o=="SYSTEM") o="系统"
      # ⚠️ PLATFORM 与空值必须映射（analyst G7）：iOS 实测出现裸 PLATFORM、Android 出现 (null)，
      #    不映射就是一行英文枚举混在中文表里
      else if (o=="PLATFORM") o="平台层"; else if (o=="" || o=="(null)" || o=="null") o="(未知)"
      lib=$2; if (lib=="" || lib=="(null)" || lib=="null") lib="(未知)"
      printf "| %s | %s | %s | %s | %s | %s |\n", pn, v, o, lib, $3, $4 }')
"
  done
  if [ -n "$(printf '%s' "$rows" | tr -d '[:space:]')" ]; then
    printf '| 平台 | 版本 | 归因方 | 代码库 | 事件 | 影响安装 |\n|---|---|---|---|---|---|\n'
    printf '%s' "$rows" | grep -v '^$' || true
  else
    printf '（本周主力版本无归因数据）\n'
  fi
  printf '\n'
}

# 性能段表（design D8/D9：只给趋势与对象，不出根因；不进台账，只在周报文档呈现）
perf_md() {
  if [ "$PERF_OK" != "1" ]; then
    printf '（性能数据源不可用，跳过本段；崩溃段变化摘要不受影响）\n'; return 0
  fi
  [ -n "$IOS_PERF_STALE" ] && printf '> ⚠️ **iOS 性能表已停更 %s 天**（截至 %s）——窗口内 0 行，下表 iOS 各列为空是数据源断更，不是「本周无异常」。\n\n' "$IOS_PERF_STALE" "$IOS_PERF_MAX"
  [ -n "$AND_PERF_STALE" ] && printf '> ⚠️ **Android 性能表已停更 %s 天**（截至 %s）——窗口内 0 行，下表 Android 各列为空是数据源断更，不是「本周无异常」。\n\n' "$AND_PERF_STALE" "$AND_PERF_MAX"
  # 完整日窗口标注（design D2）：窗口 + 滞后 + 上游进度三者都给。⛔ 与上方「取数区间 7d」不是一回事——
  # 那一行是崩溃/放量段的口径（锚在跑批时刻的 sessions 活表），性能段是完整日闭区间，两套口径不可混读。
  [ -n "$PERF_LCD" ] && printf '> 性能窗口：**%s**\n\n' "$(win_days "$PERF_WIN_START" "$PERF_LCD" "$RUN_EPOCH" "$PERF_UNTIL")"
  [ -n "$PERF_ROWS" ] || { printf '（本次未取到性能数据）\n'; return 0; }
  printf '| 平台 | 版本 | 启动 P50 | 启动 P95 | P95 WoW | 慢帧最差页 | 慢帧率 | 冻结率 | 接口错误率 |\n|---|---|---|---|---|---|---|---|---|\n'
  printf '%s' "$PERF_ROWS" | awk -F'\t' 'NF>=9{printf "| %s | %s | %sms | %sms | %s | %s | %s%% | %s%% | %s%% |\n",$1,$2,$3,$4,$9,$5,$6,$7,$8}'
  printf '%s\n' '> WoW 基准 = 同 (平台,版本) 至少 4 天前的最近一轮（基准日已标注）；「—（无基准）」= 尚无足够早的记录，⛔ 不是持平。'
  if [ "$PERF_WOW_CROSS" = 1 ]; then
    printf '%s\n' '> ⚠️ **标「跨口径」的 WoW 不可当作真实变化**：本轮性能窗口已切换为完整日闭区间，而基准那一轮取的是锚在跑批时刻的滚动窗（首尾两天残缺）。差值里混着「窗口形状变了」这一项。⛔ 历史不回填不重算，切满一轮后此标注自动消失。'
  fi
  # 第 3 态细分（C 组）：整行为空的版本在这里说清是哪一种，⛔ 不在 6 个格子里各重复一遍。
  # ⚠️ 只给日期不给数值——性能表里的滚动窗口值与 perf-history 存的单轮值口径不同，搬过来会误导。
  if [ -n "$PERF_MISSING" ]; then
    printf '%s' "$PERF_MISSING" | while IFS=$'\t' read -r _mp _mv _mk _md; do
      [ -n "$_mp" ] || continue
      if [ "$_mk" = stale_fetch ]; then
        printf '> ⚠️ **%s %s 本轮未取到性能数据**（上次有值 %s）——历史有值说明这版产出过数据，属取数故障或导出退化，⛔ 不是「这版没问题」。\n' "$_mp" "$_mv" "$_md"
      else
        printf '> — %s %s 尚无性能数据：该版本从未在性能表出现过，属批量表滞后的正常表现。\n' "$_mp" "$_mv"
      fi
    done
  fi
}

MSG="$(cat <<MSG_END
**📊 崩溃周报 · ${DAY} ${TS_HM}${WEEK_TAG:+ $WEEK_TAG}**

$CHANGES_MD

**🚀 主力版本（近 ${WEEK_DAYS} 天会话量 top2 ∪ 当日 top1）**

$(adopt_md)
> $NOTE_MD
MSG_END
)"

# 结构化卡片（CardKit v2，与日报同款；agent 原样投递，仅回填 __REPORT_URL__）
# ⚠️ 卡片只给**补入那一版**打角标（`·当日`）：窗口 top 通常同时也是当日 top，全都打上等于
#    稳态每行都多三个字，白占列宽；而需要解释的恰恰是那个「窗口累计落榜、当日却是大头」的版本。
#    ⛔ 角标只进卡片显示，不进 ADOPT_ROWS，更不进 weekly-metrics.jsonl（那会污染 WoW 匹配键）。
ADOPT_JSON="$(printf '%s' "$ADOPT_ROWS" | while IFS=$'\t' read -r _p _v _s _d _c _r _f _a _n; do
    [ -n "$_p" ] || continue
    _tag=""; [ "$(adopt_reason "$_p" "$_v")" = "当日主力" ] && _tag=" ·当日"
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$_p" "${_v}${_tag}" "$_s" "$_d" "$_c" "$_r" "$_f" "$_a" "$_n"
  done \
  | jq -Rsc 'split("\n") | map(select(length>0) | split("\t")
      | {plat:.[0], ver:.[1], sess:.[2], dev:.[3], crash:.[4], rate:.[5], cfree:.[6], anr:.[7], nf:.[8]})')"
# 只有真出现变化才红；基线与平稳周都是蓝——红色要留给「需要看一眼」的场合
HEADER_COLOR="blue"; [ "$WEEK_STATE" = changed ] && HEADER_COLOR="red"
# ── 卡片图表（change crash-card-charts）────────────────────────────────────
# 飞书 Card 2.0 原生 chart 组件（VChart spec，纯 JSON）。⚠️ 单卡建议 ≤5 图；
# ⛔ 移动端不支持纹理/锥形渐变等属性，只用最基础的 bar/line。
# ⛔ **数据不够就不画**：weekly-metrics 本轮才建立（实测 4 行全是今天），
#    画出来是一条单点"趋势线"——比不画更误导（镜头 5：变化必须有基准）。
CHART_EVENTS='[]'; CHART_SCREEN='[]'; CHART_P95='[]'
if [ -n "$ADOPT_ROWS" ]; then
  # ① 三类事件构成：平台+版本 × FATAL/ANR/非致命。⚠️ iOS 无 ANR 不produce 该系列（不填 0）
  CHART_EVENTS="$(printf '%s' "$ADOPT_ROWS" | awk -F'\t' 'NF>=9{
      gsub(/[^0-9]/,"",$5); a=$8; gsub(/ .*/,"",a); gsub(/[^0-9]/,"",a); n=$9; gsub(/[^0-9]/,"",n)
      k=$1" "$2
      printf "%s\t崩溃(FATAL)\t%s\n", k, ($5==""?0:$5)
      if (a != "") printf "%s\tANR\t%s\n", k, a
      printf "%s\t非致命\t%s\n", k, (n==""?0:n) }' \
    | jq -Rsc 'split("\n")|map(select(length>0)|split("\t")|{x:.[0],type:.[1],y:(.[2]|tonumber? // 0)})')"
fi
# ② 崩溃页面 TOP5（横向条形）——把最可行动的维度放进卡片
if ls "$OUT_DIR"/dim-screen-*.csv >/dev/null 2>&1; then
  CHART_SCREEN="$(for f in "$OUT_DIR"/dim-screen-*.csv; do
      [ -s "$f" ] || continue
      b="$(basename "$f" .csv)"; b="${b#dim-screen-}"
      csv2tsv < "$f" | awk -F'\t' -v k="${b%%-*} ${b#*-}" 'NF>=4{printf "%s · %s\t%s\n", k, $1, $2}'
    done | sort -t"$(printf '\t')" -k2 -rn | head -5 \
    | jq -Rsc 'split("\n")|map(select(length>0)|split("\t")|{x:.[0],y:(.[1]|tonumber? // 0)})' || echo '[]')"
fi
# ③ 启动 P95 趋势（折线，按天取该平台各版本最大值——代表最差体验）
if [ -s "$PERF_HISTORY" ]; then
  CHART_P95="$(jq -sc '[.[]|select(.p95)]|group_by(.platform+.day)
      |map({x:.[0].day, type:.[0].platform, y:([.[].p95]|max)})|sort_by(.x)' "$PERF_HISTORY" 2>/dev/null || echo '[]')"
  # ⛔ 少于 2 个日期不画折线：单点连不成趋势
  [ "$(printf '%s' "$CHART_P95" | jq '[.[].x]|unique|length' 2>/dev/null || echo 0)" -ge 2 ] || CHART_P95='[]'
fi

CARD_JSON="$(jq -n \
  --arg hc "$HEADER_COLOR" --arg ht "📊 崩溃周报 · ${DAY} ${TS_HM}${WEEK_TAG:+ $WEEK_TAG}" \
  --arg ch "$CHANGES_MD" --arg nm "$NOTE_MD" \
  --argjson rows "${ADOPT_JSON:-[]}" \
  --argjson chev "${CHART_EVENTS:-[]}" --argjson chsc "${CHART_SCREEN:-[]}" --argjson chp95 "${CHART_P95:-[]}" \
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
                    {name:"rate",display_name:"崩溃率",data_type:"lark_md",width:"auto",horizontal_align:"left"},
                    {name:"cfree",display_name:"Crash-free",data_type:"text",width:"auto",horizontal_align:"left"},
                    {name:"anr",display_name:"ANR",data_type:"text",width:"auto",horizontal_align:"left"},
                    {name:"nf",display_name:"非致命",data_type:"text",width:"auto",horizontal_align:"left"}],
           rows:$rows}]
         else [{tag:"markdown",content:"（本次未取到放量数据）"}] end)
      + (if ($chev | length) > 0 then [
          {tag:"markdown",content:"<font color=\u0027grey\u0027>**📊 三类事件构成**（iOS 无 ANR 系列，⛔ 不是 0）</font>"},
          {tag:"chart", color_theme:"rainbow",
           chart_spec:{type:"bar", data:{values:$chev}, xField:"x", yField:"y", seriesField:"type",
                       stack:true, legends:{visible:true, position:"bottom"},
                       title:{text:"三类事件（近 7 天，主力版本）"}}}]
         else [] end)
      + (if ($chsc | length) > 0 then [
          {tag:"markdown",content:"<font color=\u0027grey\u0027>**🎯 崩溃页面 TOP5**（绝对数，⛔ 无会话分母故不给率）</font>"},
          {tag:"chart", color_theme:"brand",
           chart_spec:{type:"bar", direction:"horizontal", data:{values:$chsc}, xField:"y", yField:"x",
                       title:{text:"崩溃最多的页面（Android=FATAL+ANR · iOS=NON_FATAL，口径不同不可并读）"}}}]
         else [] end)
      + (if ($chp95 | length) > 0 then [
          {tag:"markdown",content:"<font color=\u0027grey\u0027>**🚀 启动 P95 趋势**（每日各版本最大值＝最差体验）</font>"},
          {tag:"chart", color_theme:"complementary",
           chart_spec:{type:"line", data:{values:$chp95}, xField:"x", yField:"y", seriesField:"type",
                       legends:{visible:true, position:"bottom"},
                       title:{text:"启动 P95（ms，越小越好）"}}}]
         else [] end)
      + [{tag:"div",text:{tag:"plain_text",content:$nm,text_size:"notation",text_color:"grey"}},
         {tag:"markdown",content:"📄 [完整报告](__REPORT_URL__) · 📁 [全部报告](__FOLDER_URL__)"}])}}')"

REPORT="$STATE/reports/$DAY-weekly.md"
{
  printf '# 崩溃周报 · %s %s\n\n' "$DAY" "$WEEK_TAG"
  printf '> 取数区间 %sd：**%s**\n' "$WEEK_DAYS" "$WIN_FULL"
  printf '> 窗口起点 = 本次跑批时刻 − %s 天（SQL 下界）；终点 = sessions 活表实际取到的最新数据。\n' "$WEEK_DAYS"
  printf '## 一、本周变化\n\n%s\n\n' "$CHANGES_MD"
  [ -n "$RECUR_MD" ] && printf '%s\n\n' "$RECUR_MD"
  [ -n "$RECUR_MD" ] && printf '> ⚠️ 「回归」指该 issue 在**上一轮基准日**（取基准里 `last` 的最大值，**不是「上周」**）无记录、本轮重新出现。判定窗口是崩溃段的滚动窗口——「消失」是**窗口内无事件**，⛔ 不等于「已修复」。⛔ 只给分数不给百分比：基准规模小（实测 14 项），百分比是伪精度。\n\n'
  printf '## 二、主力版本（近 %s 天会话量 top2 ∪ 当日 top1）\n\n' "$WEEK_DAYS"
  adopt_md
  printf '\n> 日报盯的是「版本号最新的 2 个版本」（新版发得怎么样），本段盯的是「承载用户最多的版本」（盘子里的大头）。\n'
  printf '> 两段版本集常常不同，各自回答不同的问题，**不可混比**。\n'
  # G4（analyst）：crash-free 与 ANR 的必要标注原本在六段、离数字 155 行——标注必须随数字同现。
  # ⚠️ 六段（NOTE_MD）那份**不能删**，卡片用的是同一份文案。
  printf '%s\n' '> Crash-free 为**会话**口径且为**下界估计**（分子刻意不做 JOIN，见口径段），⛔ 不可与 Firebase 控制台首屏的**用户**口径对照。'
  printf '%s\n' '> ANR 率分母为会话数，与 Play Console「用户感知 ANR 率」（日活分母）**口径不同**，⛔ 不可对照商店门槛。'
  if [ -n "${ADOPT_WOW_MD:-}" ]; then printf '%b' "$ADOPT_WOW_MD"
  elif [ "$ADOPT_OK" = "1" ]; then printf '%s\n' '> 环比：本轮建立基准，下轮起显示与上一周的对比。'
  fi
  printf '\n'
  printf '## 三、影响面分布（近 %s 天，主力版本）\n\n' "$WEEK_DAYS"
  printf '> ⛔ 只给可定位对象与取证方向，**不出根因**——维度聚合只显示相关性，与性能段同一条硬约束。\n'
  printf '> **本节口径 = FATAL + ANR**（影响面需覆盖卡死），与「主力版本」表的崩溃列（仅 FATAL）**不可直接相加对照**。\n\n'
  dims_md
  printf '\n## 四、TOP %s 事件下钻（近 %s 天，主力版本）\n\n' "$DD_TOP_N" "$WEEK_DAYS"
  printf '%s\n' '> ⛔ 各维度占比的分母是**该 issue 自己的事件数**，**不是该维度的崩溃率**——页面 / 前后台 / 内存档都没有会话分母（`firebase_sessions` 表无对应字段）。占比高只说明「这个 issue 集中在这里」，⛔ 不说明「这里更容易崩」。'
  printf '%s\n' '> ⚠️ **两端口径不同不可并读**：Android = FATAL + ANR（实测按受影响安装排第一的是个 ANR，纯致命榜会让它消失）；iOS = NON_FATAL（近 60 天仅 5 次致命崩溃）。'
  # 去重（change crash-report-readability）：owner 的完整读法在三段「归因」注解里已经写过一遍，
  # 此处只留交叉引用 + 本段特有的「未经人工复核」。⛔ 不是删掉，是不在同一份文档里说两遍。
  printf '%s\n' '> ⚠️ 责任帧 `owner` 的读法同三段「归因」注解（**不是谁触发了崩溃**）。⚠️ 本段结论**未经人工复核**。'
  printf '%s\n\n' '> ⛔ 机型**不给 top 值当结论**：实测 per-issue 的唯一机型数≈影响安装数（一设备一机型），此时「top 机型」只是随机一台设备。只在真正集中时才点名，样本仅 1 台时明说判不了。'
  dd_block "$DD_AND_CSV" "Android" "FATAL + ANR" "${DD_AND_OK:-1}"
  dd_block "$DD_IOS_CSV" "iOS" "NON_FATAL" "${DD_IOS_OK:-1}"
  printf '\n## 五、性能（近 %s 天，主力版本，双端分列）\n\n' "$WEEK_DAYS"
  # ⛔ 性能段**不能套用 $WIN_FULL**——那是 sessions 活表的终点。实测 2026-08-24：
  #    sessions 到 08-24 02:11 UTC，而性能表只到 08-22 06:5x UTC，**虚报 43 小时**，
  #    读者会以为 P95 覆盖到今早。各表终点各自算，这是架构文档「缺口本身就是要看见的信息」。
  printf '> 取数区间 %sd：起点同上；**终点按各性能表自己的最新事件**——iOS %s · Android %s。\n' \
    "$WEEK_DAYS" "${IOS_PERF_MAX:-未取到}" "${AND_PERF_MAX:-未取到}"
  printf '%s\n' '> ⚠️ 性能表的同步滞后于 sessions 表是常态；⛔ 不要用一/二段的窗口终点理解本段——两者不是同一个终点。'
  printf '> 性能是连续指标、无追踪 ID，**只给趋势、可定位对象与下一步取证方向，不出根因与修复方案**（硬约束）。\n'
  printf '> **本段不写入台账**（design D8：台账只收有唯一标识、可跨周追踪的崩溃 issue）。\n\n'
  perf_md
  printf '\n> 与日报口径互补但不可混比：日报是日维度当期值，本段是周维度趋势快照，窗口天数不同。\n\n'
  # D2（analyst）：NOTE_MD 里的分析层说明与下方「分析层：…」段重复——文档侧剥掉那一行，
  # ⛔ 不能改 NOTE_MD 本身（卡片与它逐字节共用，卡片读者看不到下面那段）。
  printf '## 六、口径\n\n%s\n' "$(printf '%s\n' "$NOTE_MD" | grep -v '本周无深度分析' | grep -v '根因与修复方案见完整报告' || true)"
  # 排障信息下沉（change crash-report-readability）：run_id 与审计路径不是判读须知，
  # 读者不需要、排障才需要——原先摆在文档开头与取数区间并列，权重被读成同一级。
  # ⚠️ 只加在文档侧：NOTE_MD 被卡片与群消息逐字节共用，改它本身会把审计路径塞进卡片（F37）。
  printf '\n> 本次运行 %s · 审计 $STATE/audit/weekly-%s.events.jsonl（排障用，非判读须知）\n' "$RUN_ID" "$RUN_ID"
  # 数据/分析分层的可见化：读者必须能一眼看出「本周没有根因分析」是模型不可用，
  # 而不是「本周没问题」。缺分析和无异常是两件完全不同的事。
  if [ "$ANALYSIS_OK" = "1" ]; then
    printf '\n> 分析层：✅ 本周含深度分析（根因与修复方案**未经人工复核**，落地前须验证）。\n'
    # spec：有分析时 MUST 同时标注实际执行分析的模型标识与端点归属，且标明是环境声明。
    printf '> 执行者（**环境声明**，非上游确认）：%s\n' "$(model_provenance)"
  else
    printf '\n> 分析层：⚠️ **本周无深度分析** — %s。\n' "$ANALYSIS_SKIP_REASON"
    printf '> 以上数据、台账与变化检测均由 BigQuery + git 纯脚本产出，**不受影响**；缺的只是根因与修复方案。\n'
    printf '> %s\n' "${ANALYSIS_FIX_HINT:-看分析日志定位后重跑。}"
  fi
  # 分析层作为不参与编号的「分析层 · 根因分析」段追加进同一份文档（change crash-weekly-report-composition）。
  # 这里曾经不追加，而是在投递时用 triage 报告**整份覆盖**数据层周报——分析层按 triage skill
  # 自己的模板成文，其 prompt（fetch-snapshot.sh full 模式）从未要求带维度与指标，于是
  # 「分析越成功、周报数据面越空」：2026-08-20 投递的 30,991 字符文档里，主力版本 / 性能 /
  # crash-free / 系统版本 / 取数区间命中数**全为 0**。
  # ⛔ 只丢弃 triage 的第一行 h1（避免文档出现第二个 h1），**其余标题层级一律不动**——
  #    split-fix-list.py 用 `^##\s*.*修复清单` 定位段落，把 `## 四、修复清单` 降成三级会让它
  #    静默失效（找不到就原样返回，退出码 0、无告警）。序号重排的收益是排版，风险是断掉一条
  #    无告警的下游依赖，不划算（design D2）。
  if [ "$ANALYSIS_OK" = "1" ] && [ -s "$TRIAGE_REPORT" ]; then
    printf '\n## 分析层 · 根因分析（模型产出，**未经人工复核**）\n\n'
    awk 'h==0 && /^# /{h=1; next} {print}' "$TRIAGE_REPORT"
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

# 生命周期基准提升：与 SNAP_LAST 同一时机（都必须在 manifest 落盘之前，见上方注释）。
# ⚠️ 顺序不可提前到 render-ledger.sh 之前——渲染判「回归」要看的是**上一轮**的基准，
#    先提升会让每个 issue 的 last 都等于今天，三态永远只渲染出「遗留」。
# ⛔ 基准内容**只由 render-ledger.sh 算**（第 ④ 段），这里只负责落盘：first_seen 的取值优先级
#    在渲染器里已实现一次，调用方再算一遍必然漂移（2026-08-24 实测：调用方按 `first=今天`
#    播种，下一轮反过来把台账里真实的历史首次纳入日期全覆盖成了当天）。
if [ -s "$SEEN_NEXT_FILE" ] && jq -e 'type == "object"' "$SEEN_NEXT_FILE" >/dev/null 2>&1; then
  cp "$SEEN_NEXT_FILE" "$SEEN_FILE"
else
  echo "  ⚠️ 生命周期基准未产出，保持上一轮不变（下轮三态退回两态，不影响其余产物）"
fi

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
if [ -s "$REPORT" ]; then
  # 单一来源：$REPORT 已是完整文档——数据层五段 + （若本轮有）分析层的「分析层 · 根因分析」段。
  #
  # 这里曾是二选一：`if [ -s "$TRIAGE_REPORT" ]` 投模型报告、`elif` 才投数据层周报。
  # 那是一次回归——互斥分支自 Initial commit 就在，而影响面维度段是 2303dcc 才加进数据层的，
  # 加的时候没回头动这里。后果见上方 $REPORT 生成处的注释（08-20 实测数据面全空）。
  # 下方「跳过建文档会永久丢失性能趋势记录」的理由在**有分析的那几周同样成立**，
  # 却只在 fallback 分支被兑现——合并之后两条路径都兑现了。
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
LEDGER_TABLE_PUB=""; LEDGER_TIMELINE_PUB=""; LEDGER_NF_PUB=""
if [ "${LEDGER_RENDER_OK:-0}" = "1" ] && [ -s "$LEDGER_TABLE_FILE" ]; then
  cp "$LEDGER_TABLE_FILE" "$PUBLISH_DIR/docs/ledger-table.md"
  if [ -s "$LEDGER_NF_FILE" ]; then
    cp "$LEDGER_NF_FILE" "$PUBLISH_DIR/docs/ledger-nonfatal-table.md"
    LEDGER_NF_PUB="$PUBLISH_DIR/docs/ledger-nonfatal-table.md"
  fi
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
  --arg ledger_nf "$LEDGER_NF_PUB" \
  --arg ledger_local "$LEDGER_LOCAL" \
  '{type:"weekly", day:$day2, run_id:$run, chat_id:$chat, send:($send=="true"),
    message_file:$msg, card_file:$card,
    create_doc:(if $report != "" then {file:$report, xml_file:$reportxml, title:$title, label:"周报"} else null end),
    archive_append:(if $report != "" then {jsonl_file:$idx, type:"weekly", day:$day, ios:$ios, android:$and} else null end),
    ledger_sync:(if $ledger_table != "" then {table_file:$ledger_table, timeline_file:$ledger_timeline, nonfatal_file:$ledger_nf, local_file:$ledger_local} else null end)}' \
  > "$PUBLISH_DIR/manifest.json"

echo "  ✅ 投递清单 $PUBLISH_DIR/manifest.json（发送=${SEND_FLAG}）"

# ── 投递（确定性，无 LLM）──────────────────────────────
# 生成与投递分两个脚本、串行调用：投递失败不改变本脚本的退出码——数据已落盘，
# 重跑 deliver.sh 即可补投（--idempotency-key 保证不会重复发卡片）。
# CRASH_REPORT_NO_DELIVER=1 可只生成不投递。

# ── 产物自检（2026-09-02 立）——同 crash-daily.sh，理由见那边注释 ──
# ⛔ 放在 `if` 条件位；⚠️ 只告警不中止（数据无误，失效的是增强项）。
if [ -x "$ROOT/bin/test/assert-artifacts.sh" ]; then
  if bash "$ROOT/bin/test/assert-artifacts.sh" "$PUBLISH_DIR" >&2; then :; else
    echo "  ⚠️ 产物自检未通过（见上方 ❌ 行）——数据无误，但产物有增强项失效，投递照常" >&2
  fi
fi
if [ "${CRASH_REPORT_NO_DELIVER:-0}" != "1" ] && [ -x "$ROOT/bin/deliver.sh" ]; then
  "$ROOT/bin/deliver.sh" "$PUBLISH_DIR/manifest.json" || echo "  ⚠️ 投递失败（数据已落盘，可重跑 deliver.sh 补投）"
fi

# ── 8. 收尾 ───────────────────────────────────────────
jq -n --arg t "$TS" --argjson c "$CHANGED" '{last_run:$t,run_id:$t,ok:true,changes:$c}' > "$HEALTH"
audit run.end "" '{"ok":true}'

# latest 软链指向本次跑批产物，供 2.4/2.5 回归对比与人工排查使用（ln -sfn 覆盖式，指向相对路径避免机器间路径漂移）
ln -sfn "$TS" "$STATE/runs/$DAY/L2/latest"

# 同 L1：按前缀删会漏掉 bq-stderr-*.log，改整目录按 mtime 清（两边各清一次，幂等）
find "$STATE/logs" -type f -mtime +60 -delete 2>/dev/null || true
# -maxdepth 1 限定顶层：这是旧平铺布局的遗留清理，不带深度会递归进 runs/ 与 backup/ 误删同名文件
find "$STATE" -maxdepth 1 -name 'snapshot-*.json' -mtime +60 -delete 2>/dev/null || true
cleanup_old_runs "$STATE"
echo "=== 完成，报告：$REPORT ==="
RUN_COMPLETED=1
