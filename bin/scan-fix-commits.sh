#!/usr/bin/env bash
# 修复状态反扫（design D5/D6，change crash-ledger-l2-ownership）：跑批期扫两个业务仓库的
# commit message，按新约定 `[crash:<8位id>]` 反查当前 issue 集合（$STATE/issues/），
# 只读、不改工作区、不装任何 hook。
#
# ⚠️ 不用 bash 关联数组（declare -A）：Mac mini / MacBook 系统自带 /bin/bash 是 3.2
#    （GPLv3 前最后一版，苹果不会升级），关联数组是 bash 4+ 特性，`declare -A` 在 3.2
#    下直接报 "invalid option" 崩溃。本仓库其余脚本走 jq 做映射查表，这里照做。
#
# 用法：scan-fix-commits.sh <STATE目录> <IOS_REPO> <AND_REPO> [回溯天数=14]
# 输出：JSON 到 stdout，结构：
# {
#   "scanned_at": "<ISO8601>",
#   "window_days": 14,
#   "platform_unavailable": ["android", ...],   // 仓库不可读时该平台整体跳过
#   "mapped": {
#     "<32位id>": {"platform":"ios","commit":"<短hash>","commit_date":"<ISO8601>",
#                  "subject":"...","status":"已修待验"|"修了仍在"}
#   },
#   "ambiguous": [{"short_id":"5ac87850","candidates":["<id1>","<id2>",...],"commit":"<短hash>"}]
# }
#
# 纯函数：只读 git log 与 $STATE/issues/*.json，不写任何文件、不改台账——
# 幂等性（5.5）由此保证：相同输入必产生相同输出，落台账走 block_replace（task 6），
# 天然覆盖而非累加，连续两轮跑批扫到同一提交不会在台账里重复记录。
set -euo pipefail

STATE="${1:?用法：scan-fix-commits.sh <STATE目录> <IOS_REPO> <AND_REPO> [回溯天数]}"
IOS_REPO="${2:?缺少 IOS_REPO}"
AND_REPO="${3:?缺少 AND_REPO}"
WINDOW="${4:-14}"
ISSUES_DIR="$STATE/issues"

TMP_HITS="$(mktemp)"
TMP_UNAVAIL="$(mktemp)"
TMP_SHORT2FULL="$(mktemp)"   # jq 映射表：{"<short8>": ["<full32>", ...], ...}
trap 'rm -f "$TMP_HITS" "$TMP_UNAVAIL" "$TMP_SHORT2FULL"' EXIT

# ── 1. 扫两个仓库的 commit message，提取 [crash:<8位hex>] ──────────
# 每个 short id 在窗口内可能出现在多个 commit（同一修复多次跟进）；同一 short id 取最新一次
# 提交作为「本次修复提交」的代表（git log 默认按提交时间倒序，故每个 short id 第一次出现
# 即为窗口内最新的一条，去重逻辑在第 3 步用 awk 实现，同样不依赖关联数组）。
scan_repo() { # $1=仓库路径 $2=平台标签
  local repo="$1" label="$2"
  if [ ! -d "$repo/.git" ]; then
    echo "$label" >> "$TMP_UNAVAIL"
    return 0
  fi
  # --all 覆盖所有分支（含未合并的修复分支）；只读 log，不 checkout / reset。
  git -C "$repo" log --all --grep='\[crash:' --since="${WINDOW} days ago" \
    --format='%H%x09%aI%x09%s' 2>/dev/null | while IFS=$'\t' read -r hash date subject; do
    [ -n "$hash" ] || continue
    printf '%s\n' "$subject" | grep -oE '\[crash:[0-9a-fA-F]{8}\]' | grep -oE '[0-9a-fA-F]{8}' \
      | tr 'A-Z' 'a-z' | while read -r short; do
      printf '%s\t%s\t%s\t%s\t%s\n' "$short" "${hash:0:8}" "$date" "$label" "$subject"
    done
  done >> "$TMP_HITS" || true
}
scan_repo "$IOS_REPO" ios
scan_repo "$AND_REPO" android

# ── 2. 建立 short_id → 当前 issue 集合的映射（来自事实层 $STATE/issues/），用 jq 生成查表 ──
if [ -d "$ISSUES_DIR" ] && compgen -G "$ISSUES_DIR/*.json" >/dev/null; then
  jq -sc '
    map({id: .id, short: .id[0:8], platform: (.platform // empty)}) |
    group_by(.short) |
    map({key: .[0].short, value: {ids: map(.id), platform: .[0].platform}}) |
    from_entries
  ' "$ISSUES_DIR"/*.json > "$TMP_SHORT2FULL"
else
  echo '{}' > "$TMP_SHORT2FULL"
fi

# ── 3. 逐 short_id 解析（同一 short id 只取窗口内第一次出现 = 最新提交）───────────────
# 命中 0 个当前 issue → 忽略（提交指向的 issue 不在当前集合内，多是历史 issue 已滚出窗口，
# 不算反扫失败）；命中 1 个 → 落 mapped；命中 >1 个 → 落 ambiguous，不自动更新任何一个（5.3）。
MAPPED='{}'
AMBIGUOUS='[]'
DEDUP="$(mktemp)"
trap 'rm -f "$TMP_HITS" "$TMP_UNAVAIL" "$TMP_SHORT2FULL" "$DEDUP"' EXIT
awk -F'\t' '!seen[$1]++' "$TMP_HITS" > "$DEDUP"

while IFS=$'\t' read -r short hash date label subject; do
  [ -n "$short" ] || continue
  entry="$(jq -c --arg s "$short" '.[$s] // {ids:[],platform:null}' "$TMP_SHORT2FULL")"
  n="$(jq -r '.ids | length' <<<"$entry")"
  if [ "$n" -eq 0 ]; then
    continue   # 提交指向的 issue 不在当前集合内，跳过（不是反扫失败）
  elif [ "$n" -eq 1 ]; then
    full="$(jq -r '.ids[0]' <<<"$entry")"
    plat="$(jq -r '.platform // empty' <<<"$entry")"
    [ -n "$plat" ] || plat="$label"
    # 修复状态判定（5.6）：有修复提交，比较线上该 issue 是否有晚于提交时间的新事件。
    ev_file="$ISSUES_DIR/$full.json"
    status="已修待验"
    if [ -s "$ev_file" ]; then
      max_event="$(jq -r '[.events[]?.eventTime // empty] | sort | last // empty' "$ev_file" 2>/dev/null || true)"
      if [ -n "$max_event" ] && [ "$max_event" \> "$date" ]; then
        status="修了仍在"
      fi
    fi
    MAPPED="$(jq -c --arg id "$full" --arg plat "$plat" --arg commit "$hash" \
                    --arg date "$date" --arg subj "$subject" --arg status "$status" \
      '. + {($id): {platform:$plat, commit:$commit, commit_date:$date, subject:$subj, status:$status}}' \
      <<<"$MAPPED")"
  else
    cands="$(jq -c '.ids' <<<"$entry")"
    AMBIGUOUS="$(jq -c --arg short "$short" --arg commit "$hash" --argjson cands "$cands" \
      '. + [{short_id:$short, candidates:$cands, commit:$commit}]' <<<"$AMBIGUOUS")"
  fi
done < "$DEDUP"

UNAVAIL_JSON='[]'
if [ -s "$TMP_UNAVAIL" ]; then
  UNAVAIL_JSON="$(jq -Rsc 'split("\n") | map(select(length>0)) | unique' "$TMP_UNAVAIL")"
fi

jq -n --arg t "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --argjson w "$WINDOW" \
      --argjson unavail "$UNAVAIL_JSON" --argjson mapped "$MAPPED" --argjson amb "$AMBIGUOUS" \
  '{scanned_at:$t, window_days:$w, platform_unavailable:$unavail, mapped:$mapped, ambiguous:$amb}'
