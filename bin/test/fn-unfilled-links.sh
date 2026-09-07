#!/usr/bin/env bash
# strip_unfilled_links（deliver.sh：卡片出门前把没回填的链接占位符降级为纯文本）
#
# ⛔ 起因 2026-09-07：DRY RUN 产出的 publish/card.json 被手工单发去验列宽，
#    `[完整报告](__REPORT_URL__)` 在飞书里渲染成 `http://__report_url__` 死链。
#    ⚠️ 不是 DRY RUN 专属——weekly 分支的回填带条件，文档发布失败时卡片照发进生产群。
ROOT="${CRASH_REPORT_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}"
. "$ROOT/bin/test/harness.sh"

h_load "$ROOT/bin/deliver.sh" strip_unfilled_links
T="$(mktemp -d)"

mk() { printf '%s' "$1" > "$T/c.json"; h_run strip_unfilled_links "$T/c.json" >/dev/null 2>&1; cat "$T/c.json"; }

h_assert_eq '{"c":"📄 完整报告（链接未生成） · 📁 全部报告（链接未生成）"}' \
  "$(mk '{"c":"📄 [完整报告](__REPORT_URL__) · 📁 [全部报告](__FOLDER_URL__)"}')" \
  "① 两个占位符都降级，⛔ 不得留下 markdown 链接语法"

h_assert_eq '{"c":"📄 [完整报告](https://x.com/a?b=1&c=2) · 📁 全部报告（链接未生成）"}' \
  "$(mk '{"c":"📄 [完整报告](https://x.com/a?b=1&c=2) · 📁 [全部报告](__FOLDER_URL__)"}')" \
  "② ⛔ 已回填的真链接**必须原样保留**（含 & 与 ? 的 URL）"

h_assert_eq '{"c":"🗂 崩溃跟踪索引（链接未生成） · 📄 详情（链接未生成）"}' \
  "$(mk '{"c":"🗂 [崩溃跟踪索引](__INDEX_URL__) · 📄 [详情](__DETAIL_URL__)"}')" \
  "③ 日报那两个占位符同样认（⛔ 不得只认 REPORT）"

# ⚠️ 幂等：跑两次结果不变（send_card 重发路径会再走一次）
printf '%s' '{"c":"[a](__REPORT_URL__)"}' > "$T/c.json"
h_run strip_unfilled_links "$T/c.json" >/dev/null 2>&1
h_run strip_unfilled_links "$T/c.json" >/dev/null 2>&1
h_assert_eq '{"c":"a（链接未生成）"}' "$(cat "$T/c.json")" "④ 幂等：重复执行不叠加"

# ⛔ 降级后必须仍是合法 JSON（否则 send_card 前的 jq empty 就白做了）
printf '%s' '{"c":"[完整报告](__REPORT_URL__)"}' > "$T/c.json"
h_run strip_unfilled_links "$T/c.json" >/dev/null 2>&1
jq empty "$T/c.json" 2>/dev/null && h_assert_eq 0 0 "⑤ 降级后仍是合法 JSON" \
  || h_assert_eq 0 1 "⑤ 降级后仍是合法 JSON"

# 无占位符时不得改动一个字节
orig='{"c":"📄 [完整报告](https://real.example/doc)"}'
h_assert_eq "$orig" "$(mk "$orig")" "⑥ ⛔ 没有占位符时一个字节都不许动"

# 文件不存在 / 空文件：安静返回 0，⛔ 不得触发 ERR trap
h_assert_rc 0 strip_unfilled_links /nonexistent.json
: > "$T/empty.json"; h_assert_rc 0 strip_unfilled_links "$T/empty.json"
h_assert_silent strip_unfilled_links "$T/empty.json"

h_summary "strip_unfilled_links"
