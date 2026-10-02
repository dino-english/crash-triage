#!/usr/bin/env bash
# deliver.sh 台账标题定位：「读取失败」与「读到了但没有标题」必须分开（F62）
#
# ⛔ 本夹具存在的理由：_ledger_heading_id 两次 docs +fetch 失败时都返回空，与「文档里确实没有
#    这个标题」不可区分；sync_ledger 拿到空 id 就走 bootstrap，把整份本地台账再 append 一遍——
#    一次短暂的读取故障 = 生产台账五段结构整份重复，日志还打 ✅。
# 2026-10-02 实测 lark-cli 的两种返回（判据由此而来）：
#    · 读到了但没有：rc=0 · ok:true · .data.document.content 是字符串（可为空串）
#    · 读取失败    ：rc=1 · ok:false · content 为 null
ROOT="${CRASH_REPORT_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}"
. "$ROOT/bin/test/harness.sh"
json_only() { cat; }   # deliver.sh 里的单行辅助函数 h_load 抽不了，退化为直通（照抄 fn-lark-write-result.sh）
h_load "$ROOT/bin/deliver.sh" _lark_write_ok _ledger_fingerprint _ledger_heading_id _ledger_replace_table sync_ledger

T="$(mktemp -d)"; CALLS="$T/calls"; N="$T/n"
LARK_AS=bot; DRY_RUN=0
LEDGER_HEADING_TEXT="Issue 现状表"; LEDGER_NF_HEADING_TEXT="NON_FATAL 现状表"
printf '| 平台 | Issue ID | 处置状态 |\n|---|---|---|\n| iOS | [aaaaaaaa](u) | 未处理 |\n' > "$T/table.md"
cp "$T/table.md" "$T/nf.md"; printf -- '- 2026-10-02：x\n' > "$T/tl.md"; printf '# 台账全文\n' > "$T/full.md"

# 假 lark-cli 写成**外部脚本**，与生产形态一致（生产的 lark-cli 是外部进程）。
# ⚠️ 写成 shell 函数时，失败发生在嵌套函数里，errtrace 下会在子 shell 里打出生产不会有的 ERR（实测踩过）。
# 按 scope 分派，记录每一次调用。FAKE_OUTLINE / FAKE_KEYWORD ∈ with | without | fail | null
#   FAKE_OUTLINE=with_then_fail：第 1 次 outline 正常（FATAL 标题），之后失败（NF 标题那次）
cat > "$T/fake-lk" <<'SH'
#!/bin/bash
echo "$*" >> "$CALLS"
ok()   { printf '{"ok":true,"data":{"document":{"content":%s}}}\n' "$(printf '%s' "$1" | jq -Rs .)"; exit 0; }
fail() { echo '{"ok":false,"error":{"message":"Invalid document_id or document not found."}}'; exit 1; }
case "$*" in
  *"--scope outline"*)
    n=$(( $(cat "$N" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$N"
    m="$FAKE_OUTLINE"; if [ "$m" = with_then_fail ]; then if [ "$n" -eq 1 ]; then m=with; else m=fail; fi; fi
    case "$m" in
      with)    ok '<h2 id="hF">Issue 现状表</h2><h2 id="hN">NON_FATAL 现状表</h2>';;
      without) ok '<h1 id="h0">别的文档</h1>';;
      null)    echo '{"ok":true,"data":{}}'; exit 0;;
      *)       fail;; esac;;
  *"--scope keyword"*)
    case "$FAKE_KEYWORD" in without) ok '';; null) echo '{"ok":true,"data":{}}'; exit 0;; *) fail;; esac;;
  *"--scope section"*) ok '<table id="tbl1">';;
  *"--scope range"*)   ok "$(cat "$TABLE")";;
  *"+update"*)         echo '{"ok":true,"data":{"result":"success"}}';;
  *) fail;; esac
SH
chmod +x "$T/fake-lk"; export CALLS N TABLE="$T/table.md"
LK=("$T/fake-lk")
reset() { : > "$CALLS"; rm -f "$N"; export FAKE_OUTLINE="$1" FAKE_KEYWORD="${2:-without}"; }

echo "── _ledger_heading_id 的三态返回 ──"
reset with;              h_assert_eq "hF" "$(_ledger_heading_id d "Issue 现状表" || true)" "① 读到且有标题 → 输出 block id"
reset with;              h_assert_rc 0 _ledger_heading_id d "Issue 现状表"
reset without without;   h_assert_rc 1 _ledger_heading_id d "Issue 现状表"
                         echo "     ↑ ② 两次都读到、确实没有 → rc=1（允许 bootstrap）"
reset fail;              h_assert_rc 2 _ledger_heading_id d "Issue 现状表"
                         echo "     ↑ ③ outline 读取失败 → rc=2（⛔ 旧实现返回空 = 当成没有）"
reset without fail;      h_assert_rc 2 _ledger_heading_id d "Issue 现状表"
                         echo "     ↑ ④ outline 读到没有、keyword 读取失败 → rc=2（不能据此断定没有）"
reset null;              h_assert_rc 2 _ledger_heading_id d "Issue 现状表"
                         echo "     ↑ ⑤ rc=0 但没有 content 字段 → rc=2"

echo "── sync_ledger：读取失败必须中止，⛔ 不得 bootstrap ──"
reset fail
h_assert_rc 1 sync_ledger d "$T/table.md" markdown "$T/tl.md" markdown "$T/full.md" "$T/nf.md"
h_assert_absent "$(cat "$CALLS")" "--command append" "⑥ ⛔ 读取失败时一次 append 都不许发（旧实现会把全文再 append 一遍）"
err="$( { sync_ledger d "$T/table.md" markdown "$T/tl.md" markdown "$T/full.md" "$T/nf.md" || true; } 2>&1 >/dev/null )"
h_assert_contains "$err" "读取失败" "⑦ 日志点名是读取失败，不是「标题不存在」"

echo "── 回归：真的没有标题时 bootstrap 照常（生产 shell 设置下不得踩 ERR）──"
reset without without
out="$(h_run sync_ledger d "$T/table.md" markdown "$T/tl.md" markdown "$T/full.md" "$T/nf.md" 2>&1)"
h_assert_contains "$(cat "$CALLS")" "--command append" "⑧ 真没有标题 → 仍走 bootstrap append（首次建台账不得被误拦）"
h_assert_contains "$out" "台账新结构已 append 建立" "⑨ bootstrap 成功日志照旧"

echo "── NON_FATAL 标题读取失败：只跳过这张表，FATAL 与时间线照常 ──"
reset with_then_fail
out="$(h_run sync_ledger d "$T/table.md" markdown "$T/tl.md" markdown "$T/full.md" "$T/nf.md" 2>&1)"
h_assert_contains "$out" "NON_FATAL 现状表」标题读取失败" "⑩ NF 标题读取失败 → 明说是读取失败（不是「尚不存在」）"
h_assert_contains "$out" "时间线已追加" "⑪ 时间线照常追加"
h_assert_absent  "$(grep -- '--command append' "$CALLS" | grep -v 'tl.md' || true)" "append" "⑫ ⛔ 除时间线外不得有 append（不得 bootstrap 全文）"
rm -rf "$T"
h_summary
