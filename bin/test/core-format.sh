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

# ── 完整日窗口（change crash-data-completeness A 组）────────────────
assert_eq "2026-08-25" "$(last_complete_day '2026-08-26 06:59 UTC')" \
  "last_complete_day = DATE(DATA_UNTIL) − 1（表里有 D+1 的事件 ⇒ D 已灌完）"
assert_eq "2026-02-28" "$(last_complete_day '2026-03-01 00:30 UTC')" \
  "last_complete_day 跨月正确（非闰年 2 月 28 日）"
assert_eq "" "$(last_complete_day '—')" \
  "last_complete_day 缺数占位符 → 空（调用方跳过性能取数，走既有缺数第 2 态）"
assert_eq "" "$(last_complete_day '')" "last_complete_day 空输入 → 空"
assert_eq "" "$(last_complete_day 'not a date')" "last_complete_day 不可解析 → 空（不炸）"

assert_eq "2026-08-23" "$(day_shift 2026-08-25 -2)" "day_shift 负偏移"
assert_eq "2026-08-26" "$(day_shift 2026-08-25 1)"  "day_shift 正偏移"
assert_eq "2026-08-25" "$(day_shift 2026-08-25 0)"  "day_shift 零偏移"
assert_eq "2026-02-28" "$(day_shift 2026-03-01 -1)" "day_shift 跨月"
assert_eq "" "$(day_shift '' -2)" "day_shift 空输入 → 空（LCD 缺失时整条链路留空而不是算出个假日期）"

# ⚠️ 期望值写死：这一串直接进卡片与文档，改文案必须同时改这里
assert_eq "2026-08-23 ~ 08-25（完整日） · 滞后 2 天 · 08-26 起未合并" \
  "$(win_days 2026-08-23 2026-08-25 "$(TZ=UTC date -j -f '%Y-%m-%d %H:%M:%S' '2026-08-27 07:59:00' '+%s')" '2026-08-26 06:59 UTC')" \
  "win_days 同时给窗口、滞后与上游进度（design D2：只给窗口会丢掉「明天会不会好转」）"
assert_eq "—" "$(win_days '' '' 1787817540 '—')" \
  "win_days 无 LCD → 单个破折号，⛔ 不编一个窗口出来"

# ── 卡片短页面名（6 列列宽代价，实发验证被截后加的）────────────────
assert_eq "PaywallTheme…" "$(screen_brief PaywallThemeCoursePopupViewController)" \
  "screen_brief 先砍 ViewController 再截断"
assert_eq "STWebpage" "$(screen_brief STWebpageController)" \
  "screen_brief 砍完后够短就不截断（不硬加省略号）"
assert_eq "Activity" "$(screen_brief Activity)" \
  "screen_brief 名字本身就是后缀时不砍成空串"
assert_eq "" "$(screen_brief '')" "screen_brief 空输入 → 空"
assert_eq "DinoClass…" "$(screen_brief DinoClassLessonEntryActivity 9)" \
  "screen_brief 长度可由调用方给"
