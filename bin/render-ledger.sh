#!/usr/bin/env bash
# 台账渲染器（design D2/D11，change crash-ledger-l2-ownership）：把当次 topIssues 快照 +
# 修复状态反扫结果 + 已有台账现状表（保留首次纳入日期与结论性备注）合成新的现状表 markdown，
# 并生成本轮变更时间线条目（只含真正变化：新增/消失/暴涨/状态变更）。
# 纯函数：只读输入、只写 stdout，不碰任何持久文件——持久化由调用方负责。
#
# 用法：render-ledger.sh <snapshot.json> <fixmap.json> <prev_table.md或空> <diff.json> <day> <report_url>
# 输出：两段用 \x1e（record separator）分隔写到 stdout —— 第一段现状表 markdown，第二段时间线 markdown。
set -euo pipefail

SNAPSHOT="${1:?用法：render-ledger.sh <snapshot.json> <fixmap.json> <prev_table.md或空> <diff.json> <day> <report_url>}"
FIXMAP="${2:?缺少 fixmap.json}"
PREV_TABLE="${3:-}"   # 可以是空字符串或不存在的路径 → 视为无历史
DIFF_FILE="${4:?缺少 diff.json}"
DAY="${5:?缺少 day}"
REPORT_URL="${6:-}"

[ -s "$SNAPSHOT" ] || { echo "snapshot.json 为空：$SNAPSHOT" >&2; exit 1; }
[ -s "$FIXMAP" ] || echo '{"mapped":{},"ambiguous":[],"platform_unavailable":[]}' > "$FIXMAP"

# DIFF_FILE 可能是调用方传入的进程替换（<(...)），底层是命名管道，只能被消费一次——
# 下方对同一份 diff 数据要读 6 次（2 平台 × new/resolved/spiked），第 2 次起会读到空，
# 静默丢失时间线条目（2026-08-19 实测：DRY RUN 真实变化 5 条，时间线渲染出 0 条）。
# 落一份普通临时文件再多次读，从根上避免管道单次消费的限制。
DIFF_TMP="$(mktemp)"
cat "$DIFF_FILE" > "$DIFF_TMP"
DIFF_FILE="$DIFF_TMP"
trap 'rm -f "$DIFF_TMP"' EXIT

# ── 解析已有现状表（若存在），建立 id → {first_seen, disposition, note} 的历史映射 ──
# 表格列序固定：平台|Issue ID|标题|类型|首次纳入|处置状态|本次状态|事件量趋势|备注
# Issue ID 列渲染为短 id（8 位十六进制），用它反查历史（短 id 在当前 issue 集合内假定唯一，
# 冲突场景走 5.3 的歧义分支，不落这张表）。
PREV_JSON='{}'
if [ -n "$PREV_TABLE" ] && [ -s "$PREV_TABLE" ]; then
  PREV_JSON="$(awk -F'|' '
    /^\| *平台/ {next}
    /^\|---/ {next}
    NF >= 10 {
      gsub(/^ +| +$/, "", $3); gsub(/^ +| +$/, "", $6); gsub(/^ +| +$/, "", $7); gsub(/^ +| +$/, "", $10)
      # 列序：$1=(空) $2=平台 $3=Issue ID(短id) $4=标题 $5=类型 $6=首次纳入 $7=处置状态 $8=本次状态 $9=事件量趋势 $10=备注
      print $3 "\t" $6 "\t" $7 "\t" $10
    }
  ' "$PREV_TABLE" 2>/dev/null | jq -Rsc '
    split("\n") | map(select(length>0) | split("\t")) |
    map(select(length>=4)) |
    map({key: .[0], value: {first_seen:.[1], disposition:.[2], note:.[3]}}) |
    from_entries
  ' 2>/dev/null || echo '{}')"
fi

# ── 逐平台构建现状表行 ──────────────────────────────────
build_rows() { # $1=平台标签(iOS|Android) $2=snapshot key(ios|android)
  local label="$1" key="$2"
  jq -r --arg label "$label" --arg key "$key" --arg day "$DAY" \
    --slurpfile fm "$FIXMAP" --argjson prev "$PREV_JSON" '
    ($fm[0].mapped // {}) as $mapped |
    (.[$key] // [])[] |
    . as $iss |
    ($iss.id[0:8]) as $short |
    ($mapped[$iss.id] // null) as $fix |
    ($prev[$short] // null) as $p |
    {
      platform: $label,
      short: $short,
      full: $iss.id,
      title: $iss.title,
      type: "FATAL",
      first_seen: ($p.first_seen // $day),
      # 处置状态：反扫命中优先；否则保留历史结论；否则「未处理」（5.7：反扫只改这两列，不碰备注）
      disposition: (if $fix != null then $fix.status
                    elif $p.disposition != null and $p.disposition != "" then $p.disposition
                    else "未处理" end),
      status_badge: (if $p == null then "🆕新增" else "🔁遗留" end),
      events: ($iss.events // 0),
      note: (if $fix != null then ($fix.commit + " " + $fix.subject)
             elif $p.note != null then $p.note
             else "" end)
    } |
    "| \(.platform) | \(.short) | \(.title) | \(.type) | \(.first_seen) | \(.disposition) | \(.status_badge) | \(.events) | \(.note) |"
  ' "$SNAPSHOT"
}

{
  printf '| 平台 | Issue ID | 标题 | 类型 | 首次纳入 | 处置状态 | 本次状态 | 事件量趋势 | 备注 |\n'
  printf '|---|---|---|---|---|---|---|---|---|\n'
  build_rows "iOS" ios
  build_rows "Android" android
} > /tmp/.render-ledger-table.$$
TABLE_MD="$(cat /tmp/.render-ledger-table.$$)"
rm -f /tmp/.render-ledger-table.$$

# ── 变更时间线：只记录真正的变化（新增/消失/暴涨/反扫命中的状态变更），平稳周不追加 ──
TIMELINE_LINES=""
add_line() { TIMELINE_LINES="${TIMELINE_LINES}- ${DAY}：$1$([ -n "$REPORT_URL" ] && printf ' · [周报](%s)' "$REPORT_URL")
"; }

for plat_key_label in "ios:iOS" "android:Android"; do
  key="${plat_key_label%%:*}"; label="${plat_key_label##*:}"
  while IFS=$'\t' read -r title events; do
    [ -n "$title" ] || continue
    add_line "🆕 [$label] 新增 ${title}（$events 事件）"
  done < <(jq -r --arg k "$key" '(.[$k].new // [])[] | [.title, .events] | @tsv' "$DIFF_FILE" 2>/dev/null || true)

  while IFS=$'\t' read -r title; do
    [ -n "$title" ] || continue
    add_line "✅ [$label] 消失 $title"
  done < <(jq -r --arg k "$key" '(.[$k].resolved // [])[] | .title' "$DIFF_FILE" 2>/dev/null || true)

  while IFS=$'\t' read -r title events; do
    [ -n "$title" ] || continue
    add_line "📈 [$label] 暴涨 ${title}（$events 事件）"
  done < <(jq -r --arg k "$key" '(.[$k].spiked // [])[] | [.title, .events] | @tsv' "$DIFF_FILE" 2>/dev/null || true)
done

# 反扫命中的状态变更（已修待验/修了仍在）也进时间线——这是台账真正的价值：结论随代码事实更新
while IFS=$'\t' read -r id plat status commit subject; do
  [ -n "$id" ] || continue
  add_line "🛠️ [$plat] $status ${subject}（${commit}，issue ${id:0:8}）"
done < <(jq -r '.mapped // {} | to_entries[] | [.key, .value.platform, .value.status, .value.commit, .value.subject] | @tsv' "$FIXMAP" 2>/dev/null || true)

printf '%s\x1e%s' "$TABLE_MD" "$TIMELINE_LINES"
