#!/usr/bin/env bash
# shellcheck disable=SC2034  # SQL_DIR / x 给 source 进来的库与对照写法用
# 技术诊断日聚合取数失败只降级、不触发 ERR trap（change crash-tech-diagnostics，tasks 8.5 审查 S1）。
#
# 起因：errtrace 下 `$( )` 子 shell 继承 ERR trap，外层 `|| rc=$?` / `if` 都接不住——
# L1 / L2 这一节取数失败本该只降级成「取数失败」，却会在子 shell 里触发 on_err，
# 往日报告警目标（生产机即正式群）发一张「L1 日报失败」的假故障卡。bash 3.2 实测复现。
# ⛔ 本夹具必须跑在 harness 的生产 shell 设置下（set -euo pipefail + errtrace + ERR trap），否则测不出来。
ROOT="${CRASH_REPORT_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}"
. "$ROOT/bin/test/harness.sh"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
STATE="$T"; SQL_DIR="$ROOT/bin/sql"; SQL_DIAG_API_PRED="did = 'api_result'"
. "$ROOT/bin/lib/core/diag.sh"
. "$ROOT/bin/lib/query.sh"
. "$ROOT/bin/lib/diag.sh"
H_ERR_HIT=0   # 先于首次引用（check-scripts 第 7 项）

# ⚠️ h_run 必须在当前 shell 里调、输出写文件：写成 out="$(h_run …)" 时 h_run 跑在子 shell 里，
#    它记下的 H_ERR_HIT 传不回来，「ERR 未触发」的断言永远通过（本夹具初版就这么错过，双向测试抓到）。
# 照抄 L1 / L2 的调用形态：`diag_daily_ensure … || _drc=$?`——ERR 只可能来自函数内部
_like_l1() { local _drc=0; diag_daily_ensure 2026-11-23 7 1000 || _drc=$?; echo "$_drc"; }

echo "── bq 失败：返回非零、不触发 ERR trap ──"
bqq() { return 2; }
h_run _like_l1 > "$T/out" 2>/dev/null || true; out="$(cat "$T/out")"
h_assert_eq "1" "$out" "diag_daily_ensure 返回 1（调用方据此降级）"
h_assert_eq "0" "$H_ERR_HIT" "⛔ ERR trap 未触发（触发 = 生产里一张假故障卡）"

echo "── 回归对照：旧写法（\$( ) 里不清 trap）必然触发 ──"
# 不走 h_run（那会把这次故意的触发记成失败）：自己在生产 shell 设置下跑，捕获 trap 打到 stderr 的标记
_old() { local x rc=0; x="$(bqq csv x)" || rc=$?; echo "$rc"; }
bqq() { return 2; }
_ctl="$( { set -euo pipefail; set -o errtrace; trap 'echo __OLD_ERR__ >&2' ERR; _old; } 2>&1 >/dev/null || true )"
h_assert_contains "$_ctl" "__OLD_ERR__" "旧写法确实触发 ERR trap——证明本夹具测得出这类问题"

echo "── 表不存在：同样只返回非零 ──"
bqq() { echo "table_id"; }
h_run _like_l1 > "$T/out" 2>/dev/null || true; out="$(cat "$T/out")"
h_assert_eq "1	0" "${out}	${H_ERR_HIT}" "返回 1，ERR trap 未触发"

echo "── GA4 成功、PostHog 失败：整节降级（⛔ 不拿一半数据冒充全量），不触发 ERR trap ──"
# GA4 桩：表都在、查询回空
bqq() { if [ "$1" = csv ]; then echo "table_id"; for d in 15 16 17 18 19 20 21 22 23; do echo "events_202611$d"; done; else echo '[]'; fi; }
mkdir -p "$T/bin"; printf '#!/usr/bin/env bash\nexec python3 %q "$@"\n' "$ROOT/bin/test/fake-posthog-curl.py" > "$T/bin/curl"; chmod +x "$T/bin/curl"
PATH="$T/bin:$PATH"; export FAKE_DIR="$T"
unset CRASH_REPORT_POSTHOG_API_KEY
H_ERR_HIT=0
h_run _like_l1 > "$T/out" 2>"$T/err" || true; out="$(tail -1 "$T/out")"   # 前面是进度行
h_assert_eq "1	0" "${out}	${H_ERR_HIT}" "未配置 PostHog key：返回 1，ERR trap 未触发"
h_assert_contains "$(cat "$T/err")" "未配置 CRASH_REPORT_POSTHOG_API_KEY" "stderr 写明缺 key"
export CRASH_REPORT_POSTHOG_API_KEY=phx_fixture
H_ERR_HIT=0
FAKE_PH_FAIL=1 h_run _like_l1 > "$T/out" 2>"$T/err" || true; out="$(tail -1 "$T/out")"   # 前面是进度行
h_assert_eq "1	0" "${out}	${H_ERR_HIT}" "PostHog 请求失败：返回 1，ERR trap 未触发"
h_assert_contains "$(cat "$T/err")" "PostHog 日聚合查询失败" "stderr 写明是 PostHog 一侧"
echo "── 两边都成功：返回 0；PostHog 一侧首次补满回看窗口 ──"
H_ERR_HIT=0
: > "$T/ph.bodies"
h_run _like_l1 > "$T/out" 2>"$T/err" || true; out="$(tail -1 "$T/out")"   # 前面是进度行
h_assert_eq "0	0" "${out}	${H_ERR_HIT}" "返回 0，ERR trap 未触发"
h_assert_eq "8" "$(jq 'length' "$DIAG_DAILY_COV_PH")" "PostHog 覆盖记满当日 + 前 7 天"
h_assert_eq "2" "$(grep -c '"t0"' "$T/ph.bodies" | tr -d ' ')" "PostHog 只发 2 次（当日 1 次 + 回看窗口一次补齐）"

h_summary
