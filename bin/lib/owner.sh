#!/usr/bin/env bash
# 外壳层——崩溃负责人 @（change crash-owner-mention）：取信号、读内容文件，判定交给 core/owner.sh。
#
# 依赖（调用方先 source）：bin/lib/bq.sh（bqq）、bin/lib/query.sh（q_render）、bin/lib/core/owner.sh；
#   全局只读 ${ROOT}（找 notes/）。L1 / L2 共用，⛔ 不要在两个脚本里各写一份（F1）。
#
# ⛔ 任何一步失败都**原样返回条目**、不中断跑批：@ 是附加信息，不该让日报因它整跑失败。
#    但条目上不会有 owner_* 字段——渲染侧据此不出 @，⛔ 不得伪造兜底人。
# ⚠️ bq 失败必须在命令替换**内部**接住（`|| true`）：生产开着 errtrace，替换里最后一条命令失败
#    会先触发 ERR trap（= 发假告警卡），外层的 `||` 来不及兜（失效模式登记 F46 同类）。

# owner_enrich：$1=条目 JSON（含 plat/id）$2=fixmap 的 mapped JSON（可空）$3=iOS crash 表 $4=Android crash 表
#   → 补了 owner_mod/owner_src/owner_id/owner_note 的条目 JSON
owner_enrich() {
  local items="$1" fm="${2:-}" sig='{}' p tbl ids rows out
  [ -n "$fm" ] || fm='{}'
  for p in ios android; do
    tbl="$3"; [ "$p" = android ] && tbl="$4"
    [ -n "$tbl" ] || continue
    ids="$(printf '%s' "$items" | jq -r --arg p "$p" \
      '[.[] | select(.plat == $p) | .id | select(test("^[0-9a-f]{32}$")) | "\"" + . + "\""] | unique | join(",")' 2>/dev/null || true)"
    [ -n "$ids" ] || continue
    rows="$(bqq json "$(q_render crash-issue-owner-signals.sql TABLE="$tbl" DAYS=30 IDS="$ids" || true)" 2>/dev/null || true)"
    [ -n "$rows" ] || rows='[]'
    sig="$(jq -cn --argjson a "$sig" --argjson r "$rows" '$a + ([$r[]? | {key:.issue_id,
             value:{owner:(.owner // ""), symbol:(.symbol // ""), file:(.file // ""), library:(.library // ""), screen:(.screen // "")}}]
             | from_entries)' 2>/dev/null || printf '%s' "$sig")"
  done
  out="$(owner_attach "$items" "$fm" "$sig" \
           "$(cat "$ROOT/notes/module-rules.tsv" 2>/dev/null || true)" \
           "$(cat "$ROOT/notes/owners.tsv" 2>/dev/null || true)" 2>/dev/null || true)"
  if [ -n "$out" ]; then printf '%s' "$out"; else printf '%s' "$items"; fi
}

# owner_at：$1=平台键(ios|and|android) $2=模块键 → 该模块该端的 open_id（取不到为空）。告警卡用。
owner_at() {
  local p="$1"; [ "$p" = android ] && p=and
  awk -F'\t' -v m="$2" -v p="$p" '$1 == m && $2 == p { print $3; exit }' "$ROOT/notes/owners.tsv" 2>/dev/null || true
}
