#!/usr/bin/env bash
# owner_enrich（bin/lib/owner.sh）在**生产 shell 设置**下的行为（change crash-owner-mention）。
# ⛔ 本函数在 L1 / L2 主流程里跑：bq 失败、内容文件缺失都**不得**触发 ERR trap（= 发假告警卡），
#    也不得让条目丢失——@ 是附加信息。
ROOT="${CRASH_REPORT_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}"
. "$ROOT/bin/test/harness.sh"
SQL_DIR="$ROOT/bin/sql"
. "$ROOT/bin/lib/query.sh"
. "$ROOT/bin/lib/core/owner.sh"
. "$ROOT/bin/lib/owner.sh"

ITEMS='[{"plat":"android","id":"d3675e8284504c27f6b53d3205a45c32","users":6},
        {"plat":"android","id":"85c581edcdb39b941df627e7b1324a71","fix_subject":"fix(ai): 对齐 MicroTTSHelper","users":3},
        {"plat":"ios","id":"18101022aaaabbbbccccddddeeeeffff","users":20}]'
# 假 bqq：按表名回不同的行（形态取自 2026-10-21 生产实跑 crash-issue-owner-signals.sql）
bqq() {
  case "$2" in
    *ANDROID*) printf '%s' '[{"issue_id":"d3675e8284504c27f6b53d3205a45c32","owner":"DEVELOPER","symbol":"com.prime.dino.english.core.ai.tts.micro.SsmlBuilder.<clinit>","file":"SsmlBuilder.kt","library":"com.prime.dino.english","screen":"MainActivity"}]';;
    *IOS*)     printf '%s' '[{"issue_id":"18101022aaaabbbbccccddddeeeeffff","owner":null,"symbol":null,"file":null,"library":null,"screen":"WelcomeLoginViewController"}]';;
  esac
}
out="$(h_run owner_enrich "$ITEMS" '{}' "p.firebase_crashlytics.x_IOS_REALTIME" "p.firebase_crashlytics.x_ANDROID_REALTIME")"
h_assert_eq "voice/责任帧 voice/修复 scope account/页面" \
  "$(printf '%s' "$out" | jq -r '[.[] | "\(.owner_mod)/\(.owner_src)"] | join(" ")')" \
  "① 两端信号各自取到：自家帧 / scope / iOS 页面"

# bq 失败：⛔ 不得触发 ERR trap，条目不丢，只剩 scope 与兜底可判
bqq() { return 1; }
out="$(h_run owner_enrich "$ITEMS" '{}' "p.x_IOS_REALTIME" "p.x_ANDROID_REALTIME")"
h_assert_eq "crash_fallback voice crash_fallback" "$(printf '%s' "$out" | jq -r '[.[].owner_mod] | join(" ")')" \
  "② bq 失败 → 条目照出，无信号的落兜底（⛔ 不得发告警卡）"

# 表名为空（该端表不存在）：跳过该端取数，不报错
out="$(h_run owner_enrich "$ITEMS" '{}' "" "")"
h_assert_eq "3" "$(printf '%s' "$out" | jq 'length')" "③ 两端表都缺 → 条目数不变"

# 内容文件缺失：owner_attach 拿到空规则 → 全兜底且负责人未配置；⛔ 条目不丢、不报错
_root_bak="$ROOT"; ROOT="/nonexistent"
out="$(h_run owner_enrich "$ITEMS" '{}' "" "")"
ROOT="$_root_bak"
h_assert_eq "负责人未配置" "$(printf '%s' "$out" | jq -r '.[0].owner_note')" "④ notes/ 缺失 → 标「负责人未配置」，不静默"

h_summary "owner_enrich"
