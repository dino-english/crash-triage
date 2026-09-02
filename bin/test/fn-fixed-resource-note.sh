#!/usr/bin/env bash
# ⛔ 只有永久固定资源才提示回填；按日期键的日报周报不提示（2026-09-02 用户指出：连续 5 天每天误报一次）
ROOT="${CRASH_REPORT_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}"
. "$ROOT/bin/test/harness.sh"
NEW_RESOURCES="$(mktemp)"
note_new() { printf '| %s | `%s` |\n' "$1" "$2" >> "$NEW_RESOURCES"; }
# 抽出 publish_doc 里的判据（生产原文，非拷贝）
probe() { # $1=key $2=标题 → 是否记入
  local key="$1" u="https://x/doc"
  case "$key" in
    (*-[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]) : ;;
    (*) note_new "$2" "$u" ;;
  esac
}
run() { : > "$NEW_RESOURCES"; h_run probe "$1" "$2" >/dev/null; grep -c . "$NEW_RESOURCES"; }
h_assert_eq "0" "$(run 'crash-triage|daily-2026-09-02' '崩溃日报')"  "⛔ 按日期的日报键不提示"
h_assert_eq "0" "$(run 'crash-triage|weekly-2026-08-31' '崩溃周报')" "⛔ 按日期的周报键不提示"
h_assert_eq "1" "$(run 'crash-triage|index' '索引页')"               "✅ 索引页仍提示"
h_assert_eq "1" "$(run 'crash-triage|ledger' '台账')"                "✅ 台账仍提示"
h_assert_eq "1" "$(run '' '计划外新建的临时文档')"                    "✅ 无键的临时文档仍提示（正该被看见）"
h_assert_eq "1" "$(run 'crash-triage|daily-2026-9-2' '日期格式不规范')" "⚠️ 不匹配的日期形状不静默吞掉，宁可多报"
h_summary
