#!/usr/bin/env bash
# 修复发版判定（change crash-fix-release-status）：把 scan-fix-commits.sh 只比时间的两态，
# 按「修复提交之后的事件发生在哪个包上」改判为四态（修了仍在 / 已发版待验 / 已修未发版 / 状态未知）。
#
# 为什么要有这一步：时间规则看不见事件所在的包，2026-10-06 生产 19 条映射里 6 条说反——
# 修复没发版、或已发版但旧包用户还在崩，都被报成「修了仍在」（修复无效），处置方向整个反了。
#
# 用法：fix-release-status.sh <scan 产出的 fixmap.json> <输出路径>
#   环境：CRASH_REPORT_STATE_DIR / CRASH_REPORT_BQ_PROJECT（缺省同其他子脚本）
#         CRASH_REPORT_REPOS_SYNCED=0 → 输出顶层 repos_synced:false（调用方本轮 fetch 失败，design D5）
# 输出：与输入同结构；mapped 每条加
#   release_check: "ok" | "unavailable"
#   ok 时另加 status（四态）、status_time（原时间规则结果）、old_build_events、new_build_events
# 退出码：0 = 两端都判了；2 = 有一端取数失败（该端条目保留原状态并标 unavailable，**文件照写**）。
#   ⛔ 调用方用 `|| RC=$?` 接住后照常往下走，并让 unavailable 在呈现处可见（design D6）——
#      ⛔ 不得把失败静默当成两态：那会让读者以为发版判定照常生效。
set -euo pipefail
IN="${1:?用法：fix-release-status.sh <fixmap.json> <输出路径>}"
OUT="${2:?缺少输出路径}"

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="${CRASH_REPORT_ROOT:-$(dirname "$SELF_DIR")}"
SQL_DIR="${SQL_DIR:-$ROOT/bin/sql}"
STATE="${CRASH_REPORT_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/crash-triage}"
PROJECT="${CRASH_REPORT_BQ_PROJECT:-dino-english-497507}"
REPOS_SYNCED="${CRASH_REPORT_REPOS_SYNCED:-1}"

# shellcheck disable=SC1091
. "$ROOT/bin/lib.sh" || { echo "❌ 外壳层缺失：bin/lib.sh" >&2; exit 1; }
# shellcheck disable=SC1091
. "$ROOT/bin/lib/bq.sh" || { echo "❌ 外壳层缺失：bin/lib/bq.sh" >&2; exit 1; }
# shellcheck disable=SC1091
. "$ROOT/bin/lib/query.sh" || { echo "❌ 外壳层缺失：bin/lib/query.sh" >&2; exit 1; }
# shellcheck disable=SC1091
. "$ROOT/bin/lib/core/fixrelease.sh" || { echo "❌ 核心层缺失：bin/lib/core/fixrelease.sh" >&2; exit 1; }
# ⚠️ 承重墙：bq_init 的默认分支引用 ${TS}，本脚本不定义 TS——预设 BQ_ERRLOG 才不会死于 unbound variable。
BQ_ERRLOG="$(dirname "$OUT")/fix-release-bq-stderr.log"
bq_init
# ⛔ 完成哨兵（同 fetch-snapshot-bq.sh）：bash 3.2 下 set -u 失败进 EXIT trap 时 $? 已是 0。
trap 'rm -f "$BQ_SQLTMP"; [ "${RUN_COMPLETED:-0}" = 1 ] || exit 1' EXIT

MAPPED="$(jq -c '.mapped // {}' "$IN")"
RESULTS='{}'      # {"<id>": {verdict…}}，只收判成功的
UNAVAIL='[]'      # 取数失败的平台

for p in ios android; do
  T=IOS; [ "$p" = android ] && T=ANDROID
  # ⛔ 只替换值（口径文档 :144）：id 与 epoch 注入前校验，不合规的条目跳过（它们会落 unavailable）。
  fixes="$(jq -r --arg p "$p" '
    to_entries
    | map(select(.value.platform == $p and (.key | test("^[0-9a-f]{32}$"))
                 and (.value.commit_epoch | type) == "number"))
    | map("STRUCT(\"\(.key)\" AS id, TIMESTAMP_SECONDS(\(.value.commit_epoch | floor)) AS ct)")
    | join(", ")' <<<"$MAPPED")"
  [ -n "$fixes" ] || continue
  sql="$(q_render fix-release-builds.sql FIXES="$fixes" \
           SESS_RT_TABLE="$PROJECT.firebase_sessions.com_prime_dino_english_${T}_REALTIME" \
           SESS_TABLE="$PROJECT.firebase_sessions.com_prime_dino_english_${T}" \
           CRASH_TABLE="$PROJECT.firebase_crashlytics.com_prime_dino_english_${T}" \
           CRASH_RT_TABLE="$PROJECT.firebase_crashlytics.com_prime_dino_english_${T}_REALTIME")" \
    || { UNAVAIL="$(jq -c --arg p "$p" '. + [$p]' <<<"$UNAVAIL")"; continue; }
  _rc=0; rows="$(bqq json "$sql")" || _rc=$?
  # bq 对 0 行结果可能输出空串；⛔ 但非 0 退出码一律算失败，不把失败的空输出当「0 行」
  [ -n "$(printf '%s' "$rows" | tr -d '[:space:]')" ] || rows='[]'
  if [ "$_rc" -ne 0 ] || ! jq -e 'type == "array"' <<<"$rows" >/dev/null 2>&1; then
    echo "  ⚠️ 发版判定取数失败（${p}，rc=${_rc}），该端保留时间规则结果并标注「发版判定不可得」" >&2
    UNAVAIL="$(jq -c --arg p "$p" '. + [$p]' <<<"$UNAVAIL")"
    continue
  fi
  rel="$(jq -c '[.[] | select(.kind == "rel")]' <<<"$rows")"
  while IFS= read -r id; do
    [ -n "$id" ] || continue
    fix="$(jq -c --arg id "$id" '.[$id]' <<<"$MAPPED")"
    ev="$(jq -c --arg id "$id" '[.[] | select(.kind == "ev" and .issue_id == $id)]' <<<"$rows")"
    v="$(fix_release_verdict "$fix" "$ev" "$rel")"
    RESULTS="$(jq -c --arg id "$id" --argjson v "$v" '. + {($id): $v}' <<<"$RESULTS")"
  done < <(jq -r --arg p "$p" 'to_entries[] | select(.value.platform == $p) | .key' <<<"$MAPPED")
done

tmp="$OUT.tmp.$$"
jq --argjson res "$RESULTS" --argjson unavail "$UNAVAIL" --argjson synced "$([ "$REPOS_SYNCED" = 0 ] && echo false || echo true)" '
  .release_unavailable = $unavail
  | .repos_synced = $synced
  | .mapped = ((.mapped // {}) | with_entries(
      .key as $id
      | if $res[$id] != null then
          .value += { status_time: .value.status, release_check: "ok" } + $res[$id]
        else
          .value += { release_check: "unavailable" }
        end))' "$IN" > "$tmp"
mv "$tmp" "$OUT"

n_ok="$(jq '[.mapped[] | select(.release_check == "ok")] | length' "$OUT")"
n_un="$(jq '[.mapped[] | select(.release_check != "ok")] | length' "$OUT")"
echo "  发版判定：已判 $n_ok 条 · 不可得 $n_un 条$([ "$REPOS_SYNCED" = 0 ] && echo ' · ⚠️ 仓库未同步，判定可能滞后' || true)" >&2
RUN_COMPLETED=1
if [ "$n_un" -gt 0 ]; then exit 2; fi
