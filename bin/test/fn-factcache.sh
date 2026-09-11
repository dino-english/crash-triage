#!/usr/bin/env bash
# fc_record（bin/lib/factcache.sh）与事实层断言的函数级 / 脚本级用例。
# change crash-fact-cache-deterministic-records，tasks 2.2 / 2.4 / 4.2。
#
# ⚠️ 跑在生产 shell 设置下（harness.sh）——夹具少了 set -e + ERR trap 就测不出
#    「过程中踩了 ERR trap」这类问题（docs/CLAUDE-测试盲区.md 盲区③）。
set -uo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SELF_DIR/../.." && pwd)"
# shellcheck disable=SC1091
. "$SELF_DIR/harness.sh"
# shellcheck disable=SC1091
. "$ROOT/bin/lib/factcache.sh"

echo "── fn-factcache：观测字段落盘 ──"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
ID=aaaaaaaabbbbbbbbccccccccdddddddd
NOW="2026-09-08T00:30:12Z"

# ① 缺文件且未获准新建 → rc=3，且**不得**建出文件（D7：补建会让下轮抓取判定误判为已缓存）
h_assert_rc 3 fc_record "$TMP" "$ID" android "标题" 11 2 "" 7 "$NOW" ""
if [ -e "$TMP/$ID.json" ]; then
  echo "  ❌ rc=3 时不该建出文件"; H_FAIL=$((H_FAIL+1))
else
  echo "  ✅ rc=3 时不建文件"; H_PASS=$((H_PASS+1))
fi

# ② 获准新建 → 字段齐全；latest 为空写 null（不是空串——空串会污染后续 max 比较）
h_run fc_record "$TMP" "$ID" android "标题" 11 2 "" 7 "$NOW" bigquery >/dev/null
h_assert_eq "11"        "$(jq -r '.events_count_last_seen' "$TMP/$ID.json")" "新建写入计数"
h_assert_eq "7"         "$(jq -r '.window_days' "$TMP/$ID.json")"            "新建写入窗口天数"
h_assert_eq "$NOW"      "$(jq -r '.last_synced' "$TMP/$ID.json")"            "新建写入本轮时刻"
h_assert_eq "null"      "$(jq -r '.latest_event' "$TMP/$ID.json")"           "latest 为空写 null"
h_assert_eq "bigquery"  "$(jq -r '.source' "$TMP/$ID.json")"                 "新建写入 source"

# ③ 就地更新：不碰 source、不碰 events 数组
jq '.source="model" | .events=[{"e":1}]' "$TMP/$ID.json" > "$TMP/x" && mv "$TMP/x" "$TMP/$ID.json"
h_run fc_record "$TMP" "$ID" android "标题" 9 1 "2026-09-07 10:00 UTC" 7 "2026-09-08T01:00:00Z" "" >/dev/null
h_assert_eq "model" "$(jq -r '.source' "$TMP/$ID.json")"        "更新不改写 source"
h_assert_eq "1"     "$(jq -r '.events | length' "$TMP/$ID.json")" "更新不动 events 数组"
h_assert_eq "9"     "$(jq -r '.events_count_last_seen' "$TMP/$ID.json")" "计数下降时照样刷新（窗口非单调）"

# ④ latest_event 取 max，只进不退
h_run fc_record "$TMP" "$ID" android "标题" 9 1 "2026-09-01 00:00 UTC" 7 "2026-09-08T02:00:00Z" "" >/dev/null
h_assert_eq "2026-09-07 10:00 UTC" "$(jq -r '.latest_event' "$TMP/$ID.json")" "更早的 latest 不倒退"
h_run fc_record "$TMP" "$ID" android "标题" 9 1 "2026-09-08 00:00 UTC" 7 "2026-09-08T03:00:00Z" "" >/dev/null
h_assert_eq "2026-09-08 00:00 UTC" "$(jq -r '.latest_event' "$TMP/$ID.json")" "更晚的 latest 前进"

# ⑤ 正常路径必须安静（F30：乱报的检查会训练人忽略告警）
h_assert_silent fc_record "$TMP" "$ID" android "标题" 9 1 "" 7 "$NOW" ""

echo "── fn-factcache：事件体积收口（分层保留）──"
B="$(mktemp -d)"
python3 - "$B/x.json" <<'PYJ'
import json,sys
# 20 条事件，breadcrumbs 是**字符串**（与线上一致，⛔ 不是数组——按数组写的版本一个字节没减）
evs=[{"eventId":str(i),"eventTime":f"2026-09-{i+1:02d}T00:00:00Z","version":{"v":"1.6.0"},
      "blameFrame":{"f":"keep"},"issue":{"id":"abc"},"device":{"m":"x"*200},
      "breadcrumbs":"L"*3000} for i in range(20)]
json.dump({"id":"x","events":evs}, open(sys.argv[1],"w"))
PYJ
SZ0=$(wc -c < "$B/x.json")
h_run fc_trim_events "$B/x.json" 5 >/dev/null
h_assert_eq "20" "$(jq -r '.events | length' "$B/x.json")" "⛔ 事件条数一条不减（采样 n 靠它）"
h_assert_eq "5"  "$(jq -r '[.events[]|select(.breadcrumbs)] | length' "$B/x.json")" "只有最近 5 条留 breadcrumbs"
h_assert_eq "20" "$(jq -r '[.events[]|select(.blameFrame)] | length' "$B/x.json")" "⛔ blameFrame 全保留——分析真正吃的是它"
h_assert_eq "20" "$(jq -r '[.events[]|select(.eventTime)] | length' "$B/x.json")" "⛔ eventTime 全保留（scan-fix-commits 读它）"
h_assert_eq "2026-09-20T00:00:00Z" "$(jq -r '.events[-1].eventTime' "$B/x.json")" "留细节的是**最近**那几条，不是最早的"
if [ "$(wc -c < "$B/x.json")" -lt "$SZ0" ]; then echo "  ✅ 体积真的降了（$SZ0 → $(wc -c < "$B/x.json")）"; H_PASS=$((H_PASS+1));
else echo "  ❌ 体积没变——多半又把 breadcrumbs 当成数组了"; H_FAIL=$((H_FAIL+1)); fi
h_run fc_trim_events "$B/x.json" 5 >/dev/null
h_assert_eq "5" "$(jq -r '[.events[]|select(.breadcrumbs)] | length' "$B/x.json")" "幂等：再跑一次不变"
rm -rf "$B"

echo "── fn-factcache：断言判时刻不判日期（三向）──"
# ⛔ 这三条是本 change 的核心回归。改之前第三条（本地时间标 Z）在 L1 场景**会误过**。
A_DIR="$(mktemp -d)"; mkdir -p "$A_DIR/issues"
cat > "$A_DIR/snap.json" <<JSON
{"ios":[],"android":[{"id":"$ID","title":"fixture","events":1,"users":1,"fix_commit":null,"fix_branches":[]}]}
JSON
_mk() { # $1=last_synced 值
  printf '{"last_synced":"%s","window_days":7,"latest_event":"2026-09-06 01:00 UTC","events":[]}\n' \
    "$1" > "$A_DIR/issues/$ID.json"
}
_assert_run() { CRASH_REPORT_STATE_DIR="$A_DIR" bash "$SELF_DIR/assert-fact-cache.sh" "$A_DIR/snap.json"; }

_mk "$(date -u +%Y-%m-%dT%H:%M:%SZ)"                 # 真 UTC，本轮
h_assert_rc 0 _assert_run
_mk "$(date -u -v-2d +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d '2 days ago' +%Y-%m-%dT%H:%M:%SZ)"
h_assert_rc 1 _assert_run                            # 真 UTC，但是上一轮
_mk "$(date -u -v+8H +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d '8 hours' +%Y-%m-%dT%H:%M:%SZ)"
h_assert_rc 1 _assert_run                            # 本地时间标 Z（快 8 小时的未来时刻）

# ⑥ 覆盖率行必须出现，且不改变退出码
_mk "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
COV="$(_assert_run 2>&1)"
h_assert_contains "$COV" "事件数对照" "事件数对照行可见"
h_assert_rc 0 _assert_run
rm -rf "$A_DIR"

h_summary
