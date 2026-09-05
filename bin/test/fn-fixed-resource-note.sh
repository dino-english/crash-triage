#!/usr/bin/env bash
# ⛔ 只有永久固定资源才提示回填；按日期键的日报周报不提示（2026-09-02 用户指出：连续 5 天每天误报一次）
#
# ⚠️ 2026-09-05：本夹具原先**手抄**了一份 deliver.sh 的 case 判据，注释还写着「生产原文，非拷贝」
#    ——实际是拷贝。那种测试测的是副本：生产判据改了它照样全绿。改为 h_load 抽取生产原文，
#    并加一条元测试确认抽取真的成功（抽不到时 h_load 会失败，但断言仍可能因桩而侥幸通过）。
ROOT="${CRASH_REPORT_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}"
. "$ROOT/bin/test/harness.sh"
NEW_RESOURCES="$(mktemp)"
# 夹具桩：只记录副作用，不关心格式（与 deliver.sh 的同名函数逐字节相同纯属巧合，不依赖这点）
note_new() { printf '| %s | `%s` |\n' "$1" "$2" >> "$NEW_RESOURCES"; }

# ⛔ 判据来自生产脚本，不是拷贝
h_load "$ROOT/bin/deliver.sh" is_fixed_resource_key

# 元测试：确认抽取到的确实是生产函数，而不是夹具里残留的同名定义
h_assert_eq "1" "$(grep -c '^is_fixed_resource_key() {' "$ROOT/bin/deliver.sh")" \
  "⛔ 生产脚本里必须存在该函数（它是本夹具的唯一被测对象）"
h_assert_eq "0" "$(grep -c '^is_fixed_resource_key() {' "$0")" \
  "⛔ 夹具自身不得定义同名函数——那会把测试变成测副本"

probe() { # $1=台账键 $2=标题 → 走生产判据决定是否记入
  if is_fixed_resource_key "$1"; then note_new "$2" "https://x/doc"; fi
}
run() { : > "$NEW_RESOURCES"; h_run probe "$1" "$2" >/dev/null; grep -c . "$NEW_RESOURCES"; }

h_assert_eq "0" "$(run 'crash-triage|daily-2026-09-02' '崩溃日报')"  "⛔ 按日期的日报键不提示"
h_assert_eq "0" "$(run 'crash-triage|weekly-2026-08-31' '崩溃周报')" "⛔ 按日期的周报键不提示"
h_assert_eq "1" "$(run 'crash-triage|index' '索引页')"               "✅ 索引页仍提示"
h_assert_eq "1" "$(run 'crash-triage|ledger' '台账')"                "✅ 台账仍提示"
h_assert_eq "1" "$(run '' '计划外新建的临时文档')"                    "✅ 无键的临时文档仍提示（正该被看见）"
h_assert_eq "1" "$(run 'crash-triage|daily-2026-9-2' '日期格式不规范')" "⚠️ 不匹配的日期形状不静默吞掉，宁可多报"
h_summary
