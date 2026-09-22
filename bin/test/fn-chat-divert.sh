#!/usr/bin/env bash
# 投递分流口子（change crash-deliver-divert）。
#
# 起因：生产机 local.env 写死 oc_ 正式群且**故意盖过命令行**，于是「在生产机上跑一次真链路
# 看看对不对」不可能——只能等 cron，而 cron 发正式群。2026-09-22 就因此把「索引页那一行
# 点不点得开」推到第二天，而那正是「没测就部署」的同源病。
#
# ⛔ 本夹具钉死的唯一红线：**只接受 ou_ 私聊**。它一旦能接受 oc_，就复现了 2026-08-20
# 那次「测试卡片差点发进正式群」的事故条件。
set -uo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SELF_DIR/../.." && pwd)"
# shellcheck disable=SC1091
. "$SELF_DIR/harness.sh"
# shellcheck disable=SC1091
. "$ROOT/bin/lib/divert.sh"

probe() { # $1=DIVERT_TO 取值 → "<rc>:<结果CHAT_ID>"
  local rc=0
  ( CRASH_REPORT_DIVERT_TO="$1" CRASH_REPORT_CHAT_ID="oc_原始正式群"
    apply_chat_divert >/dev/null 2>&1 || exit $?
    printf '%s' "$CRASH_REPORT_CHAT_ID" ) > /tmp/.divert.$$ 2>/dev/null || rc=$?
  printf '%s:%s' "$rc" "$(cat /tmp/.divert.$$ 2>/dev/null || true)"; rm -f /tmp/.divert.$$
}

echo "── 放行：ou_ 私聊 ──"
h_assert_eq "0:ou_me" "$(probe ou_me)" "ou_ 私聊 → 改投它"

echo "── ⛔ 红线：一切非 ou_ 必须拒绝 ──"
for bad in oc_另一个群 oc_655033f1f85fa04f9eac25d56f056fc9 ou 私聊 "" x_ou_伪装; do
  [ -z "$bad" ] && continue
  r="$(probe "$bad")"
  case "$r" in
    1:*) echo "  ✅ 拒绝 $bad"; H_PASS=$((H_PASS+1));;
    *)   echo "  ❌ 未拒绝 ${bad} / 得到 ${r} ——这就是 2026-08-20 那次事故的条件"; H_FAIL=$((H_FAIL+1));;
  esac
done

echo "── 未设置时不得有任何副作用 ──"
r="$( unset CRASH_REPORT_DIVERT_TO; CRASH_REPORT_CHAT_ID="oc_原始正式群"
      apply_chat_divert >/dev/null 2>&1; printf '%s' "$CRASH_REPORT_CHAT_ID" )"
h_assert_eq "oc_原始正式群" "$r" "⛔ 不设分流时 CHAT_ID 一个字都不许动"

echo "── 三个入口都必须接上（⛔ 只接一个 = 子进程又被 local.env 盖回去）──"
for f in crash-daily.sh crash-weekly.sh deliver.sh; do
  if grep -q 'apply_chat_divert || exit 2' "$ROOT/bin/$f"; then
    echo "  ✅ $f 已接"; H_PASS=$((H_PASS+1))
  else
    echo "  ❌ $f 未接——deliver.sh 会重新 source local.env 把 CHAT_ID 盖回正式群"; H_FAIL=$((H_FAIL+1))
  fi
done
echo "── 顺序：必须在 local.env 之后 ──"
for f in crash-daily.sh crash-weekly.sh deliver.sh; do
  # ⚠️ 判据必须是**真正的 source 那一行**，⛔ 不是「提到 local.env 的最后一行」——
  #    后者会命中注释（deliver.sh 第 97 行就有一处），把顺序正确的代码误报成错的。
  a=$(grep -n '^\[ -f "\$STATE/local.env" \]' "$ROOT/bin/$f" | head -1 | cut -d: -f1)
  b=$(grep -n 'apply_chat_divert' "$ROOT/bin/$f" | head -1 | cut -d: -f1)
  if [ -n "$a" ] && [ -n "$b" ] && [ "$b" -gt "$a" ]; then
    echo "  ✅ ${f} 分流($b) 在 local.env($a) 之后"; H_PASS=$((H_PASS+1))
  else
    echo "  ❌ ${f} 顺序不对: local.env=$a 分流=$b ——会被 local.env 盖掉"; H_FAIL=$((H_FAIL+1))
  fi
done

h_summary
