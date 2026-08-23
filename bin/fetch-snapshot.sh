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
FACT_CACHE_POLICY="事实层缓存（${ISSUES_DIR}/<32位id>.json，一 issue 一文件，永久保留不清理）——
对每一个 issue 执行**两个独立判定**，不要把它们挤在一起：

【判定一：要不要抓取事件明细】——只决定是否调用 crashlytics_list_events（省的是真钱）
  - 强制重抓：若环境要求 CRASH_REPORT_FORCE_REFETCH=${FORCE_REFETCH} 为 1，直接全量抓取。
  - 先用 Read 工具读 ${ISSUES_DIR}/<该 issue 完整 32 位 id>.json。
    - 文件不存在 → 全量抓取，事件按 ${FACT_FIELDS} 等原始字段保存
      （尤其 threads 按原样存文本块，不要假设能拆成帧数组）。
    - 线上计数 **大于** 文件里的 events_count_last_seen → 只抓这次返回的事件，
      按唯一标识（无唯一 id 时用时间戳+blameFrame 组合）与已有 events 数组合并去重，
      **已有事件记录原样保留、不改写**，只 append 新增的。
    - 线上计数 **等于或小于** → **不抓取**（0 次额外 MCP 调用，这是本判定的核心目的）。
      ⚠️ 小于是正常的：线上计数是**滚动窗口内**的取值，老事件出窗即下降，**它不是单调量**。
      计数下降只意味着没有新事件，不意味着这个 issue 该被忽略。

【判定二：要不要更新观测字段】——**无条件执行**，与判定一的结果无关
  无论上面是否抓取，都必须把这些字段刷新为本轮观测值：
    events_count_last_seen（本次计数）· users_last_seen · window_days（本次窗口天数）
    · last_synced（本轮 ISO8601 时刻）
  latest_event 特殊：取 **max(已存值, 本次观测值)**，只进不退。
    ⚠️ 窗口内的最新事件时刻**同样非单调**——最新那条出窗后，剩余事件的最大时刻会比上一轮更早。
    直接覆盖会让台账的「最近一次发生」倒退，读者据此判断「很久没出现了」，正好相反。
  ⚠️ 跳过观测字段更新**省不下任何东西**，却会让「最近同步」停在历史某一刻——
  一个正在衰减（= 正在被修好）的 issue 会看起来像「数据停更」，好消息被读成故障。

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

③ ${FACT_CACHE_POLICY}

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

${FACT_CACHE_POLICY}

写完只回复 OK，附一行统计：
"事实层：命中 N 个（跳过）· 部分命中 M 个（增量抓取）· 未命中 K 个（全量抓取）· 失败 F 个"。
PROMPT_END
fi

# allowedTools 必须逐个列只读工具，禁止 "mcp__firebase" 前缀通配——
# 前缀匹配会放行写操作 crashlytics_update_issue，2026-08-06 已因此误关过线上 issue
# （见 $STATE/ledger/LEDGER.md「事故记录」；change crash-ledger-l2-ownership 起本地源移出仓库）。
# --add-dir 必须带 Android 仓库与 ${STATE}（事实层缓存读写落在 $STATE/issues/，不在两个业务仓库下），
# 否则 git 反查 / 事实层文件访问被权限边界拦下、静默产出未验证的 null。
cd "$IOS_REPO"
AGENT_RC=0
"${AGENT_CMD:-claude}" -p "$PROMPT" \
  --add-dir "$AND_REPO" \
  --add-dir "$STATE" \
  --allowedTools \
    "mcp__firebase__crashlytics_get_report" \
    "mcp__firebase__crashlytics_get_issue" \
    "mcp__firebase__crashlytics_list_events" \
    "mcp__firebase__crashlytics_batch_get_events" \
    "Read" "Write" "Grep" "Glob" \
    "Bash(git log:*)" "Bash(git -C:*)" "Bash(git branch:*)" "Bash(git show:*)" \
  --mcp-config "$ROOT/bin/mcp.json" \
  < /dev/null || AGENT_RC=$?

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
