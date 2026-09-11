#!/usr/bin/env bash
# 台账不得把已关闭的 issue 标成「已修待验」（失效模式 R4）。
#
# ⚠️ 本夹具**不驱动整个 render-ledger.sh**：它对输入形态很脆（缺 PREV_TABLE / 真实 DIFF 时
#    零输出 rc=1，旧版同样如此），造一份足够真实的输入成本高于收益。改为两段：
#    ① 把 disposition 的 jq 判定单独跑一遍（它是纯表达式，可精确断言）；
#    ② 源码断言，钉住生产脚本里确实是这么写的、两边不漂。
set -uo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SELF_DIR/../.." && pwd)"
# shellcheck disable=SC1091
. "$SELF_DIR/harness.sh"

echo "── disposition 判定：已关闭优先于反扫结论 ──"
disp() { # $1=state $2=有无反扫命中(1/0) $3=历史结论
  jq -rn --arg st "$1" --argjson has "$2" --arg prev "$3" '
    (if $has == 1 then {status:"已修待验", commit:"abc1234"} else null end) as $fix
    | (if $st == "CLOSED" then
         (if $fix != null then "✅已关闭（\($fix.commit)）" else "✅已关闭" end)
       elif $fix != null then $fix.status
       elif $prev != "" then $prev
       else "未处理" end)'
}
h_assert_eq "已修待验"            "$(disp OPEN 1 "")"        "OPEN + 反扫命中 → 已修待验"
h_assert_eq "✅已关闭（abc1234）" "$(disp CLOSED 1 "")"      "⛔ CLOSED + 反扫命中 → 已关闭（带提交），**不得**是已修待验"
h_assert_eq "✅已关闭"            "$(disp CLOSED 0 "")"      "CLOSED 且无反扫 → 已关闭"
h_assert_eq "人工结论"            "$(disp OPEN 0 "人工结论")" "OPEN 无反扫 → 保留历史结论"
h_assert_eq "未处理"              "$(disp OPEN 0 "")"        "都没有 → 未处理"
h_assert_eq "已修待验"            "$(disp "" 1 "")"          "⚠️ 状态未知时退回旧行为（⛔ 不把未知当已关闭）"

echo "── 源码断言：生产脚本确实这么写 ──"
for pat in 'if $states[$iss.id] == "CLOSED" then' 'CRASH_REPORT_ISSUE_STATES' 'status="✅已关闭"'; do
  if grep -qF "$pat" "$ROOT/bin/render-ledger.sh"; then
    echo "  ✅ render-ledger.sh 含：$pat"; H_PASS=$((H_PASS+1))
  else
    echo "  ❌ render-ledger.sh 缺：$pat"; H_FAIL=$((H_FAIL+1))
  fi
done
if grep -qF 'export CRASH_REPORT_ISSUE_STATES' "$ROOT/bin/crash-weekly.sh"; then
  echo "  ✅ 周报会把状态表传给渲染器"; H_PASS=$((H_PASS+1))
else
  echo "  ❌ 周报没传状态表——渲染器拿不到，等于没接"; H_FAIL=$((H_FAIL+1))
fi

echo "── ⛔ 三条渲染路径都要接（2026-09-11 只接了台账那条，卡片仍报 6 条错的）──"
# 同一个 fixmap 会被三处渲染：台账现状表 / 卡片 _fix_rows / 卡片变化行并入。
for pat in 'if $states[$iss.id] == "CLOSED" then:render-ledger.sh' \
           '_fr_state" = "CLOSED":crash-weekly.sh' \
           '_cr_state" = "CLOSED":crash-weekly.sh'; do
  needle="${pat%%:*}"; file="${pat##*:}"
  if grep -qF "$needle" "$ROOT/bin/$file"; then
    echo "  ✅ $file 已接：${needle:0:28}"; H_PASS=$((H_PASS+1))
  else
    echo "  ❌ $file 未接：${needle:0:28}——该路径会把 CLOSED 报成待验"; H_FAIL=$((H_FAIL+1))
  fi
done
h_summary
