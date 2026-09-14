#!/usr/bin/env bash
# 台账时间线「追加了几行」必须是**实际条数**（2026-09-14 生产核验）。
#
# 起因：跑批日志报「✅ 台账变更时间线已追加（16 行）」，而飞书文档里实际是 15 条。
# 原因是 `wc -l` 把源文件的尾部换行也数了进去。数据本身没问题——一行没丢——
# ⛔ 但这行日志是「追加了几行」的**唯一判据**，差 1 会在下次排查时把人引向「丢了一行」。
#
# ⚠️ dry-run 与真实投递是**两个**打印点，口径必须一致：只改一处，等于下次用 DRY RUN
#    预演时看到的数字和真投递对不上（F35 那一类：同一个数有多个渲染点）。
set -uo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SELF_DIR/../.." && pwd)"
# shellcheck disable=SC1091
. "$SELF_DIR/harness.sh"

h_load "$ROOT/bin/deliver.sh" sync_ledger _lark_write_ok || { h_summary; exit 1; }

TMPD="$(mktemp -d)"
trap 'rm -rf "$TMPD"' EXIT
# 15 条内容行 + **一个尾部空行** → `wc -l` 数 16、`grep -c .` 数 15。
# ⛔ 那个空行不可省：少了它 `wc -l` 也是 15，夹具在旧代码下照样全绿——
#    2026-09-14 初版就是这么写的，双向测试时才发现它测了个寂寞（生产文件实测以 \n\n 收尾）。
: > "$TMPD/tl.md"
for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do
  printf -- '- 2026-09-14：🆕 [iOS] 新增 issue-%02d\n' "$i" >> "$TMPD/tl.md"
done
printf '\n' >> "$TMPD/tl.md"
printf '| a |\n|---|\n| b |\n' > "$TMPD/tbl.md"

LEDGER_HEADING_TEXT="Issue 现状表"; LEDGER_NF_HEADING_TEXT="NON_FATAL 现状表"
LARK_AS=bot
json_only() { cat; }   # deliver.sh 里的辅助函数，夹具里退化为直通（照抄 fn-lark-write-result.sh）
_ledger_heading_id() { printf 'HEAD_%s' "$2"; }
_ledger_replace_table() { echo "  ✅ 台账「$5」已同步（block_replace，block-id=stub）" >&2; return 0; }
LK=(_fake_lark)

echo "── ① dry-run 打印点 ──"
DRY_RUN=1
out="$( sync_ledger DOC "$TMPD/tbl.md" markdown "$TMPD/tl.md" markdown "" "" 2>&1 )"
h_assert_contains "$out" "append 时间线增量（15 行）" "⛔ 必须是实际条数 15"
h_assert_absent  "$out" "（16 行）" "⛔ 不得退回 wc -l（尾部换行多算 1）"

echo "── ② 真实投递打印点（零网络桩）──"
DRY_RUN=0
_fake_lark() { printf '{"ok":true,"data":{"result":"success"}}'; }
out="$( sync_ledger DOC "$TMPD/tbl.md" markdown "$TMPD/tl.md" markdown "" "" 2>&1 )"
# ⛔ 桩缺依赖时 _lark_write_ok 会靠 `|| echo success` 兜底返回 0——成功分支进对了、理由却是错的。
#    这条断言就是防止本夹具自己变成「答非所问」（2026-09-14 初版当场踩到）。
h_assert_absent "$out" "command not found" "⛔ 桩不得缺依赖，否则成功分支是靠兜底进的"
h_assert_contains "$out" "已追加（15 行）" "⛔ 两个打印点口径必须一致"
h_assert_absent  "$out" "（16 行）" "⛔ 不得退回 wc -l"

echo "── ③ 反向：未生效时不得走成功分支 ──"
_fake_lark() { printf '{"ok":true,"data":{"result":"failed"}}'; }
out="$( sync_ledger DOC "$TMPD/tbl.md" markdown "$TMPD/tl.md" markdown "" "" 2>&1 )"
h_assert_contains "$out" "时间线追加失败或未生效" "ok:true 但 result=failed → 判为未生效"
h_assert_absent  "$out" "已追加（" "⛔ 不得同时打出成功文案（否则 ② 的通过不说明成功分支真被把住）"

h_summary
