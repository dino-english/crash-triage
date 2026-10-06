#!/usr/bin/env bash
# _fix_rows（crash-weekly.sh 段一的「已修待验 / 修了仍在」渲染）
#
# ⛔ 本夹具存在的理由：2026-09-05 那次修复只拆掉了 ios-only 过滤，没人测「它到底出不出东西」，
#    结果 09-07 生产实测卡片 0 条、台账 2 条。核心判据只有一条——
#    **issue 不在当周快照里也必须渲染**，因为那正是「已修待验」的定义。
ROOT="${CRASH_REPORT_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}"
. "$ROOT/bin/test/harness.sh"
. "$ROOT/bin/lib/common.sh"   # issue_url
# 状态 → 文案的唯一定义（change crash-fix-release-status）：两个渲染函数都调它，抽函数测时必须一起加载
. "$ROOT/bin/lib/core/fixrelease.sh"

FIXMAP_FILE="$(mktemp)"
cat > "$FIXMAP_FILE" <<'JSON'
{"mapped":{
  "2a800b339e12b94bc2d4555c63859df8":{"platform":"ios","commit":"29a20dc5","commit_date":"2026-08-31T16:23:36+08:00","subject":"fix(paywall): 修复 Winback 方向冲突","status":"已发版待验","release_check":"ok","old_build_events":0},
  "470ed3ef000011112222333344445555":{"platform":"ios","commit":"e3834661","commit_date":"2026-08-24T16:26:38+08:00","subject":"fix(welcome-gift): PAG 释放竞态","status":"修了仍在","release_check":"ok","old_build_events":0},
  "85c581edcdb39b941df627e7b1324a71":{"platform":"android","commit":"9bbe8b15","commit_date":"2026-08-19T13:04:14+08:00","subject":"fix(ai): MicroTTSHelper teardown","status":"已修未发版","release_check":"ok","old_build_events":1}
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
h_assert_contains "$ios0" "📦 已发版待验"    "② 已发版待验用 📦（四态，change crash-fix-release-status）"
h_assert_contains "$ios0" "⚠️ 修了仍在"      "③ 修了仍在**不得**被写成别的态（状态取 fixmap 的 status）"
h_assert_contains "$and0" "🛠️ 已修未发版"    "③b 已修未发版用 🛠️"
h_assert_absent   "$and0" "修了仍在"         "③c ⛔ 已修未发版不得落进兜底被说成修了仍在（双向测试锚点，tasks 7.2）"
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
h_assert_contains "$merged" "（📦 已发版待验 · 29a20dc5）" "⑬ 修复状态并进本行，括注带短 hash"
h_assert_contains "$merged" "[CoreFoundation] CFRelease"  "⑭ ⛔ 标题用 issue 标题，不是 commit subject"
h_assert_absent   "$merged" "fix(paywall)"            "⑮ ⛔ 括注里不放 commit subject（卡片列宽装不下）"
h_assert_absent   "$left"   "2a800b33"                "⑯ ⛔ 已被变化行吸收的不得再单独成行（恰好一次）"
h_assert_contains "$left"   "470ed3ef"                "⑰ 没进任何变化桶的仍单独成行（⛔ 不得被吞掉）"

# 「修了仍在」走另一个图标——⛔ 不得两态都写成已修待验
DIFF='{"ios":{"total":1,"events":3,"new":[{"id":"470ed3ef000011112222333344445555","title":"仍在崩","events":3,"versions":null}],
  "regressed":[],"spiked":[],"resolved":[]},"android":{"total":0,"events":0,"new":[],"regressed":[],"spiked":[],"resolved":[]}}'
h_assert_contains "$(h_run _chg_rows ios new "🆕 新增" 1 0)" "（⚠️ 修了仍在 · e3834661）" \
  "⑱ 新增行命中 fixmap 时用「修了仍在」图标（该 issue 提交后仍在崩）"

# 「状态未知」第三态（2026-10-02）：两条渲染路径都要认，⛔ 不得落进 else 被说成「修了仍在」
_UNK="$(mktemp)"
printf '{"mapped":{"4d05f9e74e77520b418eac3a355108f1":{"platform":"android","commit":"328af7a9","commit_date":"2026-09-16T10:00:00+08:00","subject":"fix(account): x","status":"状态未知"}}}\n' > "$_UNK"
# ⚠️ _fix_rows 会跳过已被变化行吸收的条目（⑯），故两条路径用两份 DIFF——共用一份时
#    _fix_rows 输出为空，「不得出现修了仍在」那条会假绿（实测踩过）
DIFF='{"ios":{"total":0,"events":0,"new":[],"regressed":[],"spiked":[],"resolved":[]},
 "android":{"total":0,"events":0,"new":[],"regressed":[],"spiked":[],"resolved":[]}}'
_unk_fix="$(FIXMAP_FILE="$_UNK" h_run _fix_rows android 0)"
DIFF='{"ios":{"total":0,"events":0,"new":[],"regressed":[],"spiked":[],"resolved":[]},
 "android":{"total":1,"events":2,"new":[{"id":"4d05f9e74e77520b418eac3a355108f1","title":"ANR","events":2,"versions":null}],"regressed":[],"spiked":[],"resolved":[]}}'
_unk_chg="$(FIXMAP_FILE="$_UNK" h_run _chg_rows android new "🆕 新增" 1 0)"
h_assert_contains "$_unk_fix" "❔ 已修·状态未知"           "⑳ _fix_rows 渲染第三态"
h_assert_absent   "$_unk_fix" "修了仍在"                  "㉑ ⛔ _fix_rows 未知不得说成修了仍在"
h_assert_contains "$_unk_chg" "（❔ 已修·状态未知 · 328af7a9）" "㉒ _chg_rows 渲染第三态"
h_assert_absent   "$_unk_chg" "修了仍在"                  "㉓ ⛔ _chg_rows 未知不得说成修了仍在"
rm -f "$_UNK"

# ── 四态的附注：旧包次数 / 发版判定不可得 / 未知状态（change crash-fix-release-status）──
_X="$(mktemp)"
printf '%s\n' '{"mapped":{
 "aaaa0000111122223333444455556666":{"platform":"android","commit":"a1a1a1a1","subject":"s1","status":"已发版待验","release_check":"ok","old_build_events":2},
 "bbbb0000111122223333444455556666":{"platform":"android","commit":"b2b2b2b2","subject":"s2","status":"已修待验","release_check":"unavailable"},
 "cccc0000111122223333444455556666":{"platform":"android","commit":"c3c3c3c3","subject":"s3","status":"奇怪的新状态","release_check":"ok"}}}' > "$_X"
DIFF='{"ios":{"total":0,"events":0,"new":[],"regressed":[],"spiked":[],"resolved":[]},
 "android":{"total":0,"events":0,"new":[],"regressed":[],"spiked":[],"resolved":[]}}'
_x="$(FIXMAP_FILE="$_X" h_run _fix_rows android 0)"
h_assert_contains "$_x" "📦 已发版待验·旧包仍崩 2 次"   "㉔ 旧包仍崩的次数要看得见（处置同已发版待验，但量级不同）"
h_assert_contains "$_x" "❔ 已修待验·发版判定不可得"     "㉕ ⛔ 取数失败时沿用的是时间规则结果，必须明说（design D6）"
h_assert_contains "$_x" "❓ 奇怪的新状态"               "㉖ 未列出的状态原样透出"
h_assert_absent   "$_x" "c3c3c3c3 · ⚠️"                "㉗ ⛔ 未知状态不得被兜底归为修了仍在"
# ⛔ 已关闭 / 已静音优先（R4）：映射收进 fix_mark 后，必须确认开关状态真的传进去了
ISSUE_STATES_JSON='{"470ed3ef000011112222333344445555":"CLOSED","2a800b339e12b94bc2d4555c63859df8":"MUTED"}'
_cl="$(h_run _fix_rows ios 0)"
h_assert_contains "$_cl" "✅ 已关闭"  "㉘ CLOSED 压过「修了仍在」（_fix_rows 把开关状态传给了 fix_mark）"
h_assert_contains "$_cl" "🔕 已静音"  "㉙ MUTED 单独成态"
h_assert_absent   "$_cl" "修了仍在"   "㉚ ⛔ 关掉的 issue 不得再推给人跟进"
ISSUE_STATES_JSON='{}'
rm -f "$_X"

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
