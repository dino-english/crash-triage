#!/usr/bin/env bash
# ⛔ ok:true ≠ 操作生效：deliver.sh 的写操作必须判 data.result
ROOT="${CRASH_REPORT_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}"
. "$ROOT/bin/test/harness.sh"
json_only() { cat; }          # deliver.sh 里的辅助函数，夹具里退化为直通
h_load "$ROOT/bin/deliver.sh" _lark_write_ok

ok='{"ok":true,"data":{"result":"success"}}'
degraded='{"ok":true,"data":{"result":"failed","warnings":["degrade_code=1011,msg=Instruction produced no document changes."]}}'
nores='{"ok":true,"data":{"revision_id":9}}'

# ⚠️ 用**生产的调用形态**（条件位）——裸调会触发 ERR trap，而生产里两处都是 `if ! f` / `f && …`
probe() { if _lark_write_ok "$1"; then printf 0; else printf 1; fi; }
r="$(h_run probe "$ok")"
h_assert_eq "0" "$r" "① result=success → 判为生效"
r="$(h_run probe "$degraded")"
h_assert_eq "1" "$r" "② ⛔ ok:true 但 result=failed → 必须判为未生效（此前被打成 ✅）"
r="$(h_run probe "$nores")"
h_assert_eq "0" "$r" "③ 无 result 字段（老版本 CLI）→ 保守判为生效，不误报"
r="$(h_run probe "这不是 JSON")"
h_assert_eq "0" "$r" "④ 非 JSON 输出 → 不崩、保守判为生效"
h_assert_eq "0" "$(h_run probe "$ok")" "⑤ 条件位调用不触发 ERR trap（生产形态）"
echo "── ⛔ 不变式：每个写操作调用点都必须判 result（F41 / F1）──"
# 2026-09-22 实测：`sync_ledger` 的 bootstrap 分支与 `overwrite_doc` 都只判退出码、
# 还把输出丢进 /dev/null，而身份无权限时飞书返回 ok:true / rc=0 / result:"failed"——
# 于是「✅ 台账新结构已 append 建立」「♻️ 原地覆盖」照打，文档 revision 一动没动。
# ⚠️ 同文件里 `_ledger_replace_table` 与时间线 append **一直是对的**：
#    同一目的的多份实现，只修了其中一份（F1），而 lint 抓不到改了名的重复。
_d="$ROOT/bin/deliver.sh"
_miss=0; _n=0
while IFS=: read -r _ln _; do
  _n=$((_n+1))
  sed -n "$((_ln-2)),$((_ln+14))p" "$_d" | grep -q '_lark_write_ok' || {
    echo "  ❌ deliver.sh:$_ln 的写操作没判 result"; _miss=1; }
done < <(grep -n 'docs +update --command' "$_d" | grep -v 'dry-run')
if [ "$_miss" = 0 ]; then
  echo "  ✅ $_n 个写操作调用点全部判了 result"; H_PASS=$((H_PASS+1))
else
  H_FAIL=$((H_FAIL+1))
fi

h_summary
