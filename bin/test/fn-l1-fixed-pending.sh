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
# ⛔ 判据是「已修未发版 且 发版判定可得」（change crash-fix-release-status）。原判据「已修待验」
#    （提交后无新事件）包含已发版且生效的修复，把好消息报成了「代码已修但未发版」告警。
if grep -qF 'select(.value.status == "已修未发版" and .value.release_check == "ok")' "$ROOT/bin/crash-daily.sh"; then
  echo "  ✅ 按发版判定后的 status 取数，且排除判定不可得的条目"; H_PASS=$((H_PASS+1))
else
  echo "  ❌ 没按「已修未发版 + 判定可得」取数"; H_FAIL=$((H_FAIL+1))
fi
if grep -qF 'fix-release-status.sh"' "$ROOT/bin/crash-daily.sh"; then
  echo "  ✅ L1 跑发版判定（与 L2 台账同一判定）"; H_PASS=$((H_PASS+1))
else
  echo "  ❌ L1 没跑发版判定——告警会退回只比时间"; H_FAIL=$((H_FAIL+1))
fi
if grep -qE 'git -C "\$REPOS_ROOT/\$_fr_r" fetch --all --tags --prune' "$ROOT/bin/crash-daily.sh"; then
  echo "  ✅ 反扫前 fetch（Android 的 main / tag 要新，否则未发版告警滞后到周一，design D5）"; H_PASS=$((H_PASS+1))
else
  echo "  ❌ L1 没 fetch——合进 main 的修复会被连报 6 天未发版"; H_FAIL=$((H_FAIL+1))
fi
# ⛔ 反向：反扫失败时**不得**回落到模型的 fix_commit 计数——那就是「找到提交就报未发版」，不判发版。
#    原夹具断言的恰是这个回落存在（2026-09-11 的设计），本 change 按 spec 去掉它。
if grep -qF "select(.fix_commit != null)] | length' \"\$CRASH_JSON\"" "$ROOT/bin/crash-daily.sh"; then
  echo "  ❌ 反扫失败仍回落模型 fix_commit 计数——不判发版就报未发版"; H_FAIL=$((H_FAIL+1))
else
  echo "  ✅ 反扫失败不回落模型计数"; H_PASS=$((H_PASS+1))
fi
if grep -qF '本轮未判定「代码已修但未发版」' "$ROOT/bin/crash-daily.sh"; then
  echo "  ✅ 反扫失败会在卡片上说出来（⛔ 不静默）"; H_PASS=$((H_PASS+1))
else
  echo "  ❌ 反扫失败没有说明——告警会静默消失"; H_FAIL=$((H_FAIL+1))
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
