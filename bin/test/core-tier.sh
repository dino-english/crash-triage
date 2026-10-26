#!/usr/bin/env bash
# tier.sh 的断言（change crash-report-attention-tiers）。
# 期望值取自 2026-10-11 生产日报 + 当日 fixmap（runs/2026-10-11/L1/latest/fixmap.json），
# 设计时逐条人工核过：只有 85c581ed 该进紧急档。

_T_ISS='[
 {"plat":"ios","id":"3c8c9ac83ccceff5bf029f7d0d95f78a","title":"[vImage] vConvert","users":1,"by_ver":"1.8.2 1 台","life":"🆕新增"},
 {"plat":"android","id":"8bc4b97e887ce32a7fada8b4fd2abc29","title":"LineApiClientBuilder","users":10,"by_ver":"1.8.2 10 台","life":"长期"},
 {"plat":"android","id":"a086ba799cf74a0238d7fb7f800b3cc0","title":"[libperfetto_hprof.so]","users":3,"by_ver":"1.8.2 3 台","life":"长期"},
 {"plat":"android","id":"af63b03d3def6cf9f5af2c6a6a019e63","title":"[libart.so]","users":2,"by_ver":"1.8.2 2 台","life":"长期"},
 {"plat":"android","id":"85c581edcdb39b941df627e7b1324a71","title":"[libc.so]","users":2,"by_ver":"1.8.2 1 台 · 1.8.1 1 台","life":"长期"}
]'
_T_FM='{"mapped":{
 "85c581edcdb39b941df627e7b1324a71":{"platform":"android","status":"修了仍在","release_check":"ok","commit":"9bbe8b15","fixed_in_version":"1.5.4","subject":"fix(ai): 对齐 MicroTTSHelper 安全 teardown\n\n正文不该进卡片"},
 "62f88f3900a1313c994871bf51c65f81":{"platform":"android","status":"修了仍在","release_check":"ok","commit":"e8f9b936","fixed_in_version":"1.8.0","subject":"fix(tts)"},
 "4d05f9e74e77520b418eac3a355108f1":{"platform":"android","status":"修了仍在","release_check":"ok","commit":"328af7a9","fixed_in_version":"1.8.0","subject":"fix(account)"},
 "8bc4b97e887ce32a7fada8b4fd2abc29":{"platform":"android","status":"已修未发版","release_check":"ok","commit":"aaaa1111","subject":"fix(app): 移除未使用的 LINE Open Chat 崩溃入口"},
 "8b297547b9f21c0b1809e8c8989edb06":{"platform":"android","status":"已修未发版","release_check":"ok","commit":"96738df6","subject":"fix(radio)"},
 "09ee5ad371c6c16acf0388f898f1839f":{"platform":"ios","status":"已修未发版","release_check":"ok","commit":"5b0dec2f","subject":"fix(asr)"},
 "2a800b339e12b94bc2d4555c63859df8":{"platform":"ios","status":"已发版待验","release_check":"ok","commit":"29a20dc5","subject":"fix(paywall)"}
}}'
_T_ST='{"3c8c9ac83ccceff5bf029f7d0d95f78a":"OPEN","8bc4b97e887ce32a7fada8b4fd2abc29":"OPEN","a086ba799cf74a0238d7fb7f800b3cc0":"OPEN",
 "af63b03d3def6cf9f5af2c6a6a019e63":"OPEN","85c581edcdb39b941df627e7b1324a71":"OPEN","62f88f3900a1313c994871bf51c65f81":"OPEN",
 "4d05f9e74e77520b418eac3a355108f1":"OPEN","8b297547b9f21c0b1809e8c8989edb06":"OPEN","09ee5ad371c6c16acf0388f898f1839f":"CLOSED",
 "2a800b339e12b94bc2d4555c63859df8":"OPEN"}'

_t_out="$(tier_classify "$_T_ISS" "$_T_FM" "$_T_ST" 2 5)"
_t_ids() { printf '%s' "$_t_out" | jq -r --arg t "$1" '[.[] | select(.tier==$t) | .id[0:8]] | join(" ")'; }

assert_eq "85c581ed" "$(_t_ids urgent)" \
  "10-11 只有 85c581ed 进紧急（修了仍在 + 7 天 2 台）；62f88f39/4d05f9e7 修了仍在但本窗口 0 台 → 不进"
assert_eq "8bc4b97e 8b297547" "$(_t_ids release)" \
  "等发版：8bc4b97e（10 台）排第一；无事件的 8b297547 也列出；CLOSED 的 09ee5ad3 不列（与 FIXED_PENDING 只数 OPEN 同判定）"
assert_eq "a086ba79 af63b03d 3c8c9ac8" "$(_t_ids watch)" \
  "观察：长期 3 台 / 2 台 < 5；新增 1 台 < 2；同档按台数降序"
assert_eq "1	2	3" "$(tier_counts "$_t_out")" "tier_counts 三档计数"
assert_eq "修了仍在：修复 9bbe8b15 已随 1.5.4 发版，新包仍崩" \
  "$(printf '%s' "$_t_out" | jq -r '.[] | select(.id[0:8]=="85c581ed") | .why')" "修了仍在的理由带提交与发版"
assert_eq "fix(ai): 对齐 MicroTTSHelper 安全 teardown" \
  "$(printf '%s' "$_t_out" | jq -r '.[] | select(.id[0:8]=="85c581ed") | .fix_subject')" \
  "修复提交只取 subject 首行（周报曾把整段正文贴进卡片）"

# 阈值边界：新增 2 台恰好达标；长期 5 台恰好达标
_t_b="$(tier_classify '[{"plat":"ios","id":"11111111111111111111111111111111","users":2,"life":"🆕新增"},
  {"plat":"ios","id":"22222222222222222222222222222222","users":5,"life":"长期"},
  {"plat":"ios","id":"33333333333333333333333333333333","users":3,"life":"🔁回归"}]' '{}' '{}' 2 5)"
assert_eq "22222222 33333333 11111111" "$(printf '%s' "$_t_b" | jq -r '[.[]|select(.tier=="urgent")|.id[0:8]]|join(" ")')" \
  "阈值是「大于等于」：新增 2 台、长期 5 台、回归 3 台都进紧急（同档按台数降序）"
assert_eq "回归（曾消失又重现） · 未修复 · 7 天 3 台" \
  "$(printf '%s' "$_t_b" | jq -r '.[]|select(.id[0:8]=="33333333")|.why')" "回归理由"

# 发版判定不可得：不依据修复状态判档，也不能说「未修复」
_t_u="$(tier_classify '[{"plat":"android","id":"44444444444444444444444444444444","users":6,"life":"长期"},
  {"plat":"android","id":"55555555555555555555555555555555","users":3,"life":"长期"}]' \
  '{"mapped":{"44444444444444444444444444444444":{"status":"修了仍在","release_check":"unavailable"},
              "55555555555555555555555555555555":{"status":"已修未发版","release_check":"unavailable"}}}' '{}' 2 5)"
assert_eq "长期 · 修复发版判定不可得 · 7 天 6 台" \
  "$(printf '%s' "$_t_u" | jq -r '.[]|select(.id[0:8]=="44444444")|.why')" \
  "判定不可得：按台数进紧急，但理由不说「修了仍在」也不说「未修复」"
assert_eq "watch" "$(printf '%s' "$_t_u" | jq -r '.[]|select(.id[0:8]=="55555555")|.tier')" \
  "判定不可得的「已修未发版」不进等发版（spec：不得退回只比时间）"

# 静音：人做过的处置决定，台数再多也只进观察
assert_eq "watch" "$(tier_classify '[{"plat":"android","id":"66666666666666666666666666666666","users":9,"life":"🆕新增"}]' '{}' \
  '{"66666666666666666666666666666666":"MUTED"}' 2 5 | jq -r '.[0].tier')" "MUTED → 观察"

# 反扫整个不可用（fixmap 为 {}）：仍能按台数判，不报错
assert_eq "urgent" "$(tier_classify '[{"plat":"ios","id":"77777777777777777777777777777777","users":5,"life":""}]' '{}' '{}' 2 5 | jq -r '.[0].tier')" \
  "fixmap 为空 + 基线轮（life 空）：按长期门槛判"

# perf_regressed
assert_eq "1" "$(perf_regressed 2400 1900 1500 20)" "P95 2400 vs 1900（+26%，已过黄档）→ 退化"
assert_eq ""  "$(perf_regressed 2231 2369 1500 20)" "10-11 Android 1.8.2 比 1.8.1 快 → 不退化"
assert_eq ""  "$(perf_regressed 0.02 0.01 0.5 20)"  "冻结 0.01→0.02（+100% 但未到黄档）→ 不算"
assert_eq ""  "$(perf_regressed '' 1900 1500 20)"   "一侧缺值 → 不判"

# os_label
assert_eq "Android 12" "$(os_label and 31)" "API 31 → Android 12"
assert_eq "API 40"     "$(os_label and 40)" "映射表外原样给 API n"
assert_eq "iOS 26"     "$(os_label ios 26)" "iOS 主版本"

# startup_drill_summary：2026-10-11 实查 Android 1.8.2（10-05~07）
_t_csv='37	5	255.0	0
36	448	1179.0	7
35	214	1355.0	5
34	175	2330.0	14
33	211	1719.0	10
32	1	628.0	0
31	66	2431.0	8
30	44	2050.0	4
29	45	5787.0	14
28	6	3656.0	3
27	10	7172.0	9'
assert_eq "34 31 30 29	27	54	40	74" "$(startup_drill_summary "$_t_csv" 2000 20)" \
  "拖后腿的桶 = 样本≥20 且 P95>红线；27/28 样本不足不列名但慢启动计入分母"
assert_eq "" "$(startup_drill_summary "$(printf '36\t448\t1179.0\t7')" 2000 20)" "没有超红线的桶 → 空（只出图不出结论）"

# 周报的暴涨与新增、回归同一门槛
assert_eq "暴涨 · 未修复 · 7 天 2 台" "$(tier_classify '[{"plat":"android","id":"88888888888888888888888888888888","users":2,"life":"📈暴涨"}]' '{}' '{}' 2 5 | jq -r '.[0].why')" \
  "暴涨 ≥2 台进紧急"

# priorities_validate（design D2）
_t_ids='["8bc4b97e887ce32a7fada8b4fd2abc29","181010225a8f7695edf124ff32b9c406"]'
assert_eq "false|priorities.json 缺失" "$(priorities_validate '' "$_t_ids" "$_t_ids" | jq -r '"\(.ok)|\(.reason)"')" "文件缺失 → 回落"
assert_eq "false|priorities.json 不是合法 JSON" "$(priorities_validate '[{"issue_id":' "$_t_ids" "$_t_ids" | jq -r '"\(.ok)|\(.reason)"')" "非法 JSON → 回落"
assert_eq "false|priorities.json 顶层不是数组" "$(priorities_validate '{"a":1}' "$_t_ids" "$_t_ids" | jq -r '"\(.ok)|\(.reason)"')" "顶层不是数组 → 回落"
_t_p='[{"issue_id":"181010225A8F7695EDF124FF32B9C406","platform":"iOS","priority":"p0","action":"先取符号化样本","why":"影响量最高"},
 {"issue_id":"8bc4b97e887ce32a7fada8b4fd2abc29","platform":"android","priority":"P1","action":"入口校验 Channel ID","why":"启动即崩"},
 {"issue_id":"ffffffffffffffffffffffffffffffff","platform":"android","priority":"P0","action":"x","why":"模型编造的 id"},
 {"issue_id":"8bc4b97e","platform":"android","priority":"P0","action":"短 id 不收","why":""},
 {"issue_id":"8bc4b97e887ce32a7fada8b4fd2abc29","platform":"android","priority":"P9","action":"","why":"非法优先级"}]'
_t_pv="$(priorities_validate "$_t_p" "$_t_ids" "$_t_ids")"
assert_eq "true|3|181010225a8f7695edf124ff32b9c406:P0:ios 8bc4b97e887ce32a7fada8b4fd2abc29:P1:android" \
  "$(printf '%s' "$_t_pv" | jq -r '"\(.ok)|\(.dropped)|" + ([.items[] | "\(.id):\(.priority):\(.plat)"] | join(" "))')" \
  "大小写归一；快照外 id / 短 id / 非法优先级逐条剔除不作废整份；按 P0→P1 排序"
assert_eq "true|0|0" "$(priorities_validate '[]' "$_t_ids" "$_t_ids" | jq -r '"\(.ok)|\(.dropped)|\(.items | length)"')" \
  "空数组合法（是否回落由调用方按「快照非空」判）"
# 窗口约束（change crash-priorities-window-gate）：P0/P1 只认数据层快照；只在分析层快照里的降 P2 进 👀
# 形态取自 2026-10-26 周报：29d4790c 末次事件 10-18 03:15 UTC，早于数据层窗口起点 10-18 21:40 UTC
_t_win='["8bc4b97e887ce32a7fada8b4fd2abc29"]'
_t_ids2='["8bc4b97e887ce32a7fada8b4fd2abc29","29d4790cd79b65c503b166bc99d0b3db","04deebf6aaaaaaaaaaaaaaaaaaaaaaaa"]'
_t_p2='[{"issue_id":"29d4790cd79b65c503b166bc99d0b3db","platform":"android","priority":"P1","action":"定位 PAG 所有权","why":"PAG finalizer超时"},
 {"issue_id":"8bc4b97e887ce32a7fada8b4fd2abc29","platform":"android","priority":"P0","action":"入口校验","why":"启动即崩"},
 {"issue_id":"04deebf6aaaaaaaaaaaaaaaaaaaaaaaa","platform":"ios","priority":"P2","action":"","why":"旧包单例"}]'
assert_eq "true|0|1|8bc4b97e:P0:启动即崩 29d4790c:P2:本周窗口内无事件 · 原判 P1 04deebf6:P2:旧包单例" \
  "$(priorities_validate "$_t_p2" "$_t_ids2" "$_t_win" | jq -r '"\(.ok)|\(.dropped)|\(.demoted)|" + ([.items[] | "\(.id[0:8]):\(.priority):\(.why)"] | join(" "))')" \
  "窗口外 P1 → P2 且改写理由、不计 dropped；窗内 P0 不动；P2 本就不在窗内也不算降级"
assert_eq "0" "$(priorities_validate "$_t_p2" "$_t_ids2" "$_t_ids2" | jq -r '.demoted')" \
  "全在窗内 → 不降级"
