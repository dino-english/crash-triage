#!/usr/bin/env bash
# 「已修待验」必须按 issue 的 OPEN/CLOSED 过滤（失效模式 R4）。
# ⛔ 事实层缓存「永久保留不清理」，2026-09-11 实测 24 条里 14 条已 CLOSED，
#    其中 6 条被报成「已修待验」——这个夹具钉住过滤逻辑本身。
set -uo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SELF_DIR/../.." && pwd)"
# shellcheck disable=SC1091
. "$SELF_DIR/harness.sh"

T="$(mktemp -d)"; mkdir -p "$T/issues"
mkfile() { printf '{"id":"%s","state":%s,"events":[]}\n' "$1" "$2" > "$T/issues/$1.json"; }
mkfile aaaaaaaa '"OPEN"'
mkfile bbbbbbbb '"CLOSED"'
mkfile cccccccc 'null'            # 同步失败/首轮：无 state
printf '{"mapped":{"aaaaaaaa":{"status":"已修待验"},"bbbbbbbb":{"status":"已修待验"},"cccccccc":{"status":"已修待验"},"dddddddd":{"status":"修了仍在"}}}\n' > "$T/fixmap.json"

# 与 crash-daily.sh 里同一段逻辑（⚠️ 这里是复制，不是抽取——它嵌在主流程里抽不出来，
# 所以额外加一条源码断言钉住两边不漂）
count=0
while IFS= read -r id; do
  [ -n "$id" ] || continue
  st="$(jq -r '.state // ""' "$T/issues/$id.json" 2>/dev/null || true)"
  if [ "$st" = "OPEN" ]; then count=$((count + 1)); fi
done < <(jq -r '(.mapped // {}) | to_entries[] | select(.value.status == "已修待验") | .key' "$T/fixmap.json")

h_assert_eq "1" "$count" "只数 OPEN 的（CLOSED 与无 state 都不计）"
h_assert_eq "CLOSED" "$(jq -r .state "$T/issues/bbbbbbbb.json")" "CLOSED 的记录仍留在缓存里（⛔ 不删——它是历史证据）"

echo "── 源码断言：主流程确实这么写 ──"
if grep -qF 'if [ "$_fp_state" = "OPEN" ]; then' "$ROOT/bin/crash-daily.sh"; then
  echo "  ✅ crash-daily.sh 按 state=OPEN 过滤"; H_PASS=$((H_PASS+1))
else
  echo "  ❌ crash-daily.sh 没按 state 过滤——CLOSED 的会被报成已修待验"; H_FAIL=$((H_FAIL+1))
fi
if grep -qF 'fetch-issue-states.py' "$ROOT/bin/crash-daily.sh"; then
  echo "  ✅ 跑批会同步 issue 状态"; H_PASS=$((H_PASS+1))
else
  echo "  ❌ 没有状态同步，state 字段永远是空的"; H_FAIL=$((H_FAIL+1))
fi
rm -rf "$T"
h_summary
