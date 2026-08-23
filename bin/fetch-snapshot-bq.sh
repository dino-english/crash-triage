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
# 核心层（纯函数）。本脚本是独立进程，必须自己加载——不能指望调用方 export 函数。
# 只加载用得到的 cache：缺失则直接失败不退化，退化版本会静默产出错误判定
# （抓取判定退化 → 事实层停更；保留谓词退化 → 误删固定文档键、重建整套飞书文档）。
# shellcheck disable=SC1091
. "$ROOT/bin/lib/core/cache.sh" || { echo "❌ 核心层缺失：bin/lib/core/cache.sh" >&2; exit 1; }
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

# 外壳层：bq 查询唯一通道（findings F1/F5 收口）。本脚本是独立进程，必须自己加载——
# 函数不跨进程；lib.sh 提供 bqq 依赖的 run_with_timeout。
# shellcheck disable=SC1091
. "$ROOT/bin/lib.sh" || { echo "❌ 外壳层缺失：bin/lib.sh" >&2; exit 1; }
# shellcheck disable=SC1091
. "$ROOT/bin/lib/bq.sh" || { echo "❌ 外壳层缺失：bin/lib/bq.sh" >&2; exit 1; }
# 沿用原有 stderr 汇集位置（随 runs/ 留存作跑批物证）。⚠️ 这行预设同时是承重墙：
# bq_init 的默认分支引用 $TS，而本脚本不定义 TS——删掉这行会死于 unbound variable。
BQ_ERRLOG="$OUT_DIR/bq-stderr.log"
bq_init
trap 'rm -f "$BQ_SQLTMP"' EXIT

bq_json() { # $1=SQL文本 → JSON 数组（失败返回空数组，由调用方判定）
  # 用变量接住再输出：bqq 失败时 stdout 是一个空行，直接 `bqq || echo '[]'` 会把
  # 空行混在 [] 前面，破坏「失败输出恰为 []」的契约
  local out
  out="$(bqq json "$1")" || { echo '[]'; return 0; }
  printf '%s\n' "$out"
}

platform_rows() { # $1=平台键(ios/android) $2=crashlytics表 → JSON 数组
  local sql
  sql="$(sed -e "s|{{TABLE}}|$2|g" -e "s|{{DAYS}}|$DAYS|g" -e "s|{{LIMIT}}|$LIMIT|g" \
           "$SQL_DIR/crash-issues-all.sql")"
  bq_json "$sql"
}

# NON_FATAL（台账 NON_FATAL 现状表用）。**必须截断**：iOS 近 14 天 1020 条，
# 全量写台账会把 FATAL 的十几条淹没在一千条里，台账随即失去用途。
# 按受影响安装数取 top N（SQL 已按 users 排序），未呈现的数量由渲染层标注。
NF_LIMIT="${CRASH_REPORT_LEDGER_NF_LIMIT:-10}"
nonfatal_rows() { # $1=平台键 $2=crashlytics表 → JSON 数组
  local sql
  sql="$(sed -e "s|{{TABLE}}|$2|g" -e "s|{{DAYS}}|$DAYS|g" -e "s|{{LIMIT}}|$NF_LIMIT|g" \
           -e 's|{{VERSIONS}}|{{ALLVER}}|g' "$SQL_DIR/crash-nonfatal-issues.sql")"
  # 台账跨版本追踪，与 crash-issues-all.sql 同理**刻意不加版本过滤**——
  # 加了会让「上一版修好、这版没复发」的 issue 从现状表凭空消失、时间线断档。
  sql="$(printf '%s' "$sql" | sed -e '/AND application.display_version IN ({{ALLVER}})/d')"
  bq_json "$sql"
}

IOS_TBL="$PROJECT.firebase_crashlytics.com_prime_dino_english_IOS_REALTIME"
AND_TBL="$PROJECT.firebase_crashlytics.com_prime_dino_english_ANDROID_REALTIME"

echo "--- L2 数据层：bq 取崩溃 issue（${DAYS}d 窗口，全版本口径）---"
IOS_RAW="$(platform_rows ios "$IOS_TBL")"
AND_RAW="$(platform_rows android "$AND_TBL")"
IOS_NF="$(nonfatal_rows ios "$IOS_TBL")"
AND_NF="$(nonfatal_rows android "$AND_TBL")"

# 两端都空 = bq 真出了问题（正常情况下至少一端有数据）。这里必须失败，
# 否则会把「取数挂了」渲染成「本周零崩溃」——那是最坏的一种错误报告。
IOS_N="$(printf '%s' "$IOS_RAW" | jq 'length' 2>/dev/null || echo 0)"
AND_N="$(printf '%s' "$AND_RAW" | jq 'length' 2>/dev/null || echo 0)"
if [ "$IOS_N" -eq 0 ] && [ "$AND_N" -eq 0 ]; then
  echo "  ❌ bq 两端均无数据，判定取数失败（详见 $OUT_DIR/bq-stderr.log）" >&2
  exit 1
fi
echo "  iOS $IOS_N 类 · Android $AND_N 类"
echo "  NON_FATAL（台账用，按影响面取前 ${NF_LIMIT}）：iOS $(printf '%s' "$IOS_NF" | jq 'length' 2>/dev/null || echo 0) 类 · Android $(printf '%s' "$AND_NF" | jq 'length' 2>/dev/null || echo 0) 类"

# fix_commit / fix_branches 从 fixmap.json 填充（scan-fix-commits.sh 的产物，纯 git）。
# 键是 8 位短 id，与反扫的 commit message 约定 [crash:<8位id>] 对齐。
FIXMAP_JSON='{}'
if [ -n "$FIXMAP" ] && [ -s "$FIXMAP" ]; then
  FIXMAP_JSON="$(jq -c '.mapped // {}' "$FIXMAP" 2>/dev/null || echo '{}')"
fi

jq -n --argjson ios "$IOS_RAW" --argjson android "$AND_RAW" \
      --argjson iosnf "$IOS_NF" --argjson andnf "$AND_NF" \
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
  {ios: ($ios | norm("ios")), android: ($android | norm("android")),
   nonfatal: {ios: $iosnf, android: $andnf}}
' > "$SNAP"

jq -e '.ios and .android' "$SNAP" >/dev/null || { echo "  ❌ snapshot.json 结构异常" >&2; exit 1; }

# ── 事实层缓存（$STATE/issues/<32位id>.json，一 issue 一文件，永久保留不清理）──
#
# **两个判定必须拆开**（change crash-fact-cache-freshness D1）：
#   ① 抓取判定：要不要发起事件明细抓取。计数没变或下降 → 没有新事件 → 跳过，这是**正确的**。
#   ② 记录更新：观测字段（计数 / 最近事件 / 最近同步）**每轮无条件刷新**。
#
# 旧实现把两者挤在一个 if/else 里，于是「跳过抓取」连带跳过了记录，导致：
#   · `latest_event` 冻结 → 台账的「最近一次发生」停在历史峰值那天，直接误导处置判断；
#   · `last_synced` 冻结 → 正在衰减（= 正在被修好）的 issue 看起来像「数据停更」，好消息读成故障。
#
# ⚠️ 根因是**口径错配**：`crash-issues-all.sql` 的 events 是**滚动窗口内**的 COUNT(*)，
#    老事件出窗即下降，**不是单调量**；而 `-gt` 判定是从 MCP topIssues 时代原样搬来的。
#
# ⚠️ bq 路径的「跳过」本来就省不了任何东西——那一行数据已经在 $SNAP 里（就是 bq 查询的结果），
#    跳过只避免了一次 jq + mv。是模型路径（fetch-snapshot.sh）才真省一次昂贵的 MCP 调用。
FETCH_NEW=0; FETCH_APPEND=0; FETCH_SKIP=0; REC_UPDATED=0
while IFS=$'\t' read -r iid plat title events users latest; do
  [ -n "$iid" ] || continue
  f="$ISSUES_DIR/$iid.json"
  now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

  # ── ① 抓取判定（bq 路径下「抓取」退化为空操作，但语义与模型路径保持一致）──
  # 判定本身已上移核心层（bin/lib/core/cache.sh），这里只负责把文件状态读成入参。
  if [ -f "$f" ]; then
    exists=1; prev="$(jq -r '.events_count_last_seen // 0' "$f" 2>/dev/null || echo 0)"
  else
    exists=0; prev=0
  fi
  verdict="$(cache_verdict "$FORCE_REFETCH" "$exists" "$prev" "$events")"
  case "$verdict" in
    new)    FETCH_NEW=$((FETCH_NEW+1));;
    append) FETCH_APPEND=$((FETCH_APPEND+1));;
    skip)   FETCH_SKIP=$((FETCH_SKIP+1));;
  esac

  # ── ② 记录更新：无条件执行 ──
  # ⛔ 更新分支**不碰 `.source`**：该字段区分「只有聚合事实」（bigquery）与「有完整事件数组」（模型路径），
  # 由创建者写死。更新时改写它会把模型路径记录的来源标签抹掉——events 数组还在，标签却说没有。
  # latest_event 取 max(已存, 本次)：窗口内的 MAX(event_timestamp) **同样非单调**——
  # 最新那条事件出窗后，剩余事件的 MAX 会比上一轮更早。直接覆盖会把「冻结」换成更糟的「倒退」
  # （倒退会让台账显示一个比真实「最近一次发生」更早的时刻，读者据此判断「很久没出现了」，正好相反）。
  if [ "$verdict" = new ]; then
    jq -n --arg id "$iid" --arg p "$plat" --arg t "$title" --arg l "$latest" \
          --argjson e "$events" --argjson u "$users" --argjson w "$DAYS" --arg ts "$now" \
      '{id:$id, platform:$p, title:$t, events_count_last_seen:$e, users_last_seen:$u,
        latest_event:$l, window_days:$w, source:"bigquery", last_synced:$ts}' > "$f"
  else
    tmp="$(mktemp)"
    jq --argjson e "$events" --argjson u "$users" --arg l "$latest" \
       --argjson w "$DAYS" --arg ts "$now" \
      '.events_count_last_seen=$e | .users_last_seen=$u
       | .latest_event=(if ((.latest_event // "") < $l) then $l else .latest_event end)
       | .window_days=$w | .last_synced=$ts' \
      "$f" > "$tmp" && mv "$tmp" "$f"
  fi
  REC_UPDATED=$((REC_UPDATED+1))
done < <(jq -r '
  (.ios     | map([.id,"ios",     .title, (.events|tostring), (.users|tostring), (.latest // "")] | @tsv) | .[]),
  (.android | map([.id,"android", .title, (.events|tostring), (.users|tostring), (.latest // "")] | @tsv) | .[])
' "$SNAP")

# ⛔ 多字节字符不能紧跟 ${var}：bash 会把全角括号的后续字节并进变量名，
# set -u 下报 `FORCE_REFETCH?: unbound variable`（CLAUDE.md 记过这条，这里又踩了两次）。
# 最省事的解法是这类位置一律用 ASCII 括号，别跟全角字符较劲。
# 措辞区分两件事：「抓取」的三态是判定结果，「记录」是无条件的。
# 旧文案「命中跳过 N」在 bq 路径上会造成歧义——每条记录其实都写了，跳过的只是抓取。
echo "  事实层缓存 · 抓取: 新建 $FETCH_NEW / 增量 $FETCH_APPEND / 跳过 $FETCH_SKIP (FORCE_REFETCH=$FORCE_REFETCH)"
echo "  事实层缓存 · 记录: 更新 $REC_UPDATED 条 (观测字段每轮无条件刷新，window_days=$DAYS)"
echo "  → $SNAP"
