#!/usr/bin/env bash
# 台账「沿用上一轮」（F63）：上一版现状表的 Issue ID 列是 `[短id](url)`，解析时必须剥成短 id。
#
# 起因（2026-10-06 实测）：ID 列自 2026-09-10 起带链接，render-ledger.sh 把原文当键、用短 id 查，
# 于是「反扫未命中时保留上一轮处置状态 / 备注 / 首次纳入」**一次都没生效过**，且无任何报错。
# ⛔ 修键的同时不得沿用开关状态派生的值：8101c07c 09-21 CLOSED → 09-28 重新 OPEN，
#    沿用「✅已关闭」会把重新打开的 issue 显示成已了结（R4 的镜像）。
#
# ⛔ 整脚本跑而不是抽函数：解析上一版表格在脚本顶层，抽函数看不到它。
set -uo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SELF_DIR/../.." && pwd)"
# shellcheck disable=SC1091
. "$SELF_DIR/harness.sh"

_T="$(mktemp -d)"; trap 'rm -rf "$_T"' EXIT
A=4d05f9e74e77520b418eac3a355108f1   # 上一轮有修复状态、本轮反扫未命中 → 应沿用
B=8101c07c8e1f4a2b9c3d4e5f60718293   # 上一轮 ✅已关闭、本轮已重新打开 → 不得沿用
C=0055b556aaaabbbbccccddddeeeeffff   # 上一轮表格用无链接的旧写法 → 同样要能查到
jq -n --arg a "$A" --arg b "$B" --arg c "$C" \
  '{ios:[], android:[{id:$a,title:"ta",events:5},{id:$b,title:"tb",events:2},{id:$c,title:"tc",events:1}]}' > "$_T/snap.json"
echo '{"mapped":{}}' > "$_T/fix.json"
echo '{}' > "$_T/diff.json"
echo '{}' > "$_T/disp.json"
{
  printf '| 平台 | Issue ID | 标题 | 类型 | 首次纳入 | 处置状态 | 本次状态 | 事件量趋势 | 备注 |\n'
  printf '|---|---|---|---|---|---|---|---|---|\n'
  printf '| Android | [4d05f9e7](https://x/issues/%s) | ta | FATAL | 2026-09-15 | 已修待验 | 🔁遗留 | 3 | abc1234 fix: x |\n' "$A"
  printf '| Android | [8101c07c](https://x/issues/%s) | tb | FATAL | 2026-09-01 | ✅已关闭（def5678） | 🔁遗留 | 1 | def5678 fix: y |\n' "$B"
  printf '| Android | 0055b556 | tc | FATAL | 2026-08-20 | 修了仍在 | 🔁遗留 | 1 |  |\n'
} > "$_T/prev.md"

run() { CRASH_REPORT_ROOT="$ROOT" CRASH_REPORT_ISSUE_STATES="" bash "$ROOT/bin/render-ledger.sh" \
          "$_T/snap.json" "$_T/fix.json" "$_T/prev.md" "$_T/diff.json" 2026-10-06 "" "" "" "$_T/disp.json" \
          | tr '\036' '\n' | grep -E '^\| Android \|'; }
out="$(run)"; rc=$?
h_assert_eq "0" "$rc" "整脚本跑通"
row() { printf '%s\n' "$out" | grep -F "$1"; }

echo "── 带链接的上一版表格必须查得到（F63 本体）──"
# ⚠️ 沿用旧两态的「已修待验」时标「（旧口径）」（change crash-fix-release-status：它在四态下有歧义）
h_assert_contains "$(row 4d05f9e7)" '| 已修待验（旧口径） |' '⛔ 反扫未命中时沿用上一轮处置状态——修前这里是「未处理」'
h_assert_contains "$(row 4d05f9e7)" 'abc1234 fix: x'     '⛔ 沿用上一轮备注'
h_assert_contains "$(row 4d05f9e7)" '| 2026-09-15 |'     '⛔ 首次纳入沿用上一轮（基准缺省时）'

echo "── ⛔ 开关状态派生的值不沿用（8101c07c 重新打开）──"
h_assert_contains "$(row 8101c07c)" '| 未处理 |'          '本轮不是 CLOSED → 不得带着「✅已关闭」'
h_assert_absent  "$(row 8101c07c)" '已关闭'              '⛔ 重新打开的 issue 不得显示成已了结'

echo "── 旧写法（无链接）照样查得到 ──"
h_assert_contains "$(row 0055b556)" '| 修了仍在 |'        '无链接的短 id 也要命中'

h_summary
