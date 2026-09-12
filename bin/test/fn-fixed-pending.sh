#!/usr/bin/env bash
# _fix_rows（crash-weekly.sh 段一的「已修待验 / 修了仍在」渲染）
#
# ⛔ 本夹具存在的理由：2026-09-05 那次修复只拆掉了 ios-only 过滤，没人测「它到底出不出东西」，
#    结果 09-07 生产实测卡片 0 条、台账 2 条。核心判据只有一条——
#    **issue 不在当周快照里也必须渲染**，因为那正是「已修待验」的定义。
ROOT="${CRASH_REPORT_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}"
. "$ROOT/bin/test/harness.sh"
. "$ROOT/bin/lib/common.sh"   # issue_url

FIXMAP_FILE="$(mktemp)"
cat > "$FIXMAP_FILE" <<'JSON'
{"mapped":{
  "2a800b339e12b94bc2d4555c63859df8":{"platform":"ios","commit":"29a20dc5","commit_date":"2026-08-31T16:23:36+08:00","subject":"fix(paywall): 修复 Winback 方向冲突","status":"已修待验"},
  "470ed3ef000011112222333344445555":{"platform":"ios","commit":"e3834661","commit_date":"2026-08-24T16:26:38+08:00","subject":"fix(welcome-gift): PAG 释放竞态","status":"修了仍在"},
  "85c581edcdb39b941df627e7b1324a71":{"platform":"android","commit":"9bbe8b15","commit_date":"2026-08-19T13:04:14+08:00","subject":"fix(ai): MicroTTSHelper teardown","status":"已修待验"}
},"ambiguous":[],"platform_unavailable":[]}
JSON

# ⛔ DIFF 里放一条**诱饵**：旧实现只认它、且看不见 fixmap 里那三条。
#    新实现必须反过来——渲染 fixmap 的三条、完全不碰这条。
DIFF='{"ios":{"total":0,"events":0,"fixed_pending":[{"id":"deadbeef000011112222333344445555","title":"⛔不该出现的快照标题","fix_commit":"ffffffff"}]},"android":{"total":0,"events":0,"fixed_pending":[]}}'

# ⚠️ _fix_rows 自 2026-09-11 起读 ${ISSUE_STATES_JSON}（issue 开关状态）。夹具必须显式给出，
#    否则 set -u 下每次调用都打一行 unbound 噪音——它不让夹具变红，但会淹掉真错误。
ISSUE_STATES_JSON='{}'
h_load "$ROOT/bin/crash-weekly.sh" _fix_rows

ios0="$(h_run _fix_rows ios 0)"
ios1="$(h_run _fix_rows ios 1)"
and0="$(h_run _fix_rows android 0)"

h_assert_contains "$ios0" "2a800b33"        "① 快照为空也要渲染（⛔ 这条就是 09-07 漏报的根因）"
h_assert_contains "$ios0" "🛠️ 代码已修待验"  "② 已修待验用 🛠️"
h_assert_contains "$ios0" "⚠️ 修了仍在"      "③ 修了仍在**不得**被写成已修待验（状态取 fixmap 的 status）"
h_assert_contains "$ios0" "29a20dc5"        "④ 带出提交短 hash"
h_assert_absent   "$ios0" "85c581ed"        "⑤ ⛔ 不得串平台：ios 调用不出 android 条目"
h_assert_contains "$and0" "85c581ed"        "⑥ Android 照样渲染（e15bbcd 的 ios-only 过滤不得复活）"
h_assert_absent   "$and0" "2a800b33"        "⑦ ⛔ 反向也不串"
h_assert_absent   "$ios0" "https://"        "⑧ want_link=0 无链接（卡片/聊天路径）"
h_assert_contains "$ios1" "https://console.firebase.google.com" "⑨ want_link=1 出链接（文档路径）"
h_assert_absent   "$ios1" '`2a800b33`'      "⑩ ⛔ 链接版不加反引号（md2docx 链接正则不处理嵌套行内代码）"
h_assert_absent   "$ios0" "不该出现的快照标题"  "⑪ ⛔ 不再读 DIFF.fixed_pending（数据源已换成 fixmap）"

# ── 合并：fixmap 每条在卡片上**恰好出现一次** ──────────────────────
# ⛔ 2026-09-07：`470ed3ef` 同时满足「消失」与「已修待验」，分成两行、各带一个不同描述
#    （issue 标题 vs commit subject）会被读成两条打架的记录。合并成一行、括注只放短 hash。
h_load "$ROOT/bin/crash-weekly.sh" _chg_rows
DIFF='{"ios":{"total":0,"events":0,
  "new":[],"regressed":[],"spiked":[],
  "resolved":[{"id":"2a800b339e12b94bc2d4555c63859df8","title":"[CoreFoundation] CFRelease","events":0,"versions":null}]},
 "android":{"total":0,"events":0,"new":[],"regressed":[],"spiked":[],"resolved":[]}}'
merged="$(h_run _chg_rows ios resolved "✅ 消失" 0 0)"
left="$(h_run _fix_rows ios 0)"

h_assert_contains "$merged" "✅ 消失"                 "⑫ 命中 fixmap 的消失行仍是消失行"
h_assert_contains "$merged" "（🛠️ 代码已修待验 · 29a20dc5）" "⑬ 修复状态并进本行，括注带短 hash"
h_assert_contains "$merged" "[CoreFoundation] CFRelease"  "⑭ ⛔ 标题用 issue 标题，不是 commit subject"
h_assert_absent   "$merged" "fix(paywall)"            "⑮ ⛔ 括注里不放 commit subject（卡片列宽装不下）"
h_assert_absent   "$left"   "2a800b33"                "⑯ ⛔ 已被变化行吸收的不得再单独成行（恰好一次）"
h_assert_contains "$left"   "470ed3ef"                "⑰ 没进任何变化桶的仍单独成行（⛔ 不得被吞掉）"

# 「修了仍在」走另一个图标——⛔ 不得两态都写成已修待验
DIFF='{"ios":{"total":1,"events":3,"new":[{"id":"470ed3ef000011112222333344445555","title":"仍在崩","events":3,"versions":null}],
  "regressed":[],"spiked":[],"resolved":[]},"android":{"total":0,"events":0,"new":[],"regressed":[],"spiked":[],"resolved":[]}}'
h_assert_contains "$(h_run _chg_rows ios new "🆕 新增" 1 0)" "（⚠️ 修了仍在 · e3834661）" \
  "⑱ 新增行命中 fixmap 时用「修了仍在」图标（该 issue 提交后仍在崩）"

# ⛔ 没有 fixmap 时变化行一个字节都不许变
# ⚠️ 用子 shell 隔离这次改写：直接改全局 FIXMAP_FILE 会让后面那段 `: > "$FIXMAP_FILE"`
#    去创建 /nonexistent/…，夹具照样全绿却在 stderr 漏一条错误（实测踩过）。
h_assert_absent "$(FIXMAP_FILE=/nonexistent/fixmap.json h_run _chg_rows ios new "🆕 新增" 1 0)" \
  "（" "⑲ ⛔ 无 fixmap 时不得出现任何括注"

# 空 / 缺失 fixmap：静默且 rc=0，⛔ 不得触发 ERR trap
: > "$FIXMAP_FILE"
h_assert_silent _fix_rows ios 1
h_assert_rc 0 _fix_rows ios 1
FIXMAP_FILE="/nonexistent/fixmap.json"
h_assert_rc 0 _fix_rows ios 1

h_summary "_fix_rows"
