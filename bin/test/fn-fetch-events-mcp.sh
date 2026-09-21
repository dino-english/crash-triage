#!/usr/bin/env bash
# bin/fetch-events-mcp.py 的密封夹具（change crash-fact-cache-model-free-events）。
#
# 为什么需要它：这个脚本是事实层唯一的写入点，而它最重要的几条分支
# （429 退避 · 取不到就不落盘 · 不改写已有事件）在真实环境里**难以按需复现**——
# 2026-09-18 的生产实测 6 次调用一次 429 都没碰上。⛔ 「只过代码审查」的分支
# 正是本仓库反复吃亏的地方（失效模式 F52 的根因就藏在一条没人验过的路径里）。
# 用假 MCP server（bin/test/fake-mcp-server.py）把它们逐条打开。
set -uo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SELF_DIR/../.." && pwd)"
# shellcheck disable=SC1091
. "$SELF_DIR/harness.sh"

FETCHER="$ROOT/bin/fetch-events-mcp.py"
FAKE="$SELF_DIR/fake-mcp-server.py"
ID=aaaaaaaabbbbbbbbccccccccdddddddd
TMP=""

_setup() {
  TMP="$(mktemp -d)"
  mkdir -p "$TMP/issues"
}
_teardown() { [ -n "$TMP" ] && rm -rf "$TMP"; }

_run() { # $1=线上计数；其余行为由 FAKE_* 环境变量控制
  printf '%s\tandroid\t%s\n' "$ID" "$1" \
    | env -u PYTHONPATH CRASH_REPORT_MCP_BACKOFF="0.01,0.01" \
        python3 "$FETCHER" --issues-dir "$TMP/issues" \
          --ios-app ios-app --android-app and-app --days 89 --page-size 50 \
          --mcp-command "python3 $FAKE" 2>&1
}
_events_n() { jq '(.events // []) | length' "$TMP/issues/$ID.json" 2>/dev/null || echo -1; }

if [ ! -x "$FETCHER" ] && [ ! -f "$FETCHER" ]; then
  echo "❌ 找不到 $FETCHER"; exit 1
fi
# ⚠️ 没有 PyYAML 就跳过而不是失败：装机闸在 setup.sh，这里报红只会误导。
# ⛔ 但**退出码用 77 不用 0**——0 会让 check-scripts 把「没跑」当成「通过」，
#    而本夹具覆盖的正是 429 退避、取不到不落盘这些生产里碰不到的分支（盲区⑥）。
# 开发机装不上（PEP 668 托管）时的绕法：
#   python3 -m venv /tmp/ct-venv && /tmp/ct-venv/bin/pip install pyyaml
#   PATH="/tmp/ct-venv/bin:$PATH" bash bin/test/fn-fetch-events-mcp.sh
if ! env -u PYTHONPATH python3 -c 'import yaml' 2>/dev/null; then
  echo "ℹ️ 未安装 PyYAML，跳过 fetch-events-mcp 夹具（绕法见本文件头部；装机闸见 bin/setup.sh）"
  exit 77
fi

echo "── 取数：正常抓取并落盘 ──"
_setup
OUT="$(FAKE_EVENT_IDS="e1,e2,e3" _run 0)"
h_assert_eq "3" "$(_events_n)" "3 条事件落盘"
h_assert_contains "$OUT" "全量 1" "统计行报全量 1 个"
_teardown

echo "── 取数：429 退避两轮后成功（⛔ 生产实测碰不到，只能在这里验）──"
_setup
OUT="$(FAKE_429_TIMES=2 FAKE_EVENT_IDS="e1,e2" _run 0)"
h_assert_eq "2" "$(_events_n)" "⛔ 退避后仍要把事件抓回来"
h_assert_absent "$OUT" "失败 1" "两轮内恢复不算失败"
_teardown

echo "── 取数：429 超过退避次数 → 失败且非零退出 ──"
_setup
OUT="$(FAKE_429_TIMES=99 _run 0)"; RC=$?
h_assert_eq "1" "$RC" "⛔ 失败必须非零退出（退出码是唯一失败信号）"
h_assert_contains "$OUT" "429 退避两轮后仍失败" "失败原因要说人话"
h_assert_eq "-1" "$(_events_n)" "⛔ 失败时不得落盘"
_teardown

echo "── 取数：一条事件都没取到 → ⛔ 不落盘（F52 毒记录的防线）──"
_setup
OUT="$(FAKE_MODE=empty _run 0)"; RC=$?
h_assert_eq "1" "$RC" "空结果算失败"
h_assert_eq "-1" "$(_events_n)" "⛔ 宁可不落盘，也不写条数正确、内容中空的记录"
h_assert_contains "$OUT" "不落盘" "日志要说清楚下轮会重抓"
_teardown

echo "── 取数：返回形状不对 → 判失败，不硬塞 ──"
_setup
OUT="$(FAKE_MODE=garbage _run 0)"; RC=$?
h_assert_eq "1" "$RC" "形状不对算失败"
h_assert_eq "-1" "$(_events_n)" "⛔ 不得把非列表结果硬塞进 events"
_teardown

echo "── 合并：已有事件原样保留，只 append 新增 ──"
_setup
printf '{"id":"%s","events":[{"eventId":"old1","marker":"keep-me"}],"events_count_last_seen":1}\n' "$ID" \
  > "$TMP/issues/$ID.json"
OUT="$(FAKE_EVENT_IDS="old1,new1" _run 5)"
h_assert_eq "2" "$(_events_n)" "去重后应为 2 条（old1 不重复计）"
h_assert_eq "keep-me" "$(jq -r '.events[0].marker' "$TMP/issues/$ID.json")" \
  "⛔ 已有事件原样保留、不被改写（fc_compact 压过的也不复原）"
h_assert_eq "1" "$(jq -r '.events_count_last_seen' "$TMP/issues/$ID.json")" \
  "⛔ 观测字段不归本脚本写，必须原样留给 shell"
_teardown

echo "── 判定：线上计数不超过已存真事件数 → 跳过，0 次 MCP 调用 ──"
_setup
printf '{"id":"%s","events":[{"eventId":"old1"},{"eventId":"old2"}]}\n' "$ID" \
  > "$TMP/issues/$ID.json"
OUT="$(_run 2)"
h_assert_contains "$OUT" "跳过 1" "计数未涨要跳过（省的是真钱）"
h_assert_eq "2" "$(_events_n)" "跳过时不动文件"
_teardown

echo "── 判定：占位条目不算已存 → ⛔ 必须重抓（F52）──"
_setup
printf '{"id":"%s","events":[{"format":"x","encoding":"base64","data":"__EVENT_0__"}]}\n' "$ID" \
  > "$TMP/issues/$ID.json"
OUT="$(FAKE_EVENT_IDS="e1,e2" _run 1)"
h_assert_contains "$OUT" "增量 1" "⛔ 占位条目不得被当成已覆盖而跳过"
h_assert_eq "2" "$(jq '[(.events//[])[]|select((.eventId//"")|tostring|length>0)]|length' "$TMP/issues/$ID.json")" \
  "重抓后是 2 条真事件"
_teardown

echo "── 文件损坏：不覆盖、判失败（⛔ 覆盖会把原有事件悄悄丢掉）──"
_setup
printf '{"events":[' > "$TMP/issues/$ID.json"
OUT="$(_run 0)"; RC=$?
h_assert_eq "1" "$RC" "非法 JSON 算失败"
h_assert_contains "$OUT" "非法 JSON" "要点名是文件坏了，不是抓不到"
h_assert_eq "1" "$(grep -c '{"events":\[$' "$TMP/issues/$ID.json" || true)" \
  "⛔ 坏文件原样保留，交给产物断言去报"
_teardown

h_summary
