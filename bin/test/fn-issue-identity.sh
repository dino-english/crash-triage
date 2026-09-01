ROOT="${CRASH_REPORT_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}"
. "$ROOT/bin/test/harness.sh"
. "$ROOT/bin/lib/common.sh"
T="$(mktemp -d)"

# ── A. DIFF 的 jq 程序（从生产脚本原样抽出，不是拷贝）────────────
awk '/^DIFF=/{f=1;next} f && $0=="\047)\"" {exit} f{print}' "$ROOT/bin/crash-weekly.sh" > "$T/diff.jq"
h_assert_contains "$(cat "$T/diff.jq")" 'regressed:' "抽出的是生产 jq 程序"

cat > "$T/new.json" <<'J'
{"ios":[{"id":"aaaa0000000000000000000000000001","title":"全新的","events":3,"versions":[{"version":"1.5.6","n":3}]},
        {"id":"bbbb0000000000000000000000000002","title":"回来的","events":2,"versions":null},
        {"id":"cccc0000000000000000000000000003","title":"暴涨的","events":20,"versions":[{"version":"1.5.4","n":12},{"version":"1.5.6","n":8}]}],
 "android":[]}
J
cat > "$T/old.json" <<'J'
{"ios":[{"id":"cccc0000000000000000000000000003","title":"暴涨的","events":5},
        {"id":"dddd0000000000000000000000000004","title":"消失的","events":9}],"android":[]}
J
# 基准里有「回来的」和「暴涨的」「消失的」，没有「全新的」
cat > "$T/seen.json" <<'J'
{"bbbb0000000000000000000000000002":{"first":"2026-07-01","last":"2026-08-10"},
 "cccc0000000000000000000000000003":{"first":"2026-07-01","last":"2026-08-24"},
 "dddd0000000000000000000000000004":{"first":"2026-07-01","last":"2026-08-24"}}
J
DIFF="$(jq -n --slurpfile new "$T/new.json" --slurpfile old "$T/old.json" --slurpfile seen "$T/seen.json" -f "$T/diff.jq")"
h_assert_eq "全新的"  "$(echo "$DIFF" | jq -r '.ios.new[].title')"       "不在基准里 → 新增"
h_assert_eq "回来的"  "$(echo "$DIFF" | jq -r '.ios.regressed[].title')" "在基准里但上轮消失 → 回归（⛔ 不再混进新增）"
h_assert_eq "暴涨的"  "$(echo "$DIFF" | jq -r '.ios.spiked[].title')"    "5→20 翻倍且≥5 → 暴涨"
h_assert_eq "消失的"  "$(echo "$DIFF" | jq -r '.ios.resolved[].title')"  "本轮不在 → 消失"

# 基准为空 → 退回两态
DIFF2="$(jq -n --slurpfile new "$T/new.json" --slurpfile old "$T/old.json" --slurpfile seen <(echo '{}') -f "$T/diff.jq")"
h_assert_eq "2" "$(echo "$DIFF2" | jq '.ios.new | length')" "基准为空 → 全归新增（退回两态）"
h_assert_eq "0" "$(echo "$DIFF2" | jq '.ios.regressed | length')" "基准为空 → 无回归"

# ── B. 渲染：id / 版本括注 / 链接 ─────────────────────────
h_load "$ROOT/bin/crash-weekly.sh" _chg_rows
out="$(h_run _chg_rows ios new "🆕 新增" 1 0)"
h_assert_contains "$out" '`aaaa0000`' "卡片版：反引号包裹的 8 位 id"
h_assert_eq "" "$(printf '%s' "$out" | grep -o '（.*）' || true)" "单版本 issue **无**版本括注"
h_assert_eq "" "$(printf '%s' "$out" | grep -o 'console.firebase' || true)" "卡片版无链接"

out="$(h_run _chg_rows ios spiked "📈 暴涨" 1 0)"
h_assert_contains "$out" "（1.5.4 12 · 1.5.6 8）" "跨版本 issue 出版本括注"
h_assert_contains "$out" "· 20 事件" "合计事件数仍在"

out="$(h_run _chg_rows ios spiked "📈 暴涨" 1 1)"
h_assert_contains "$out" "[cccc0000](https://console.firebase.google.com" "文档版：id 本身即链接（⛔ 不带反引号，md2docx 不处理嵌套）"
h_assert_contains "$out" "issues/cccc0000000000000000000000000003)" "链接用完整 32 位 id"

out="$(h_run _chg_rows ios regressed "🔁 回归" 1 0)"
h_assert_contains "$out" "🔁 回归" "回归态可渲染"
h_assert_eq "" "$(printf '%s' "$out" | grep -o '（.*）' || true)" "versions=null → 无括注且不报错"
h_summary
