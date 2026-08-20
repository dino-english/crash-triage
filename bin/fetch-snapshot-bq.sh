#!/usr/bin/env bash
# fetch-snapshot-bq.sh — L2 数据层：纯 bq 取崩溃 issue 快照，全程不调模型。
#
# 产出 $1/snapshot.json，结构与 fetch-snapshot.sh 完全一致（下游 diff / 台账渲染
# 都吃这个形状，不能变）：
#   {"ios":[{id,title,events,users,fix_commit,fix_branches}], "android":[...]}
#
# 为什么数据层不该用模型（change crash-ledger-l2-ownership 补充）：
#   数据与分析分层——数据是确定性的聚合，分析才需要模型。旧实现把两者绑在
#   `claude -p` 一次调用里，代价是 2026-08-19/20 实测的那次 429：模型额度一挂，
#   snapshot.json 落不了盘，crash-weekly.sh 直接 fail，群里什么都收不到。
#   而崩溃事件数、影响面、issue 标题这些数字本来就在 BigQuery 里躺着。
#
# 与 fetch-snapshot.sh（模型路径）的能力差异——本脚本**拿不到**：
#   - 堆栈明细与 blameFrame（台账「根因」列因此留空）
#   - issue 的 OPEN/CLOSED 状态（BigQuery 是事件级，不含开关状态；
#     这反而是迁移的动机之一，见 change crash-source-bigquery-migration）
#   - report.md 深度分析（那是分析层的产物，由调用方决定要不要跑）
# 拿得到的：id / title / events / users / latest，以及 fix_commit（走 git 反扫，
# 同样不经模型）——足够渲染台账现状表、变更时间线与群卡片。
#
# 用法：fetch-snapshot-bq.sh <输出目录> [fixmap.json]
#   fixmap.json 可选，由 scan-fix-commits.sh 产出；给了就填 fix_commit /
#   fix_branches，不给就置 null（与模型路径在 Android 上的行为一致）。
set -euo pipefail

OUT_DIR="${1:?用法：fetch-snapshot-bq.sh <输出目录> [fixmap.json]}"
FIXMAP="${2:-}"
mkdir -p "$OUT_DIR"

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="${CRASH_REPORT_ROOT:-$(dirname "$SELF_DIR")}"
SQL_DIR="${SQL_DIR:-$ROOT/bin/sql}"
STATE="${CRASH_REPORT_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/crash-triage}"
ISSUES_DIR="$STATE/issues"
mkdir -p "$ISSUES_DIR"

PROJECT="${CRASH_REPORT_BQ_PROJECT:-dino-english-497507}"
DAYS="${CRASH_REPORT_WEEK_DAYS:-7}"
LIMIT="${CRASH_REPORT_ISSUE_LIMIT:-20}"
# 事实层缓存判定在 shell 里做，不在 prompt 里——旧实现把「命中就跳过」写给模型
# 自觉执行，模型走神就白花一次抓取。这里是文件存在性 + 事件计数比较，确定性的。
FORCE_REFETCH="${CRASH_REPORT_FORCE_REFETCH:-0}"

SNAP="$OUT_DIR/snapshot.json"

bq_json() { # $1=SQL文本 → JSON 数组（失败返回空数组，由调用方判定）
  printf '%s' "$1" | bq query --use_legacy_sql=false --format=json 2>>"$OUT_DIR/bq-stderr.log" || echo '[]'
}

platform_rows() { # $1=平台键(ios/android) $2=crashlytics表 → JSON 数组
  local sql
  sql="$(sed -e "s|{{TABLE}}|$2|g" -e "s|{{DAYS}}|$DAYS|g" -e "s|{{LIMIT}}|$LIMIT|g" \
           "$SQL_DIR/crash-issues-all.sql")"
  bq_json "$sql"
}

IOS_TBL="$PROJECT.firebase_crashlytics.com_prime_dino_english_IOS_REALTIME"
AND_TBL="$PROJECT.firebase_crashlytics.com_prime_dino_english_ANDROID_REALTIME"

echo "--- L2 数据层：bq 取崩溃 issue（${DAYS}d 窗口，全版本口径）---"
IOS_RAW="$(platform_rows ios "$IOS_TBL")"
AND_RAW="$(platform_rows android "$AND_TBL")"

# 两端都空 = bq 真出了问题（正常情况下至少一端有数据）。这里必须失败，
# 否则会把「取数挂了」渲染成「本周零崩溃」——那是最坏的一种错误报告。
IOS_N="$(printf '%s' "$IOS_RAW" | jq 'length' 2>/dev/null || echo 0)"
AND_N="$(printf '%s' "$AND_RAW" | jq 'length' 2>/dev/null || echo 0)"
if [ "$IOS_N" -eq 0 ] && [ "$AND_N" -eq 0 ]; then
  echo "  ❌ bq 两端均无数据，判定取数失败（详见 $OUT_DIR/bq-stderr.log）" >&2
  exit 1
fi
echo "  iOS $IOS_N 类 · Android $AND_N 类"

# fix_commit / fix_branches 从 fixmap.json 填充（scan-fix-commits.sh 的产物，纯 git）。
# 键是 8 位短 id，与反扫的 commit message 约定 [crash:<8位id>] 对齐。
FIXMAP_JSON='{}'
if [ -n "$FIXMAP" ] && [ -s "$FIXMAP" ]; then
  FIXMAP_JSON="$(jq -c '.mapped // {}' "$FIXMAP" 2>/dev/null || echo '{}')"
fi

jq -n --argjson ios "$IOS_RAW" --argjson android "$AND_RAW" \
      --argjson fixmap "$FIXMAP_JSON" '
  def norm($plat):
    map({
      id:           .id,
      title:        .title,
      events:       (.events | tonumber),
      users:        (.users  | tonumber),
      latest:       .latest,
      fix_commit:   ($fixmap[(.id[0:8])].commit  // null),
      fix_branches: ($fixmap[(.id[0:8])].branches // null)
    });
  {ios: ($ios | norm("ios")), android: ($android | norm("android"))}
' > "$SNAP"

jq -e '.ios and .android' "$SNAP" >/dev/null || { echo "  ❌ snapshot.json 结构异常" >&2; exit 1; }

# ── 事实层缓存（$STATE/issues/<32位id>.json，一 issue 一文件，永久保留不清理）──
# 判定：文件不存在 → 写入；events 变大 → 更新计数与时间戳；相等 → 跳过。
# bq 路径拿不到 events 明细（那要 crashlytics_list_events），所以这里存的是
# 聚合事实而非事件数组——模型路径写的文件结构更丰富，两者用 source 字段区分，
# 谁也不覆盖谁的 events 键。
CACHED_NEW=0; CACHED_UPD=0; CACHED_HIT=0
while IFS=$'\t' read -r iid plat title events users latest; do
  [ -n "$iid" ] || continue
  f="$ISSUES_DIR/$iid.json"
  if [ "$FORCE_REFETCH" = "1" ] || [ ! -f "$f" ]; then
    jq -n --arg id "$iid" --arg p "$plat" --arg t "$title" --arg l "$latest" \
          --argjson e "$events" --argjson u "$users" \
          --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
      '{id:$id, platform:$p, title:$t, events_count_last_seen:$e, users_last_seen:$u,
        latest_event:$l, source:"bigquery", last_synced:$ts}' > "$f"
    CACHED_NEW=$((CACHED_NEW+1))
  else
    prev="$(jq -r '.events_count_last_seen // 0' "$f" 2>/dev/null || echo 0)"
    if [ "$events" -gt "$prev" ] 2>/dev/null; then
      tmp="$(mktemp)"
      jq --argjson e "$events" --argjson u "$users" --arg l "$latest" \
         --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        '.events_count_last_seen=$e | .users_last_seen=$u | .latest_event=$l | .last_synced=$ts' \
        "$f" > "$tmp" && mv "$tmp" "$f"
      CACHED_UPD=$((CACHED_UPD+1))
    else
      CACHED_HIT=$((CACHED_HIT+1))
    fi
  fi
done < <(jq -r '
  (.ios     | map([.id,"ios",     .title, (.events|tostring), (.users|tostring), (.latest // "")] | @tsv) | .[]),
  (.android | map([.id,"android", .title, (.events|tostring), (.users|tostring), (.latest // "")] | @tsv) | .[])
' "$SNAP")

# ⛔ 多字节字符不能紧跟 ${var}：bash 会把全角括号的后续字节并进变量名，
# set -u 下报 `FORCE_REFETCH?: unbound variable`（CLAUDE.md 记过这条，这里又踩了两次）。
# 最省事的解法是这类位置一律用 ASCII 括号，别跟全角字符较劲。
echo "  事实层缓存: 新增 $CACHED_NEW · 更新 $CACHED_UPD · 命中跳过 $CACHED_HIT (FORCE_REFETCH=$FORCE_REFETCH)"
echo "  → $SNAP"
