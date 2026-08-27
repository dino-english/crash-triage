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


echo "── 第 3 态细分（C 组：⛔ 0 不得被当成缺失）──"
h_load "$ROOT/bin/crash-daily.sh" hist_lookup hist_perf_last_day perf_eta_of state_text_perf state_text
PERF_HIST_KEYS='["start_p50_1d","start_p95_1d","slow_pct_1d","frozen_pct_1d","net_err_pct_1d"]'
CELL_BREVITY=0
IOS_PERF_TAIL=""; AND_PERF_TAIL=""; DAY="2026-08-27"
. "$ROOT/bin/lib/core/format.sh"   # ⛔ 用真的 day_shift，夹具里造个假的等于没测

# ① 全 null：这版从没产出过性能数据 → 不能说「本轮未取到」
HIST_ARR='[{"day":"2026-08-25","ios":{"1.5.5":{"start_p50_1d":null,"start_p95_1d":null,"slow_pct_1d":null,"frozen_pct_1d":null,"net_err_pct_1d":null}}}]'
h_assert_eq "" "$(h_run hist_perf_last_day ios 1.5.5)" '全 null → 无「最后有值日」'
out="$(h_run state_text_perf no_version ios 1.5.5 '2026-08-26 06:59 UTC')"
h_assert_absent "$out" '本轮未取到' '⛔ 从没有过数据的版本不得报成「本轮未取到」'

# ② 历史有值、本轮 null → 必须报「本轮未取到」且**必须带日期**（design D7）
HIST_ARR='[{"day":"2026-08-24","ios":{"1.5.4":{"start_p50_1d":"281.0","start_p95_1d":"1038.0","slow_pct_1d":null,"frozen_pct_1d":null,"net_err_pct_1d":null}}},
           {"day":"2026-08-25","ios":{"1.5.4":{"start_p50_1d":null,"start_p95_1d":null,"slow_pct_1d":null,"frozen_pct_1d":null,"net_err_pct_1d":null}}}]'
h_assert_eq "2026-08-24" "$(h_run hist_perf_last_day ios 1.5.4)" '取最后一个有值的日期，不是最后一条记录'
out="$(h_run state_text_perf no_version ios 1.5.4 '2026-08-26 06:59 UTC')"
h_assert_contains "$out" '本轮未取到' '历史有值 + 本轮无 → 判为取数故障'
h_assert_contains "$out" '2026-08-24' '⚠️ 沿用/未取到文案必须带日期（不然连续多轮失败看不出僵住）'

# ③ ⛔ 本轮取到 0：0 是慢帧/冻结/错误率的合法值，MUST NOT 被当成缺失
HIST_ARR='[{"day":"2026-08-25","and":{"1.5.4":{"start_p50_1d":null,"start_p95_1d":null,"slow_pct_1d":null,"frozen_pct_1d":"0.0","net_err_pct_1d":null}}}]'
h_assert_eq "2026-08-25" "$(h_run hist_perf_last_day and 1.5.4)" '⛔ 冻结率 0.0 是有值——真值性判断会把它读成 null'
h_assert_eq "0" "$(h_run hist_lookup and 1.5.4 frozen_pct_1d | cut -f1 | cut -d. -f1)" '⛔ hist_lookup 取得回 0'
HIST_ARR='[{"day":"2026-08-25","and":{"1.5.4":{"start_p50_1d":null,"start_p95_1d":null,"slow_pct_1d":null,"frozen_pct_1d":0,"net_err_pct_1d":null}}}]'
h_assert_eq "2026-08-25" "$(h_run hist_perf_last_day and 1.5.4)" '⛔ 数字 0（非字符串）同样算有值'

# ④ 预计到位日：只有残日里真有行才敢给日期
HIST_ARR='[]'
IOS_PERF_TAIL="1.5.5"
out="$(h_run state_text_perf no_version ios 1.5.5 '2026-08-26 06:59 UTC')"
h_assert_contains "$out" '2026-08-28' '残日已有行 → 明天 LCD 推进即到位'
IOS_PERF_TAIL=""
out="$(h_run state_text_perf no_version ios 1.5.5 '2026-08-26 06:59 UTC')"
h_assert_contains "$out" '该版本无数据' '⛔ 残日也没有就回落既有第 3 态文案，不空口承诺'

# ⑤ 前两态一字不动
out="$(h_run state_text_perf stale ios 1.5.5 '2026-08-26 06:59 UTC')"
h_assert_eq "⚠️ 数据未同步（截至 2026-08-26 06:59 UTC）" "$out" '⛔ 第 2 态文案原样委托给 state_text'
out="$(h_run state_text_perf table_missing ios 1.5.5 '—')"
h_assert_eq "表未同步" "$out" '⛔ 第 1 态文案原样委托'

echo "── 口径断裂标记（D 组 5.1/5.3：⛔ 跨口径不得静默给数）──"
h_load "$ROOT/bin/crash-daily.sh" hist_mode_perfday dodwow_note
HIST_ARR='[{"day":"2026-08-18","ios":{"1.5.3":{"perf_day":"2026-08-18","start_p95_1d":"715.0"}}},
           {"day":"2026-08-27","window_mode":"complete_day","ios":{"1.5.3":{"perf_day":"2026-08-25","start_p95_1d":"980.0"}}}]'
h_assert_eq "legacy" "$(h_run hist_mode_perfday 2026-08-18 ios 1.5.3)" \
  '⛔ 缺 window_mode 的旧行读作 legacy（默认成 complete_day 等于把残日值和完整天悄悄混比）'
h_assert_eq "complete_day" "$(h_run hist_mode_perfday 2026-08-25 ios 1.5.3)" \
  '有 window_mode 就按它读'
h_assert_eq "" "$(h_run hist_mode_perfday 2026-08-01 ios 1.5.3)" \
  '查不到该基准日 → 空（⛔ 没有基准不等于跨口径，不能乱标）'

# dodwow_note 的跨口径分支。⚠️ 取值用**真的 dv_**读真夹具文件，不写同名 stub——
# check-scripts 第 3 项会把夹具里的同名函数判成「共享函数没收口」，而且 stub 掉取值等于
# 把「dv_ 读不到文件时返回什么」这一半也一起测没了。
h_load "$ROOT/bin/crash-daily.sh" dv_
TMP="$T"
printf '%s\n' '{"perf_day":"2026-08-25","perf_prev_day":"2026-08-24","start_p95_1d":"980.0"}' > "$T/d-ios-1.5.3.json"
PERF_D7=2026-08-18; WINDOW_SWITCH_DAY=2026-08-27
out="$(h_run dodwow_note ios 1.5.3)"
h_assert_contains "$out" '本行 WoW 跨口径' '基准是旧口径 → 必须标注'
h_assert_contains "$out" '2026-08-27'      '标注里要说清口径何时切换的'
PERF_D7=2026-08-25
out="$(h_run dodwow_note ios 1.5.3)"
h_assert_absent "$out" '跨口径' '⛔ 基准同为新口径时不得误标（切满 7 天后标注要自动消失）'
PERF_D7=2026-08-01
out="$(h_run dodwow_note ios 1.5.3)"
h_assert_absent "$out" '跨口径' '⛔ 无基准时不标'


h_summary
