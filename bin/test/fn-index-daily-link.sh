#!/usr/bin/env bash
# 索引页「今日日报」入口的回填（失效模式 F59）。
#
# 2026-09-22 读回**生产**索引页发现那一行没有链接，而同页归档表 38 条链接全好。
# 根因：deliver.sh 回填的是 markdown 版，发布的却是 XML 版——index.xml 由 markdown 在
# 回填**之前**转出来，里面始终是 `<a href="__DAILY_URL__">`，从未被 patch。
#
# ⛔ 最阴的一点：**飞书丢掉非法 href 只留文字**，产物里既没有链接、也没有残留占位符，
# 于是「grep 产物找占位符」和「看有没有链接」两条常规判据同时失效。
# ⇒ 判据只能落在**发布前的文件**上。
set -uo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SELF_DIR/../.." && pwd)"
# shellcheck disable=SC1091
. "$SELF_DIR/harness.sh"

D="$ROOT/bin/deliver.sh"
chk() { # $1=子串 $2=说明
  if grep -qF "$1" "$D"; then echo "  ✅ $2"; H_PASS=$((H_PASS+1))
  else echo "  ❌ $2 —— deliver.sh 里找不到：$1"; H_FAIL=$((H_FAIL+1)); fi
}

echo "── 回填必须覆盖**即将发布的那个**文件 ──"
chk 'fill "$INDEX_FILE" "__DAILY_URL__"' '回填 markdown 版（XML 失败时的回退源）'
chk '[ -s "$INDEX_XML" ] && fill "$INDEX_XML" "__DAILY_URL__"' '⛔ 必须同时回填 XML 版——它才是实际发布的那个'

echo "── 发布前断言：残留占位符必须中止 ──"
chk '_assert_filled "$INDEX_XML"' '⛔ 发布 XML 前必须断言已填满'
chk '_assert_filled "$INDEX_FILE"' '回退到 markdown 时同样要断言'

echo "── 断言函数本身：三态 ──"
h_load "$D" _assert_filled 2>/dev/null || true
T="$(mktemp)"; printf '<a href="https://x/y">ok</a>\n' > "$T"
h_assert_rc 0 _assert_filled "$T"                 '填满的文件 → 放行'
printf '<a href="__DAILY_URL__">x</a>\n' > "$T"
h_assert_rc 1 _assert_filled "$T"                 '⛔ 残留 __DAILY_URL__ → 必须中止'
printf '<a href="__A__">x</a><b>__B__</b>\n' > "$T"
h_assert_rc 1 _assert_filled "$T"                 '任意 __XXX__ 都算残留（不只硬编码那一个）'
rm -f "$T"

echo "── 自测口子：必须存在且拒绝指向生产索引页 ──"
chk 'CRASH_REPORT_INDEX_DOC_ID' '⚠️ 没有这个口子，索引页在开发机上永远验不了——F59 就是这么活下来的'
chk '⛔ 拒绝：CRASH_REPORT_INDEX_DOC_ID 指向的正是生产索引页' '⛔ 必须拒绝指向生产索引页'

h_summary
