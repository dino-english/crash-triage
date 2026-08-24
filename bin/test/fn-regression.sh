#!/usr/bin/env bash
# 本轮新增/改动函数的回归用例，全部跑在生产 shell 设置下（bin/test/harness.sh）。
# ⛔ 每条用例的价值在于「它对应一个真发生过的 bug」——见 docs/CLAUDE-失效模式登记.md。
set -uo pipefail
SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; ROOT="$(cd "$SELF/../.." && pwd)"
. "$SELF/harness.sh"
export SQL_DIR="$ROOT/bin/sql"
. "$ROOT/bin/lib.sh"; . "$ROOT/bin/lib/csv.sh"; . "$ROOT/bin/lib/bq.sh"; . "$ROOT/bin/lib/query.sh"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT

echo "── q_render（F31：grep 无匹配返回 1 触发 ERR trap）──"
h_assert_silent q_render crash-rate.sql TABLE=T SESSIONS_TABLE=S DAYS=7 VERSIONS="'v'"
h_assert_rc 1 q_render crash-rate.sql TABLE=T DAYS=7           # 漏传必须失败
h_assert_silent q_render latest-versions.sql TABLE=T DAYS=7 MIN_SESSIONS=5   # F30：多传不得报警

echo "── csv2tsv（F1/F2：Apple 机型自带逗号）──"
out="$(h_run csv2tsv <<< '"Apple iPad7,11",1,1,0,,1.0')"
h_assert_contains "$out" 'Apple iPad7,11' '含逗号机型不被切断'
h_assert_absent  "$out" '"Apple iPad7'    '不产生嵌套引号残片'

echo "── dd_block（下钻表 + 机型三分支）──"
h_load "$ROOT/bin/crash-weekly.sh" dd_block
DD_MODEL_CONC_PCT=60
printf 'aaaa000011112222,T,sub,screen,ChatActivity,6,1,1,6,1\naaaa000011112222,T,sub,model,Pixel 8 Pro,6,1,1,6,1\n' > "$T/one.csv"
out="$(h_run dd_block "$T/one.csv" Android '口径' 1)"
h_assert_contains "$out" '| Issue | 场景 |' '渲染为表格而非列表'
h_assert_contains "$out" '单台设备'          '单设备不谎称机型特异性'
h_assert_absent  "$out" '%%'                'awk 拼接不残留 %%（F28）'
out="$(h_run dd_block "$T/empty.csv" iOS '口径' 0)"
h_assert_contains "$out" '取数失败'          '取数失败与「无 issue」可区分'
out="$(h_run dd_block "$T/empty.csv" iOS '口径' 1)"
h_assert_contains "$out" '无可下钻'          '真无 issue 时说无 issue'

echo "── dim_table_nd（无分母维度，bash glob 无匹配路径）──"
h_load "$ROOT/bin/crash-weekly.sh" dim_table_nd
OUT_DIR="$T"
out="$(h_run dim_table_nd screen '页面' '**页面**')"
h_assert_contains "$out" '无数据' '无 CSV 时降级不报错'
printf 'MainActivity,30,25,1.2\n(未知),7,7,1.0\n' > "$T/dim-screen-Android-1.5.3.csv"
out="$(h_run dim_table_nd screen '页面' '**页面**')"
h_assert_contains "$out" '| Android | 1.5.3 | MainActivity |' '有数据时出表'
h_assert_contains "$out" '(未知)' '未知桶不被丢弃（F/G9）'

echo "── 分析层失败原因识别（F32：不得把 529 说成额度问题）──"
acls() { # $1=日志内容 $2=退出码 → 只回原因
  local d; d="$(mktemp -d)"; mkdir -p "$d/analysis"
  [ -n "$1" ] && printf '%s\n' "$1" > "$d/analysis/agent-1.log"
  OUT_DIR="$d" TRIAGE_RC="$2" bash -c '
    _alog="$OUT_DIR/analysis/agent"
    _atxt="$(cat "${_alog}"*.log 2>/dev/null | tail -c 8000 || true)"
    _acode="$(printf "%s" "$_atxt" | grep -oE "API Error: [0-9]{3}" | grep -oE "[0-9]{3}" | tail -1 || true)"
    case "${_acode:-}" in
      (429) printf "额度耗尽" ;; (529) printf "服务端过载" ;;
      (5??) printf "服务端错误" ;; (4??) printf "请求被拒" ;;
      (*)   printf "未识别" ;;
    esac'
  rm -rf "$d"
}
h_assert_contains "$(acls 'API Error: 529 Overloaded' 1)" '服务端过载' '529 不被说成额度问题'
h_assert_contains "$(acls 'API Error: 429 rate limit' 1)" '额度耗尽'   '429 正确识别为额度'
h_assert_contains "$(acls 'random failure' 7)"           '未识别'     '⛔ 无错误码时明说未识别'
h_assert_contains "$(acls '' 9)"                          '未识别'     '⛔ 日志缺失时不谎称原因'

h_summary
