#!/usr/bin/env bash
# L1 的「代码已修但未发版」改走确定性反扫（2026-09-11）。
# ⛔ 原来读模型的 fix_commit，而 L1 prompt 只让它按 **32 位** id 反查，
#    团队实际在用的 `Crashlytics <8位>` 写法一律漏掉——于是这个数常年为 0。
set -uo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SELF_DIR/../.." && pwd)"
# shellcheck disable=SC1091
. "$SELF_DIR/harness.sh"

echo "── L1 fixed_pending 的数据源 ──"
if grep -qF 'scan-fix-commits.sh" "$STATE"' "$ROOT/bin/crash-daily.sh"; then
  echo "  ✅ L1 会跑确定性反扫"; H_PASS=$((H_PASS+1))
else
  echo "  ❌ L1 没跑反扫，又回到信模型 fix_commit"; H_FAIL=$((H_FAIL+1))
fi
if grep -qF 'select(.value.status == "已修待验")' "$ROOT/bin/crash-daily.sh"; then
  echo "  ✅ 按 fixmap 的 status 取数，与 L2 台账同源"; H_PASS=$((H_PASS+1))
else
  echo "  ❌ 没按 fixmap status 取数"; H_FAIL=$((H_FAIL+1))
fi
if grep -qF '回落模型反查值' "$ROOT/bin/crash-daily.sh"; then
  echo "  ✅ 反扫失败有回落且会说出来（⛔ 不静默变 0）"; H_PASS=$((H_PASS+1))
else
  echo "  ❌ 反扫失败没有回落——会静默变 0"; H_FAIL=$((H_FAIL+1))
fi

echo "── 反扫本身认三种写法（回归守卫）──"
R="$(mktemp -d)"; git -C "$R" init -q; git -C "$R" config user.email t@t; git -C "$R" config user.name t
mk() { echo "$RANDOM" > "$R/f"; git -C "$R" add -A; git -C "$R" commit -q -m "$1"; }
mk "fix(a): 旧约定 [crash:aaaaaaaa]"
mk "fix(b): Crashlytics: bbbbbbbb111122223333444455556666"
mk "fix(c): Crashlytics cccccccc；无冒号 8 位（Android 实际写法）"
WINDOW=3650; TMP_HITS="$(mktemp)"; TMP_UNAVAIL="$(mktemp)"
h_load "$ROOT/bin/scan-fix-commits.sh" scan_repo || { h_summary; exit 1; }
h_run scan_repo "$R" t >/dev/null
out="$(cat "$TMP_HITS")"
for id in aaaaaaaa bbbbbbbb cccccccc; do h_assert_contains "$out" "$id" "认得 $id"; done
rm -rf "$R" "$TMP_HITS" "$TMP_UNAVAIL"
h_summary
