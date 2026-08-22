#!/usr/bin/env bash
# 事实层缓存的**产物断言**（change crash-fact-cache-freshness D6）。
#
# 为什么是产物断言而不是检查 prompt 文本：事实层由两条路径写——确定性 shell（fetch-snapshot-bq.sh）
# 与模型执行的 prompt（fetch-snapshot.sh）。prompt 是自然语言，**措辞一致 ≠ 行为一致**：
# 两份都改对了模型仍可能没照做。唯一可靠的检查是断言**落盘产物**。
#
# 用法：assert-fact-cache.sh [快照 json]（默认取最近一次 L2 跑批的 snapshot.json）
#   对快照里出现的每个 issue 断言：last_synced 是本轮时刻 · window_days 已写入 · latest_event 未倒退。
# 退出码：0 全通过 / 1 有断言失败
set -uo pipefail
STATE="${CRASH_REPORT_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/crash-triage}"
SNAP="${1:-$(ls -t "$STATE"/runs/*/L2/*/snapshot.json 2>/dev/null | head -1)}"
BASE="${FACT_CACHE_BASELINE:-}"          # 可选：跑批前的 issues/ 快照目录，用于验 latest_event 未倒退
[ -s "$SNAP" ] || { echo "❌ 找不到 snapshot.json（传参或先跑一次 L2）" >&2; exit 1; }

TODAY="$(date -u +%Y-%m-%d)"
rc=0; n=0
while IFS= read -r id; do
  [ -n "$id" ] || continue
  f="$STATE/issues/$id.json"
  n=$((n + 1))
  if [ ! -s "$f" ]; then echo "❌ ${id:0:8} 事实层文件缺失"; rc=1; continue; fi

  ls_="$(jq -r '.last_synced // ""' "$f")"
  case "$ls_" in "$TODAY"*) ;; *) echo "❌ ${id:0:8} last_synced=$ls_ 不是本轮（观测字段应无条件刷新）"; rc=1;; esac

  wd="$(jq -r '.window_days // ""' "$f")"
  [ -n "$wd" ] || { echo "❌ ${id:0:8} 缺 window_days（计数无窗口口径则无法解释）"; rc=1; }

  if [ -n "$BASE" ] && [ -s "$BASE/$id.json" ]; then
    o="$(jq -r '.latest_event // ""' "$BASE/$id.json")"; c="$(jq -r '.latest_event // ""' "$f")"
    if [ -n "$o" ] && [[ "$c" < "$o" ]]; then
      echo "❌ ${id:0:8} latest_event 倒退：$o → $c（必须取 max，窗口内 MAX 非单调）"; rc=1
    fi
  fi
done < <(jq -r '(.ios // [])[].id, (.android // [])[].id' "$SNAP" 2>/dev/null)

[ "$n" -gt 0 ] || { echo "❌ 快照里没有 issue，无法断言" >&2; exit 1; }
[ $rc -eq 0 ] && echo "✅ 事实层产物断言通过（$n 个 issue）"
exit $rc
