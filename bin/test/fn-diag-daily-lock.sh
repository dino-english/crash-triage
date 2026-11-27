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
_like_caller() { local rc=0; diag_daily_store "$1" 2026-11-23 2026-11-23 "${2:-ga4}" >/dev/null || rc=$?; echo "$rc"; }

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

echo "── 4. 两个数据源（design 决策 8）：存时两边原样存、按来源整段替换、各记各的覆盖；读时按平台 × 版本 × 天二选一 ──"
# 起点：上一段留下的一行 GA4（ios 2.1.0，没有 src 字段 = 改动前写入的旧行）
jq -c '. + [{"d":"2026-11-23","kind":"api","plat":"IOS","ver":"2.1.2","s1":"ga4-212","s2":"x","devices":"1","users":"1","events":"1"},
            {"d":"2026-11-23","kind":"api","plat":"ANDROID","ver":"2.2.0","s1":"dev-220","s2":"x","devices":"5","users":"5","events":"5"}]' "$SRC2" > "$T/ga4.json"
H_ERR_HIT=0
h_run _like_caller "$T/ga4.json" ga4 > "$T/out" 2>/dev/null || true
h_assert_eq "0	0" "$(cat "$T/out")	${H_ERR_HIT}" "GA4 写入：返回 0，ERR 未触发"
cat > "$T/ph.json" <<'JSON'
[{"d":"2026-11-23","kind":"api","plat":"IOS","ver":"2.1.2","s1":"ph","s2":"y","devices":7,"users":7,"events":8},
 {"d":"2026-11-23","kind":"api","plat":"ANDROID","ver":"2.2.0","s1":"dev-220","s2":"x","devices":4,"users":4,"events":4}]
JSON
cp "$DIAG_DAILY_COV" "$T/cov-ga4.before"
h_run _like_caller "$T/ph.json" posthog > "$T/out" 2>/dev/null || true
h_assert_eq "0	0" "$(cat "$T/out")	${H_ERR_HIT}" "PostHog 写入：返回 0，ERR 未触发"
h_assert_eq "5" "$(jq -s length "$DIAG_DAILY_FILE")" "存的时候两边原样存（3 行 GA4 + 2 行 PostHog），⛔ 不在存储时丢行"
h_assert_eq "ga4 ga4 ga4 posthog posthog" "$(jq -r .src "$DIAG_DAILY_FILE" | sort | tr '\n' ' ' | sed 's/ $//')" "⛔ PostHog 整段替换没有抹掉 GA4 同一天的行；每行都带 src"
h_assert_eq "true" "$(jq -r 'has("2026-11-23")' "$DIAG_DAILY_COV_PH")" "PostHog 覆盖记在 daily-coverage-posthog.json"
cmp -s "$DIAG_DAILY_COV" "$T/cov-ga4.before" && _same="same" || _same="diff"
h_assert_eq "same" "$_same" "GA4 的覆盖文件不被 PostHog 写入改动"
_picked="$(diag_daily_rows 2026-11-23 2026-11-23)"
h_assert_eq "ph" "$(jq -r '[.[]|select(.ver=="2.1.2")|.s1]|join(",")' <<<"$_picked")" "iOS 2.1.2：PostHog 7 台 > GA4 1 台 → 只留 PostHog"
h_assert_eq "5" "$(jq '[.[]|select(.ver=="2.2.0")|.devices]|add' <<<"$_picked")" \
  "⛔ Android 2.2.0：GA4 5 台 > PostHog 4 台 → 只留 GA4，不相加成 9（审查 #2）；只在 GA4 的开发分支版本不丢（审查 #1）"
h_assert_eq "5" "$(diag_daily_rows 2026-11-23 2026-11-23 raw | jq length)" "raw = 两边原样（断数检测用）"
echo '[]' > "$T/empty.json"
h_run _like_caller "$T/empty.json" ga4 > "$T/out" 2>/dev/null || true
h_assert_eq "posthog" "$(jq -r .src "$DIAG_DAILY_FILE" | sort -u | tr '\n' ' ' | sed 's/ $//')" "GA4 重取为空：只清掉 GA4 的行，PostHog 的行还在"
h_run _like_caller "$T/empty.json" bogus > "$T/out" 2>"$T/err" || true
h_assert_eq "1	0" "$(cat "$T/out")	${H_ERR_HIT}" "未知数据源：返回 1，ERR 未触发"

echo "── 5. 断数检测 diag_daily_gaps：某来源当天 0 行而前 7 天每天都有 → 报出来 ──"
: > "$DIAG_DAILY_FILE"
for k in 1 2 3 4 5 6 7; do
  d="$(_diag_day_add 2026-11-23 "-$k")"
  printf '{"d":"%s","kind":"api","plat":"IOS","ver":"2.1.2","s1":"a","s2":"b","devices":1,"users":1,"events":1,"src":"posthog"}\n{"d":"%s","kind":"api","plat":"IOS","ver":"2.1.1","s1":"a","s2":"b","devices":9,"users":9,"events":9,"src":"ga4"}\n' "$d" "$d" >> "$DIAG_DAILY_FILE"
done
printf '{"d":"2026-11-23","kind":"api","plat":"IOS","ver":"2.1.1","s1":"a","s2":"b","devices":9,"users":9,"events":9,"src":"ga4"}\n' >> "$DIAG_DAILY_FILE"
_gap_like_caller() { local g; g="$(trap - ERR; diag_daily_gaps 2026-11-23 2026-11-23)"; echo "[$g]"; }
H_ERR_HIT=0
h_run _gap_like_caller > "$T/out" 2>/dev/null || true
h_assert_eq "[posthog@2026-11-23]	0" "$(cat "$T/out")	${H_ERR_HIT}" "PostHog 当天 0 行 → 报 posthog@2026-11-23（GA4 有行也盖不住），ERR 未触发"

h_summary
