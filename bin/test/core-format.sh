#!/usr/bin/env bash
# format.sh 的断言。⚠️ 期望值从**行为意图**推导，不从当前输出反抄——
# 反抄会把 bug 一起固化成规范。
# ⚠️ 涉及时区的用例必须固定 TZ：_fmt 不传时区参数时读环境 TZ，否则换台机器结果就变。

assert_eq ""      "$(rate_pct '' 100)"   "rate_pct 分子为空 → 空串"
assert_eq ""      "$(rate_pct 3 '')"     "rate_pct 分母为空 → 空串"
assert_eq ""      "$(rate_pct 3 0)"      "rate_pct 分母为零 → 空串（不是 0，「无法计算」的根）"
assert_eq "3.00"  "$(rate_pct 3 100)"    "rate_pct 正常"
assert_eq "0.36"  "$(rate_pct 23 6427)"  "rate_pct 实际量级"

assert_eq ""     "$(int '')"      "int 空输入 → 空串"
assert_eq "251"  "$(int 251.0)"   "int 去掉 BigQuery 的浮点尾巴"
assert_eq ""     "$(pct '')"      "pct 空输入 → 空串"
assert_eq "0"    "$(pct 0.00)"    "pct 整数不留小数"
assert_eq "73.5" "$(pct 73.50)"   "pct 小数保留一位"

assert_eq "" "$(_until_epoch '')"          "_until_epoch 空 → 空"
assert_eq "" "$(_until_epoch '—')"         "_until_epoch 破折号 → 空（缺数占位符不是时间）"
assert_eq "" "$(_until_epoch 'not a date')" "_until_epoch 不可解析 → 空（不炸）"

# 基准 epoch 固定 → 结果可断言。1755000000 = 2025-08-12 UTC 附近，与真实数据无关。
assert_eq "$(TZ=UTC date -r 1754913600 '+%m-%d %H:%M') → —" \
          "$(TZ=UTC win_compact 1755000000 '+0000' 1 '')" \
          "win_compact 止点为空 → 降级形态（只给起点）"
