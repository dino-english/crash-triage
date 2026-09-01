ROOT="${CRASH_REPORT_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}"
. "$ROOT/bin/test/harness.sh"; . "$ROOT/bin/lib/common.sh"
XC_HEAD="#DCE9FF"; XC_ZEBRA="#F5F5F5"
h_load "$ROOT/bin/crash-daily.sh" xml_csv_table
C="$(mktemp)"; printf '"2a800b33","长期","标题 <危险> & 符号","1","1","1.0","2026-08-29","2a800b339e12b94bc2d4555c63859df8"\n' > "$C"

# 负向：不传第 4 参 → 必须与改造前完全一样（无 <a>）
out="$(h_run xml_csv_table "$C" 'Issue,状态,标题,事件,影响安装,集中度,最新' '1,2,3,4,5,6,7')"
h_assert_eq "" "$(printf '%s' "$out" | grep -o '<a href' || true)" "不传规格 → 无链接（其余 9 个调用点不受影响）"
h_assert_contains "$out" '&lt;危险&gt; &amp; 符号' "字段值仍被转义"

# 正向：传规格 → 显示列变成链接，href 用完整 id
out="$(h_run xml_csv_table "$C" 'Issue,状态,标题,事件,影响安装,集中度,最新' '1,2,3,4,5,6,7' "1:8:$(issue_url_prefix ios)")"
h_assert_contains "$out" '<a href="https://console.firebase.google.com' "传规格 → 出链接"
h_assert_contains "$out" 'issues/2a800b339e12b94bc2d4555c63859df8">2a800b33</a>' "href 用完整 32 位、显示 8 位"
h_assert_eq "" "$(printf '%s' "$out" | grep -o '<a href=[^"]' || true)" "href 有引号包裹"

# 边界：完整 id 列为空 → 回落纯文本，不出半个链接
printf '"2a800b33","长期","T","1","1","1.0","2026-08-29",""\n' > "$C"
out="$(h_run xml_csv_table "$C" 'Issue,状态,标题,事件,影响安装,集中度,最新' '1,2,3,4,5,6,7' "1:8:$(issue_url_prefix ios)")"
h_assert_eq "" "$(printf '%s' "$out" | grep -o '<a href' || true)" "id 列为空 → 回落纯文本"
h_summary
