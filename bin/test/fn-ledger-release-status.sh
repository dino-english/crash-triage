#!/usr/bin/env bash
# 台账渲染的四态（change crash-fix-release-status）：处置状态列文案 + 时间线取舍。整脚本跑。
#
# ⛔ 两条要钉住：
#   · 判定不可得的条目在处置状态列**明说**，且**不进时间线**——时间线只追加不修改，
#     写进一条只比时间的回退值，下一轮判定恢复后又写一条相反的，永久互相打架
#   · 「已发版待验」带旧包次数；无 release_check 的旧 fixmap 原样透传（向后兼容）
# ⚠️ report_url 必须传非空：空串会让 add_line 末尾的 [ -n … ] 在 set -e 下静默退出（F63 登记里写过）。
set -uo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SELF_DIR/../.." && pwd)"
# shellcheck disable=SC1091
. "$SELF_DIR/harness.sh"

_T="$(mktemp -d)"; trap 'rm -rf "$_T"' EXIT
A=aaaa0000111122223333444455556666; B=bbbb0000111122223333444455556666
C=cccc0000111122223333444455556666; D=dddd0000111122223333444455556666
jq -n --arg a "$A" --arg b "$B" --arg c "$C" --arg d "$D" \
  '{ios:[], android:[{id:$a,title:"ta",events:1},{id:$b,title:"tb",events:1},{id:$c,title:"tc",events:1},{id:$d,title:"td",events:1}]}' > "$_T/snap.json"
jq -n --arg a "$A" --arg b "$B" --arg c "$C" --arg d "$D" '{mapped:{
  ($a):{platform:"android",commit:"a1a1a1a1",subject:"sa",status:"已发版待验",release_check:"ok",old_build_events:2},
  ($b):{platform:"android",commit:"b2b2b2b2",subject:"sb",status:"已修未发版",release_check:"ok",old_build_events:0},
  ($c):{platform:"android",commit:"c3c3c3c3",subject:"sc",status:"已修待验",release_check:"unavailable"},
  ($d):{platform:"android",commit:"d4d4d4d4",subject:"sd",status:"⚠️修了仍在"}}}' > "$_T/fix.json"
jq -n '{ios:{new:[],regressed:[],resolved:[],spiked:[]},android:{new:[],regressed:[],resolved:[],spiked:[]}}' > "$_T/diff.json"
echo '{}' > "$_T/disp.json"

raw="$(CRASH_REPORT_ROOT="$ROOT" CRASH_REPORT_ISSUE_STATES="" bash "$ROOT/bin/render-ledger.sh" \
        "$_T/snap.json" "$_T/fix.json" "" "$_T/diff.json" 2026-10-06 "__REPORT_URL__" "" "" "$_T/disp.json" \
        | tr '\036' '\n')"; rc=$?
h_assert_eq "0" "$rc" "整脚本跑通"
row() { printf '%s\n' "$raw" | grep -E '^\| Android \|' | grep -F "${1:0:8}"; }
tl="$(printf '%s\n' "$raw" | grep -F '🛠️ [android]' || true)"

echo "── 处置状态列 ──"
h_assert_contains "$(row "$A")" '| 已发版待验·旧包仍崩 2 次 |' "已发版待验带旧包次数"
h_assert_contains "$(row "$B")" '| 已修未发版 |'               "已修未发版原样"
h_assert_contains "$(row "$C")" '| 已修待验·发版判定不可得 |'   "⛔ 判定不可得要明说（design D6）"
h_assert_contains "$(row "$D")" '| ⚠️修了仍在 |'               "无 release_check 的旧 fixmap 原样透传"

echo "── 时间线 ──"
h_assert_contains "$tl" 'a1a1a1a1' "判定可得的进时间线"
h_assert_contains "$tl" 'b2b2b2b2' "判定可得的进时间线"
h_assert_absent   "$tl" 'c3c3c3c3' "⛔ 判定不可得的不进时间线（只追加不修改，写进去就永久打架）"
h_assert_absent   "$tl" '旧包仍崩'  "⛔ 时间线不带旧包次数：次数每周变，带上就每周多一条同义行"

h_summary
