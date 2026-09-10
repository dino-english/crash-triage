#!/usr/bin/env bash
# 事实层缓存的**产物断言**（change crash-fact-cache-freshness D6）。
#
# 为什么是产物断言而不是检查 prompt 文本：事实层由两条路径写——确定性 shell（fetch-snapshot-bq.sh）
# 与模型执行的 prompt（fetch-snapshot.sh）。prompt 是自然语言，**措辞一致 ≠ 行为一致**：
# 两份都改对了模型仍可能没照做。唯一可靠的检查是断言**落盘产物**。
#
# 用法：assert-fact-cache.sh [快照 json]（默认取最近一次 L2 跑批的 snapshot.json）
#   对快照里出现的每个 issue 断言：文件是合法 JSON · last_synced 是本轮时刻 · window_days 已写入 · latest_event 未倒退。
# 退出码：0 全通过 / 1 有断言失败
set -uo pipefail
_FC_SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
. "$_FC_SELF/../lib/factcache.sh" || { echo "❌ 缺失：bin/lib/factcache.sh" >&2; exit 1; }
STATE="${CRASH_REPORT_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/crash-triage}"
SNAP="${1:-$(ls -t "$STATE"/runs/*/L2/*/snapshot.json 2>/dev/null | head -1)}"
BASE="${FACT_CACHE_BASELINE:-}"          # 可选：跑批前的 issues/ 快照目录，用于验 latest_event 未倒退
[ -s "$SNAP" ] || { echo "❌ 找不到 snapshot.json（传参或先跑一次 L2）" >&2; exit 1; }

# ⛔ 判定的是**时刻**不是日期（change crash-fact-cache-deterministic-records D4）。
# 原实现比 `date -u +%Y-%m-%d` 的日期前缀，粒度是天且基准是 UTC 日期。2026-09-08 夹具实测
# 三种情形，它把「本地时间标 Z」（快 8 小时）的记录**在 L1 场景判成通过**、在 L2 场景
# （本地 05:30 = UTC 前一天）把**已正确刷新**的记录判成陈旧——同一个缺陷两种相反表现。
NOW_EP="$(date -u +%s)"
TOL="${FACT_CACHE_TOLERANCE_SEC:-1800}"   # 容差取一轮跑批的最长时长（L1/L2 实测均 ~8 分钟）

# ⚠️ macOS 与 Linux 的 date 解析参数不同，两种都试；都失败则输出空串由调用处报错。
_fc_epoch() { # $1=ISO8601 Z → epoch 秒
  date -u -j -f "%Y-%m-%dT%H:%M:%SZ" "$1" +%s 2>/dev/null && return 0
  date -u -d "$1" +%s 2>/dev/null && return 0
  printf ''
}

rc=0; n=0
CLAIMED=0; STORED=0; OWED=0; UNFETCHABLE=0
# 窗口起点：区分「还没抓」与「抓不到」（findings F-1/F-2）。⚠️ 7 天与 prompt 里的窗口一致。
FC_CUT="$(fc_cutoff_date "${FACT_CACHE_WINDOW_DAYS:-7}")"
while IFS= read -r id; do
  [ -n "$id" ] || continue
  f="$STATE/issues/$id.json"
  n=$((n + 1))
  if [ ! -s "$f" ]; then echo "❌ ${id:0:8} 事实层文件缺失"; rc=1; continue; fi
  # 合法性先于语义：文件解析不了时下面每一条 jq 都返回空串，断言会**静默全过**——
  # 2026-08-21 那 12 个非法 JSON 就是这样绕过本脚本、一路坏到反扫失败的。
  if ! jq empty "$f" 2>/dev/null; then
    echo "❌ ${id:0:8} 事实层文件不是合法 JSON（下游 jq 全线静默降级，见 fetch-snapshot.sh 落盘校验）"
    rc=1; continue
  fi

  # 内容覆盖率的两个累加项（非判定，只输出——理由见 D5：当前基线下任何阈值都会全红）
  CLAIMED=$((CLAIMED + $(jq -r '(.events_count_last_seen // 0) | tonumber? // 0' "$f")))
  _st="$(jq -r '(.events // []) | length' "$f")"
  STORED=$((STORED + _st))
  # 欠账 = 计数为正而一条事件都没有（change crash-fact-cache-events-backfill）。
  # 逐轮看这个数在不在降，是「补抓有没有真在收敛」的唯一判据。
  if [ "$_st" -eq 0 ] && [ "$(jq -r '(.events_count_last_seen // 0) | tonumber? // 0' "$f")" -gt 0 ]; then
    # ⛔ 两类必须分开报：「还没抓」会收敛，「抓不到」（事件已出窗）不会。
    #    混成一个数当收敛判据永远不达标，而看数的人会以为补抓坏了（findings F-2）。
    if fc_unfetchable "$f" "$FC_CUT"; then UNFETCHABLE=$((UNFETCHABLE + 1)); else OWED=$((OWED + 1)); fi
  fi

  ls_="$(jq -r '.last_synced // ""' "$f")"
  ep="$(_fc_epoch "$ls_")"
  if [ -z "$ep" ]; then
    echo "❌ ${id:0:8} last_synced=$ls_ 解析不出时刻（应为 UTC ISO8601，形如 2026-09-08T00:30:12Z）"; rc=1
  else
    age=$((NOW_EP - ep))
    # ⚠️ 取绝对值：**未来时刻同样是错的**。「本地时间标 Z」正是快 8 小时的未来时刻，
    #    只判「太旧」会把它放过去——那恰恰是 2026-09-08 之前 L1 一直在发生的事。
    if [ "$age" -lt 0 ]; then age=$((0 - age)); fi
    if [ "$age" -gt "$TOL" ]; then
      echo "❌ ${id:0:8} last_synced=$ls_ 不是本轮（相差 ${age}s，容差 ${TOL}s；观测字段应无条件刷新）"; rc=1
    fi
  fi

  wd="$(jq -r '.window_days // ""' "$f")"
  [ -n "$wd" ] || { echo "❌ ${id:0:8} 缺 window_days（计数无窗口口径则无法解释）"; rc=1; }

  if [ -n "$BASE" ] && [ -s "$BASE/$id.json" ]; then
    o="$(jq -r '.latest_event // ""' "$BASE/$id.json")"; c="$(jq -r '.latest_event // ""' "$f")"
    if [ -n "$o" ] && [[ "$c" < "$o" ]]; then
      echo "❌ ${id:0:8} latest_event 倒退：$o → ${c}（必须取 max，窗口内 MAX 非单调）"; rc=1
    fi
  fi
done < <(jq -r '(.ios // [])[].id, (.android // [])[].id' "$SNAP" 2>/dev/null)

[ "$n" -gt 0 ] || { echo "❌ 快照里没有 issue，无法断言" >&2; exit 1; }
# ⛔ 非判定项：不改 rc。观测字段刷新与事件明细落盘是两件事，前者正常**不蕴含**后者正常——
# 2026-09-08 实测存在「声称 55 条、实存 6 条」而断言全绿的状态。先让它可见，攒够几轮再定阈值
# （现在设阈值会一次性全红，把要长期看的指标变成噪音，F30 那一类）。
# ⚠️ 两个量**口径不同**，不是一个比值：窗口计数是滚动窗口内的 COUNT（非单调），
#    events 是累积数组（只 append）。攒久了 M > N 是**正常**的（2026-09-08 开发机实测
#    110 vs 29）；有意义的信号只有一个方向——M 远小于 N 说明有事件从没被抓下来
#    （同日生产机实测 6 vs 55）。⛔ 别把它读成百分比。
echo "ℹ️ 事件数对照：本轮窗口计数合计 ${CLAIMED} · 已存累积事件 ${STORED} 条 · 待补 ${OWED} 个 · 不可补 ${UNFETCHABLE} 个（事件已出窗）· ${n} 个 issue"

[ $rc -eq 0 ] && echo "✅ 事实层产物断言通过（$n 个 issue）"
exit $rc
