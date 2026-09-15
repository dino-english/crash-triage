#!/usr/bin/env bash
# 性能单元格：「流水线自己没见过」≠「表里没有过」（F49）。
#
# 起因（2026-09-15 生产日报实抓）：Android 1.7.0 那一列 5 行全渲染成
#   「— 有会话（20）但无性能数据」
# 而该版本在性能表里有 3,658 行（09-04~09-10），只是落在报告窗口 09-11~09-13 之外。
# 第 4 态的措辞是在**断言**「这个版本不上报性能」——对它是假的。
# ⛔ 更要命的是错得有方向：第 2 态是「要查」，第 4 态是「不用查」，误报把该查的标成了不用查。
#
# 根因：hist_perf_last_day() 读 metrics-history.jsonl，即流水线自己写过的历史；
# Android 1.7.0 当天**首次进报告**，历史里查不到 → 第 2 态不触发 → 落到第 4 态。
# ⚠️ 每次版本交替必踩，不是偶发。
ROOT="${CRASH_REPORT_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}"
. "$ROOT/bin/test/harness.sh"

h_load "$ROOT/bin/crash-daily.sh" state_text_perf perf_last_day_of perf_eta_of hist_perf_last_day state_text
. "$ROOT/bin/lib/core/format.sh"   # day_shift 在核心层，不在 crash-daily.sh 里

# ⚠️ perf_eta_of 内部要 day_shift "$DAY" 1——夹具漏设 $DAY 时 set -u 直接触发 ERR trap
#    （2026-09-15 首跑当场踩到）。⛔ 别为了绕开它去 stub perf_eta_of：那样「排序」这条
#    负向断言就测不到真东西了。

# 夹具：流水线历史恒空（模拟「该版本首次进报告」），其余按参数摆布
CELL_BREVITY=0
DAY=2026-09-13
hist_perf_last_day() { printf ''; }          # ⛔ 流水线没见过这个版本
state_text() { printf 'STATE_TEXT(%s)' "$1"; }
mk() { # $1=scan TSV（第 4 列 = 表内末次有行日） $2=残日版本清单
  AND_PERF_SCAN="$1"; IOS_PERF_SCAN="$1"
  AND_PERF_TAIL="$2"; IOS_PERF_TAIL="$2"
}

echo "── 正向：表里有过、窗口内没有 → 第 2 态并带真实日期 ──"
mk $'1.7.0\t0\t0\t2026-09-10\n1.6.0\t1044511\t55067\t2026-09-14' ""
out="$(h_run state_text_perf no_version and 1.7.0 "2026-09-14 06:59" 20)"
h_assert_contains "$out" "本轮未取到（上次有值 2026-09-10）" "表里 09-10 有过 → 必须说出这个日期"
h_assert_absent "$out" "有会话" "⛔ 不得再渲染第 4 态——那是在断言它不上报性能"
h_assert_absent "$out" "无性能数据" "⛔ 同上，换个措辞也不行"

echo "── 负向①：表里**真的**一行都没有 → 第 4 态照旧（⛔ 不得被新分支吃掉）──"
mk $'1.6.0\t446643\t18243\t2026-09-14' ""
out="$(h_run state_text_perf no_version ios 1.8.0 "2026-09-14 06:59" 21)"
h_assert_eq "— 有会话（21）但无性能数据" "$out" "回看窗内查不到该版本 = 它真的从不上报，第 4 态成立"

echo "── 负向②：残日有行 → 仍优先「预计 X 到位」，⛔ 新分支不得抢走 ──"
# ⚠️ 这条是排序的守门人：last_day 存在时若新分支排在残日之前，就会把更有用的
#    「明天就到」降级成「上次有值」。把顺序钉进断言，不靠读代码记住。
mk $'1.9.0\t0\t12\t2026-09-14' "1.9.0"
out="$(h_run state_text_perf no_version ios 1.9.0 "2026-09-14 06:59" 30)"
h_assert_contains "$out" "预计" "残日有行必须给「预计到位」，而不是「上次有值」"
h_assert_absent "$out" "上次有值" "⛔ 新分支排序错了会在这里变红"

echo "── 负向③：流水线自己有历史时，仍以它为准（⛔ 既有第 2 态路径零变更）──"
hist_perf_last_day() { printf '2026-09-08'; }
mk $'1.7.0\t0\t0\t2026-09-10' ""
out="$(h_run state_text_perf no_version and 1.7.0 "2026-09-14 06:59" 20)"
h_assert_contains "$out" "上次有值 2026-09-08" "流水线历史优先，⛔ 不得被表的 09-10 覆盖"
hist_perf_last_day() { printf ''; }

echo "── 负向④：非 no_version 的态原样委托，⛔ 一字不改 ──"
mk $'1.7.0\t0\t0\t2026-09-10' ""
out="$(h_run state_text_perf stale and 1.7.0 "2026-09-14 06:59" 20)"
h_assert_eq "STATE_TEXT(stale)" "$out" "前两态必须原样交给 state_text()"

echo "── 短文案：日期必须保留 ──"
CELL_BREVITY=1
mk $'1.7.0\t0\t0\t2026-09-10' ""
out="$(h_run state_text_perf no_version and 1.7.0 "2026-09-14 06:59" 20)"
h_assert_eq "⚠️ 未取到 09-10" "$out" "短文案砍措辞不砍日期（与既有第 2 态同规格）"
CELL_BREVITY=0

echo "── perf_last_day_of 本身 ──"
mk $'1.7.0\t0\t0\t2026-09-10\n1.6.0\t9\t9\t2026-09-14' ""
h_assert_eq "2026-09-10" "$(h_run perf_last_day_of and 1.7.0)" "按版本取第 4 列"
h_assert_eq "" "$(h_run perf_last_day_of and 9.9.9)" "⛔ 查不到返回空，不猜"
mk $'1.7.0\t0\t0' ""
h_assert_eq "" "$(h_run perf_last_day_of and 1.7.0)" "⛔ 只有 3 列的旧形态 TSV 一律返回空，不得越界取值"

h_summary
