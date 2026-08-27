#!/usr/bin/env bash
# version.sh 的断言。

VCSV='1.5.4,82,12
1.5.3,287,172
1.5.10,5,5
1.5.9,900,800'

assert_eq "1.5.10 1.5.9" "$(pick_newest "$VCSV" 2 | tr '\n' ' ' | sed 's/ $//')" \
  "pick_newest 按版本号语义排序——1.5.10 > 1.5.9（字典序会判反，这是 sort -V 存在的理由）"
assert_eq "1.5.9 1.5.3" "$(pick_top_sessions "$VCSV" | tr '\n' ' ' | sed 's/ $//')" \
  "pick_top_sessions 按会话量，与版本号无关"
assert_eq "1.5.10 1.5.9 1.5.4" "$(union_versions '1.5.10
1.5.4' '1.5.9' 3 | tr '\n' ' ' | sed 's/ $//')" \
  "union_versions 合并去重、版本号降序、受上限截断"
assert_eq "1.5.10" "$(union_versions '1.5.10
1.5.4' '1.5.9' 1)" "union_versions 上限为 1 只留最新"
assert_eq "287" "$(ver_field "$VCSV" 1.5.3 2)" "ver_field 命中取会话数"
assert_eq "172" "$(ver_field "$VCSV" 1.5.3 3)" "ver_field 命中取设备数"
assert_eq ""    "$(ver_field "$VCSV" 9.9.9 2)" "ver_field 未命中 → 空"
# 单版本可比时的退化：只有一个版本时 pick_newest 取 2 只得 1 个，调用方据此判断无上一版
assert_eq "1.5.4" "$(pick_newest '1.5.4,10,5' 2 | tr '\n' ' ' | sed 's/ $//')" \
  "pick_newest 候选不足 N 时只返回已有的（调用方据此判定「无上一版可比」）"

# ── pick_versions_perf（change crash-data-completeness B 组）────────
# ⛔ 判据只有「性能表里有没有这一版」，与会话量无关——下面所有用例的候选表都不带会话数，
#    就是为了让「掺会话量门槛」这种改法在测试里直接编译不过（拿不到会话数）。
PVCAND='1.5.5
1.5.4
1.5.3
1.5.2
1.5.1
1.5.0'
PVAVAIL='1.5.4
1.5.3
1.5.2
1.5.1
1.5.0'

assert_eq "1.5.4 1.5.3" "$(pick_versions_perf "$PVCAND" "$PVAVAIL" 2 2 | tr '\n' ' ' | sed 's/ $//')" \
  "pick_versions_perf 跳过性能表零行的最新版，回退到有数据的两版"
assert_eq "1.5.5 1.5.4" "$(pick_versions_perf "$PVCAND" "$PVCAND" 2 2 | tr '\n' ' ' | sed 's/ $//')" \
  "pick_versions_perf 最新版有数据时不回退（⛔ 不得无条件降级到旧版）"
assert_eq "" "$(pick_versions_perf "$PVCAND" '1.5.1
1.5.0' 2 2 | tr '\n' ' ' | sed 's/ $//')" \
  "pick_versions_perf 回溯上限 2 版：前 4 个候选都没有就停手，⛔ 不继续翻到远古版本"
assert_eq "1.5.3" "$(pick_versions_perf "$PVCAND" '1.5.3' 2 2 | tr '\n' ' ' | sed 's/ $//')" \
  "pick_versions_perf 只凑到 1 个就返回 1 个（不足不补，调用方据此少一列）"
assert_eq "" "$(pick_versions_perf "$PVCAND" '' 2 2)" \
  "pick_versions_perf 性能表整体无数据 → 空（走既有「数据未同步」，不是「该版本无数据」）"
assert_eq "" "$(pick_versions_perf '' "$PVAVAIL" 2 2)" \
  "pick_versions_perf 候选为空（版本解析失败）→ 空，不炸"
assert_eq "1.5.10 1.5.9" "$(pick_versions_perf '1.5.9
1.5.10
1.5.2' '1.5.10
1.5.9
1.5.2' 2 2 | tr '\n' ' ' | sed 's/ $//')" \
  "pick_versions_perf 候选顺序由自己排：1.5.10 > 1.5.9（字典序会判反）"
