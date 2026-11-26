#!/usr/bin/env bash
# L1 卡片的 L0 停摆可见（change crash-tech-diagnostics）：抽 crash-daily.sh 里的接线段，在生产 shell 设置下逐状态跑。
# ⚠️ 只抽这一段（从 `DIAG_L0_LINE=""` 到它的 `fi`），不跑整份 L1——判定在 core 的 diag_l0_line，这里验接线与降级。
ROOT="${CRASH_REPORT_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}"
. "$ROOT/bin/test/harness.sh"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
awk '/^DIAG_L0_LINE=""/{f=1} f{print} f && /^\}\$\{DIAG_L0_LINE\}"; fi$/{exit}' "$ROOT/bin/crash-daily.sh" > "$T/snippet.sh"
h_assert_contains "$(cat "$T/snippet.sh")" 'diag_l0_line' "抽到接线段（抽空了说明 crash-daily.sh 的这一段被改过，夹具要跟着改）"

case_run() { # $1=状态 → stdout：跑完后的 CARD_NOTES；ERR trap 命中时带 __ERR__
  rm -f "$T/health-diag.json"
  case "$1" in
    fresh)  jq -n --arg t "$(date -v-50M +%Y%m%d-%H%M%S)" '{last_run:$t,ok:true}' > "$T/health-diag.json" ;;
    stale)  jq -n --arg t "$(date -v-5H +%Y%m%d-%H%M%S)" '{last_run:$t,ok:true}' > "$T/health-diag.json" ;;
    failed) jq -n --arg t "$(date -v-20M +%Y%m%d-%H%M%S)" '{last_run:$t,ok:false,error:"数据缺失：测试"}' > "$T/health-diag.json" ;;
    broken) echo 'not json' > "$T/health-diag.json" ;;
  esac
  /bin/bash -c 'set -euo pipefail; set -o errtrace; trap "echo __ERR__" ERR
    STATE="$1"; CARD_NOTES="原有备注"; . "$2/bin/lib/core/diag.sh"; . "$1/snippet.sh"; printf "%s" "$CARD_NOTES"' _ "$T" "$ROOT" 2>/dev/null
}
h_assert_eq "原有备注" "$(case_run absent)" "L0 未启用（无 health-diag.json）→ 卡片不变"
h_assert_eq "原有备注" "$(case_run fresh)" "50 分钟前成功 → 卡片不变"
h_assert_contains "$(case_run stale)" "已 5 小时没有运行" "超过 3 小时没跑 → 停摆一行"
h_assert_contains "$(case_run failed)" "最近一次失败：数据缺失：测试" "最近一次失败 → 失败一行"
h_assert_contains "$(case_run broken)" "health-diag.json 读不出或缺字段" "文件损坏 → 按失败报，不算出几十万小时"
for c in absent fresh stale failed broken; do
  h_assert_absent "$(case_run "$c")" "__ERR__" "⛔ ${c}：不触发 ERR trap"
done
h_summary
