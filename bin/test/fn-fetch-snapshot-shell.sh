#!/usr/bin/env bash
# fetch-snapshot.sh 的**壳层**密封夹具（change crash-fact-cache-deterministic-records，tasks 3.1/3.3）。
#
# 为什么需要它：这条链路此前只能靠 5 分钟的真跑批验，而它的每一次验证都要花一次模型调用。
# 于是「回写计数打在 stderr 上、而调用方 crash-daily.sh 带 2>/dev/null」这种错，
# 2026-09-08 是**整跑完在日志里怎么找都找不到那行**才发现的（findings F-4）。
# 本夹具用脚本自带的 `AGENT_CMD` 钩子把模型换成桩，让壳层逻辑秒级可验：
# 重试判定 → 观测字段回写 → 非法 JSON 隔离。
#
# ⚠️ HOME 也指向临时目录：模型端点预检读 ~/.claude/settings.json，指开发者真实 HOME
#    会让夹具随本机 cc-switch 是否在跑而飘（那条分支另有 fn-model-endpoint.sh 专测）。
set -uo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SELF_DIR/../.." && pwd)"
# shellcheck disable=SC1091
. "$SELF_DIR/harness.sh"

ID1=1111111122222222333333334444aaaa
ID2=5555555566666666777777778888bbbb
TMP=""

_setup() { # 每个用例一套干净环境
  TMP="$(mktemp -d)"
  mkdir -p "$TMP/home" "$TMP/state/issues" "$TMP/out" \
           "$TMP/repos/dino-english-ios" "$TMP/repos/dino-english-android"
  cat > "$TMP/stub" <<'STUB'
#!/usr/bin/env bash
# 假 agent：忽略全部参数（真 claude 收一长串 --allowedTools），只按 STUB_MODE 产出。
printf '%s\n' "$@" > "$STUB_OUT/prompt.txt"
if [ "${STUB_MODE:-ok}" = ok ]; then
  cat > "$STUB_OUT/snapshot.json" <<JSON
{"ios":[],"android":[
  {"id":"$STUB_ID1","title":"标题一","events":9,"users":2,"fix_commit":null,"fix_branches":[]},
  {"id":"$STUB_ID2","title":"标题二","events":4,"users":1,"fix_commit":null,"fix_branches":[]}]}
JSON
fi
if [ -n "${STUB_DENY:-}" ]; then
  # 照抄真实形状：被拒信息出现在 tool_result 的 content 里
  echo '{"type":"user","message":{"content":[{"type":"tool_result","content":"This command requires approval"}]}}'
  echo '{"type":"user","message":{"content":[{"type":"tool_result","content":"This command requires approval"}]}}'
fi
echo "事实层：命中 1 个（跳过）· 部分命中 0 个（增量抓取）· 未命中 1 个（全量抓取）· 失败 0 个"
STUB
  chmod +x "$TMP/stub"
  # 假事实层取数器（2026-09-18）：把 id 清单与参数原样落盘，零 MCP 调用。
  # ⚠️ 与 AGENT_CMD 同一套形态——欠账补抓的断言从 prompt 搬到了这里，
  #    因为那段行为已经从「写进 prompt 让模型做」改成「喂给确定性脚本」。
  cat > "$TMP/festub" <<'FESTUB'
#!/usr/bin/env bash
cat > "$STUB_OUT/fact-events-stdin.tsv"
printf '%s\n' "$@" > "$STUB_OUT/fact-events-args.txt"
FESTUB
  chmod +x "$TMP/festub"
}
_teardown() { [ -n "$TMP" ] && rm -rf "$TMP"; }

_run() { # stdout 原样返回；⛔ stderr 丢弃——这正是 crash-daily.sh 的调用形态
  CRASH_REPORT_ROOT="$ROOT" CRASH_REPORT_STATE_DIR="$TMP/state" HOME="$TMP/home" \
  REPOS_ROOT="$TMP/repos" AGENT_CMD="$TMP/stub" STUB_OUT="$TMP/out" \
  STUB_ID1="$ID1" STUB_ID2="$ID2" STUB_MODE="${STUB_MODE:-ok}" STUB_DENY="${STUB_DENY:-}" \
  FACT_EVENTS_CMD="$TMP/festub" \
  CRASH_REPORT_AGENT_ATTEMPTS=1 \
    bash "$ROOT/bin/fetch-snapshot.sh" "$TMP/out" light 2>/dev/null
}

echo "── 壳层：观测字段回写 ──"
_setup
# ID1 已有事实层文件（模型往轮攒下的），ID2 没有
printf '{"id":"%s","source":"model","events_count_last_seen":3,"users_last_seen":1,"window_days":7,"latest_event":"2026-09-01 00:00 UTC","events":[{"eventId":"2261816082204424232"}],"last_synced":"2026-08-01T00:00:00Z"}\n' "$ID1" \
  > "$TMP/state/issues/$ID1.json"
OUT="$(_run)"; RC=$?
h_assert_eq "0" "$RC" "整体 rc=0"
# ⛔ 本条是 findings F-4 的回归守卫：stderr 已被丢弃，这行仍必须看得见
h_assert_contains "$OUT" "事实层观测字段回写：1 条" "回写计数在 stdout（⛔ 不得回到 stderr）"
h_assert_contains "$OUT" "缺文件 1 条" "缺文件计入并说明下轮重抓"
_LS="$(jq -r .last_synced "$TMP/state/issues/$ID1.json")"
h_assert_eq "9" "$(jq -r .events_count_last_seen "$TMP/state/issues/$ID1.json")" "计数刷成本轮观测值"
h_assert_eq "model" "$(jq -r .source "$TMP/state/issues/$ID1.json")" "⛔ 不改写 source"
h_assert_eq "1" "$(jq -r '.events|length' "$TMP/state/issues/$ID1.json")" "⛔ 不动 events 数组"
case "$_LS" in *Z) h_assert_contains "$_LS" "$(date -u +%Y-%m-%dT%H)" "last_synced 是本轮真 UTC";; esac
if [ -e "$TMP/state/issues/$ID2.json" ]; then
  echo "  ❌ ⛔ 缺文件不得补建（补了会让下轮抓取判定误判为已缓存）"; H_FAIL=$((H_FAIL+1))
else
  echo "  ✅ ⛔ 缺文件不补建"; H_PASS=$((H_PASS+1))
fi
_teardown

echo "── 壳层：非法 JSON 的回写失败与隔离 ──"
_setup
printf '{坏掉的 JSON\n' > "$TMP/state/issues/$ID1.json"
OUT="$(_run)"; RC=$?
h_assert_eq "0" "$RC" "坏文件不致整体失败（事实层不参与日报数字）"
h_assert_contains "$OUT" "写入失败 1 条" "回写失败被计数并说出来"
if ls "$TMP/state/backup"/corrupt-issues-*/"$ID1.json" >/dev/null 2>&1; then
  echo "  ✅ 坏文件已隔离到 backup/corrupt-issues-*"; H_PASS=$((H_PASS+1))
else
  echo "  ❌ 坏文件未被隔离"; H_FAIL=$((H_FAIL+1))
fi
if [ -e "$TMP/state/issues/$ID1.json" ]; then
  echo "  ❌ 隔离后不该还留在 issues/（下轮据此全量重抓）"; H_FAIL=$((H_FAIL+1))
else
  echo "  ✅ 隔离后 issues/ 里已移除，下轮全量重抓"; H_PASS=$((H_PASS+1))
fi
_teardown

echo "── 壳层：模型没产出快照 ──"
_setup
STUB_MODE=nosnap
OUT="$(_run)"; RC=$?
STUB_MODE=ok
if [ "$RC" != 0 ]; then echo "  ✅ 无 snapshot.json → 非零退出（产物校验，⛔ 不得只看退出码）"; H_PASS=$((H_PASS+1));
else echo "  ❌ 无 snapshot.json 却 rc=0"; H_FAIL=$((H_FAIL+1)); fi
h_assert_absent "$OUT" "观测字段回写" "⛔ 没有快照时不谎报回写"
if ls "$TMP/state/backup"/corrupt-issues-* >/dev/null 2>&1; then
  echo "  ❌ 无坏文件却建了隔离目录"; H_FAIL=$((H_FAIL+1))
else
  echo "  ✅ 无坏文件时不建隔离目录（正常路径安静）"; H_PASS=$((H_PASS+1))
fi
_teardown

echo "── 壳层：欠账补抓清单（design D1/D4）──"
_setup
# 造 5 个欠账记录（计数 > 0、events 为空），id 刻意乱序建，断言取的是排序后的前 3 个
for suffix in ee dd aa cc bb; do
  printf '{"events_count_last_seen":7,"events":[],"window_days":7,"last_synced":"2026-09-01T00:00:00Z"}\n' \
    > "$TMP/state/issues/00000000000000000000000000000${suffix}.json"
done
# 一个**有事件**的记录：⛔ 不得进清单
printf '{"events_count_last_seen":9,"events":[{"eventId":"2261816082204424232"}],"window_days":7,"last_synced":"2026-09-01T00:00:00Z"}\n' \
  > "$TMP/state/issues/00000000000000000000000000000ff.json"
OUT="$(_run)"; RC=$?
FEIN="$(cat "$TMP/out/fact-events-stdin.tsv" 2>/dev/null || echo)"
PROMPT="$(cat "$TMP/out/prompt.txt" 2>/dev/null || echo)"
h_assert_contains "$FEIN" "00000000000000000000000000000aa" "欠账清单喂给取数器：排序第 1 个"
h_assert_contains "$FEIN" "00000000000000000000000000000cc" "欠账清单喂给取数器：排序第 3 个"
h_assert_absent  "$FEIN" "00000000000000000000000000000ee" "⛔ 排序在后的不进本轮清单"
h_assert_absent  "$FEIN" "00000000000000000000000000000ff" "⛔ 有真事件的记录不算欠账"
h_assert_eq "5" "$(printf '%s\n' "$FEIN" | grep -c . || true)" \
  "⛔ 节流生效：3 个欠账 + 2 个本轮快照 issue"
# ⛔ 模型侧必须彻底撒手——它一碰就会写出占位条目（F52）
h_assert_contains "$PROMPT" "只读不写" "prompt 要求事实层只读不写"
# ⛔ 2026-09-21 回归：初版写成「不要读它」，L2 当周证据等级从 4 处✅钻取确认掉到 0 处，
#    模型在报告里原话「未读取…事实层缓存，因此均为⚠️聚合推断」。封锁能力要分清读与写。
h_assert_contains "$PROMPT" "要读" "⛔ 必须要求模型**读**事实层——那是✅钻取确认的唯一依据"
h_assert_absent  "$PROMPT" "不要读它" "⛔ 不得禁止读取（禁读 = 证据等级全线降级）"
h_assert_absent  "$PROMPT" "【本轮欠账补抓】" "⛔ 欠账段不得再进 prompt"
h_assert_absent  "$PROMPT" "失败 F 个" "⛔ 不得再让模型自报事实层统计"
_teardown

echo "── 壳层：占位条目不算真事件（2026-09-18，F52 毒记录）──"
_setup
# ⛔ 数组非空、但一条真事件都没有。只数长度会让「已存」与线上计数相等，
#    `cache_verdict` 从此永久判命中跳过——比缺文件更糟且不自愈。判据见 fc_real_events。
printf '{"events_count_last_seen":5,"events":[{"format":"crashlytics-list-events-yaml","encoding":"base64","data":"__EVENT_0__"}],"window_days":7,"last_synced":"2026-09-01T00:00:00Z"}\n' \
  > "$TMP/state/issues/00000000000000000000000000000a1.json"
# ⚠️ 对照组：同一轮里放一条**真事件**记录，证明新判据不是把谁都判成欠账
printf '{"events_count_last_seen":9,"events":[{"eventId":"2261816082204424232"}],"window_days":7,"last_synced":"2026-09-01T00:00:00Z"}\n' \
  > "$TMP/state/issues/00000000000000000000000000000a2.json"
OUT="$(_run)"; RC=$?
FEIN="$(cat "$TMP/out/fact-events-stdin.tsv" 2>/dev/null || echo)"
h_assert_contains "$FEIN" "00000000000000000000000000000a1" "⛔ 占位条目必须进欠账清单"
h_assert_absent  "$FEIN" "00000000000000000000000000000a2" "⛔ 真事件记录不得被误判成欠账"
_teardown

echo "── 壳层：超出保留期的记录不进候选，其余必须带显式区间 ──"
_setup
# aa/bb 在窗口内、cc/dd/ee 已出窗且 id 排序靠前——⛔ 旧实现会让 cc/dd/ee 占满 3 个名额
# ⚠️ 取 30 天前：它在 7 天取数窗之外、却在 89 天保留期之内——正是 2026-09-10 判错的那一类
_recent="$(date -u -v-30d +'%Y-%m-%d 00:00 UTC' 2>/dev/null || date -u -d '30 days ago' +'%Y-%m-%d 00:00 UTC')"
for suffix in cc dd ee; do
  printf '{"events_count_last_seen":7,"events":[],"window_days":7,"latest_event":"2025-01-01 00:00 UTC","last_synced":"2026-09-01T00:00:00Z"}\n' \
    > "$TMP/state/issues/00000000000000000000000000000${suffix}.json"
done
for suffix in ff gg; do
  printf '{"events_count_last_seen":7,"events":[],"window_days":7,"latest_event":"%s","last_synced":"2026-09-01T00:00:00Z"}\n' \
    "$_recent" > "$TMP/state/issues/00000000000000000000000000000${suffix}.json"
done
OUT="$(_run)"; RC=$?
FEIN="$(cat "$TMP/out/fact-events-stdin.tsv" 2>/dev/null || echo)"
FEARGS="$(cat "$TMP/out/fact-events-args.txt" 2>/dev/null || echo)"
h_assert_absent  "$FEIN" "00000000000000000000000000000cc" "⛔ 超出保留期的不进候选"
h_assert_contains "$FEIN" "00000000000000000000000000000ff" "⛔ 30 天前的记录**必须**进候选（7 天窗之外但保留期之内）"
h_assert_contains "$FEIN" "00000000000000000000000000000gg" "另一条同样进"
# ⛔ 显式区间的要求搬进了取数脚本：它按 --days 自己算 intervalStartTime/EndTime。
#    这里断言「窗口按保留期而不是 7 天取数窗」——不传就是 API 默认 7 天、空手而归。
h_assert_contains "$FEARGS" "--days" "⛔ 必须显式传窗口天数（不传就是 API 默认的 7 天）"
h_assert_contains "$FEARGS" "89" "⛔ 窗口取保留期 89 天，不是 7 天取数窗"
h_assert_eq "4" "$(printf '%s\n' "$FEIN" | grep -c . || true)" \
  "候选数不被超期记录挤掉：2 个欠账 + 2 个本轮快照 issue"
_teardown

echo "── 壳层：强制重抓与 pageSize 必须进 prompt ──"
_setup
STUB_MODE=ok
OUT="$(CRASH_REPORT_FORCE_REFETCH=1 _run)"; RC=$?
FEARGS="$(cat "$TMP/out/fact-events-args.txt" 2>/dev/null || echo)"
h_assert_eq "0" "$RC" "⛔ 非零退出即说明脚本被 set -e 打断（`[ ] && VAR=` 那类写法）"
# ⛔ 强制重抓不再靠 prompt 措辞传达（2026-09-11 实测模型收到了也照样报「命中·跳过」，
#    那张空头支票正是卡片里「用 FORCE_REFETCH=1 重跑可补齐」依赖的）——改成命令行开关。
h_assert_contains "$FEARGS" "--force" "⛔ 强制重抓必须落到取数器的开关上，不是 prompt 措辞"
# ⚠️ 断言要挑**这一段独有**的字样：只查 "pageSize" 会被 topIssues 那行（pageSize=20）蒙混过关
h_assert_contains "$FEARGS" "--page-size" "⛔ pageSize 必须显式传（默认值是 1，事实层永远攒不出样本量）"
h_assert_contains "$FEARGS" "50" "pageSize 取 50（2026-09-10 实测：不传 24 条，传 50 抓到 185 条）"
# ⛔ 工具级日志必须落盘：没有它就判不出「模型到底调没调 list_events」（F45 ③）
if ls "$TMP/out"/agent-*.jsonl >/dev/null 2>&1; then
  echo "  ✅ 模型原始事件流已落盘（agent-*.jsonl）"; H_PASS=$((H_PASS+1))
else
  echo "  ❌ 没有 agent-*.jsonl——工具调用不可见，根因永远判不了"; H_FAIL=$((H_FAIL+1))
fi
h_assert_contains "$OUT" "事实层" "⚠️ 桩的纯文本仍要透出到跑批日志（不得被 JSON 解析吃空）"
_teardown
_setup
OUT="$(_run)"; RC=$?
FEARGS="$(cat "$TMP/out/fact-events-args.txt" 2>/dev/null || echo)"
h_assert_eq "0" "$RC" "⛔ 不强制时同样不得被 set -e 打断"
h_assert_absent "$FEARGS" "--force" "不强制时不得带 --force"
_teardown

echo "── 壳层：无欠账时不加子句 ──"
_setup
printf '{"events_count_last_seen":3,"events":[{"eventId":"2261816082204424232"}],"window_days":7,"last_synced":"2026-09-01T00:00:00Z"}\n' \
  > "$TMP/state/issues/$ID1.json"
OUT="$(_run)"; RC=$?
PROMPT="$(cat "$TMP/out/prompt.txt" 2>/dev/null || echo)"
h_assert_absent "$PROMPT" "【本轮欠账补抓】" "⛔ 无欠账时 prompt 不带该段（正常路径安静）"
FEIN="$(cat "$TMP/out/fact-events-stdin.tsv" 2>/dev/null || echo)"
h_assert_eq "2" "$(printf '%s\n' "$FEIN" | grep -c . || true)" \
  "⛔ 无欠账时只喂本轮快照的 2 个 issue"
_teardown


echo "── 壳层：模型被权限闸拦下必须报出来（2026-09-18，F52）──"
_setup
OUT="$(STUB_DENY=1 _run)"; RC=$?
h_assert_eq "0" "$RC" "⛔ 被拒只提示不判失败——检查自己不得走进 ERR trap（F30/F31）"
h_assert_contains "$OUT" "模型被权限闸拦下 2 次" "⛔ 拦截次数必须出现在跑批日志里"
_teardown
# ⚠️ 反向：正常轮次不得误报——「一个乱红的检查项比不会红的更危险」
_setup
OUT="$(_run)"; RC=$?
h_assert_absent "$OUT" "模型被权限闸拦下" "⛔ 没有被拒时不得误报"
_teardown

h_summary
