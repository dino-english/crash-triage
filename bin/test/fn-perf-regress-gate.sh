#!/usr/bin/env bash
# 性能版本退化（🚨 规则 ⑤）的样本门槛：两版日会话都要 ≥ SAMPLE_SESSION_MIN 才比（change crash-report-attention-tiers）。
# 数据取自 2026-10-12 生产首轮 runs/2026-10-12/L1/latest/m-and-*.json——当天误报了两条「性能退化」。
ROOT="${CRASH_REPORT_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}"
. "$ROOT/bin/test/harness.sh"
. "$ROOT/bin/lib/core/verdict.sh"
. "$ROOT/bin/lib/core/tier.sh"

SAMPLE_SESSION_MIN=213; PERF_P95_SAMPLE_MIN=20; PERF_REGRESS_PCT=20
START_P95_YELLOW=1500; SLOW_FRAME_YELLOW=30; FROZEN_YELLOW=0.5; NET_ERR_YELLOW=0.5
AND_COLS="1.8.2 1.8.1"; IOS_COLS=""
M_182='{"adopt":{"sessions":"804"},"perf":{"start_samples":"1058","p95":"2022","slow_all":"47","frozen_all":"0.51","net_err":"0.6"}}'
M_181='{"adopt":{"sessions":"30"},"perf":{"start_samples":"46","p95":"1853","slow_all":"30.1","frozen_all":"0.89","net_err":"0.4"}}'
# 假 mv_：与生产同签名（$1=plat $2=版本 $3=jq 路径），从上面两份 JSON 取值
mv_() { local j; case "$2" in 1.8.2) j="$M_182";; 1.8.1) j="$M_181";; *) echo ""; return 0;; esac
  printf '%s' "$j" | jq -r --arg p "$3" 'getpath($p | split(".")) // "" | tostring'; }

h_load "$ROOT/bin/crash-daily.sh" prev_ver_of cmp_prev_ver_of _tier_metric_add _tier_regress
# ⚠️ h_run 在子 shell 里跑：_tier_regress 改的全局 TIER_METRIC 传不回来——直接断言全局会**恒为空、恒通过**
#    （本夹具初版就是这样，用例 ① 是假绿）。故在同一个子 shell 里跑完再把结果打出来。
_probe() { TIER_METRIC='[]'; _tier_regress "$@"; printf '%s' "$TIER_METRIC"; }

echo "── ① 2026-10-12 生产：上一版 1.8.1 日会话 30 < 213 → 不比，不出「性能退化」──"
h_assert_eq "0" "$(h_run _probe and Android 1.8.2 | jq 'length')" "⛔ 退场版本当基准比出的「退化」是误报（当天 🚨 多了慢帧 / 接口错误率两条）"
h_assert_eq "" "$(h_run cmp_prev_ver_of and 1.8.2)" "可比的上一版为空（「对比上一版」那句也随之不出）"

echo "── ② 正向：上一版样本足够时规则照常生效（门槛没把规则关掉）──"
M_181='{"adopt":{"sessions":"900"},"perf":{"start_samples":"460","p95":"1853","slow_all":"30.1","frozen_all":"0.89","net_err":"0.4"}}'
h_assert_eq "慢帧 接口错误率" "$(h_run _probe and Android 1.8.2 | jq -r '[.[].title | split(" ")[2]] | join(" ")')" \
  "两版都过门槛 → 慢帧（+56%）、接口错误率（+50%）判退化；P95 +9% 不到 20% 不判"
h_assert_eq "1.8.1" "$(h_run cmp_prev_ver_of and 1.8.2)" "可比的上一版 = 1.8.1"

echo "── ③ 边界：恰好 213 视为够 ──"
M_181='{"adopt":{"sessions":"213"},"perf":{}}'
h_assert_eq "1.8.1" "$(h_run cmp_prev_ver_of and 1.8.2)" "门槛是「大于等于」"
M_181='{"adopt":{"sessions":""},"perf":{}}'
h_assert_eq "" "$(h_run cmp_prev_ver_of and 1.8.2)" "会话数取不到 → 不比（宁可不报，不拿未知当够）"
h_summary
