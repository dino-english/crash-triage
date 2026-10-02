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

# ── 1. 扫两个仓库的 commit message，提取 issue id ──────────
# **两种形式都认**（2026-09-01 实测订正）：
#   ① `[crash:<8位hex>]`      —— 最初约定的形式，实测**两个仓库近 90 天各 0 条**
#   ② `Crashlytics[ issue|-Issue]: <32位hex>` —— **事实上正在用的形式**：
#      Android 4 条（08-19 起，写在 **subject**）、iOS 1 条（08-31，写在 **body**）
#      那 4 个 Android id 在 BigQuery 里全部查得到，是真 issue（85c581ed / a34175e5 /
#      ce481263 / fa48b2eb）。
# ⛔ 因此「Android 未采用约定故 fix_commit 恒 null」这条旧结论**已过期**——不是没人写，
#    是我们只认一种没人用的写法。两端的「处置状态」列此前都是死的。
# ⚠️ 必须扫**整条 message 而不是 subject**：两个仓库的落点不同（Android 在 subject、
#    iOS 在 body），只扫 %s 会漏掉 iOS 那一半。
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
  # 多个 --grep 之间是 OR；⛔ 别写成单个带 \| 的模式，git 默认 BRE，正则风味容易踩空。
  # %at = 作者时间的 epoch 秒，给第 3 步做状态判定用（⛔ 不拿 %aI 字符串比：带 +08:00，事件是 UTC）
  git -C "$repo" log --all --grep='\[crash:' --grep='[Cc]rashlytics' --since="${WINDOW} days ago" \
    --format='%H%x09%aI%x09%at%x09%s' 2>/dev/null | while IFS=$'\t' read -r hash date epoch subject; do
    [ -n "$hash" ] || continue
    _msg="$(git -C "$repo" show -s --format=%B "$hash" 2>/dev/null || true)"
    # ⛔ 每个 grep 都要 `|| true`：无匹配返回 1，而 set -o pipefail 下会让整条管道失败（F31）。
    {
      printf '%s\n' "$_msg" | grep -oE '\[crash:[0-9a-fA-F]{8}\]' | grep -oE '[0-9a-fA-F]{8}' || true
      # ⛔ **冒号必须可选、长度 8 与 32 都要收**（2026-09-11 实测订正）。原正则写死
      #    `crashlytics( issue)?:` 要求冒号、且只认 32 位，于是实际在用的两种写法全漏：
      #      · iOS  a9c8c306：`修复 Crashlytics issue 8baf564f0cf7443bfcb27d8bd10f55d4`（无冒号）
      #      · Android a4a7ce99（09-01）：`Crashlytics 26335e5d；不保证 SIGSEGV 归零`（无冒号、8 位）
      #    后者正是我们事实层里的 issue——「已修待验恒为 0」不是没数据，是**没抓到**。
      # ⚠️ 放宽不会引入误报：下面第 2 步只保留**能在当前 issue 集合里查到**的 short id，
      #    随机的 8 位 hex（如 git 短哈希）匹配不上任何 issue，自然被丢弃。
      # ⛔ **连字符也要收**（2026-10-02 实测订正）：Android 09-14 起改用 git trailer 写法
      #    `Crashlytics-Issue: <32位>`（8fea0314 等 41 条），原正则只认空白分隔，
      #    其中 9 个 id 在 FATAL 事实层里，14 天窗口下 fixmap 实测 0 条。
      printf '%s\n' "$_msg" | grep -oiE 'crashlytics([[:space:]-]+issue)?:?[[:space:]]*[0-9a-fA-F]{8,32}' \
        | grep -oE '[0-9a-fA-F]{8,32}' | cut -c1-8 || true
    } | tr 'A-Z' 'a-z' | sort -u | while read -r short; do
      [ -n "$short" ] || continue
      printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$short" "${hash:0:8}" "$date" "$epoch" "$label" "$subject"
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

while IFS=$'\t' read -r short hash date epoch label subject; do
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
    # ⛔ **两个来源取较晚者，统一换算 epoch 再比**（2026-10-02 实测订正，夹具 fn-fix-status.sh）：
    #    · 只看 `events[]` 不够：明细常为空（抓取滞后 / 补抓失败），旧实现空即判「已修待验」，
    #      同一轮 17 条里 5 条被说反——提交后仍在崩，`latest_event`（每轮无条件刷新）早已写明。
    #    · eventTime 实测有带引号的脏值（`'2026-…Z'`），字符串比较恒小于提交时间。
    #    · 提交时间带 +08:00、事件是 UTC，字符串比较差 8 小时——故提交侧用 git 给的 epoch。
    #    · latest_event 有两种格式：`2026-09-16 01:30 UTC`（bq 路径）与 ISO `…T…Z`
    #      （生产实测 45 条里 2 条，开发机 0 条），两种都要收，否则空明细时落进「状态未知」。
    # ⛔ 两个来源都没有 → 「状态未知」，**不得默认已修待验**：那是把「没证据」报成好消息。
    ev_file="$ISSUES_DIR/$full.json"
    last_ts=""
    if [ -s "$ev_file" ]; then
      last_ts="$(jq -r '
        def ev_ts: try (gsub("^[^0-9]+|[^0-9Z]+$"; "") | sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601) catch null;
        def le_ts: if test("^[0-9-]+T") then ev_ts
                   else try (sub(" UTC$"; "") | sub(" "; "T") + ":00Z" | fromdateiso8601) catch null end;
        [ (.events[]?.eventTime // empty | ev_ts), (.latest_event // empty | le_ts) ]
        | map(select(. != null)) | max // empty
      ' "$ev_file" 2>/dev/null || true)"
    fi
    if [ -z "$last_ts" ] || [ -z "$epoch" ]; then status="状态未知"
    elif [ "$last_ts" -gt "$epoch" ]; then status="修了仍在"
    else status="已修待验"; fi
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
