#!/usr/bin/env bash
# scan-fix-commits.sh 的提交约定识别：两种形式都认，且 subject / body 都要扫
ROOT="${CRASH_REPORT_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}"
. "$ROOT/bin/test/harness.sh"

R="$(mktemp -d)"; git -C "$R" init -q 2>/dev/null; git -C "$R" config user.email t@t; git -C "$R" config user.name t
mk() { echo "$RANDOM" > "$R/f"; git -C "$R" add -A; git -C "$R" commit -q -m "$1"; }
mk "fix(a): 旧约定 [crash:aaaaaaaa] 修好了"
mk "fix(b): Android 形式 Crashlytics: bbbbbbbb111122223333444455556666 写在 subject"
mk "$(printf 'fix(c): iOS 形式 写在 body\n\n- Crashlytics issue: cccccccc111122223333444455556666\n')"
mk "fix(d): 与 issue 无关的普通提交"
mk "fix(e): 提到 crashlytics 但没有 id"

# 直接跑生产 scan_repo（从脚本抽出，非拷贝）
WINDOW=3650; TMP_HITS="$(mktemp)"; TMP_UNAVAIL="$(mktemp)"
h_load "$ROOT/bin/scan-fix-commits.sh" scan_repo
h_run scan_repo "$R" testplat >/dev/null
out="$(cat "$TMP_HITS")"

h_assert_contains "$out" "aaaaaaaa" "① 旧约定 [crash:<8位>] 仍认（⛔ 不得回归）"
h_assert_contains "$out" "bbbbbbbb" "② Crashlytics: <32位> 写在 subject 也认（Android 实际写法）"
h_assert_contains "$out" "cccccccc" "③ Crashlytics issue: <32位> 写在 body 也认（iOS 实际写法）"
h_assert_eq "3" "$(printf '%s' "$out" | grep -c . )" "④ 无 id 的提交不产生命中（负向：不误报）"
h_assert_eq "" "$(printf '%s' "$out" | grep -o 'dddddddd\|eeeeeeee' || true)" "⑤ 「提到 crashlytics 但没 id」不误命中"
h_summary
