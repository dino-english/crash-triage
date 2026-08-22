#!/usr/bin/env bash
# verdict.sh 的断言。

assert_eq ""       "$(traffic_light '' 1 0.5)"        "traffic_light 空值不判定（「空值不告警」口径的根）"
assert_eq ""       "$(traffic_light 无法计算 1 0.5)"   "traffic_light 「无法计算」不判定"
assert_eq "red"    "$(traffic_light 1.01 1 0.5)"      "traffic_light 略高于红线 → red"
assert_eq "yellow" "$(traffic_light 0.51 1 0.5)"      "traffic_light 红黄之间 → yellow"
assert_eq "green"  "$(traffic_light 0.5 1 0.5)"       "traffic_light 等于黄线 → green（阈值是「大于」不是「大于等于」）"
assert_eq "green"  "$(traffic_light 0 1 0.5)"         "traffic_light 零 → green"
# crash-free 用「坏方向值判定、好方向值展示」，100% 对应崩溃会话率 0
assert_eq "green"  "$(traffic_light 0 1.0 0.5)"       "crash-free 100% → green（方向反转后不能判成 red）"

assert_eq "—" "$(delta_cell '' 3 pp lower_better)"          "delta_cell 缺一端 → —"
assert_eq "—" "$(delta_cell 无法计算 3 pp lower_better)"     "delta_cell 「无法计算」→ —"
assert_eq '<font color=red>+2.00pp ↑</font>'   "$(delta_cell 5 3 pp lower_better)"  "lower_better 涨 = 变差（红）"
assert_eq '<font color=green>-2.00pp ↓</font>' "$(delta_cell 3 5 pp lower_better)"  "lower_better 跌 = 变好（绿）"
assert_eq '<font color=green>+2.00pp ↑</font>' "$(delta_cell 5 3 pp higher_better)" "higher_better 涨 = 变好（crash-free 靠它）"
assert_eq '<font color=red>-2.00pp ↓</font>'   "$(delta_cell 3 5 pp higher_better)" "higher_better 跌 = 变差"
assert_eq '-2 ↓' "$(delta_cell 3 5 n neutral)"  "neutral 不着色（会话数：箭头跟数值、不判好坏）"
assert_eq '0'    "$(delta_cell 3 3 n lower_better)" "零增量无箭头无颜色"

# 基准 epoch 固定：1755000000 起，3 天窗口的下界是 1754740800
assert_eq ""  "$(stale_days 1755000000 '2025-08-12 12:00 UTC' 3)" "stale_days 窗口内 → 空（未停更）"
assert_eq ""  "$(stale_days 1755000000 '' 3)"                     "stale_days 无时间戳 → 空（不可解析不算停更）"
