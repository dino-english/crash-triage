#!/usr/bin/env bash
# shellcheck disable=SC2034  # SQL_DIR 给 source 进来的 query.sh 用
# ph_query（bin/lib/posthog.sh）的函数级夹具（change crash-tech-diagnostics「PostHog 双源」）：
#   正常回包 → 行对象｜未配置 key / curl 失败 / HTTP 错误 / 回满 50000 行 → 只返回非零、写明原因、不踩 ERR trap｜
#   ⛔ key 不上命令行（ps 看得见）｜⛔ 来自数据的值走 values、不拼进查询文本｜缓存目录冻结回包。
# ⛔ 必须跑在 harness 的生产 shell 设置下；h_run 在当前 shell 调、输出写文件（否则 H_ERR_HIT 传不回来）。
# curl 换成 bin/test/fake-posthog-curl.py，零真实请求。
ROOT="${CRASH_REPORT_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}"
. "$ROOT/bin/test/harness.sh"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin" "$T/fx"
printf '#!/usr/bin/env bash\nexec python3 %q "$@"\n' "$ROOT/bin/test/fake-posthog-curl.py" > "$T/bin/curl"
chmod +x "$T/bin/curl"
PATH="$T/bin:$PATH"; export FAKE_DIR="$T"
SQL_DIR="$ROOT/bin/sql"
. "$ROOT/bin/lib/query.sh"
. "$ROOT/bin/lib/posthog.sh"
unset CRASH_REPORT_BQ_CACHE FAKE_PH_FAIL FAKE_PH_HTTP FAKE_PH_ROWS
H_ERR_HIT=0   # 先于首次引用（check-scripts 第 7 项）
KEY="phx_fixture_SECRET_123"

cat > "$T/fx/ph-hourly.json" <<'JSON'
[{"h":"2026-11-26 08","plat":"IOS","ver":"2.1.2","target":"/a","code":"http_401","devices":3,"users":2,"events":5},
 {"h":"2026-11-27 08","plat":"IOS","ver":"2.1.2","target":"/a","code":"http_401","devices":9,"users":9,"events":9}]
JSON
cat > "$T/fx/ph-breakdown.json" <<'JSON'
[{"dim":"geo","sig":"/a × http_401","k1":"IOS","k2":"","k3":"2.1.2","devices":3,"affected":3}]
JSON
echo '{"t0":"2026-11-26 00:00:00","t1":"2026-11-27 00:00:00"}' > "$T/v-day.json"

# 照抄调用方的形态：`ph_query … || rc=$?`
_like_caller() { local rc=0; ph_query "$1" "$2" "$T/out.json" || rc=$?; echo "$rc"; }

echo "── 1. 正常：回包转成行对象，只回 values 窗口内的行 ──"
export CRASH_REPORT_POSTHOG_API_KEY="$KEY"
h_run _like_caller diag-hourly.hogql "$T/v-day.json" > "$T/rc" 2>"$T/err" || true
h_assert_eq "0" "$(cat "$T/rc")" "返回 0"
h_assert_eq "0" "$H_ERR_HIT" "⛔ ERR trap 未触发"
h_assert_eq '[{"h":"2026-11-26 08","plat":"IOS","ver":"2.1.2","target":"/a","code":"http_401","devices":3,"users":2,"events":5}]' \
  "$(cat "$T/out.json")" "列名 × 行 → 对象数组"
h_assert_absent "$(cat "$T/curl.argv")" "$KEY" "⛔ key 不在 curl 命令行上（ps 看得见）"
h_assert_contains "$(cat "$T/curl.stdin")" "Authorization: Bearer $KEY" "key 经 -K - 从 stdin 传"
h_assert_eq "force_blocking" "$(tail -1 "$T/ph.bodies" | jq -r .refresh)" "⛔ 不走 PostHog 查询缓存（当天要重取）"
h_assert_absent "$(tail -1 "$T/ph.bodies" | jq -r .query.query)" "{{" "模板占位全部替换"
h_assert_contains "$(tail -1 "$T/ph.bodies" | jq -r .query.query)" "match(code, '^http_2\\\\d\\\\d\$')" \
  "接口类谓词按 HogQL 字符串转义渲染（\\\\d 到 PostHog 是正则 \\d）"

echo "── 2. 来自数据的签名只走 values，不拼进查询文本 ──"
jq -n '{t0:"2026-11-26 00:00:00", t1:"2026-11-26 01:00:00", sigs:["/a × http_401", "x'"'"' OR 1=1 --"]}' > "$T/v-sig.json"
h_run _like_caller diag-breakdown.hogql "$T/v-sig.json" > "$T/rc" 2>/dev/null || true
h_assert_eq "0	0" "$(cat "$T/rc")	${H_ERR_HIT}" "返回 0，ERR 未触发"
h_assert_absent "$(tail -1 "$T/ph.bodies" | jq -r .query.query)" "OR 1=1" "⛔ 签名不出现在查询文本里"
h_assert_eq "2" "$(tail -1 "$T/ph.bodies" | jq '.query.values.sigs | length')" "签名原样在 values 里"
h_assert_eq "1" "$(jq length "$T/out.json")" "回放出 1 行分布"

echo "── 3. 失败一律只返回非零、写明原因、不踩 ERR trap ──"
unset CRASH_REPORT_POSTHOG_API_KEY
H_ERR_HIT=0; : > "$T/curl.argv"
h_run _like_caller diag-hourly.hogql "$T/v-day.json" > "$T/rc" 2>"$T/err" || true
h_assert_eq "1	0" "$(cat "$T/rc")	${H_ERR_HIT}" "未配置 key：返回 1，ERR 未触发"
h_assert_contains "$(cat "$T/err")" "未配置 CRASH_REPORT_POSTHOG_API_KEY" "写明缺 key"
h_assert_eq "0" "$(wc -l < "$T/curl.argv" | tr -d ' ')" "没有 key 就不发请求"
export CRASH_REPORT_POSTHOG_API_KEY="$KEY"
for case in "FAKE_PH_FAIL=1|请求失败（curl rc=7" "FAKE_PH_HTTP=400|HTTP 400，模板 diag-hourly.hogql）：fake bad query" "FAKE_PH_ROWS=50000|可能被截断"; do
  envv="${case%%|*}"; want="${case#*|}"
  H_ERR_HIT=0; rm -f "$T/out.json"
  export "${envv?}"
  h_run _like_caller diag-hourly.hogql "$T/v-day.json" > "$T/rc" 2>"$T/err" || true
  unset "${envv%%=*}"
  h_assert_eq "1	0" "$(cat "$T/rc")	${H_ERR_HIT}" "${envv}：返回 1，ERR 未触发"
  h_assert_contains "$(cat "$T/err")" "$want" "${envv}：stderr 写明原因"
  h_assert_eq "absent" "$([ -e "$T/out.json" ] && echo present || echo absent)" "${envv}：不留半份输出"
done
H_ERR_HIT=0
FAKE_PH_ROWS=49999 h_run _like_caller diag-hourly.hogql "$T/v-day.json" > "$T/rc" 2>/dev/null || true
h_assert_eq "0" "$(cat "$T/rc")" "反向：49999 行不算截断（判据卡在 50000，不是过严）"

echo "── 3b. 成败都留审计事件（同 bqq 的 bq.call；只成功时记 = 失败只在 stderr 里留痕）──"
audit() { printf '%s\t%s\n' "$1" "$3" >> "$T/audit.log"; }
: > "$T/audit.log"
FAKE_PH_HTTP=400 h_run _like_caller diag-hourly.hogql "$T/v-day.json" > /dev/null 2>&1 || true
h_run _like_caller diag-hourly.hogql "$T/v-day.json" > /dev/null 2>&1 || true
h_assert_eq "false http_400
true " "$(cut -f2 "$T/audit.log" | jq -r '"\(.ok) \(.why)"')" "失败一条 ok:false why=http_400，成功一条 ok:true"
h_assert_absent "$(cat "$T/audit.log")" "$KEY" "⛔ 审计里没有 key"
unset -f audit

echo "── 4. 回归对照：命令替换里不清 ERR trap 的旧写法，curl 失败必然触发 ──"
# 不走 h_run（那会把这次故意的触发记成失败）：自己在生产 shell 设置下跑，捕获 trap 打到 stderr 的标记
_old() { local x rc=0; x="$(curl -sS -o "$T/o" --data-binary @"$T/v-day.json")" || rc=$?; echo "$rc"; }
_ctl="$( { set -euo pipefail; set -o errtrace; trap 'echo __OLD_ERR__ >&2' ERR; FAKE_PH_FAIL=1 _old; } 2>&1 >/dev/null || true )"
h_assert_contains "$_ctl" "__OLD_ERR__" "旧写法确实触发 ERR trap——证明本夹具测得出这类问题"

echo "── 5. 冻结缓存（CRASH_REPORT_BQ_CACHE）：第二次不发请求，回包相同 ──"
mkdir -p "$T/cache"; export CRASH_REPORT_BQ_CACHE="$T/cache"
: > "$T/curl.argv"
h_run _like_caller diag-hourly.hogql "$T/v-day.json" > /dev/null 2>&1 || true; cp "$T/out.json" "$T/out1.json"
h_run _like_caller diag-hourly.hogql "$T/v-day.json" > /dev/null 2>&1 || true
h_assert_eq "1" "$(wc -l < "$T/curl.argv" | tr -d ' ')" "两次查询只发 1 次请求"
cmp -s "$T/out.json" "$T/out1.json" && _same="same" || _same="diff"
h_assert_eq "same" "$_same" "缓存回包与首次相同"
h_assert_absent "$(cat "$T"/cache/ph-*.json)" "$KEY" "⛔ 缓存文件里没有 key"
unset CRASH_REPORT_BQ_CACHE

h_summary
