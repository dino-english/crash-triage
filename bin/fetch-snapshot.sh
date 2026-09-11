#!/usr/bin/env bash
# 抓取 Crashlytics 数据 + git 反查修复状态，产出到指定目录；同步维护事实层缓存（$STATE/issues/）。
#
# 两种模式，别混：
#   light（默认，L1 每天）—— 只抓 snapshot.json，不做根因不给方案。日报每天跑完整 triage
#                            既贵又违背「日报轻量」的设计。
#                            自 2026-08-14 起 light 模式从「日报崩溃主数据源」降级为「对照/回退」：
#                            日报崩溃段与卡片计数已改走 BigQuery firebase_crashlytics 事件级，
#                            此处 MCP topIssues 只用于 ①首验期对照两套数值 ②索引页「跟踪中的 issue」
#                            ③修复状态反查（fix_commit）。确认一致后移除（见 change
#                            crash-source-bigquery-migration D4）。
#   full （L2 每周）      —— 跑完整 firebase-crash-triage skill，额外产出 report.md
#                            （含根因与修复方案，标注未经人工复核）。
#
# 事实层缓存（design D4，change crash-ledger-l2-ownership）：两种模式都维护 $STATE/issues/<32位id>.json——
# 崩溃事件是不可变历史，一次抓取永久可用。命中判定 = 本地已存事件数 vs 线上 topIssues 返回的 events 计数：
# 相等则跳过（0 次额外 MCP 调用），线上更多则只抓增量并追加，已有事件记录不改写。
# CRASH_REPORT_FORCE_REFETCH=1 强制忽略缓存全量重抓。
set -euo pipefail

ROOT="${CRASH_REPORT_ROOT:?CRASH_REPORT_ROOT 未设置}"
IOS_APP_ID="1:465344775452:ios:610bc2f8ea0750fff466d9"
AND_APP_ID="1:465344775452:android:2c546b57b0176325f466d9"
OUT_DIR="$1"
MODE="${2:-light}"
mkdir -p "$OUT_DIR"

# STATE 独立解析，与 crash-daily.sh / crash-weekly.sh 同一套公式——本脚本可能被独立调用，
# 不能只依赖调用方 export（2026-08-18 对 REPOS_ROOT 已踩过同类坑，此处照抄该教训）。
STATE="${CRASH_REPORT_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/crash-triage}"
ISSUES_DIR="$STATE/issues"
mkdir -p "$ISSUES_DIR"
FORCE_REFETCH="${CRASH_REPORT_FORCE_REFETCH:-0}"
# ⛔ 给模型看的是**结论**不是变量对照：原文写「CRASH_REPORT_FORCE_REFETCH=1 为 1」，
#    2026-09-11 实测模型收到了却照样报「命中·跳过」，强制重抓形同虚设——
#    而卡片告警里「用 CRASH_REPORT_FORCE_REFETCH=1 重跑可补齐」正是靠它，等于开了张空头支票。
FORCE_REFETCH_WORD=否
# ⚠️ **已订正的过期结论**（2026-09-11 实测）：此处曾注为「`[ … ] && VAR=值` 在条件不成立时
#    会触发 set -e 当场终止脚本」——**不成立**。bash 对 `&&` 列表有豁免（除最后一个命令外），
#    实测 `set -euo pipefail; [ "0" = 1 ] && V=是; echo 到这里` 正常执行、rc=0。
#    真正会被 set -e 打断的是**裸命令**失败（如 `grep -q` 无匹配，F31 说的是这一种）。
#    写成 if 只是为了与本文件其余分支统一、读起来更直白，不是因为 && 有危险。
if [ "$FORCE_REFETCH" = 1 ]; then FORCE_REFETCH_WORD=是; fi

# 观测字段的落盘由本脚本负责，不再交给模型（change crash-fact-cache-deterministic-records）。
# shellcheck disable=SC1091
. "$ROOT/bin/lib/factcache.sh" || { echo "❌ 缺失：bin/lib/factcache.sh" >&2; exit 1; }
# ⚠️ 模型路径走 Firebase topIssues 的**默认 7 天窗**（prompt 里写死「用 Firebase 默认 7 天窗，
#    不要自行扩大窗口」）。这个常量必须与那句 prompt 同步，改一处要改两处。
FACT_WINDOW_DAYS=7

# 业务仓库：优先运行根的同级目录（与 crash-daily/weekly 同一套探测逻辑）。
# 独立调用本脚本时也要能自己解析，不能只依赖调用方传——调用方漏 export 就会 cd 到不存在的路径
# （2026-08-18 实测：周报整跑失败、日报 MCP 对照段被误判成超时）。
if [ -z "${REPOS_ROOT:-}" ]; then
  if [ -d "$(dirname "$ROOT")/dino-english-ios/.git" ]; then
    REPOS_ROOT="$(dirname "$ROOT")"
  else
    REPOS_ROOT="$ROOT/repos"
  fi
fi
IOS_REPO="$REPOS_ROOT/dino-english-ios"
AND_REPO="$REPOS_ROOT/dino-english-android"

# 事实层字段集（1.6 spike 实测确认，见 design.md D3 第 7 点）：
# 堆栈（threads 纯文本 + blameFrame 结构化单帧）、device、operatingSystem、memory.free/used、
# processState、breadcrumbs（含 firebase_screen_class）、issueVariant。current_screen 不可假设存在。
FACT_FIELDS='threads, blameFrame, device, operatingSystem, memory, processState, breadcrumbs, issueVariant, customKeys'

# 事实层缓存策略：**单一事实源**。两处 prompt（light / full 两种模式）都插值引用它。
# ⛔ 不要把这段复制成两份——prompt 是自然语言，没有语法检查、没有 lint，
#    改漏一份不会报错，只会让模型在某个模式下按旧策略执行（change crash-fact-cache-freshness D5）。
#    「消除重复」而不是「检测重复」：用一个同样会被忘记的版本号去防止遗忘，等于没防。
# ── 欠账补抓清单（change crash-fact-cache-events-backfill，design D1）────────
# ⛔ **不让模型自己判断「数组是不是空的」**：它已被证明会跳过读文件那一步——
#    2026-09-08/09 连续两轮自陈「权限阻断」却仍报「命中 N 个（跳过）」。
#    能确定性算出来的不交给模型，模型只干抓取。
# ⚠️ 清单按 id 排序后取前 N，**不随机、不按计数排序**：每轮取同一批直到它们被补上，
#    「欠账数逐轮下降」才能成为可观测的收敛信号。
BACKFILL_LIMIT="${CRASH_REPORT_BACKFILL_LIMIT:-3}"
# ⛔ 用**保留期**（89 天）判「抓不到」，不是取数窗口（7 天）——见 factcache.sh 顶部的订正说明。
BACKFILL_CUTOFF="$(fc_cutoff_date "$FC_RETENTION_DAYS")"
BACKFILL_FROM="$(fc_cutoff_date "$FC_RETENTION_DAYS")T00:00:00Z"
BACKFILL_IDS=""
BACKFILL_N=0
for _bf in "$ISSUES_DIR"/*.json; do
  [ -e "$_bf" ] || continue
  [ "$BACKFILL_N" -lt "$BACKFILL_LIMIT" ] || break
  _bc="$(jq -r '(.events_count_last_seen // 0) | tonumber? // 0' "$_bf" 2>/dev/null || echo 0)"
  _bs="$(jq -r '(.events // []) | length' "$_bf" 2>/dev/null || echo -1)"
  # ⛔ 事件已滑出窗口的记录**不进候选**（findings F-1）：它们抓不到，
  #    而按 id 排序的节流会让它们每轮占住一个名额，把真正可补的永远挤在后面。
  #    2026-09-10 实测：15 条欠账里 13 条已出窗，按 id 排序前三名全是它们。
  if fc_unfetchable "$_bf" "$BACKFILL_CUTOFF"; then continue; fi
  if [ "$_bc" -gt 0 ] 2>/dev/null && [ "$_bs" -eq 0 ] 2>/dev/null; then
    _bid="$(basename "$_bf" .json)"
    BACKFILL_IDS="${BACKFILL_IDS}${BACKFILL_IDS:+ }${_bid}"
    BACKFILL_N=$((BACKFILL_N + 1))
  fi
done
# ⛔ 全角括号先条件赋值再拼接，禁 ${var:+（…）}——bash 会把全角字节并进变量名。
BACKFILL_CLAUSE=""
if [ -n "$BACKFILL_IDS" ]; then
  BACKFILL_CLAUSE="

【本轮欠账补抓】以下 ${BACKFILL_N} 个 issue 的事实层**有计数但一条事件都没存下来**，
本轮对它们**全量抓取**事件明细并写入缓存，忽略判定一的计数比较：
${BACKFILL_IDS}
⛔ 抓这几个时**必须显式传 \`pageSize\`（取 50）与时间区间** \`filter.intervalStartTime=\"${BACKFILL_FROM}\"\` 与
\`filter.intervalEndTime\`=当前时刻——\`crashlytics_list_events\` **默认只查最近 7 天**，
而欠账记录的事件多半在 7 天之外（实测 08-17 的事件放宽窗口后能完整取回）。
不传区间就会空手而归，看起来像「抓不到」，其实是没去要。
⚠️ 只抓这几个，不要扩大范围——其余 issue 仍按判定一处理。"
fi

FACT_CACHE_POLICY="事实层缓存（${ISSUES_DIR}/<32位id>.json，一 issue 一文件，永久保留不清理）——
对每一个 issue 执行**两个独立判定**，不要把它们挤在一起：

【判定一：要不要抓取事件明细】——只决定是否调用 crashlytics_list_events（省的是真钱）
⛔ **只要本判定的结论是「抓」，调 crashlytics_list_events 就必须显式传 `pageSize`（取 50）**——
它的**默认值是 1**，不传就只回一条，事实层永远攒不出样本量，台账/周报的
「✅钻取确认（采样 n=…）」也就永远是 n=1。2026-09-10 实测：同一批 issue 不传共抓到 24 条，
传 pageSize=50 抓到 185 条。⚠️ 全量、增量、强制重抓**三条路径都适用**。
  - **本轮是否强制重抓：${FORCE_REFETCH_WORD}**。为「是」时忽略下面所有计数比较，对每个 issue 都全量抓取。
  - 先用 Read 工具读 ${ISSUES_DIR}/<该 issue 完整 32 位 id>.json。
    - 文件不存在 → 全量抓取，事件按 ${FACT_FIELDS} 等原始字段保存
      （尤其 threads 按原样存文本块，不要假设能拆成帧数组）。
    - 线上计数 **大于** 文件里的 events_count_last_seen → 只抓这次返回的事件，
      按唯一标识（无唯一 id 时用时间戳+blameFrame 组合）与已有 events 数组合并去重，
      **已有事件记录原样保留、不改写**，只 append 新增的。
    - 线上计数 **等于或小于** → **不抓取**（0 次额外 MCP 调用，这是本判定的核心目的）。
      ⚠️ 小于是正常的：线上计数是**滚动窗口内**的取值，老事件出窗即下降，**它不是单调量**。
      计数下降只意味着没有新事件，不意味着这个 issue 该被忽略。

【判定二：观测字段】——**你不要写**
  events_count_last_seen · users_last_seen · window_days · last_synced · latest_event
  这五个字段由调用方在你退出后按快照内容统一回写，**你不要修改它们**。
  你只需保证 events 数组的合并语义（已有记录原样保留、只 append 新增）。

抓取失败（MCP 调用报错/超时）：不中止整体流程，跳过该 issue 的事实层更新，
在报告里标明该 issue 的事实层「抓取失败/不完整」（区分「已查证为空」与「未查」）。"


if [ "$MODE" = "full" ]; then
read -r -d '' PROMPT <<PROMPT_END || true
你是崩溃排查执行器。调用本仓库 skill firebase-crash-triage 并按其完整工作流执行。

appId：
- ios:     ${IOS_APP_ID}
- android: ${AND_APP_ID}

仓库（已 fetch 到最新，只读，禁止任何写操作 / commit / push）：
- iOS:     ${IOS_REPO}
- Android: ${AND_REPO}

**取数口径必须与日报一致**（否则同一天日报说 8 个、周报说 31 个，看的人会失去信任）：
\`crashlytics_get_report{report:'topIssues', filter:{issueErrorTypes:['FATAL']}, pageSize:20}\`，
用 Firebase 默认 7 天窗，不要自行扩大窗口或条数。需要更多上下文时在报告正文里说明，
但 snapshot.json 只放这个口径下的结果。

产出三类文件。**必须先写完 ① 再写 ②③**——完整流程耗时长，
连接中断时至少保住快照，不至于全空（2026-08-07 实测断过一次，两份都没落盘）。

① ${OUT_DIR}/snapshot.json —— 结构严格如下，数字必须是 JSON 数字：
{"ios":[{"id":"32位hex","title":"...","events":N,"users":N,"fix_commit":null,"fix_branches":[]}],"android":[同上结构]}
fix_commit 用 git -C 仓库 log --oneline --all --grep="完整id" 反查，找不到填 null。

② ${OUT_DIR}/report.md —— 按 skill 报告模板写，含根因、版本流转、风险分级与修复方案。
开头必须加一行：> 本报告由每周自动化流程生成，修复方案未经人工复核，落地前须验证。

③ ${FACT_CACHE_POLICY}${BACKFILL_CLAUSE}

若某个仓库的 git 命令无法执行，必须在 report.md 顶部显式声明该平台反查未完成。
不得让 null 冒充「查过没有」。

不 commit、不 push、不改业务代码。三类文件都处理完后只回复 OK，附一行统计：
"事实层：命中 N 个（跳过）· 部分命中 M 个（增量抓取）· 未命中 K 个（全量抓取）· 失败 F 个"。
PROMPT_END
else
read -r -d '' PROMPT <<PROMPT_END || true
你是数据抓取器，只抓不分析、不下结论、不给修复建议。

对以下两个 app 各调一次 crashlytics_get_report，参数 report=topIssues，
filter.issueErrorTypes=["FATAL"]，pageSize=20：
- ios:     ${IOS_APP_ID}
- android: ${AND_APP_ID}

对每个返回的 issue，在对应仓库用完整 32 位 id 反查修复提交：
- iOS:     ${IOS_REPO}
- Android: ${AND_REPO}
命令：git -C 仓库路径 log --oneline --all --grep="完整id"
找到则 fix_commit 记短 hash，找不到记 null。

若某仓库的 git 命令无法执行，在 JSON 顶层加 "git_unavailable": ["android"] 标明。
不得让 null 冒充「查过没有」。

把结果写到 ${OUT_DIR}/snapshot.json，结构严格如下，数字必须是 JSON 数字：
{"ios":[{"id":"32位hex","title":"...","events":N,"users":N,"fix_commit":null,"fix_branches":[]}],"android":[同上结构]}

${FACT_CACHE_POLICY}${BACKFILL_CLAUSE}

写完只回复 OK，附一行统计：
"事实层：命中 N 个（跳过）· 部分命中 M 个（增量抓取）· 未命中 K 个（全量抓取）· 失败 F 个"。
PROMPT_END
fi

# ⛔ **`firebase_read_resources` 必须放行**（2026-09-10 实测根因）：
#    `crashlytics_get_report` 的工具描述原文写着「Agents **must read** the Firebase
#    Crashlytics Reports Guide (firebase://guides/crashlytics/reports) **using the
#    `firebase_read_resources` tool** before calling」。不放行它，模型会拒绝执行并回报
#    「读取 Crashlytics Reports Guide 的权限未获授权」——⚠️ 那句话**字面是真的**，
#    只是措辞让人以为是文件系统权限，我们照这个方向查了半个月（见记忆 model-misreports…）。
#    它是只读工具（读 MCP resource），不违反下面那条「逐个列只读工具」的红线。
# allowedTools 必须逐个列只读工具，禁止 "mcp__firebase" 前缀通配——
# 前缀匹配会放行写操作 crashlytics_update_issue，2026-08-06 已因此误关过线上 issue
# （见 $STATE/ledger/LEDGER.md「事故记录」；change crash-ledger-l2-ownership 起本地源移出仓库）。
# --add-dir 必须带 Android 仓库与 ${STATE}（事实层缓存读写落在 $STATE/issues/，不在两个业务仓库下），
# 否则 git 反查 / 事实层文件访问被权限边界拦下、静默产出未验证的 null。
cd "$IOS_REPO"

# ── 模型调用：一次重试 + 产物校验 + 失败诊断（2026-08-23）────────
# 起因：同日实测同一条命令首次退出码 1、**stdout 与 stderr 全空**，原样重跑即成功。
# 这个失败模式不留任何诊断信息，后果却是静默的——crash-weekly.sh 拿到非零退出码后
# 只在周报与卡片上标一行「本周无深度分析」，整跑照常「成功」退出，没人会去追。
#
# ⛔ **成功判据不能只看退出码**：那次失败里 snapshot.json 写出来了、report.md 没有。
#    只看退出码的话，一个「rc=0 但少写一份产物」的变体会直接溜过去，
#    而下游 crash-weekly.sh 判的是 `[ -s "$OUT_DIR/analysis/report.md" ]`——
#    两处判据不一致，正是「静默降级」的温床。
#
# 重试次数保守取 2：观测到的失败第二次即成功；模型调用不便宜，且 crash-weekly.sh
# 外层还有 TRIAGE_TIMEOUT 兜着，无限重试会把整跑拖成超时（超时的诊断价值更低）。
AGENT_LOG_BASE="$OUT_DIR/agent"
ATTEMPTS="${CRASH_REPORT_AGENT_ATTEMPTS:-2}"
AGENT_RC=1

# ── 模型端点预检：本地代理未监听时尝试拉起（2026-09-01）─────────────
# 起因：2026-08-28 ~ 09-01 连续 5 天、L1 与 L2 的每一次模型调用全部失败，而日志里只有
#   `API Error: Connection refused — a firewall or proxy may be blocking it (ConnectionRefused)`
#   ——不含任何 HTTP 状态码，于是 crash-weekly.sh 的错误码识别落进兜底分支，
#   周报上只写「模型不可用（退出码 1）· 未能从日志识别 API 错误码」，没人知道要去拉什么。
# 根因既不是额度也不是网络：本机 ~/.claude/settings.json 把 ANTHROPIC_BASE_URL 指向
#   http://127.0.0.1:15721（由 cc-switch 提供，LaunchAgent com.ccswitch.desktop，
#   RunAtLoad + KeepAlive 都为 true），而该应用 08-27 20:09 之后不在运行、端口无人监听。
#   同期 curl https://api.anthropic.com 从该机 43ms 可达——**公网可达不等于端点可达**。
#
# ⛔ 只处理「已配置本机端点」这一种情况：未配 ANTHROPIC_BASE_URL、或它不指向本机时一律直接返回。
#    远端可达性不在这里猜——那是模型调用自身连同既有重试/诊断路径的职责。
# ⚠️ 全程不得失败退出。任何一步出错都只降级为「不预检」，让模型调用照常尝试。
#    预检本身绝不能成为整跑失败的原因（新增检查不得走触发 ERR trap 的路径）。
MODEL_PROXY_LABEL="${CRASH_REPORT_MODEL_PROXY_LABEL:-com.ccswitch.desktop}"
MODEL_PROXY_WAIT="${CRASH_REPORT_MODEL_PROXY_WAIT:-20}"

# stdout：本机端点的端口号；未配置、配置不可读或指向非本机时输出空串。
_endpoint_port() {
  local _url
  _url="$(jq -r '.env.ANTHROPIC_BASE_URL // ""' "$HOME/.claude/settings.json" 2>/dev/null || true)"
  case "$_url" in
    http://127.0.0.1:*|http://localhost:*) printf '%s' "${_url##*:}" ;;
    *)                                     printf '' ;;
  esac
}

_port_listening() { lsof -nP -iTCP:"$1" -sTCP:LISTEN >/dev/null 2>&1; }

# 返回值恒为 0：预检只做「尽力恢复 + 如实播报」，判定成败仍由模型调用本身负责。
preflight_model_endpoint() {
  local _port _waited
  _port="$(_endpoint_port)"
  [ -n "$_port" ] || return 0
  _port_listening "$_port" && return 0

  echo "  ⚠️ 模型端点 127.0.0.1:${_port} 无人监听，尝试拉起 ${MODEL_PROXY_LABEL}" >&2
  launchctl kickstart -k "gui/$(id -u)/${MODEL_PROXY_LABEL}" >/dev/null 2>&1 || true

  _waited=0
  while [ "$_waited" -lt "$MODEL_PROXY_WAIT" ]; do
    sleep 2
    _waited=$((_waited + 2))
    if _port_listening "$_port"; then
      echo "  ✅ 模型端点已恢复（${_waited}s）" >&2
      return 0
    fi
  done

  echo "  ⚠️ 拉起后 ${MODEL_PROXY_WAIT}s 内端口仍无人监听；照常调用模型，失败按既有路径诊断" >&2
  return 0
}

preflight_model_endpoint

# allowedTools 必须逐个列只读工具（理由见上方注释块）。
# 把 stream-json 还原成人读的正文：跑批日志里要的是模型说了什么，不是几百行 JSON。
# ⛔ **不得只保留正文**：工具调用（调了哪个 MCP 工具、传了什么参数）只存在于 .jsonl 里，
#    而那正是 2026-09-08 登记为「根因不可判定的唯一阻塞」（失效模式 F45 ③）的东西——
#    2026-09-11 想判「模型到底有没有抓事件」，卡的就是它。
# ⚠️ 桩/旧版 CLI 可能不吐 JSON：解析不出内容时**原样透出**，不要把日志吃空。
agent_text() {
  local line out any=0
  while IFS= read -r line; do
    out="$(printf '%s' "$line" | jq -r 'select(.type=="assistant") | (.message.content[]? | select(.type=="text") | .text) // empty' 2>/dev/null || true)"
    if [ -n "$out" ]; then printf '%s\n' "$out"; any=1; continue; fi
    # 非 JSON（桩、旧版、报错行）原样透出
    if ! printf '%s' "$line" | jq -e . >/dev/null 2>&1; then printf '%s\n' "$line"; any=1; fi
  done
  return 0
}

run_agent() { # $1=尝试序号；输出同时进 stdout（跑批日志）与 agent-<N>.log（事后排查）
  "${AGENT_CMD:-claude}" -p "$PROMPT" \
    --add-dir "$AND_REPO" \
    --add-dir "$STATE" \
    --allowedTools \
      "mcp__firebase__crashlytics_get_report" \
      "mcp__firebase__crashlytics_get_issue" \
      "mcp__firebase__crashlytics_list_events" \
      "mcp__firebase__crashlytics_batch_get_events" \
      "mcp__firebase__firebase_read_resources" \
      "Read" "Write" "Grep" "Glob" \
      "Bash(git log:*)" "Bash(git -C:*)" "Bash(git branch:*)" "Bash(git show:*)" \
    --mcp-config "$ROOT/bin/mcp.json" \
    --output-format stream-json --verbose \
    < /dev/null 2>&1 | tee "${AGENT_LOG_BASE}-$1.jsonl" | agent_text
  # ⚠️ 退出码取**第一段**（模型本身），不是 tee/agent_text 的——pipefail 下最左的失败会胜出，
  #    但 agent_text 恒 0，所以这里拿到的就是模型的码。
}


# 产物齐全才算成功；full 模式多要一份 report.md（与 crash-weekly.sh 的判据对齐）。
artifacts_ok() {
  [ -s "$OUT_DIR/snapshot.json" ] || return 1
  if [ "$MODE" = "full" ]; then [ -s "$OUT_DIR/report.md" ] || return 1; fi
  return 0
}

# ⚠️ 不能写成 `wc -c < "$1" 2>/dev/null`：`<` 的失败发生在 shell 展开阶段、早于 wc 启动，
# wc 的 2>/dev/null 压不住它——文件不存在时会漏出一行 "No such file or directory"，
# 而这个函数正是在「产物缺失」的失败路径上被调用的，等于每次都吐一行噪声。
_bytes() { if [ -f "$1" ]; then wc -c < "$1" | tr -d ' '; else printf '0'; fi; }

for _try in $(seq 1 "$ATTEMPTS"); do
  _t0="$(date +%s)"
  AGENT_RC=0
  run_agent "$_try" || AGENT_RC=$?
  _el="$(( $(date +%s) - _t0 ))"
  if [ "$AGENT_RC" = 0 ] && artifacts_ok; then
    if [ "$_try" -gt 1 ]; then echo "  ✅ 分析层第 $_try 次尝试成功（耗时 ${_el}s）" >&2; fi
    break
  fi
  # 这三行正是上次失败时**全都缺失**的信息：退出码 / 模型输出量 / 产物落盘情况
  echo "  ⚠️ 分析层第 $_try/$ATTEMPTS 次失败：退出码 $AGENT_RC · 耗时 ${_el}s · 模型输出 $(_bytes "${AGENT_LOG_BASE}-$_try.log") 字节" >&2
  echo "     产物 snapshot.json $(_bytes "$OUT_DIR/snapshot.json") 字节 · report.md $(_bytes "$OUT_DIR/report.md") 字节（完整输出见 ${AGENT_LOG_BASE}-$_try.log）" >&2
  if [ "$AGENT_RC" = 0 ]; then AGENT_RC=1; fi   # rc=0 但产物不全，同样判失败
done

# ── 观测字段回写（change crash-fact-cache-deterministic-records D1）──────
# 模型只负责「要不要抓事件明细」与 events 数组；观测字段由这里确定性写入。
# ⛔ 位置必须在**落盘校验之前**：反过来会对刚被隔离（mv 走）的文件写出一份只有观测字段的
#    残缺记录。先回写再隔离，坏文件照常被隔离，下一轮全量重抓补回，与原语义一致。
# ⚠️ 缺文件的**不补建**（factcache.sh 的 rc=3）：补一条带真实计数的记录会让下一轮的抓取
#    判定把它当成已缓存而跳过，事件明细就永远补不回来了。宁可留空让下轮全量重抓。
FC_WROTE=0; FC_MISSING=0; FC_FAILED=0
if [ -s "$OUT_DIR/snapshot.json" ]; then
  FC_NOW="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  while IFS=$'\t' read -r _fid _fplat _ftitle _fev _fus; do
    [ -n "$_fid" ] || continue
    _frc=0
    fc_record "$ISSUES_DIR" "$_fid" "$_fplat" "$_ftitle" "$_fev" "$_fus" "" \
              "$FACT_WINDOW_DAYS" "$FC_NOW" "" || _frc=$?
    case "$_frc" in
      0) FC_WROTE=$((FC_WROTE + 1));;
      3) FC_MISSING=$((FC_MISSING + 1));;
      *) FC_FAILED=$((FC_FAILED + 1));;
    esac
  done < <(jq -r '
    (.ios     // [] | map([.id,"ios",     (.title // ""), ((.events // 0)|tostring), ((.users // 0)|tostring)] | @tsv) | .[]),
    (.android // [] | map([.id,"android", (.title // ""), ((.events // 0)|tostring), ((.users // 0)|tostring)] | @tsv) | .[])
  ' "$OUT_DIR/snapshot.json" 2>/dev/null || true)
  # ⛔ 全角括号先条件赋值再拼接，禁 ${var:+（…）}——bash 会把全角字节并进变量名。
  _fc_extra=""
  if [ "$FC_MISSING" -gt 0 ]; then _fc_extra="${_fc_extra} · 缺文件 ${FC_MISSING} 条（下轮全量重抓）"; fi
  if [ "$FC_FAILED"  -gt 0 ]; then _fc_extra="${_fc_extra} · ⚠️ 写入失败 ${FC_FAILED} 条"; fi
  # ⛔ 必须走 stdout：crash-daily.sh 调本脚本时带 `2>/dev/null`（见其 fetch 段），
  #    写 stderr 等于把「写入失败 N 条」这个信号丢进黑洞。2026-09-08 整跑实测发现。
  echo "  事实层观测字段回写：${FC_WROTE} 条${_fc_extra}"
fi

# ── 事实层落盘校验（2026-08-23）─────────────────────────
# 这些文件由模型用 Write 工具**直接写盘**，shell 侧没有写入点可以校验，唯一能挂的位置是这里。
# 起因：2026-08-21 07:06 那一批 20 个文件里有 12 个是非法 JSON（breadcrumbs 数组多一个 `]`）。
# 事实层「一次抓永久留、不参与清理」，所以坏文件**不会自愈**：此后每一轮跑批的每个下游
# 都在 `jq: parse error` 上静默降级——实测 scan-fix-commits.sh 整个反扫失败，
# 台账「处置状态」列停更，而流水线退出码是 0、卡片上一个字都没提。
#
# 隔离而不是删除：坏文件是模型行为的物证，删掉就再也查不出它当时想写成什么样。
# 隔离后下一轮该 issue 会被判定为「文件不存在」而全量重抓，自动补回。
# 校验放在 AGENT_RC 捕获之后：模型调用失败时更需要校验（半截写入正是坏文件的来源）。
CORRUPT_DIR="$STATE/backup/corrupt-issues-$(date -u +%Y%m%d-%H%M%S)"
CORRUPT_N=0
for f in "$ISSUES_DIR"/*.json; do
  [ -e "$f" ] || continue
  if jq empty "$f" 2>/dev/null; then continue; fi
  mkdir -p "$CORRUPT_DIR"
  if mv "$f" "$CORRUPT_DIR/"; then CORRUPT_N=$((CORRUPT_N + 1)); fi
done
if [ "$CORRUPT_N" -gt 0 ]; then
  echo "  ⚠️ 事实层落盘校验：$CORRUPT_N 个文件不是合法 JSON，已隔离到 ${CORRUPT_DIR}（下轮自动重抓）" >&2
fi

exit "$AGENT_RC"
