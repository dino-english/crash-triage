#!/usr/bin/env bash
# 抓取 Crashlytics 数据 + git 反查修复状态，产出到指定目录。
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
set -euo pipefail

ROOT="${CRASH_REPORT_ROOT:?CRASH_REPORT_ROOT 未设置}"
IOS_APP_ID="1:465344775452:ios:610bc2f8ea0750fff466d9"
AND_APP_ID="1:465344775452:android:2c546b57b0176325f466d9"
OUT_DIR="$1"
MODE="${2:-light}"
mkdir -p "$OUT_DIR"

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

产出两份文件。**必须先写完 ① 再写 ②**——完整流程耗时长，
连接中断时至少保住快照，不至于全空（2026-08-07 实测断过一次，两份都没落盘）。

① ${OUT_DIR}/snapshot.json —— 结构严格如下，数字必须是 JSON 数字：
{"ios":[{"id":"32位hex","title":"...","events":N,"users":N,"fix_commit":null,"fix_branches":[]}],"android":[同上结构]}
fix_commit 用 git -C 仓库 log --oneline --all --grep="完整id" 反查，找不到填 null。

② ${OUT_DIR}/report.md —— 按 skill 报告模板写，含根因、版本流转、风险分级与修复方案。
开头必须加一行：> 本报告由每周自动化流程生成，修复方案未经人工复核，落地前须验证。

若某个仓库的 git 命令无法执行，必须在 report.md 顶部显式声明该平台反查未完成。
不得让 null 冒充「查过没有」。

不 commit、不 push、不改业务代码。两份文件都写完后只回复 OK。
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

写完只回复 OK，不要输出别的。
PROMPT_END
fi

# allowedTools 必须逐个列只读工具，禁止 "mcp__firebase" 前缀通配——
# 前缀匹配会放行写操作 crashlytics_update_issue，2026-08-06 已因此误关过线上 issue
# （见 reports/LEDGER.md「事故记录」）。
# --add-dir 必须带 Android 仓库，否则 git 反查被权限边界拦下、静默产出未验证的 null。
cd "$IOS_REPO"
"${AGENT_CMD:-claude}" -p "$PROMPT" \
  --add-dir "$AND_REPO" \
  --allowedTools \
    "mcp__firebase__crashlytics_get_report" \
    "mcp__firebase__crashlytics_get_issue" \
    "mcp__firebase__crashlytics_list_events" \
    "mcp__firebase__crashlytics_batch_get_events" \
    "Read" "Write" "Grep" "Glob" \
    "Bash(git log:*)" "Bash(git -C:*)" "Bash(git branch:*)" "Bash(git show:*)" \
  --mcp-config "$ROOT/bin/mcp.json" \
  < /dev/null
