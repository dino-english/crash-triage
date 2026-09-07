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

# 空 / 缺失 fixmap：静默且 rc=0，⛔ 不得触发 ERR trap
: > "$FIXMAP_FILE"
h_assert_silent _fix_rows ios 1
h_assert_rc 0 _fix_rows ios 1
FIXMAP_FILE="/nonexistent/fixmap.json"
h_assert_rc 0 _fix_rows ios 1

h_summary "_fix_rows"
