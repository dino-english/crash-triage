#!/usr/bin/env bash
# change crash-report-version-alignment：主力版本集合 = 窗口 top2 ∪ 当日 top1（上限 3）
ROOT="${CRASH_REPORT_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}"
. "$ROOT/bin/test/harness.sh"

# 用假 bqq 喂两套窗口的数据（真实 SQL 已在实施时对真表验过）
mk() { # $1=7天CSV $2=当日CSV
  W7="$1"; W1="$2"
  # 假 bqq 按窗口分流：q_render 把参数原样回显，其中含 DAYS=1 的即当日窗口
  q_render() { printf '%s' "$*"; }
  bqq() { case "$*" in (*"DAYS=1 "*) printf '%s\n' "$W1";; (*) printf '%s\n' "$W7";; esac; }
  WEEK_DAYS=7; MIN_SESSIONS=1
  # ⚠️ sub() 先执行会把 "  }" 变成 "}"，退出条件必须在改写前判——否则一路抽到文件尾
  eval "$(awk '/^  main_versions\(\) \{/{f=1} f{done=($0=="  }"); sub(/^  /,""); print; if(done) exit}' "$ROOT/bin/crash-weekly.sh")"
}

SEV='version,sessions,devices
1.5.4,3666,1944
1.5.5,2064,1157
1.5.6,1819,900
1.5.3,536,300'

# ① 放量周：当日 top1 是 1.5.6，窗口 top2 没有它 → 补第 3 行
mk "$SEV" 'version,sessions,devices
1.5.6,855,700
1.5.5,46,30'
out="$(h_run main_versions tbl)"
h_assert_eq "3" "$(printf '%s\n' "$out" | grep -c . )" "分歧周 → 3 行（上限 3）"
h_assert_contains "$out" "1.5.4,3666,1944,窗口主力" "窗口 top1 标窗口主力"
h_assert_contains "$out" "1.5.6,1819,900,当日主力" "补入行标当日主力，⚠️ 会话/设备取**窗口**口径（1819 不是 855）"
h_assert_eq "" "$(printf '%s' "$out" | grep -o '855' || true)" "⛔ 当日数字不得混进窗口列"

# ② 稳态：当日 top1 已在窗口 top2 内 → 只有 2 行
mk "$SEV" 'version,sessions,devices
1.5.4,900,500'
out="$(h_run main_versions tbl)"
h_assert_eq "2" "$(printf '%s\n' "$out" | grep -c . )" "重合周 → 2 行（形态与启用前一致）"
h_assert_contains "$out" "1.5.4,3666,1944,窗口+当日" "重合时标窗口+当日"

# ③ ⛔ 不得掺会话量门槛：当日 top1 只有 1 个会话也要补入
mk "$SEV" 'version,sessions,devices
1.5.3,1,1'
out="$(h_run main_versions tbl)"
h_assert_contains "$out" "1.5.3,536,300,当日主力" "当日仅 1 会话仍补入（⛔ 门槛会静默剔除刚放量/被叫停的新版）"

# ④ 当日窗口取不到数据 → 退回纯窗口 top2，不报错
mk "$SEV" 'version,sessions,devices'
out="$(h_run main_versions tbl)"
h_assert_eq "2" "$(printf '%s\n' "$out" | grep -c . )" "当日无数据 → 退回 2 行"
h_summary
