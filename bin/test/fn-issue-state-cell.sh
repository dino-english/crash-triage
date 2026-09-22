#!/usr/bin/env bash
# issue 明细表的「开关」列（change crash-issue-state-visibility）。
#
# 起因（2026-09-22 实测，`crashlytics_get_report` 与 BigQuery 同窗逐条对）：
# Android FATAL 当窗 12 条，Firebase 只显示 4 条 OPEN——差集 7 CLOSED + 1 MUTED。
# 而差集里有**事件量最大的两条**（fb6588bb 11 次 / 227fc097 10 次，都还在现网 1.7.1 上崩）。
# 它们排在明细表最前面，却一个字没说是关着的：拿 id 去控制台核 → 搜不到 → 判定报告错了。
#
# ⛔ 本夹具钉的是「四态一个都不能合并」，以及**两个渲染点都接上了**（F35：
# 其中一处就是 DRY RUN 预览，即验收工具本身，只改另一处会让预览骗过你）。
ROOT="${CRASH_REPORT_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}"
. "$ROOT/bin/test/harness.sh"

h_load "$ROOT/bin/crash-daily.sh" issue_state_cell

ISSUE_STATES_JSON='{"aaaa":"OPEN","bbbb":"CLOSED","cccc":"MUTED","dddd":"REGRESSED"}'

echo "── 三态各自可辨 ──"
h_assert_eq "开启"     "$(h_run issue_state_cell aaaa)" "OPEN"
h_assert_eq "✅已关闭" "$(h_run issue_state_cell bbbb)" "CLOSED（⛔ 这就是 fb6588bb 那行）"
h_assert_eq "🔕已静音" "$(h_run issue_state_cell cccc)" "MUTED 是第三态，⛔ 不得并进 CLOSED"

echo "── 缺失态必须与 OPEN 可区分（⛔ 不得留空）──"
h_assert_eq "？未取到" "$(h_run issue_state_cell eeee)" "映射里没有这个 id"
ISSUE_STATES_JSON='{}' \
  h_assert_eq "？未取到" "$(ISSUE_STATES_JSON='{}'; h_run issue_state_cell aaaa)" "整张映射为空（同步失败）"

echo "── 未知取值原样透传（⛔ 不得归并到已知三态）──"
h_assert_eq "REGRESSED" "$(h_run issue_state_cell dddd)" "Firebase 日后加状态时宁可看不懂也不要静默吞掉"

echo "── 坏输入不得触发 ERR trap（⛔ 会发一张假故障告警卡）──"
ISSUE_STATES_JSON='不是 JSON'
h_assert_eq "？未取到" "$(ISSUE_STATES_JSON='不是 JSON'; h_run issue_state_cell aaaa)" "jq 解析失败要降级不要炸"
ISSUE_STATES_JSON='{"aaaa":"OPEN"}'

echo "── 源码断言：两个渲染点都必须接上（F35）──"
SRC="$(cat "$ROOT/bin/crash-daily.sh")"
h_assert_contains "$SRC" '"$(life_tag "$fid")" "$(issue_state_cell "$fid")" "$ti" "$n" "$us" "$cc" "$la"' \
  '⛔ markdown 明细表必须调用开关列'
h_assert_contains "$SRC" '"$(life_tag "$fid")" "$(issue_state_cell "$fid")" "$ti" "$n" "$us" "$cc" "$la" "$fid"' \
  '⛔ DocxXML 明细表必须调用开关列'
h_assert_contains "$SRC" "'Issue,生命周期,开关,标题,事件,影响安装,集中度,最新' '1,2,3,4,5,6,7,8'" \
  '⛔ DocxXML 表头与列规格必须同步加列'
h_assert_contains "$SRC" '"1:9:$(issue_url_prefix "$1")"' \
  '⛔ 链接列规格里完整 id 的列号必须从 8 改成 9——改漏不报错，只会静默产出坏链接'
h_assert_absent "$SRC" '| Issue | 状态 | 标题 |' \
  '⛔ 原「状态」列必须改名「生命周期」：它渲染的是 life_tag，与开关状态正交（F26 同名不同义）'

h_summary
