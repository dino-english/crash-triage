#!/usr/bin/env bash
# 告警判定对象回退（alert_ver）：回退原因**必须自带主语**。
#
# 起因（2026-09-14 生产核验）：摘要行渲染成
#   「ℹ️ 告警判定对象：iOS 1.6.0（会话数 33 < 213，比率无法分辨阈值）」
# 计算全对——33 是被否掉的**最新版 1.8.0** 的会话数，1.6.0 是替代的判定对象。
# 但括号紧跟在 1.6.0 后面，而同一份报告的表格里 1.6.0 写着 543 会话，
# ⛔ 读者只会判成自相矛盾。同函数的另一个分支（无性能数据）当初就带了主语，只有这支漏了。
#
# ⚠️ 这类缺陷 check-scripts 看不见、整跑也不会红——只有把文案钉进断言才拦得住。
ROOT="${CRASH_REPORT_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}"
. "$ROOT/bin/test/harness.sh"

h_load "$ROOT/bin/crash-daily.sh" alert_ver

# 假 mv_：只喂 alert_ver 用到的两个字段（adopt.sessions / perf.state）
mk() { # $1=最新版会话数 $2=最新版 perf.state
  MV_SESS="$1"; MV_PST="$2"
  mv_() { case "$3" in (adopt.sessions) printf '%s' "$MV_SESS";; (perf.state) printf '%s' "$MV_PST";; esac; }
  IOS_V1=1.8.0; IOS_TOPSESS=$'1.6.0\n1.5.2'; SAMPLE_SESSION_MIN=213
}

echo "── 条件①：最新版样本撑不起阈值 ──"
mk 33 ok
out="$(h_run alert_ver ios)"
h_assert_contains "$out" "1.6.0" "判定对象回退到会话量最大的版本"
h_assert_contains "$out" "最新版 1.8.0 会话数 33" "⛔ 原因必须点名主语——33 属于 1.8.0，不属于判定对象 1.6.0"
# ⚠️ 负向判据必须钉在**本函数的输出**上：全角括号是外层 add_alert 拼的，
# 写成 h_assert_absent "（会话数 33" 就是条永远通过的废断言（2026-09-14 双向测试当场抓到）。
# 原因串以 TAB 分隔紧跟版本号，旧写法就是「<TAB>会话数 」开头。
h_assert_absent "$out" $'\t会话数 ' "⛔ 不得退回无主语写法（原因不能直接以「会话数」开头）"

echo "── 条件②：样本够但没有性能数据 ──"
mk 9999 no_version
out="$(h_run alert_ver ios)"
h_assert_contains "$out" "最新版 1.8.0 无性能数据" "这一支原本就带主语，⚠️ 一并钉住防回退"

echo "── 负向：稳态不回退 ──"
mk 9999 ok
out="$(h_run alert_ver ios)"
h_assert_eq "1.8.0	" "$out" "⛔ 会话够且性能可用 → 判定对象仍是最新版，原因为空"

echo "── 负向：没有可替代对象时不回退 ──"
mk 1 ok
IOS_TOPSESS=1.8.0
out="$(h_run alert_ver ios)"
h_assert_eq "1.8.0	" "$out" "⛔ top1 就是最新版时，即使样本不足也不得编出一个回退原因"

h_summary
