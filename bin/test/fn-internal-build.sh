#!/usr/bin/env bash
# 内部构建标注：两端判据不同且**不可互换**。
#
# 起因（2026-09-17）：用户只关心上架版本，而报告里长期混着内部包。
# ⛔ 但**不能过滤只能标注**——实测 Android 上架首日只有 4~7 台设备（170012 首日 7 台 → 次日 529 台），
# 与内部包（2~9 台）完全重叠，任何门槛都会让新版上架第一天整列消失，而那恰恰是最该盯的一天。
#
# ⛔ 本夹具最重要的是那条负向：**iOS 的判据用在 Android 上会把每个版本都标成内部构建**
# （Android 的 performance_data_collection_enabled 恒 false，实测 5142 台的上架包也是 0）。
ROOT="${CRASH_REPORT_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}"
. "$ROOT/bin/test/harness.sh"

h_load "$ROOT/bin/crash-daily.sh" internal_build internal_note
. "$ROOT/bin/lib/core/version.sh"   # ver_field 在核心层

# CSV 形态：version,sessions,devices,devs_perf_on,max_build_tail3（2026-09-17 起 5 列）
# 数字取自 2026-09-17 实测
IOS_VER_CSV='1.8.0,395,39,0,
1.7.1,120,15,13,
1.7.0,3000,536,501,
1.6.0,9000,2081,2024,
1.5.6,60,28,0,'
AND_VER_CSV='1.8.0,20,2,0,0
1.7.1,900,365,0,2
1.7.0,2000,746,0,12
1.6.0,12000,5175,0,20'

echo "── iOS：采集全关 = 内部构建 ──"
h_assert_eq "1" "$(h_run internal_build ios 1.8.0)" "1.8.0 实测 0/39 台采集开着"
h_assert_eq "1" "$(h_run internal_build ios 1.5.6)" "1.5.6 实测 0/28——⚠️ 与「性能表全时段零行」互证"
h_assert_eq ""  "$(h_run internal_build ios 1.7.0)" "⛔ 上架版本不得误标（501/536）"
h_assert_eq ""  "$(h_run internal_build ios 1.6.0)" "⛔ 主力版本不得误标（2024/2081）"
h_assert_eq ""  "$(h_run internal_build ios 1.7.1)" "⛔ 刚上架放量中的也不得误标（13/15）"

echo "── Android：所有 build 都未过 CI = 内部构建 ──"
h_assert_eq "1" "$(h_run internal_build and 1.8.0)" "1.8.0 唯一 build 180000，末三位 0"
h_assert_eq ""  "$(h_run internal_build and 1.7.1)" "⛔ 有 CI 包（末三位 2）不得标"
h_assert_eq ""  "$(h_run internal_build and 1.6.0)" "⛔ 上架版本不得标（末三位 20）"

echo "── ⛔ 命门：两端判据不可互换 ──"
# Android 的 devs_perf_on 恒 0（实测 5142 台的上架包 160020 也是 0）。
# 若 internal_build 对 android 误用了 iOS 那条判据，下面三条会同时变红——
# 那意味着生产上每个 Android 版本都会被标成「内部构建」。
h_assert_eq "" "$(h_run internal_build and 1.6.0)" "⛔ Android 上架版 devs_perf_on=0，用 iOS 判据必误标"
h_assert_eq "" "$(h_run internal_build and 1.7.0)" "⛔ 同上（746 台）"
h_assert_eq "" "$(h_run internal_build and 1.7.1)" "⛔ 同上（365 台）"

echo "── 反向：iOS 不得误用 Android 判据 ──"
# iOS 的 max_build_tail3 恒空（build_version 是 1.8.0.28，SAFE_CAST 转不动）。
# 若误用，iOS 全部版本都不会被标（空 != "0"），1.8.0 就漏标了。
h_assert_eq "1" "$(h_run internal_build ios 1.8.0)" "⛔ iOS 第 5 列恒空，误用 Android 判据会漏标"

echo "── 取不到数据时保持沉默（⛔ 不猜）──"
h_assert_eq "" "$(h_run internal_build ios 9.9.9)" "版本不在 CSV 里 → 不标"
h_assert_eq "" "$(h_run internal_build and 9.9.9)" "同上"

echo "── 摘要行 ──"
IOS_COLS=$'1.8.0\n1.7.1\n1.6.0'; AND_COLS=$'1.8.0\n1.7.0'
out="$(h_run internal_note)"
h_assert_contains "$out" "iOS 1.8.0"     "列出 iOS 的内部构建"
h_assert_contains "$out" "Android 1.8.0" "列出 Android 的内部构建"
h_assert_absent  "$out" "1.7.1"          "⛔ 上架版本不得出现在清单里"
h_assert_absent  "$out" "1.6.0"          "⛔ 同上"
h_assert_contains "$out" "未上架"         "必须说清这是什么意思，⛔ 不能只丢一个版本号"

echo "── 负向：没有内部构建时**一个字都不输出**（⛔ 否则每天多一行空噪音）──"
IOS_COLS=$'1.7.0\n1.6.0'; AND_COLS=$'1.7.0\n1.6.0'
h_assert_eq "" "$(h_run internal_note)" "⛔ 全是上架版本 → 摘要行不得出现"

h_summary
