#!/usr/bin/env bash
# diag.sh 的断言（change crash-tech-diagnostics tasks 3.2）。
# 默认阈值 10 台 / 4 倍；11-23 的数字取自 proposal「Why」与回测（13 台 vs 同小时基线约 2）。
# ⛔ 双向：「基线按 1 计」「设备下限」「去重窗口」三个分支各有一条去掉它就变红的用例（行尾注明）。

_D_MIN=10; _D_MULT=4

# ── diag_spike ──
assert_eq "spike" "$(diag_spike 13 2.2 $_D_MIN $_D_MULT)" "11-23 17 点 409：13 台 vs 基线 2.2 → 激增"
assert_eq "flat"  "$(diag_spike 40 38.6 $_D_MIN $_D_MULT)" "21 点 biz_40010 与前 7 天同小时相当 → 平稳"
assert_eq "flat"  "$(diag_spike 3 0 $_D_MIN $_D_MULT)"     "基线 0 + 3 台 → 平稳"
assert_eq "spike" "$(diag_spike 12 0 $_D_MIN $_D_MULT)"    "基线 0 + 12 台 → 激增"
assert_eq "flat"  "$(diag_spike 3 0 2 4)"   "下限放低到 2 时，基线 0 按 1 计：3 < 1×4 → 平稳（去掉「按 1 计」则变红）"
assert_eq "spike" "$(diag_spike 10 2.5 $_D_MIN $_D_MULT)"  "边界：恰好 10 台、恰好 4 倍 → 激增（≥ 不是 >）"
assert_eq "flat"  "$(diag_spike 9 0 $_D_MIN $_D_MULT)"     "边界：9 台不到下限 → 平稳（去掉下限则变红：9 ≥ 1×4）"

# ── diag_dedupe ──（epoch 秒，窗口 6 小时）
_D_T0=1795424400                          # 2026-11-23 09:00 UTC = 17:00 MYT
_D_A="{\"/x × http_409\":{\"sent\":$_D_T0,\"first\":\"2026-11-23 17\",\"last\":\"2026-11-23 17\"}}"
assert_eq "send" "$(diag_dedupe '{}' '/x × http_409' $((_D_T0)) 21600)"            "从未投递 → 发"
assert_eq "send" "$(diag_dedupe '' '/x × http_409' $((_D_T0)) 21600)"              "alerted.json 为空串（首次运行）→ 发"
assert_eq "skip" "$(diag_dedupe "$_D_A" '/x × http_409' $((_D_T0 + 3600)) 21600)"  "6 小时内第二次命中 → 不发（去掉去重则变红）"
assert_eq "send" "$(diag_dedupe "$_D_A" '/x × http_409' $((_D_T0 + 21600)) 21600)" "恰好 6 小时后再命中 → 发"
assert_eq "send" "$(diag_dedupe "$_D_A" '/y × http_500' $((_D_T0 + 60)) 21600)"    "别的签名不受这条去重影响"
assert_eq "send" "$(diag_dedupe '{"/x × http_409":{"sent":null,"first":"2026-11-23 17","last":"2026-11-23 17"}}' '/x × http_409' $((_D_T0 + 60)) 21600)" \
  "命中过但没投递成功（sent 为 null）→ 下一小时照发"

# ── diag_evaluate ──
# 历史：前 7 天 17 点 409 每天 2 台（iOS 1 + Android 1）→ 基线 2；21 点 biz_40010 每天 40 台。
_d_hist="$(jq -cn '
  [range(16; 23) as $d
   | ("2026-11-" + ($d | tostring)) as $day
   | {h:($day + " 17"), plat:"IOS", ver:"1.8.2", target:"/app/v2/onboarding-journey/bootstrap", code:"http_409", devices:1, users:1, events:3},
     {h:($day + " 17"), plat:"ANDROID", ver:"1.8.2", target:"/app/v2/onboarding-journey/bootstrap", code:"http_409", devices:1, users:1, events:2},
     {h:($day + " 21"), plat:"IOS", ver:"1.8.2", target:"/app/v1/purchase", code:"biz_40010", devices:40, users:38, events:60}]
  + [{h:"2026-11-15 17", plat:"IOS", ver:"1.8.2", target:"/app/v2/onboarding-journey/bootstrap", code:"http_409", devices:99, users:99, events:99}]')"
_d_cur='[
 {"h":"2026-11-23 17","plat":"IOS","ver":"1.8.2","target":"/app/v2/onboarding-journey/bootstrap","code":"http_409","devices":9,"users":8,"events":120},
 {"h":"2026-11-23 17","plat":"ANDROID","ver":"1.8.2","target":"/app/v2/onboarding-journey/bootstrap","code":"http_409","devices":4,"users":4,"events":30},
 {"h":"2026-11-23 17","plat":"IOS","ver":"1.8.2","target":"/app/v1/new","code":"http_500","devices":12,"users":0,"events":12},
 {"h":"2026-11-23 16","plat":"IOS","ver":"1.8.2","target":"/app/v1/new","code":"http_500","devices":50,"users":0,"events":50}
]'
_d_ev="$(diag_evaluate "$_d_cur" "$_d_hist" "2026-11-23 17" $_D_MIN $_D_MULT)"
assert_eq "/app/v2/onboarding-journey/bootstrap × http_409	13	12	150	2	spike" \
  "$(printf '%s' "$_d_ev" | jq -r '.[] | select(.code=="http_409") | [.sig,.devices,.users,.events,.baseline,.verdict] | @tsv')" \
  "签名级：两平台相加 13 台；基线只取前 7 天同小时（11-15 的 99 台在窗口外，不进基线）"
assert_eq "/app/v1/new × http_500	12	0	spike" \
  "$(printf '%s' "$_d_ev" | jq -r '.[] | select(.code=="http_500") | [.sig,.devices,.baseline,.verdict] | @tsv')" \
  "历史无此签名 → 基线 0（按 1 计）；16 点的行不进 17 点的判定"
assert_eq "http_409 http_500" "$(printf '%s' "$_d_ev" | jq -r '[.[].code] | join(" ")')" "按设备数降序"
assert_eq "40	flat" \
  "$(diag_evaluate '[{"h":"2026-11-23 21","plat":"IOS","ver":"1.8.2","target":"/app/v1/purchase","code":"biz_40010","devices":45,"users":44,"events":70}]' \
     "$_d_hist" "2026-11-23 21" $_D_MIN $_D_MULT | jq -r '.[0] | [.baseline,.verdict] | @tsv')" \
  "同小时基线压掉 21 点作息高峰：45 台 vs 40 → 平稳"
assert_eq "1" \
  "$(diag_evaluate '[{"h":"2026-11-23 00","plat":"IOS","ver":"1","target":"/z","code":"http_500","devices":1,"users":1,"events":1}]' \
     '[{"h":"2026-11-22 23","plat":"IOS","ver":"1","target":"/z","code":"http_500","devices":70,"users":1,"events":1},
       {"h":"2026-11-22 00","plat":"IOS","ver":"1","target":"/z","code":"http_500","devices":7,"users":1,"events":1}]' \
     "2026-11-23 00" $_D_MIN $_D_MULT | jq -r '.[0].baseline')" \
  "跨零点：00 点的基线取前几天 00 点（7/7=1），不取前一小时 23 点"

# ── diag_plan / diag_mark_sent ──
_d_ev1='[{"sig":"/x × http_409","target":"/x","code":"http_409","devices":13,"users":12,"events":150,"baseline":2.4,"verdict":"spike"},
         {"sig":"/p × biz_40010","target":"/p","code":"biz_40010","devices":40,"users":40,"events":60,"baseline":38,"verdict":"flat"}]'
_d_p1="$(diag_plan '{}' "$_d_ev1" "2026-11-23 17" $_D_T0 21600)"
assert_eq "/x × http_409	2026-11-23 17" "$(printf '%s' "$_d_p1" | jq -r '.send[] | [.sig,.first] | @tsv')" "首次激增：只发激增的签名，本轮首个小时 = 本小时"
assert_eq "null	2026-11-23 17" "$(printf '%s' "$_d_p1" | jq -r '.state["/x × http_409"] | [(.sent|tostring),.last] | @tsv')" \
  "diag_plan 不写 sent（投递成功才写）"
assert_eq "false" "$(printf '%s' "$_d_p1" | jq -r '.state | has("/p × biz_40010")')" "平稳签名不进状态"
_d_s1="$(diag_mark_sent "$(printf '%s' "$_d_p1" | jq -c .state)" '["/x × http_409"]' $_D_T0)"
_d_ev2="$(printf '%s' "$_d_ev1" | jq -c '.[0].devices = 35')"
_d_p2="$(diag_plan "$_d_s1" "$_d_ev2" "2026-11-23 18" $((_D_T0 + 3600)) 21600)"
assert_eq "0	2026-11-23 17	2026-11-23 18" \
  "$(printf '%s' "$_d_p2" | jq -r '[(.send|length), .state["/x × http_409"].first, .state["/x × http_409"].last] | @tsv')" \
  "下一小时仍激增：不发；本轮首个小时沿用 17 点，last 前移"
_d_p3="$(diag_plan "$(printf '%s' "$_d_p2" | jq -c .state)" "$_d_ev2" "2026-11-24 00" $((_D_T0 + 7 * 3600)) 21600)"
assert_eq "1	2026-11-24 00" "$(printf '%s' "$_d_p3" | jq -r '[(.send|length), .send[0].first] | @tsv')" \
  "中断后（18 点之后不再激增）再次激增：出了 6 小时窗口 → 发，首个小时重新起算"
assert_eq "2026-11-23 17" "$(diag_plan "$_d_s1" "$_d_ev1" "2026-11-23 17" $((_D_T0 + 60)) 21600 | jq -r '.state["/x × http_409"].first')" \
  "同一小时重跑：沿用 first，不发（幂等）"
assert_eq "false" "$(diag_plan '{"/old × http_500":{"sent":1,"first":"2026-11-10 01","last":"2026-11-10 01"}}' '[]' "2026-11-23 17" $_D_T0 21600 | jq -r '.state | has("/old × http_500")')" \
  "状态里 last 早于 7 天的条目清掉"
# 复判上一小时先于本小时 plan（diag-hourly.sh）：重跑同一小时时状态里 last 已是本小时，复判 17 点 ⛔ 不能把 last 拉回 17、把 first 重置成 17
_d_s4='{"/x × http_409":{"sent":null,"first":"2026-11-23 15","last":"2026-11-23 18"}}'
assert_eq "2026-11-23 15	2026-11-23 18" "$(diag_plan "$_d_s4" "$_d_ev1" "2026-11-23 17" $_D_T0 21600 | jq -r '.state["/x × http_409"] | [.first, .last] | @tsv')" \
  "复判更早的小时：first 沿用、last 只前移不后退"
assert_eq "2026-11-23 17	2026-11-23 17" "$(diag_plan '{"/x × http_409":{"sent":null,"first":"2026-11-23 18","last":"2026-11-23 18"}}' "$_d_ev1" "2026-11-23 17" $_D_T0 21600 | jq -r '.send[0].first, .state["/x × http_409"].first' | paste -sd '\t' -)" \
  "复判发现上一小时已在激增：first 取较早的上一小时"
assert_eq "false" "$(printf '%s' "$_d_p1" | jq -r '.send[0] | has("st")')" "send 条目不带状态字段"
# 回放更早的小时（状态比它新一小时以上）：⛔ 不把不连续的激增并成一段，状态原样保留（审查 2026-11-27 #3）
_d_s5='{"/x × http_409":{"sent":null,"first":"2026-11-26 21","last":"2026-11-26 21"}}'
assert_eq "2026-11-20 10	2026-11-26 21	2026-11-26 21" "$(diag_plan "$_d_s5" "$_d_ev1" "2026-11-20 10" $_D_T0 21600 | jq -r '[.send[0].first, .state["/x × http_409"].first, .state["/x × http_409"].last] | @tsv')" \
  "回放旧小时：卡片 first = 该小时，状态 first / last 不变"

# ── diag_pick_suffix ──
assert_eq "20261125" "$(diag_pick_suffix $'events_20261125\nevents_intraday_20261125\nevents_intraday_20261126' 20261125)" "日表与 intraday 并存 → 取日表"
assert_eq "intraday_20261126" "$(diag_pick_suffix $'events_20261125\nevents_intraday_20261126' 20261126)" "只有 intraday → 取 intraday"
assert_eq "" "$(diag_pick_suffix $'events_20261125' 20261127)" "都不存在 → 空串（调用方判失败）"

# ── diag_missing ──（按来源各判各的，前 7 天同小时每天都有才算基线；返回断数的来源，空串 = 正常）
_d_rows="$(for k in 1 2 3 4 5 6 7; do printf '{"h":"2026-11-%02d 17","devices":3}\n' $((23 - k)); done | jq -sc '. + [{"h":"2026-11-23 15","devices":5}]')"
assert_eq "ga4" "$(diag_missing "$_d_rows" "2026-11-23 17")" "GA4：本小时与上一小时都无数据、前 7 天同小时每天都有 → 断数（没有 src 的旧行按 ga4 算）"
assert_eq "" "$(diag_missing "$(printf '%s' "$_d_rows" | jq -c '. + [{"h":"2026-11-23 16","devices":1}]')" "2026-11-23 17")" "上一小时有数据 → 不算缺失（只缺一小时不报）"
assert_eq "" "$(diag_missing '[]' "2026-11-23 17")" "前 7 天同小时也没有（冷启动）→ 不报缺失"
assert_eq "" "$(diag_missing "$(printf '%s' "$_d_rows" | jq -c 'del(.[3])')" "2026-11-23 17")" \
  "前 7 天只有 6 天有（量小的来源夜里常空）→ 不报（改回「任一天有」则变红，审查 #3）"
_d_ph="$(printf '%s' "$_d_rows" | jq -c 'map(. + {src:"posthog"}) + [{"h":"2026-11-23 17","devices":40}]')"
assert_eq "posthog" "$(diag_missing "$_d_ph" "2026-11-23 17")" \
  "PostHog 断、GA4 这一小时有 40 台 → 只报 PostHog（两边合起来判就被 GA4 盖住，变红）"
assert_eq "ga4 posthog" "$(diag_missing "$(printf '%s' "$_d_rows" | jq -c '. + map(. + {src:"posthog"})')" "2026-11-23 17")" "两边都断 → 两边都报"

# ── diag_card ──
_d_send='[{"sig":"/x × http_409","target":"/x","code":"http_409","devices":35,"users":32,"events":392,"baseline":2.6,"first":"2026-11-23 17",
  "geo":[{"k1":"IOS","k2":"Saudi Arabia","k3":"2.1.1","devices":14,"affected":35},{"k1":"ANDROID","k2":"South Korea","k3":"2.1.0","devices":11,"affected":35}],
  "cfg":[{"k1":"experiment","k2":"2124743975533666306","devices":18,"affected":35},{"k1":"direct","k2":"190101","devices":3,"affected":35}]}]'
_d_card="$(diag_card "$_d_send" "2026-11-23 18" ok 10 4)"
_d_txt="$(printf '%s' "$_d_card" | jq -r '[.. | .content? // empty] | join("\n")')"
# spec「每小时激增告警」必含：签名、设备 / 用户数与基线、首次激增时刻、平台 × 版本 × 国家、策略配置分布；不给根因
for _d_need in "2026-11-23 18:00" "/x × http_409" "**35 台** · 32 账号" "| 2.6 |" "13×" "从 17:00 起持续" \
               "iOS 2.1.1：Saudi Arabia 14" "Android 2.1.0：South Korea 11" "受影响 35 台里" "experiment 2124743975533666306 18 台" "不判断根因"; do
  assert_eq "1" "$(printf '%s' "$_d_txt" | grep -cF "$_d_need" | tr -d ' ' | sed 's/^[1-9][0-9]*$/1/')" "卡片含「${_d_need}」"
done
assert_eq "0" "$(printf '%s' "$_d_txt" | grep -cE '根因：|原因是|导致' || true)" "卡片不写根因结论"
assert_eq "0" "$(printf '%s' "$_d_txt" | grep -c '共同点' || true)" "只有 1 个签名时不写「共同点」"
assert_eq "0" "$(printf '%s' "$_d_txt" | grep -c '0 账号 =' || true)" "没有 0 账号的签名就不写那句解释"
_d_send2="$(printf '%s' "$_d_send" | jq -c '. + [{"sig":"/y × http_409","target":"/y","code":"http_409","devices":12,"users":0,"baseline":0.4,"first":"2026-11-23 18",
  "geo":[{"k1":"IOS","k2":"Saudi Arabia","k3":"2.1.1","devices":12,"affected":12}]}]')"
_d_txt2="$(diag_card "$_d_send2" "2026-11-23 18" ok 10 4 | jq -r '[.. | .content? // empty] | join("\n")')"
assert_eq "1" "$(printf '%s' "$_d_txt2" | grep -c '共同点：都是 http_409 · 设备最多的版本 2.1.1、国家 Saudi Arabia')" \
  "2 个签名：共同点只并分布数数（平台不同就不写「都在」）"
assert_eq "1" "$(printf '%s' "$_d_txt2" | grep -c '| 12×' )" "倍数 = 设备 / max(基线, 1)：基线 0.4 按 1 计 → 12×（与判定口径一致）"
assert_eq "1" "$(printf '%s' "$_d_txt2" | grep -c '0 账号 = 这些设备都没登录')" "有 0 账号的签名才解释"
assert_eq "0" "$(printf '%s' "$_d_txt2" | grep -c '/y × http_409 | .*起持续')" "首次 = 本小时：不写「起持续」"
assert_eq "1" "$(printf '%s' "$_d_txt" | grep -c '下一小时会复判一次')" "实时卡脚注写明下一小时会复判"
_d_rc="$(diag_card "$_d_send" "2026-11-23 18" ok 10 4 recheck)"
assert_eq "🚨 技术诊断报错激增（复判补报）· 2026-11-23 18:00（MYT）· 1 个接口	red" "$(printf '%s' "$_d_rc" | jq -r '[.header.title.content, .header.template] | @tsv')" "复判卡：标题写「复判补报」与被复判的小时"
_d_rtxt="$(printf '%s' "$_d_rc" | jq -r '[.. | .content? // empty] | join("\n")')"
assert_eq "1	1	0" "$(printf '%s' "$_d_rtxt" | grep -c '| 该小时 |')	$(printf '%s' "$_d_rtxt" | grep -c '复判补报：这一小时在整点后 5 分钟')	$(printf '%s' "$_d_rtxt" | grep -c '本小时' || true)" \
  "复判卡：表头「该小时」、脚注说明晚报一小时的原因，不出现「本小时」"
assert_eq "1	0" "$(diag_card "$(printf '%s' "$_d_send" | jq -c '.[0].cfg = []')" "2026-11-23 18" ok 10 4 recheck | jq -r '[.. | .content? // empty] | join("\n")' | { t="$(cat)"; printf '%s\t%s' "$(printf '%s' "$t" | grep -c '受影响设备该小时没有上报')" "$(printf '%s' "$t" | grep -c '本小时' || true)"; })" \
  "复判卡：没有策略配置上报时也写「该小时」（11-27 本机回放实发发现）"
assert_eq "orange" "$(diag_card '[]' "2026-11-23 18" GA4 10 4 | jq -r .header.template)" "只有数据缺失时卡片为橙色"
assert_eq "1" "$(diag_card '[]' "2026-11-23 18" GA4 10 4 | jq -r '[.. | .content? // empty] | join(" ")' | grep -c '数据缺失')" "数据缺失卡片写明「数据缺失」"
assert_eq "1" "$(diag_card '[]' "2026-11-23 18" PostHog 10 4 | jq -r '[.. | .content? // empty] | join(" ")' | grep -c 'PostHog 一侧没有')" "写明是哪个来源断数（另一边可能照常有数据）"

# ── diag_need_dates ──（20261125 的次日 00:05 UTC = 1795651500）
_d_cov='{"20261124":{"src":"daily","at":1},"20261125":{"src":"intraday","at":1795651500},"20261126":{"src":"intraday","at":1795651499}}'
assert_eq "20261126 20261127" "$(diag_need_dates "$_d_cov" '["20261124","20261125","20261126","20261127"]')" \
  "日表 → 完整；intraday 在次日 00:05 UTC 及之后取的 → 完整；之前取的 / 没取过 → 要取"
assert_eq "20261124" "$(diag_need_dates '' '["20261124"]')" "coverage 为空（首次运行）→ 全部要取"

# ── diag_evaluate_days / diag_daily_table ──（日级阈值 50 台 / 3 倍，tasks 1.3）
# 历史：前 7 天 409 每天 iOS 2.1.1 30 台 + Android 2.1.0 20 台（签名级 50）；flow 每天 100 台
_dd_hist="$(jq -cn '[range(16; 23) as $x | ("2026-11-" + ($x | tostring)) as $d
  | {d:$d, kind:"api", plat:"IOS", ver:"2.1.1", s1:"/b", s2:"http_409", devices:30, users:30, events:40},
    {d:$d, kind:"api", plat:"ANDROID", ver:"2.1.0", s1:"/b", s2:"http_409", devices:20, users:20, events:30},
    {d:$d, kind:"flow", plat:"ANDROID", ver:"2.1.0", s1:"launch_journey_state", s2:"timeout", devices:100, users:90, events:300}]')"
_dd_cur='[
 {"d":"2026-11-23","kind":"api","plat":"IOS","ver":"2.1.1","s1":"/b","s2":"http_409","devices":120,"users":110,"events":900},
 {"d":"2026-11-23","kind":"api","plat":"ANDROID","ver":"2.1.0","s1":"/b","s2":"http_409","devices":58,"users":56,"events":400},
 {"d":"2026-11-23","kind":"api","plat":"IOS","ver":"1.9.0","s1":"/old","s2":"http_500","devices":99,"users":9,"events":99},
 {"d":"2026-11-23","kind":"flow","plat":"ANDROID","ver":"2.1.0","s1":"launch_journey_state","s2":"timeout","devices":400,"users":380,"events":900}]'
_dd_all="$(jq -cn --argjson a "$_dd_cur" --argjson b "$_dd_hist" '$a + $b')"
_dd_ev="$(printf '%s' "$_dd_all" | diag_evaluate_days "2026-11-23" 50 3)"
assert_eq "/b × http_409	178	50	spike" "$(printf '%s' "$_dd_ev" | jq -r '.[] | select(.sig=="/b × http_409") | [.sig,.devices,.baseline,.verdict]|@tsv')" \
  "日级签名级：跨平台跨版本相加 178 台 vs 前 7 天均值 50 → 激增"
assert_eq "false" "$(printf '%s' "$_dd_ev" | jq -r 'any(.[]; .sig | startswith("launch_journey_state"))')" "流程类不进日级判定"
_dd_v='{"IOS":["2.1.1","2.1.0"],"ANDROID":["2.1.0","2.0.0"]}'
assert_eq '"iOS","2.1.1","/b × http_409","120","110","30","🚨 全版本 178 台 vs 均值 50"
"Android","2.1.0","/b × http_409","58","56","20","🚨 全版本 178 台 vs 均值 50"' \
  "$(printf "%s" "$_dd_all" | diag_daily_table "2026-11-23" api "$_dd_v" 10 "$_dd_ev")" \
  "接口类表：只取报告版本（iOS 1.9.0 那行不出）；行基线按同平台同版本同签名；激增按签名级写"
assert_eq '"Android","2.1.0","launch_journey_state × timeout","400","380","100","不判"' \
  "$(printf "%s" "$_dd_all" | diag_daily_table "2026-11-23" flow "$_dd_v" 10 "$_dd_ev")" "流程类表：激增列写「不判」"
assert_eq "1" "$(printf "%s" "$_dd_all" | diag_daily_table "2026-11-23" api "$_dd_v" 1 "$_dd_ev" | wc -l | tr -d ' ')" "条数上限生效"
assert_eq "—" "$(printf "%s" "$_dd_all" | diag_daily_table "2026-11-23" api "$_dd_v" 1 '[]' | awk -F'","' '{print $7}' | tr -d '"')" "无激增 → 「—」"

# ── diag_need_days ──（2026-11-23 的完整线 = MYT 11-24 00:05）
_dn_end="$(TZ=Asia/Kuala_Lumpur date -j -f '%Y-%m-%d %H:%M:%S' '2026-11-24 00:05:00' +%s)"
# ⚠️ JSON 先拼进变量：bash 3.2 下 "$( … "{\"…\"}" … )" 这种嵌套转义引号会把参数拆错（实测）
_dn_cov="$(jq -cn --argjson e "$_dn_end" '{"2026-11-23": $e, "2026-11-22": ($e - 86400 - 1), "2026-11-24": $e}')"
assert_eq "2026-11-22 2026-11-24" \
  "$(diag_need_days "$_dn_cov" '["2026-11-22","2026-11-23","2026-11-24"]')" \
  "次日 00:05 MYT 及之后取的 → 完整；之前取的 / 当天还没过完 → 要取"
assert_eq "2026-11-23" "$(diag_need_days '' '["2026-11-23"]')" "coverage 为空 → 要取"

# ── diag_weekly ──（跑批日 2026-11-24 周一：本周 11-17～11-23，上周 11-10～11-16，前 4 周 10-20～11-16）
_dw_rows="$(jq -cn '
  def day($k): ("2026-10-20" | strptime("%Y-%m-%d") | mktime + $k * 86400 | strftime("%Y-%m-%d"));
  [ range(0; 35) as $k | day($k) as $d
    | {d:$d, kind:"api", plat:"IOS", ver:"2.1.1", s1:"/b", s2:"http_409", devices:(if $d == "2026-11-23" then 178 else 52 end), users:1, events:1},
      (if $k >= 28 then {d:$d, kind:"api", plat:"ANDROID", ver:"2.1.0", s1:"/new", s2:"http_500", devices:(if $d == "2026-11-22" then 30 else 2 end), users:1, events:1} else empty end),
      (if $k >= 30 then {d:$d, kind:"flow", plat:"ANDROID", ver:"2.1.0", s1:"strategy_x", s2:"timeout", devices:5, users:1, events:1} else empty end) ]')"
_dw="$(printf '%s' "$_dw_rows" | diag_weekly "2026-11-24" '{"IOS":["2.1.1"],"ANDROID":["2.1.0"]}' 10 10 50)"
assert_eq "2026-11-17 2026-11-23 2026-11-10 2026-11-16" "$(printf '%s' "$_dw" | jq -r '(.week + .prev) | join(" ")')" "周窗口：本周 D-7…D-1，上周 D-14…D-8"
assert_eq "/b × http_409	70	52	35" "$(printf '%s' "$_dw" | jq -r '.top[] | select(.sig=="/b × http_409") | [.sig,.this_avg,.prev_avg,.wow]|@tsv')" \
  "409：本周日均 (52×6+178)/7=70 vs 上周 52 → +35%（签名级）"
assert_eq "iOS 2.1.1 70" "$(printf '%s' "$_dw" | jq -r '.top[] | select(.sig=="/b × http_409") | .by_ver | map("\(.plat) \(.ver) \(.this_avg)") | join(" · ")')" \
  "主力版本分布只列给定版本"
# 新版放量：上周只在旧版有、本周换到新版——签名级环比不受影响（⛔ 不按版本算环比，那会得出天文数字）
_dw_ramp="$(jq -cn '[ range(0; 14) as $k | ("2026-11-10" | strptime("%Y-%m-%d") | mktime + $k * 86400 | strftime("%Y-%m-%d")) as $d
  | {d:$d, kind:"api", plat:"IOS", ver:(if $k < 7 then "2.0.0" else "2.1.0" end), s1:"/r", s2:"http_500", devices:20, users:1, events:1} ]')"
assert_eq "20	20	0	iOS 2.1.0 20" "$(printf '%s' "$_dw_ramp" | diag_weekly "2026-11-24" '{"IOS":["2.1.0"],"ANDROID":[]}' 10 10 50 \
  | jq -r '.top[0] | [.this_avg, .prev_avg, .wow, (.by_ver | map("\(.plat) \(.ver) \(.this_avg)") | join(" · "))] | @tsv')" \
  "旧版 → 新版换代：签名级环比 0%，分布里只有本周主力 2.1.0"
assert_eq "/new × http_500	2026-11-17	30" "$(printf '%s' "$_dw" | jq -r '.new[] | [.sig,.first,.peak]|@tsv')" \
  "前 4 周一行都没有、本周峰值 30 ≥ 10 → 本周新出现（首次 11-17）；409 前 4 周天天有 → 不是新的"
assert_eq "0" "$(printf '%s' "$_dw" | jq '[.new[] | select(.kind=="flow")] | length')" "峰值 5 < 10 的流程类新签名不进「新出现」"
assert_eq "/b × http_409" "$(printf '%s' "$_dw" | jq -r '[.high[].sig] | join(" ")')" "持续高位：本周 70、上周 52 都 ≥ 50"
assert_eq "" "$(printf '%s' "$_dw_rows" | diag_weekly "2026-11-24" '{"IOS":["2.1.1"],"ANDROID":["2.1.0"]}' 10 10 53 | jq -r '[.high[].sig] | join(" ")')" "上周 52 < 53 → 不算持续高位（两周都要过线）"

# ── diag_l0_line ──（L1 卡片看 L0 健康，最长间隔 3 小时）
assert_eq "" "$(diag_l0_line true '' 1000 4000 10800)" "健康：50 分钟前跑过且成功 → 空"
assert_eq "⚠️ L0 每小时诊断告警已 4 小时没有运行——定时任务可能停了，期间的接口激增不会告警" \
  "$(diag_l0_line true '' 1000 $((1000 + 4 * 3600 + 5)) 10800)" "超过 3 小时没跑 → 停摆一行（成功也报）"
assert_eq "⚠️ L0 每小时诊断告警最近一次失败：数据缺失：2026-11-23 18:00" \
  "$(diag_l0_line false '数据缺失：2026-11-23 18:00' 1000 4000 10800)" "最近一次失败 → 失败一行"
assert_eq "" "$(diag_l0_line true '' 1000 $((1000 + 10800)) 10800)" "边界：恰好 3 小时不算停摆（> 不是 ≥）"

# ── diag_pick ──（PostHog 双源，design 决策 8：每个平台 × 版本 × 天只留设备多的一边，不相加）
_D_PR='[{"d":"2026-11-26","plat":"ANDROID","ver":"2.2.0","devices":5},
 {"d":"2026-11-26","plat":"IOS","ver":"2.1.2","src":"ga4","devices":2},
 {"d":"2026-11-26","plat":"IOS","ver":"2.1.2","src":"posthog","devices":20},{"d":"2026-11-26","plat":"IOS","ver":"2.1.2","src":"posthog","devices":3},
 {"d":"2026-11-25","plat":"IOS","ver":"2.1.2","src":"ga4","devices":9},{"d":"2026-11-25","plat":"IOS","ver":"2.1.2","src":"posthog","devices":4},
 {"d":"2026-11-24","plat":"ANDROID","ver":"2.1.1","src":"ga4","devices":3},{"d":"2026-11-24","plat":"ANDROID","ver":"2.1.1","src":"posthog","devices":3}]'
assert_eq "2026-11-26 ANDROID 2.2.0 ga4,2026-11-26 IOS 2.1.2 posthog,2026-11-26 IOS 2.1.2 posthog,2026-11-25 IOS 2.1.2 ga4,2026-11-24 ANDROID 2.1.1 posthog" \
  "$(printf '%s' "$_D_PR" | diag_pick d | jq -r 'map([.d,.plat,.ver,.src]|join(" "))|join(",")')" \
  "只在 GA4 的版本（Android 2.2.0 开发分支）留下（按版本号划分界则变红，审查 #1）；两边都有时按天取设备多的（11-26 PostHog 23 > 2，11-25 GA4 9 > 4）；相等取 PostHog；没有 src 的旧行按 GA4 算"
assert_eq "23" "$(printf '%s' "$_D_PR" | diag_pick d | jq '[.[]|select(.d=="2026-11-26" and .ver=="2.1.2")|.devices]|add')" \
  "⛔ 不两边相加（相加是 25）"
assert_eq "ga4" "$(printf '%s' '[{"h":"2026-11-26 03","plat":"IOS","ver":"2.1.2","src":"posthog","devices":1},{"h":"2026-11-26 23","plat":"IOS","ver":"2.1.2","devices":30}]' | diag_pick h | jq -r 'map(.src)|unique|join(" ")')" \
  "小时聚合按 MYT 日分桶：同一天不同小时一起比"

# ── diag_day_gaps ──（日级断数：某来源当天 0 行而前 7 天每天都有）
_D_GR="$(for k in 1 2 3 4 5 6 7; do d="$(date -j -v-"$k"d -f %Y-%m-%d 2026-11-26 +%Y-%m-%d)"; printf '{"d":"%s","src":"posthog"}\n{"d":"%s"}\n' "$d" "$d"; done | jq -sc '. + [{"d":"2026-11-26"}]')"
assert_eq "posthog@2026-11-26" "$(printf '%s' "$_D_GR" | diag_day_gaps '["2026-11-26"]')" "PostHog 当天 0 行、GA4 照常 → 只报 PostHog（两边合起来看就被 GA4 盖住，审查 #4）"
assert_eq "" "$(printf '%s' "$_D_GR" | jq -c 'del(.[0])' | diag_day_gaps '["2026-11-26"]')" "前 7 天只有 6 天有（刚放量）→ 不报"
assert_eq "" "$(printf '%s' "$_D_GR" | jq -c '. + [{"d":"2026-11-26","src":"posthog"}]' | diag_day_gaps '["2026-11-26"]')" "当天有行 → 不报"
