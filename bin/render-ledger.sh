#!/usr/bin/env bash
# 台账渲染器（design D2/D11，change crash-ledger-l2-ownership）：把当次 topIssues 快照 +
# 修复状态反扫结果 + 已有台账现状表（保留首次纳入日期与结论性备注）合成新的现状表 markdown，
# 并生成本轮变更时间线条目（只含真正变化：新增/消失/暴涨/状态变更）。
# 纯函数：只读输入、只写 stdout，不碰任何持久文件——持久化由调用方负责。
#
# 用法：render-ledger.sh <snapshot.json> <fixmap.json> <prev_table.md或空> <diff.json> <day> <report_url> [issue-seen.json]
# 输出：**三段**用 \x1e（record separator）分隔写到 stdout：
#   ① FATAL 现状表 markdown  ② 变更时间线 markdown  ③ NON_FATAL 现状表 markdown
#   ④ 更新后的生命周期基准 JSON —— **必须由本脚本产出**：first_seen 的取值优先级只在这里
#      实现一次。调用方另算一遍必然与表格里的值漂移（2026-08-24 实测：调用方按 `first=今天`
#      播种，下一轮 $s.first 反过来覆盖了台账里真实的历史首次纳入日期）。
set -euo pipefail

SNAPSHOT="${1:?用法：render-ledger.sh <snapshot.json> <fixmap.json> <prev_table.md或空> <diff.json> <day> <report_url> [issue-seen.json]}"
FIXMAP="${2:?缺少 fixmap.json}"
PREV_TABLE="${3:-}"   # 可以是空字符串或不存在的路径 → 视为无历史
DIFF_FILE="${4:?缺少 diff.json}"
DAY="${5:?缺少 day}"
REPORT_URL="${6:-}"
SEEN_FILE="${7:-}"   # 生命周期基准 {"<32位id>":{"first","last"}}；缺省则退回两态
SEEN_CUTOFF="${8:-}" # 基准保留期起点（YYYY-MM-DD），早于它的条目在第 ④ 段输出时清理

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

# ── 生命周期基准（change crash-report-correctness-fixes，design D4）──────────
# spec crash-perf-issue-lifecycle 要三态：新增 / 回归 / 长期。此前只有两态，回归从未被渲染过。
# 「上一轮」取基准里的**最大 last**，不假设为「上周」——漏跑一轮时按固定周期推断
# 会把全部 issue 误判成回归（crash-daily.sh:830 已踩过同一个坑）。
SEEN_JSON='{}'; SEEN_PREV_DAY=""; LIFECYCLE_OK=0
if [ -n "$SEEN_FILE" ] && [ -s "$SEEN_FILE" ]; then
  SEEN_JSON="$(jq -c '.' "$SEEN_FILE" 2>/dev/null || echo '{}')"
  SEEN_PREV_DAY="$(printf '%s' "$SEEN_JSON" | jq -r '[.[].last] | max // ""' 2>/dev/null || echo "")"
  [ "$(printf '%s' "$SEEN_JSON" | jq 'length' 2>/dev/null || echo 0)" -gt 0 ] && LIFECYCLE_OK=1
fi

# ── 逐平台构建现状表行 ──────────────────────────────────
build_rows() { # $1=平台标签(iOS|Android) $2=snapshot key(ios|android)
  local label="$1" key="$2"
  jq -r --arg label "$label" --arg key "$key" --arg day "$DAY" \
    --slurpfile fm "$FIXMAP" --argjson prev "$PREV_JSON" \
    --argjson seen "$SEEN_JSON" --arg prevday "$SEEN_PREV_DAY" --argjson lcok "$LIFECYCLE_OK" '
    ($fm[0].mapped // {}) as $mapped |
    (.[$key] // [])[] |
    . as $iss |
    ($iss.id[0:8]) as $short |
    ($mapped[$iss.id] // null) as $fix |
    ($prev[$short] // null) as $p |
    ($seen[$iss.id] // null) as $s |
    {
      platform: $label,
      short: $short,
      full: $iss.id,
      title: $iss.title,
      type: "FATAL",
      # 基准的 first 优先：issue 消失后从现状表掉出，$p 随之为空，
      # 只看 $p 会把回归的 issue 记成「今天首次纳入」。
      first_seen: ($s.first // $p.first_seen // $day),
      # 处置状态：反扫命中优先；否则保留历史结论；否则「未处理」（5.7：反扫只改这两列，不碰备注）
      disposition: (if $fix != null then $fix.status
                    elif $p.disposition != null and $p.disposition != "" then $p.disposition
                    else "未处理" end),
      # 三态（spec crash-perf-issue-lifecycle）。⚠️ $s.last 是**上一轮**的值——
      # 基准提升发生在渲染之后，此处读到的还没被刷成今天。
      status_badge: (
        if $lcok == 1 then
          (if $s == null then "🆕新增"
           elif $prevday != "" and $s.last == $prevday then "🔁遗留"
           else "🔁回归" end)
        else
          # 基准尚未建立（本 change 落地后的第一轮）：退回旧两态，不比现状差，
          # 也不会凭空刷出一屏「回归」。下一轮基准就位后自动切到三态。
          (if $p == null then "🆕新增" else "🔁遗留" end)
        end),
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

# ── NON_FATAL 现状表 ────────────────────────────────────
# **与 FATAL 分两张表，不加「类型」列混排**：单表混排时两类交错，读者无法一眼看出
# 「有几个致命问题」——而那是台账最主要的用途。
# **必须截断**：取数层已按受影响安装数取 top N；此处标注未呈现的数量，不静默丢弃。
NF_TABLE=""
nf_rows() { # $1=平台标签 $2=snapshot key
  # 空标题必须渲染成「—」：iOS 存在 issue_title 为空的记录（实测 a7cb1856），
  # 空单元格会被读成「渲染坏了」。`// "—"` 挡不住空字符串，必须显式判空。
  jq -r --arg label "$1" --arg key "$2" '
    ((.nonfatal[$key]) // [])[] |
    "| \($label) | \(.issue_id[0:8]) | \(if (.title // "") == "" then "—" else .title end) | \(if (.subtitle // "") == "" then "—" else .subtitle end) | \(.n) | \(.users) | \(.latest) |"
  ' "$SNAPSHOT" 2>/dev/null || true
}
NF_N_IOS="$(jq -r '((.nonfatal.ios) // []) | length' "$SNAPSHOT" 2>/dev/null || echo 0)"
NF_N_AND="$(jq -r '((.nonfatal.android) // []) | length' "$SNAPSHOT" 2>/dev/null || echo 0)"
if [ "$NF_N_IOS" != "0" ] || [ "$NF_N_AND" != "0" ]; then
  NF_TABLE="$({
    printf '| 平台 | Issue ID | 位置 | 异常 | 事件 | 影响安装 | 最新 |\n'
    printf '|---|---|---|---|---|---|---|\n'
    nf_rows "iOS" ios
    nf_rows "Android" android
    # ⛔ **只输出表格本身，不带说明文字**：deliver.sh 的 block_replace 替换的是飞书文档里的
    # 单个 <table> 块，把说明一起塞进去会把段落挤进表格位置。说明常驻在文档/LEDGER.md 的
    # 标题下方（静态内容，不参与同步），与 FATAL 现状表同一套做法。
  })"
fi

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

# ── ④ 更新后的生命周期基准 ─────────────────────────────
# first 的取值与表格行逐字相同（基准的 first 优先，其次上一版表格的首次纳入，最后本轮日期）。
# ⚠️ last 一律刷成本轮日期；超期条目按 SEEN_CUTOFF 清理（缺省则不清理）。
SEEN_NEXT="$(jq -c --argjson prev "$PREV_JSON" --argjson seen "$SEEN_JSON" \
  --arg day "$DAY" --arg cut "$SEEN_CUTOFF" '
  [(.ios // [])[], (.android // [])[]]
  | map({ id: .id, short: (.id[0:8]) })
  | map({ key: .id,
          value: { first: ((($seen[.id] // {}).first) // (($prev[.short] // {}).first_seen) // $day),
                   last:  $day } })
  | from_entries
  | . as $cur
  | (if $cut == "" then $seen else ($seen | with_entries(select(.value.last >= $cut))) end) + $cur
' "$SNAPSHOT" 2>/dev/null || echo '{}')"

printf '%s\x1e%s\x1e%s\x1e%s' "$TABLE_MD" "$TIMELINE_LINES" "$NF_TABLE" "$SEEN_NEXT"
