#!/usr/bin/env bash
# shellcheck disable=SC2034  # SQL_DIR / SQL_DIAG_API_PRED 给 source 进来的库用
# diag_daily_store 的目录写锁（审查 G5：L2 / L1 / 手工回填并发读-改-写会互相覆盖）：
#   无锁正常写并释放｜新鲜锁被占 → 等满 120 次后返回非零且不改文件｜超 10 分钟的残留锁被清掉｜全程不踩 ERR trap。
# ⚠️ 不真等 120 秒：函数里的 `sleep 1` 用同名 shell 函数替身（函数优先于外部命令），只记次数，业务代码不改。
# ⛔ 必须跑在 harness 的生产 shell 设置下；h_run 在当前 shell 调、输出写文件（否则 H_ERR_HIT 传不回来）。
ROOT="${CRASH_REPORT_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}"
. "$ROOT/bin/test/harness.sh"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
STATE="$T"; SQL_DIR="$ROOT/bin/sql"; SQL_DIAG_API_PRED="did = 'api_result'"
. "$ROOT/bin/lib/core/diag.sh"
. "$ROOT/bin/lib/query.sh"
. "$ROOT/bin/lib/diag.sh"

LOCK="$STATE/diag/.daily.lock"
H_ERR_HIT=0   # 每个用例前显式清零（先于首次引用，check-scripts 第 7 项）
mkdir -p "$STATE/diag"
SLEEPS="$T/sleeps"; : > "$SLEEPS"
sleep() { echo "$1" >> "$SLEEPS"; }
NSLEEP() { wc -l < "$SLEEPS" | tr -d ' '; }

SRC="$T/rows.json"
cat > "$SRC" <<'JSON'
[{"d":"2026-11-23","kind":"api","plat":"ios","ver":"2.1.0","s1":"a","s2":"b","devices":"5","users":"4","events":"9"}]
JSON
SRC2="$T/rows2.json"
sed 's/"events":"9"/"events":"77"/' "$SRC" > "$SRC2"

# 照抄调用方的形态：`diag_daily_store … || rc=$?`
_like_caller() { local rc=0; diag_daily_store "$1" 2026-11-23 2026-11-23 >/dev/null || rc=$?; echo "$rc"; }

echo "── 1. 无锁：写入 daily.jsonl 与 coverage，返回 0，锁释放 ──"
h_run _like_caller "$SRC" > "$T/out" 2>/dev/null || true; out="$(cat "$T/out")"
h_assert_eq "0" "$out" "返回 0"
h_assert_eq "0" "$H_ERR_HIT" "⛔ ERR trap 未触发"
h_assert_eq "1" "$(wc -l < "$DIAG_DAILY_FILE" | tr -d ' ')" "daily.jsonl 写入 1 行"
h_assert_eq "9" "$(jq -r '.events' "$DIAG_DAILY_FILE")" "行内容：events=9（字符串已转数字）"
h_assert_eq "true" "$(jq -r 'has("2026-11-23")' "$DIAG_DAILY_COV")" "daily-coverage.json 记了 2026-11-23"
[ -d "$LOCK" ] && _held=yes || _held=no
h_assert_eq "no" "$_held" "锁已释放"
h_assert_eq "0" "$(NSLEEP)" "无锁时不等待"

echo "── 2. 新鲜锁被别人持有：等满 120 次后返回非零，文件不被改写 ──"
cp "$DIAG_DAILY_FILE" "$T/jsonl.before"; cp "$DIAG_DAILY_COV" "$T/cov.before"
: > "$SLEEPS"; mkdir "$LOCK"
H_ERR_HIT=0
h_run _like_caller "$SRC2" > "$T/out" 2>"$T/err" || true; out="$(cat "$T/out")"
h_assert_eq "1" "$out" "返回 1（调用方据此降级）"
h_assert_eq "0" "$H_ERR_HIT" "⛔ ERR trap 未触发"
h_assert_eq "120" "$(NSLEEP)" "恰好等了 120 次（上限）"
h_assert_contains "$(cat "$T/err")" "写锁超时" "stderr 说明超时原因"
cmp -s "$DIAG_DAILY_FILE" "$T/jsonl.before" && _same="same" || _same="diff"
h_assert_eq "same" "$_same" "daily.jsonl 未被改写"
cmp -s "$DIAG_DAILY_COV" "$T/cov.before" && _same="same" || _same="diff"
h_assert_eq "same" "$_same" "daily-coverage.json 未被改写"
[ -d "$LOCK" ] && _held=yes || _held=no
h_assert_eq "yes" "$_held" "别人的锁没被误删"
rmdir "$LOCK"

echo "── 3. 超过 10 分钟的残留锁：被清掉并正常写入 ──"
: > "$SLEEPS"; mkdir "$LOCK"; touch -t 200001010000 "$LOCK"
H_ERR_HIT=0
h_run _like_caller "$SRC2" > "$T/out" 2>/dev/null || true; out="$(cat "$T/out")"
h_assert_eq "0" "$out" "返回 0"
h_assert_eq "0" "$H_ERR_HIT" "⛔ ERR trap 未触发"
h_assert_eq "0" "$(NSLEEP)" "残留锁不等待"
h_assert_eq "77" "$(jq -r '.events' "$DIAG_DAILY_FILE")" "新数据已写入（整段替换）"
[ -d "$LOCK" ] && _held=yes || _held=no
h_assert_eq "no" "$_held" "锁已释放"

h_summary
