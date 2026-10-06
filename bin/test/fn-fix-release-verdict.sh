#!/usr/bin/env bash
# 修复发版四态判定（change crash-fix-release-status，bin/lib/core/fixrelease.sh）。
#
# 用例取自 2026-10-06 生产实测（fixmap 19 条 + fix-release-builds.sql 真实返回），⚠️ 数值保持字符串——
# bq 的 json 输出就是字符串，判定层必须吃得下。每条都写明它防的是哪种说反。
set -uo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SELF_DIR/../.." && pwd)"
# shellcheck disable=SC1091
. "$SELF_DIR/harness.sh"
# shellcheck disable=SC1091
. "$ROOT/bin/lib/core/fixrelease.sh"

v() { h_run fix_release_verdict "$1" "$2" "$3"; }
st() { jq -r '"\(.status) old=\(.old_build_events) new=\(.new_build_events)"' <<<"$1"; }

echo "── Android：修复还没发版，崩溃全在旧包上（8bc4b97e）──"
# 修复 10-05 06:57 UTC 只在 dev/feature/1.8.2；崩溃在 09-30 首现的 182010
out="$(v '{"platform":"android","commit_epoch":1791183447,"release_ref":null,"fixed_in_version":null}' \
         '[{"build":"182010","version":"1.8.2","first_seen":"1759224000","perf_on":"0","events":"1"}]' '[]')"
h_assert_eq "已修未发版 old=1 new=0" "$(st "$out")" "⛔ 旧规则报「修了仍在」——修复根本没上线"

echo "── Android：已发版，新包 0 次，旧包还在崩（8b297547）──"
out="$(v '{"platform":"android","commit_epoch":1790581208,"release_ref":"V1.8.2","fixed_in_version":"1.8.2"}' \
         '[{"build":"181001","version":"1.8.1","first_seen":"1758547560","perf_on":"0","events":"2"}]' '[]')"
h_assert_eq "已发版待验 old=2 new=0" "$(st "$out")" "⛔ 旧规则报「修了仍在」——修复已随 1.8.2 发出且有效"

echo "── Android：与修复同日上线、但不含修复的版本（62f88f39）──"
# 修复 09-15 02:23 UTC；1.7.1（171002）09-15 09:23 首现——只比时间会当成含修复，tag 说要到 1.8.0
out="$(v '{"platform":"android","commit_epoch":1789438980,"release_ref":"V1.8.0","fixed_in_version":"1.8.0"}' \
         '[{"build":"171002","version":"1.7.1","first_seen":"1789464180","perf_on":"0","events":"11"},
           {"build":"181001","version":"1.8.1","first_seen":"1790083560","perf_on":"0","events":"4"}]' '[]')"
h_assert_eq "修了仍在 old=11 new=4" "$(st "$out")" "1.7.1 计旧包（版本 < 1.8.0），1.8.1 计含修复"

echo "── Android：同版本号、但首现早于修复的包不算含修复 ──"
# fixed_in=1.8.2，182006 是 1.8.2 的内部包但在修复之前就出现了
out="$(v '{"platform":"android","commit_epoch":1790581208,"release_ref":"V1.8.2","fixed_in_version":"1.8.2"}' \
         '[{"build":"182006","version":"1.8.2","first_seen":"1790500000","perf_on":"0","events":"3"}]' '[]')"
h_assert_eq "已发版待验 old=3 new=0" "$(st "$out")" "⛔ 版本号够但首现早于提交 → 不可能含修复"

echo "── Android：进了 main 但没有 tag → 退回「首现晚于提交」──"
fixmain='{"platform":"android","commit_epoch":1000,"release_ref":"main","fixed_in_version":null}'
h_assert_eq "修了仍在 old=0 new=5" "$(st "$(v "$fixmain" '[{"build":"190001","version":"1.9.0","first_seen":"2000","perf_on":"0","events":"5"}]' '[]')")" \
  "首现晚于提交的包上有事件 → 修了仍在"
h_assert_eq "已发版待验 old=5 new=0" "$(st "$(v "$fixmain" '[{"build":"182010","version":"1.8.2","first_seen":"500","perf_on":"0","events":"5"}]' '[]')")" \
  "首现早于提交 → 旧包；进了 main 即已上线"

echo "── Android：已发版、修复后 0 事件 ──"
h_assert_eq "已发版待验 old=0 new=0" \
  "$(st "$(v '{"platform":"android","commit_epoch":1,"release_ref":"V1.8.0","fixed_in_version":"1.8.0"}' '[]' '[]')")" \
  "无事件 + 已上线 → 已发版待验"

echo "── iOS：修复后还没有新上架包（09ee5ad3）──"
rel='[{"build":"1.7.1.2","version":"1.7.1","first_seen":"1757941500","perf_on":"2790"}]'
h_assert_eq "已修未发版 old=0 new=0" \
  "$(st "$(v '{"platform":"ios","commit_epoch":1791182515}' '[]' "$rel")")" \
  "⛔ 没事件不等于已上线——旧规则报「已修待验」"

echo "── iOS：内部包上的崩溃不改判（c3184f91 先例）──"
fixi='{"platform":"ios","commit_epoch":1000}'
relafter='[{"build":"1.8.0.48","version":"1.8.0","first_seen":"5000","perf_on":"900"}]'
out="$(v "$fixi" '[{"build":"1.8.0.30","version":"1.8.0","first_seen":"3000","perf_on":"0","events":"10"}]' "$relafter")"
h_assert_eq "已发版待验 old=10 new=0" "$(st "$out")" "⛔ 内测包（采集关）首现晚于提交也不算含修复"

echo "── iOS：上架包上仍在崩 ──"
out="$(v "$fixi" '[{"build":"1.8.0.48","version":"1.8.0","first_seen":"5000","perf_on":"900","events":"3"}]' "$relafter")"
h_assert_eq "修了仍在 old=0 new=3" "$(st "$out")" "首现晚于提交的上架包上有事件"

echo "── iOS：⛔ 上架包首现早于提交 → 不含修复，也不算已上线 ──"
out="$(v "$fixi" '[{"build":"1.7.1.2","version":"1.7.1","first_seen":"500","perf_on":"2790","events":"4"}]' \
         '[{"build":"1.7.1.2","version":"1.7.1","first_seen":"500","perf_on":"2790"}]')"
h_assert_eq "已修未发版 old=4 new=0" "$(st "$out")" "提交之前的上架包不可能含修复"

echo "── 版本号按数字比较 ──"
out="$(v '{"platform":"android","commit_epoch":1,"release_ref":"V1.9.0","fixed_in_version":"1.9.0"}' \
         '[{"build":"1100001","version":"1.10.0","first_seen":"2","perf_on":"0","events":"1"}]' '[]')"
h_assert_eq "修了仍在 old=0 new=1" "$(st "$out")" "⛔ 1.10.0 ≥ 1.9.0（字符串比较会判反）"

h_summary
