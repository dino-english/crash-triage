#!/usr/bin/env bash
# 投递分流（change crash-deliver-divert）。
#
# ⛔ **不改** local.env 盖过命令行那条纪律——「本机身份由机器决定，不由手打的命令决定」
# （2026-08-20 那次差点把卡片发进正式群，理由仍然成立）。
#
# ⚠️ 但它有代价：生产机上**跑一次真链路看看对不对**变成不可能，只能等 cron，而 cron 发正式群。
# 2026-09-22 就因此把「索引页那一行点不点得开」推到了第二天——而那正是「没测就部署」的同源病。
#
# 于是开一个**比 local.env 更窄**的口子：
# ⛔ **只接受 ou_ 私聊**，拒绝一切 oc_ 群 ⇒ 它在结构上不可能把报告投到另一个群，
#    也就不可能复现 2026-08-20 那次事故。
# ⚠️ 分流后 CHAT_ID 变成 ou_，deliver.sh 据此自动进自测模式（跳过归档 / 索引页 / 台账同步）。
#    要连索引页与台账一起验，配合 CRASH_REPORT_INDEX_DOC_ID / CRASH_REPORT_LEDGER_DOC_ID
#    指向**另建的测试文档**（那两个口子各自会拒绝指向生产文档）。
# ⚠️ 它**不隔离 $STATE**：在生产机上分流跑批仍会写 metrics-history（同日多一行，
#    而 hist_val 取首条，读侧不受影响）并刷新生命周期基准（当天本就已刷过，等价空操作）。
#    ⛔ 不要用它在生产机上反复跑——验一次就够。
apply_chat_divert() { # → 0=已分流或未启用 / 1=参数非法
  [ -n "${CRASH_REPORT_DIVERT_TO:-}" ] || return 0
  case "$CRASH_REPORT_DIVERT_TO" in
    ou_*) ;;
    *) echo "⛔ CRASH_REPORT_DIVERT_TO 只接受 ou_ 私聊（拒绝：${CRASH_REPORT_DIVERT_TO}）——" >&2
       echo "   这个口子存在的前提就是它永远投不到群里。" >&2
       return 1 ;;
  esac
  echo "  🧪 投递分流：本轮改投私聊 ${CRASH_REPORT_DIVERT_TO}（自测模式，⛔ 不写归档/索引页/台账）" >&2
  CRASH_REPORT_CHAT_ID="$CRASH_REPORT_DIVERT_TO"
  export CRASH_REPORT_CHAT_ID
}
