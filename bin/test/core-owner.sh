#!/usr/bin/env bash
# owner.sh 的断言（change crash-owner-mention）。
# 信号形态取自 2026-10-21 生产 crashlytics REALTIME 近 30 天实测（blame_frame / custom_keys.current_screen），
# 修复 subject 取自当日 fixmap。规则与负责人用仓库里的真实内容文件——改规则就该看到这里变红。

_O_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
_O_RULES="$(cat "$_O_ROOT/notes/module-rules.tsv")"
_O_OWN="$(cat "$_O_ROOT/notes/owners.tsv")"
_O_FM='{"62f88f3900a1313c994871bf51c65f81":{"subject":"fix(tts): 隔离停止等待并阻止超时引擎复用"}}'
_O_SIG='{
 "d3675e82000000000000000000000000":{"owner":"DEVELOPER","symbol":"com.prime.dino.english.core.ai.tts.micro.SsmlBuilder.<clinit>","file":"","library":"com.prime.dino.english","screen":"MainActivity"},
 "62f88f3900a1313c994871bf51c65f81":{"owner":"SYSTEM","symbol":"","file":"","library":"libMicrosoft.CognitiveServices.Speech.core.so","screen":"MainActivity"},
 "aaaaaaaa000000000000000000000000":{"owner":"SYSTEM","symbol":"","file":"","library":"libMicrosoft.CognitiveServices.Speech.core.so","screen":"MainActivity"},
 "18101022000000000000000000000000":{"owner":"SYSTEM","symbol":"","file":"","library":"libsystem_kernel.dylib","screen":"WelcomeLoginViewController"},
 "85c581edcdb39b941df627e7b1324a71":{"owner":"SYSTEM","symbol":"","file":"","library":"libc.so","screen":"MainActivity"},
 "8b297547000000000000000000000000":{"owner":"DEVELOPER","symbol":"com.prime.dino.english.feature.radio.lessonsong.ui.Hilt_LessonSongActivity","file":"","library":"com.prime.dino.english","screen":""},
 "bbbbbbbb000000000000000000000000":{"owner":"THIRD_PARTY","symbol":"com.prime.dino.english.feature.dinoclass.X","file":"","library":"com.prime.dino.english","screen":"MainActivity"}
}'
_O_ITEMS='[
 {"plat":"android","id":"85c581edcdb39b941df627e7b1324a71","fix_subject":"fix(ai): 对齐 MicroTTSHelper 安全 teardown","users":3},
 {"plat":"android","id":"d3675e82000000000000000000000000","users":6},
 {"plat":"android","id":"62f88f3900a1313c994871bf51c65f81","users":8},
 {"plat":"android","id":"aaaaaaaa000000000000000000000000","users":1},
 {"plat":"ios","id":"18101022000000000000000000000000","users":20},
 {"plat":"android","id":"8b297547000000000000000000000000","fix_subject":"fix(radio): 移除透明调度页的固定方向限制","users":1},
 {"plat":"android","id":"bbbbbbbb000000000000000000000000","users":2},
 {"plat":"android","id":"cccccccc000000000000000000000000","fix_subject":"fix(pay): x","users":1}
]'
_o_out="$(owner_attach "$_O_ITEMS" "$_O_FM" "$_O_SIG" "$_O_RULES" "$_O_OWN")"
_o() { printf '%s' "$_o_out" | jq -r --arg i "$1" '.[] | select(.id | startswith($i)) | "\(.owner_mod)/\(.owner_src)/\(.owner_id[0:11])/\(.owner_note)"'; }

assert_eq "voice/修复 scope/ou_5536eda7/" "$(_o 85c581ed)" "owner ① libc.so 修了仍在：fix(ai) scope → voice（scope 先于责任帧）"
assert_eq "voice/责任帧/ou_5536eda7/" "$(_o d3675e82)" "owner ② 自家帧 core.ai.tts → voice"
assert_eq "voice/修复 scope/ou_5536eda7/" "$(_o 62f88f39)" "owner ③ 条目无 subject 时取 fixmap 的 fix(tts)"
assert_eq "voice/SDK/ou_5536eda7/" "$(_o aaaaaaaa)" "owner ④ Azure 语音 SDK → voice（明显属于模块的 SDK 归模块）"
assert_eq "account/页面/ou_24e6a37a/" "$(_o 18101022)" "owner ⑤ iOS 登录页 → account（iOS 负责人）"
assert_eq "crash_fallback/兜底/ou_aa2ee8f8/" "$(_o 8b297547)" "owner ⑥ fix(radio) 未映射 + radio 帧未映射 → 兜底（⛔ 灰色项不猜）"
assert_eq "crash_fallback/兜底/ou_aa2ee8f8/" "$(_o bbbbbbbb)" "owner ⑦ ⛔ 非 DEVELOPER 帧不走 own；MainActivity 不命中任何 screen 规则"
assert_eq "pay/修复 scope/ou_07dfda34/" "$(_o cccccccc)" "owner ⑧ 无信号但有 fix(pay) → pay"

# ⛔ 第三方 SDK 帧不看页面（2026-10-21 回放订正）：4ade82c7 / ed3883b1 是 PAG 的 nativeFinalize（GC 回收线程），
#    崩时停在 CommonWebActivity 纯属巧合——按页面会 @ webview，而同一崩溃拆出的 29d4790c 落兜底，三条互相矛盾。
_O_PAG='{"4ade82c75524f5143fd8a00c357a733f":{"owner":"THIRD_PARTY","symbol":"org.libpag.PAGPlayer.nativeFinalize","file":"r8-map-id-eeec","library":"com.prime.dino.english","screen":"CommonWebActivity"}}'
# 2026-10-26 起 pag 单列（用户确认）：⑬ 由「兜底」改为 SDK 规则认领——仍不按页面归属
assert_eq "pag/SDK/ou_aa2ee8f8" \
  "$(owner_attach '[{"plat":"android","id":"4ade82c75524f5143fd8a00c357a733f"}]' '{}' "$_O_PAG" "$_O_RULES" "$_O_OWN" | jq -r '.[0] | "\(.owner_mod)/\(.owner_src)/\(.owner_id[0:11])"')" \
  "owner ⑬ ⛔ 第三方 SDK 帧不按页面归属（CommonWebActivity ≠ webview）；org.libpag 由 SDK 规则认领 → pag"
# PAG 的四种信号形态取自 2026-10-26 近 30 天实测（6 个 FATAL/ANR 全覆盖）
_O_PAG2='{
 "3fc8c6cb8eff4ce6cb72812126a5c839":{"owner":"THIRD_PARTY","symbol":"pag::PAGFont::~PAGFont()","file":"","library":"libpag","screen":""},
 "376127db3b207a4d7c3db322ed1ff79c":{"owner":"DEVELOPER","symbol":"@objc DinoPAGView.__ivar_destroyer","file":"DinoPAGView.swift","library":"dino-english-ios","screen":""},
 "0beff74d000000000000000000000000":{"owner":"THIRD_PARTY","symbol":"org.libpag.PAGPlayer.flushAndFenceSync","file":"Native method","library":"com.prime.dino.english","screen":"MainActivity"},
 "a4c03816000000000000000000000000":{"owner":"DEVELOPER","symbol":"-[FIRCLSNonFatalError initWithError:userInfo:rolloutsInfoJSON:]","file":"FIRCLSNonFatalError.m","library":"dino-english-ios","screen":""}
}'
_o_pag="$(owner_attach '[{"plat":"ios","id":"3fc8c6cb8eff4ce6cb72812126a5c839"},{"plat":"ios","id":"376127db3b207a4d7c3db322ed1ff79c"},
  {"plat":"android","id":"0beff74d000000000000000000000000"},{"plat":"ios","id":"a4c03816000000000000000000000000"},
  {"plat":"ios","id":"dddddddd000000000000000000000000","fix_subject":"fix(pag): 升级至 4.5.98 修复空纹理析构崩溃"}]' '{}' "$_O_PAG2" "$_O_RULES" "$_O_OWN" \
  | jq -r '[.[] | "\(.id[0:8]):\(.owner_mod)/\(.owner_src)/\(.owner_id[0:11])"] | join(" ")')"
assert_eq "3fc8c6cb:pag/SDK/ou_8ae48f5c 376127db:pag/责任帧/ou_8ae48f5c 0beff74d:pag/SDK/ou_aa2ee8f8 a4c03816:crash_fallback/兜底/ou_8ae48f5c dddddddd:pag/修复 scope/ou_8ae48f5c" \
  "$_o_pag" "owner ⑰ iOS libpag / 自家 DinoPAGView / Android org.libpag ANR / fix(pag) → pag；⛔ 标题碰巧含 pag 的 FIRCLSNonFatalError 不认领"

# 负责人解析：模块缺 → 平台兜底；连兜底都缺 → 不 @ 且必须标出来
_O_PF="$(printf 'platform_fallback\tand\tou_pf\n')"
assert_eq "voice/修复 scope/ou_pf/平台兜底" \
  "$(owner_attach "$_O_ITEMS" "$_O_FM" "$_O_SIG" "$_O_RULES" "$_O_PF" | jq -r '.[0] | "\(.owner_mod)/\(.owner_src)/\(.owner_id)/\(.owner_note)"')" \
  "owner ⑨ 模块负责人未配置 → platform_fallback 并标注"
assert_eq "//负责人未配置" \
  "$(owner_attach "$_O_ITEMS" "$_O_FM" "$_O_SIG" "$_O_RULES" "" | jq -r '.[0] | "\(.owner_id)//\(.owner_note)"')" \
  "owner ⑩ ⛔ 连兜底都没有 → owner_id 空且 note 可见，不得静默"
# 信号取数失败（{}）不得报错，只是全靠 scope / 兜底
assert_eq "voice/修复 scope" \
  "$(owner_attach "$_O_ITEMS" '{}' '{}' "$_O_RULES" "$_O_OWN" | jq -r '.[0] | "\(.owner_mod)/\(.owner_src)"')" \
  "owner ⑪ 信号与 fixmap 都为空时仍按条目自带 subject 判"

# 覆盖率：ios 20 台全归到模块；android 1+3+6+8+1 = 19 归到，1+2 = 3 兜底
assert_eq '{"ios":{"all":20,"hit":20},"android":{"all":22,"hit":19}}' "$(owner_coverage "$_o_out")" "owner ⑫ 覆盖率按台数"

# 覆盖率一行（10-21 影子跑实测形态：iOS 0/3 台 · Android 5/12 台）
_O_COV='{"ios":{"all":3,"hit":0},"android":{"all":12,"hit":5}}'
assert_eq "🧭 模块归属覆盖（近 7 天受影响设备）：iOS 0/3 台 · Android 5/12 台；⚠️ Android 过半归不到模块，建议在崩溃 custom keys 补模块 / 路由字段（Android 的 current_screen 现几乎恒为 MainActivity，分不出页面）" \
  "$(owner_coverage_line "$_O_COV" 10)" "owner ⑭ ⛔ iOS 只有 3 台 < 10 → 只给分数不给建议；Android 12 台照给"
assert_eq "🧭 模块归属覆盖（近 7 天受影响设备）：iOS 9/10 台 · Android 无受影响设备" \
  "$(owner_coverage_line '{"ios":{"all":10,"hit":9},"android":{"all":0,"hit":0}}' 10)" "owner ⑮ 覆盖过半不给建议；无设备一端写明"
assert_eq "" "$(owner_coverage_line '{"ios":{"all":0,"hit":0},"android":{"all":0,"hit":0}}' 10)" "owner ⑯ 两端都无设备 → 不出这一行"
