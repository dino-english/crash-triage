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
h_summary
