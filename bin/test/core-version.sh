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
