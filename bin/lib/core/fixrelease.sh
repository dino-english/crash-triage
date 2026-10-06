#!/usr/bin/env bash
# 核心层（Functional Core）——修复发版四态判定（change crash-fix-release-status，design D1/D2）
#
# ⛔ 本层是**纯函数**：所有输入经位置参数传入，输出经 stdout 返回；不读文件、不查数据、不读时钟、
#    不引用任何脚本全局变量。取数在 bin/fix-release-status.sh + bin/sql/fix-release-builds.sql。
#
# 判据是「修复提交之后的事件发生在哪个包上」，⛔ 不是只比时间（旧规则把旧包存量报成「修了仍在」，
# 2026-10-06 生产 19 条里 6 条说反）：
#   含修复的包上有事件            → 修了仍在
#   否则，含修复的包已上线        → 已发版待验（不含修复的包上仍有 N 次 → old_build_events=N）
#   否则                          → 已修未发版
#
# 「含修复的包」与「已上线」按端可得的信号判（design D2）：
#   iOS     含修复 = 首现晚于提交 且 上架包（perf_on>0）；已上线 = rel 清单里有首现晚于提交的
#           ⛔ 不用 tag（缺 v1.8.1/v1.8.2，修复多为 cherry-pick 不在 tag 祖先链上）
#           ⛔ 内部包（perf_on=0）不算含修复：一次内测崩溃不得改判「修了仍在」（c3184f91 先例）
#   Android 已上线 = release_ref 非空（进了 main 或某个 V* tag）
#           含修复 = 版本号 ≥ fixed_in_version 且 首现晚于提交；fixed_in_version 为 null（进 main 无 tag）
#           时退回「首现晚于提交」
#           ⛔ 不用设备数门槛（用户决定 2026-10-06）
#
# 用法：fix_release_verdict <fix条目JSON> <该 issue 的 ev 行JSON数组> <rel 行JSON数组>
#   fix 条目至少含 platform / commit_epoch，Android 另含 release_ref / fixed_in_version
#   ev 行：{build, version, first_seen, perf_on, events}（数值可为字符串，bq json 输出即如此）
# 输出：{"status":…, "old_build_events":N, "new_build_events":N}
fix_release_verdict() {
  jq -cn --argjson fix "$1" --argjson ev "$2" --argjson rel "$3" '
    # 版本号拆成数字数组比较（1.10.0 > 1.9.0）。⛔ 不从 versionCode 反推（末 3 位是 CI 序号）
    def vparts: tostring | split(".") | map(tonumber? // 0);
    def num: if . == null then 0 else tonumber end;
    ($fix.commit_epoch | num) as $ct |
    ($fix.platform // "") as $p |
    (if $p == "android" then
       ($fix.fixed_in_version // null) as $fv |
       def contains_fix: (.first_seen | num) > $ct and
         (if $fv == null then true else ((.version | vparts) >= ($fv | vparts)) end);
       { released: (($fix.release_ref // null) != null),
         rows: ($ev | map(. + {fixed: contains_fix})) }
     else
       def contains_fix: (.first_seen | num) > $ct and (.perf_on | num) > 0;
       { released: ($rel | map(select((.first_seen | num) > $ct and (.perf_on | num) > 0)) | length > 0),
         rows: ($ev | map(. + {fixed: contains_fix})) }
     end) as $j |
    ([$j.rows[] | select(.fixed)     | .events | num] | add // 0) as $new |
    ([$j.rows[] | select(.fixed|not) | .events | num] | add // 0) as $old |
    { status: (if $new > 0 then "修了仍在"
               elif $j.released then "已发版待验"
               else "已修未发版" end),
      old_build_events: $old,
      new_build_events: $new }'
}

# 状态 → 呈现文案（design D8）。**全仓唯一定义**：卡片 _chg_rows / _fix_rows 两条路径都调它——
# 旧写法两处各写一份 if/elif，且都以「其余一律修了仍在」兜底：新状态一进来就被说成修复无效（F1 / F35 同形）。
# ⛔ 不设兜底归类：未列出的状态原样透出并打「❓」，MUST NOT 归入任一已知态（spec「两态不得被写死成一态」）。
# 用法：fix_mark <status> <release_check> <old_build_events> <开关状态 OPEN|CLOSED|MUTED|空>
fix_mark() {
  local st="${1:-}" rc="${2:-}" old="${3:-0}" state="${4:-}" old_txt=""
  # ⛔ 已关闭 / 已静音优先（R4）：fixmap 来自永久保留的事实层，关掉的 issue 永远在里面
  if [ "$state" = "CLOSED" ]; then printf '✅ 已关闭'; return 0; fi
  if [ "$state" = "MUTED" ]; then printf '🔕 已静音'; return 0; fi
  # 取数失败：沿用的是只比时间的结果，必须明说（design D6）
  if [ -n "$rc" ] && [ "$rc" != "ok" ]; then printf '❔ %s·发版判定不可得' "$st"; return 0; fi
  case "$old" in ''|*[!0-9]*) old=0 ;; esac
  if [ "$old" -gt 0 ]; then old_txt="·旧包仍崩 ${old} 次"; fi
  case "$st" in
    修了仍在)   printf '⚠️ 修了仍在' ;;
    已发版待验) printf '📦 已发版待验%s' "$old_txt" ;;
    已修未发版) printf '🛠️ 已修未发版' ;;
    状态未知)   printf '❔ 已修·状态未知' ;;
    *)          printf '❓ %s' "$st" ;;
  esac
}
