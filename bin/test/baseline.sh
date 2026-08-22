#!/usr/bin/env bash
# 等价性基线：快照回滚协议（change crash-perf-functional-core，design D7）。
#
#   备份 $STATE 基准文件 → 跑批 → 收集三层产物并归一化 → **从备份还原基准文件**
#
# ⛔ 还原这一步不可省，两个理由都是实测踩出来的：
#   ① `crash-weekly.sh` 的基线提升（cp SNAP_NEW → SNAP_LAST）在 NO_DELIVER 闸门**之前**，
#      不还原则第二次跑批看到零变化 —— L2 的等价性验收全是假阳性。
#   ② `issues/` 事实层缓存每次跑批都写，不还原则第二次跑批缓存已热
#      （新建/增量 → 跳过），两次走的是**不同代码分支**。
#
# 用法：baseline.sh <L1|L2> <输出目录> [额外环境变量...]
#   例：baseline.sh L1 "$STATE/backup/baseline-l1-cold"
#       CRASH_REPORT_SKIP_ANALYSIS=1 baseline.sh L2 "$STATE/backup/baseline-l2-cold"
set -uo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SELF_DIR/../.." && pwd)"
# shellcheck disable=SC1091
. "$SELF_DIR/artifacts.sh"

LVL="${1:?用法：baseline.sh <L1|L2> <输出目录>}"
OUT="${2:?缺少输出目录}"
case "$LVL" in L1) SCRIPT=crash-daily.sh;; L2) SCRIPT=crash-weekly.sh;; *) echo "❌ LVL 只能是 L1 / L2" >&2; exit 1;; esac

SNAP_DIR="$(mktemp -d)"
restore() {
  local n=0
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    if [ -e "$SNAP_DIR/$f" ]; then cp -p "$SNAP_DIR/$f" "$STATE/$f"; n=$((n+1))
    elif [ -e "$STATE/$f" ]; then rm -f "$STATE/$f"; n=$((n+1)); fi   # 跑批新建的也要还原（删掉）
  done < <(artifacts_baseline_files)
  while IFS= read -r d; do
    [ -n "$d" ] || continue
    [ -d "$SNAP_DIR/$d" ] || continue
    rm -rf "$STATE/$d"; cp -Rp "$SNAP_DIR/$d" "$STATE/$d"; n=$((n+1))
  done < <(artifacts_baseline_dirs)
  echo "  ↩︎ 已还原 $n 项基准" >&2
}
# BASELINE_KEEP_STATE=1：跑完**不还原**，供「冷热两组连跑」——
# 组 A 跑完把状态留给组 B（此时缓存已热），组 B 结束后由调用方统一还原。
if [ "${BASELINE_KEEP_STATE:-0}" = 1 ]; then
  trap 'rm -rf "$SNAP_DIR"' EXIT
else
  trap 'restore; rm -rf "$SNAP_DIR"' EXIT
fi

# ── 1. 备份 ──
while IFS= read -r f; do [ -n "$f" ] && [ -e "$STATE/$f" ] && cp -p "$STATE/$f" "$SNAP_DIR/$f"; done < <(artifacts_baseline_files)
while IFS= read -r d; do [ -n "$d" ] && [ -d "$STATE/$d" ] && cp -Rp "$STATE/$d" "$SNAP_DIR/$d"; done < <(artifacts_baseline_dirs)
echo "  📦 已备份基准到临时目录" >&2

# ── 2. 跑批 ──
echo "  ▶︎ 跑批 ${SCRIPT}（NO_DELIVER）" >&2
CRASH_REPORT_NO_DELIVER=1 CRASH_REPORT_BQ_CACHE="${BASELINE_BQ_CACHE:-}" bash "$ROOT/bin/$SCRIPT" >"$SNAP_DIR/run.log" 2>&1
RC=$?
[ "$RC" -eq 0 ] || { echo "  ❌ 跑批失败 rc=${RC}，日志见 $OUT/run.log" >&2; mkdir -p "$OUT"; cp "$SNAP_DIR/run.log" "$OUT/"; exit "$RC"; }

# ── 3. 收集三层产物（归一化后）──
rm -rf "$OUT"; mkdir -p "$OUT"/{intermediate,publish,baseline}
RUN_DIR="$(artifacts_run_dir "$LVL")"
if [ -n "$RUN_DIR" ]; then
  for f in "$RUN_DIR"/*.json "$RUN_DIR"/*.csv; do
    [ -e "$f" ] || continue
    bash "$SELF_DIR/normalize.sh" "$f" > "$OUT/intermediate/$(basename "$f")"
  done
fi
find "$STATE/publish" -type f 2>/dev/null | while IFS= read -r f; do
  rel="${f#"$STATE/publish/"}"; mkdir -p "$OUT/publish/$(dirname "$rel")"
  bash "$SELF_DIR/normalize.sh" "$f" > "$OUT/publish/$rel"
done
while IFS= read -r f; do
  [ -n "$f" ] && [ -e "$STATE/$f" ] && bash "$SELF_DIR/normalize.sh" "$STATE/$f" > "$OUT/baseline/$f"
done < <(artifacts_baseline_files)
while IFS= read -r d; do
  [ -n "$d" ] && [ -d "$STATE/$d" ] || continue
  find "$STATE/$d" -type f | while IFS= read -r f; do
    rel="${f#"$STATE/"}"; mkdir -p "$OUT/baseline/$(dirname "$rel")"
    bash "$SELF_DIR/normalize.sh" "$f" > "$OUT/baseline/$rel"
  done
done < <(artifacts_baseline_dirs)
cp "$SNAP_DIR/run.log" "$OUT/"

echo "  ✅ 三层产物已收集：${OUT}（中间 $(ls "$OUT/intermediate" 2>/dev/null | wc -l | tr -d ' ') · 投递 $(find "$OUT/publish" -type f 2>/dev/null | wc -l | tr -d ' ') · 基准 $(find "$OUT/baseline" -type f 2>/dev/null | wc -l | tr -d ' ')）" >&2
