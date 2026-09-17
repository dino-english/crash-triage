#!/usr/bin/env bash
# 启动 P50/P95 的样本量提示（F50）。
#
# 起因（2026-09-16 生产日报 iOS 段实抓）：三列并排、零标记——
#   1.6.0  299ms / 927ms   ← 1681 样本 / 66 设备
#   1.8.0 1505ms / 1777ms  ← **3 样本 / 1 设备**
#   1.7.0  178ms / 178ms   ← **1 样本 / 1 设备**（P50=P95 是单样本的指纹）
# 读者按列对比只会读出「1.8.0 劣化 5 倍、1.7.0 改善 40%」，两个都是噪音。
#
# ⛔ 既有的 SAMPLE_SESSION_MIN 判**会话数**、且只用于告警判定对象回退，结构上拦不住：
# 1.7.0 当天会话很多、性能样本只有 1 个。
# ⚠️ 样本数 perf-traces.sql 第 2 列一直在输出，只是从没被读——修的是「没取」不是「取不到」。
ROOT="${CRASH_REPORT_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}"
. "$ROOT/bin/test/harness.sh"

h_load "$ROOT/bin/crash-daily.sh" perf_sample_note

CELL_BREVITY=0
P50_MIN=10; P95_MIN=20

echo "── 正向：低于阈值必须标出样本数 ──"
h_assert_eq " ⚠️ 样本 1"  "$(h_run perf_sample_note 1 "$P50_MIN")"  "1 个样本必须标（⛔ 这就是 178ms 那格）"
h_assert_eq " ⚠️ 样本 3"  "$(h_run perf_sample_note 3 "$P50_MIN")"  "3 个样本必须标（1505ms 那格）"
h_assert_eq " ⚠️ 样本 7"  "$(h_run perf_sample_note 7 "$P50_MIN")"  "7 个样本必须标（Android 1.7.0）"

echo "── 负向①：主力版本一律不得触发（⛔ 否则天天在标 = 噪音源，见 F30）──"
h_assert_eq "" "$(h_run perf_sample_note 1681 "$P50_MIN")" "iOS 1.6.0 实测样本 1681"
h_assert_eq "" "$(h_run perf_sample_note 2769 "$P95_MIN")" "Android 1.6.0 实测样本 2769"
h_assert_eq "" "$(h_run perf_sample_note 398  "$P95_MIN")" "实测最小的主力窗口 398 也不得触发"

echo "── 边界：阈值本身不触发，差一个就触发 ──"
h_assert_eq "" "$(h_run perf_sample_note 10 "$P50_MIN")" "⛔ 等于阈值不算不足（<，不是 <=）"
h_assert_eq " ⚠️ 样本 9" "$(h_run perf_sample_note 9 "$P50_MIN")" "差一个就标"
h_assert_eq "" "$(h_run perf_sample_note 20 "$P95_MIN")" "P95 等于阈值不触发"
h_assert_eq " ⚠️ 样本 19" "$(h_run perf_sample_note 19 "$P95_MIN")" "P95 差一个就标"

echo "── 负向②：P95 阈值必须比 P50 严（n=15 时 P50 放行、P95 拦下）──"
# ⚠️ 这条钉的是「两个阈值不可合并成一个」：P95 在 n<20 时退化成最大值，比 P50 更早失真
h_assert_eq "" "$(h_run perf_sample_note 15 "$P50_MIN")" "n=15 对 P50 够用"
h_assert_eq " ⚠️ 样本 15" "$(h_run perf_sample_note 15 "$P95_MIN")" "⛔ 同一个 n，P95 必须标"

echo "── 负向③：样本数取不到时保持沉默（⛔ 不得编一个警告出来）──"
h_assert_eq "" "$(h_run perf_sample_note "" "$P50_MIN")" "空样本数 → 无提示，不猜"

echo "── 短文案：卡片窄列只留符号+数字（⛔ 数字不能砍，它才是信息）──"
CELL_BREVITY=1
h_assert_eq " ⚠️1" "$(h_run perf_sample_note 1 "$P50_MIN")" "卡片版保留样本数"
h_assert_eq ""     "$(h_run perf_sample_note 1681 "$P50_MIN")" "卡片版同样不得误报"
CELL_BREVITY=0

echo "── 生产形态：条件位调用不得触发 ERR trap ──"
h_assert_eq "" "$(h_run perf_sample_note 9999 "$P50_MIN")" "正常路径安静"

echo "── 对比列：任一侧样本不足 → 退回 neutral（不再染红断言「变差」）──"
# 2026-09-17 生产卡实抓：「1505ms ⚠️ 样本 3」与「759ms ⚠️ 样本 2」两格都标了，
# 它们的差却渲染成 `+746ms ↑`，一个警告都没有——读者会当成真实劣化。
# ⛔ 订正：原以为那个差值是红色的，实测**不是**——文档剥掉全部 font 标记、卡片没有对比列。
#    下面对 color=red 的断言因此**只锁函数行为，不代表产物观感**，⚠️ 别据此宣称修好了颜色。
h_load "$ROOT/bin/crash-daily.sh" perf_delta_cell perf_sample_note
. "$ROOT/bin/lib/core/verdict.sh"   # delta_cell 在核心层（⛔ 不把 mv_ 依赖塞进核心层）
MVP50_A=""; MVP50_B=""; MVN_A=""; MVN_B=""
mv_() { case "$2:$3" in (A:perf.p50) printf '%s' "$MVP50_A";; (B:perf.p50) printf '%s' "$MVP50_B";;
                        (A:perf.start_samples) printf '%s' "$MVN_A";; (B:perf.start_samples) printf '%s' "$MVN_B";; esac; }

MVP50_A=1505; MVP50_B=759; MVN_A=3; MVN_B=2
out="$(h_run perf_delta_cell ios A B perf.p50 10)"
h_assert_contains "$out" "+746ms" "⛔ 数值必须还在——藏起来会把「新版刚放量」一并藏掉"
h_assert_contains "$out" "↑"      "方向也保留"
h_assert_absent  "$out" "color=red" "⛔ 不得染红：两个小样本的差不足以断言「变差」"
h_assert_contains "$out" "⚠️ 样本 2" "标出两侧较小的那个样本数"

MVP50_A=1505; MVP50_B=759; MVN_A=3; MVN_B=999
out="$(h_run perf_delta_cell ios A B perf.p50 10)"
h_assert_absent "$out" "color=red" "⛔ 只要**一侧**不足就退回 neutral（不是两侧都不足才退）"
h_assert_contains "$out" "⚠️ 样本 3" "取较小的那一侧"

MVP50_A=1505; MVP50_B=759; MVN_A=1681; MVN_B=2769
out="$(h_run perf_delta_cell ios A B perf.p50 10)"
h_assert_contains "$out" "color=red" "两侧都够 → 恢复红绿判定（⛔ 否则等于把对比列废掉）"
h_assert_absent  "$out" "⚠️" "⛔ 样本够时不得留下任何警告"

MVP50_A=""; MVP50_B=759; MVN_A=""; MVN_B=2
out="$(h_run perf_delta_cell ios A B perf.p50 10)"
h_assert_eq "—" "$out" "⛔ 一侧无值 → 原样委托给 delta_cell 渲染「—」，不得在「—」后挂警告"

echo "── 源码断言：两处单元格**确实接上了**（⛔ 函数写了没接上，上面 16 条照样全绿）──"
# ⚠️ 这一节是本夹具的命门：抽函数出来测，原理上看不见「调用方有没有用它」（盲区①）。
SRC="$(cat "$ROOT/bin/crash-daily.sh")"
h_assert_contains "$SRC" 'start_p50)      val="$(mv_ "$1" "$2" perf.p50)"' 'start_p50 分支还在'
h_assert_contains "$SRC" 'perf_sample_note "$(mv_ "$1" "$2" perf.start_samples)" "$PERF_P50_SAMPLE_MIN"' '⛔ P50 单元格必须调用样本提示'
h_assert_contains "$SRC" 'perf_sample_note "$(mv_ "$1" "$2" perf.start_samples)" "$PERF_P95_SAMPLE_MIN"' '⛔ P95 单元格必须调用，且用的是 P95 的阈值'
h_assert_contains "$SRC" 'start_samples:$pn' '⛔ 样本数必须落进 metrics JSON，否则 mv_ 取到空、提示永不触发'
h_assert_contains "$SRC" "cut -d, -f2 | head -1" '⛔ 必须真的去读第 2 列（样本数的唯一来源）'
h_assert_contains "$SRC" 'perf_delta_cell "$1" "$2" "$3" perf.p50 "$PERF_P50_SAMPLE_MIN"' '⛔ P50 对比列必须走守卫版'
h_assert_contains "$SRC" 'perf_delta_cell "$1" "$2" "$3" perf.p95 "$PERF_P95_SAMPLE_MIN"' '⛔ P95 对比列必须走守卫版，且用 P95 阈值'
h_assert_absent  "$SRC" 'start_p50)      delta_cell' '⛔ 对比列不得再直连裸 delta_cell（那是 09-17 那个红色 +746ms 的来源）'

h_summary
