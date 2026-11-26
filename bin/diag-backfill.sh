#!/usr/bin/env bash
# shellcheck disable=SC2034  # TS / SQL_DIR 由 source 进来的 bq.sh、query.sh 读取
# 技术诊断日聚合的一次性回填（change crash-tech-diagnostics）。
#
# 用法：bash bin/diag-backfill.sh <天数> [--dry-run]
#   回填「昨天（MYT）往前 <天数> 天」到 $STATE/diag/daily.jsonl，一条查询（N 天读 N+1 张表）。
#   --dry-run：只打印 bq 的扫描估算字节数，不执行、不写本地。
#
# ⛔ 大回填执行前**先报 dry-run 字节数给维护者**（生产机 35 天回填由维护者 2026-11-26 批准并已执行，
#    实际计费 47.41 GB；以后换机 / 重建再回填，照样先报字节数、等批准）。日常补缺由 L1 / L2 自己做，不需要跑本脚本。
# ⚠️ 只写 $STATE/diag/daily*.json*，不碰 L0 的小时聚合（L0 首次运行自己回填前 7 天）。
set -euo pipefail
unset PYTHONPATH

N="${1:-}"; MODE="${2:-}"
case "$N" in (''|*[!0-9]*) echo "用法：bash bin/diag-backfill.sh <天数> [--dry-run]" >&2; exit 2 ;; esac
case "$MODE" in (''|--dry-run) ;; (*) echo "未知参数：${MODE}" >&2; exit 2 ;; esac

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="${CRASH_REPORT_ROOT:-$(dirname "$SELF_DIR")}"
STATE="${CRASH_REPORT_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/crash-triage}"
# shellcheck disable=SC1091
[ -f "$STATE/path.env" ] && . "$STATE/path.env"
export PATH
TS="$(date +%Y%m%d-%H%M%S)"
SQL_DIR="$ROOT/bin/sql"
# shellcheck disable=SC1091
. "$ROOT/bin/lib.sh"
# shellcheck disable=SC1091
. "$ROOT/bin/lib/bq.sh" || exit 1
# shellcheck disable=SC1091
. "$ROOT/bin/lib/query.sh"
# shellcheck disable=SC1091
. "$ROOT/bin/lib/core/diag.sh"
# shellcheck disable=SC1091
. "$ROOT/bin/lib/diag.sh"
bq_init
trap 'rm -f "$BQ_SQLTMP"' EXIT

TO="$(TZ=Asia/Kuala_Lumpur date -v-1d +%Y-%m-%d)"
FROM="$(_diag_day_add "$TO" "-$((N - 1))")"
echo "技术诊断日聚合回填：${FROM} ～ ${TO}（${N} 天）→ ${DIAG_DAILY_FILE}"
if [ "$MODE" = --dry-run ]; then
  BQ_DRY_RUN=1 diag_daily_fetch "$FROM" "$TO" 200000000000
else
  # 计费上限 200 GB：防的是 SQL 写错扫全库，不是这次回填本身（35 天约 47.4 GB，2026-11-26 实测）
  diag_daily_fetch "$FROM" "$TO" 200000000000
fi
