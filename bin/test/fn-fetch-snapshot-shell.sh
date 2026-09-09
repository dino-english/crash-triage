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
echo "事实层：命中 1 个（跳过）· 部分命中 0 个（增量抓取）· 未命中 1 个（全量抓取）· 失败 0 个"
STUB
  chmod +x "$TMP/stub"
}
_teardown() { [ -n "$TMP" ] && rm -rf "$TMP"; }

_run() { # stdout 原样返回；⛔ stderr 丢弃——这正是 crash-daily.sh 的调用形态
  CRASH_REPORT_ROOT="$ROOT" CRASH_REPORT_STATE_DIR="$TMP/state" HOME="$TMP/home" \
  REPOS_ROOT="$TMP/repos" AGENT_CMD="$TMP/stub" STUB_OUT="$TMP/out" \
  STUB_ID1="$ID1" STUB_ID2="$ID2" STUB_MODE="${STUB_MODE:-ok}" \
  CRASH_REPORT_AGENT_ATTEMPTS=1 \
    bash "$ROOT/bin/fetch-snapshot.sh" "$TMP/out" light 2>/dev/null
}

echo "── 壳层：观测字段回写 ──"
_setup
# ID1 已有事实层文件（模型往轮攒下的），ID2 没有
printf '{"id":"%s","source":"model","events_count_last_seen":3,"users_last_seen":1,"window_days":7,"latest_event":"2026-09-01 00:00 UTC","events":[{"e":1}],"last_synced":"2026-08-01T00:00:00Z"}\n' "$ID1" \
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
printf '{"events_count_last_seen":9,"events":[{"e":1}],"window_days":7,"last_synced":"2026-09-01T00:00:00Z"}\n' \
  > "$TMP/state/issues/00000000000000000000000000000ff.json"
OUT="$(_run)"; RC=$?
PROMPT="$(cat "$TMP/out/prompt.txt" 2>/dev/null || echo)"
h_assert_contains "$PROMPT" "【本轮欠账补抓】" "prompt 里出现欠账补抓段"
h_assert_contains "$PROMPT" "以下 3 个 issue" "⛔ 节流生效：只放 3 个（造了 5 个欠账）"
h_assert_contains "$PROMPT" "00000000000000000000000000000aa" "取排序后的第 1 个"
h_assert_contains "$PROMPT" "00000000000000000000000000000cc" "取排序后的第 3 个"
h_assert_absent  "$PROMPT" "00000000000000000000000000000ee" "⛔ 排序在后的不进本轮清单"
h_assert_absent  "$PROMPT" "00000000000000000000000000000ff" "⛔ 有事件的记录不算欠账"
_teardown

echo "── 壳层：无欠账时不加子句 ──"
_setup
printf '{"events_count_last_seen":3,"events":[{"e":1}],"window_days":7,"last_synced":"2026-09-01T00:00:00Z"}\n' \
  > "$TMP/state/issues/$ID1.json"
OUT="$(_run)"; RC=$?
PROMPT="$(cat "$TMP/out/prompt.txt" 2>/dev/null || echo)"
h_assert_absent "$PROMPT" "【本轮欠账补抓】" "⛔ 无欠账时 prompt 不带该段（正常路径安静）"
_teardown

h_summary
