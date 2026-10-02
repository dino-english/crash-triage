#!/usr/bin/env bash
# scan-fix-commits.sh 的修复状态判定（已修待验 / 修了仍在 / 状态未知）
#
# ⛔ 本夹具存在的理由（2026-10-02 实测）：旧判定只看事实层 `events[].eventTime`，
#    而事件明细常为空（抓取滞后 / 补抓失败）——空就默认「已修待验」。
#    同一轮 17 条映射里 5 条其实提交后仍在崩（latest_event 晚于提交），被说反成「待验」。
#    另两处：eventTime 带引号（`'2026-…Z'`）时字符串比较恒小于提交时间；
#    提交时间带 +08:00 而事件是 UTC，字符串比较差 8 小时。
#
# 判定是顶层代码不是函数，故**整脚本原样跑**（即生产 shell 设置），用临时仓库 + 临时 STATE。
ROOT="${CRASH_REPORT_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}"
. "$ROOT/bin/test/harness.sh"

R="$(mktemp -d)"; ST="$(mktemp -d)"; mkdir -p "$ST/issues"
git -C "$R" init -q 2>/dev/null; git -C "$R" config user.email t@t; git -C "$R" config user.name t
# 所有提交统一落在 2026-09-16T10:00:00+08:00 = 02:00:00Z
mk() { echo "$RANDOM" > "$R/f"; git -C "$R" add -A
       GIT_AUTHOR_DATE="2026-09-16T10:00:00+08:00" GIT_COMMITTER_DATE="2026-09-16T10:00:00+08:00" \
         git -C "$R" commit -q -m "fix: $1"$'\n\n'"Crashlytics-Issue: $2"; }
iss() { printf '%s\n' "$2" > "$ST/issues/$1.json"; }

A=aaaaaaaa111122223333444455556666; B=bbbbbbbb111122223333444455556666
C=cccccccc111122223333444455556666; D=dddddddd111122223333444455556666
E=eeeeeeee111122223333444455556666; F=ffffffff111122223333444455556666
mk "a" $A; mk "b" $B; mk "c" $C; mk "d" $D; mk "e" $E; mk "f" $F
iss $A "{\"id\":\"$A\",\"platform\":\"android\",\"events\":[],\"latest_event\":\"2026-09-30 21:49 UTC\"}"
iss $B "{\"id\":\"$B\",\"platform\":\"android\",\"events\":[{\"eventTime\":\"'2026-09-20T23:47:01Z'\"}],\"latest_event\":\"2026-09-15 00:00 UTC\"}"
iss $C "{\"id\":\"$C\",\"platform\":\"android\",\"events\":[{\"eventTime\":\"2026-09-10T00:00:00Z\"}],\"latest_event\":\"2026-09-15 08:00 UTC\"}"
iss $D "{\"id\":\"$D\",\"platform\":\"android\"}"
iss $E "{\"id\":\"$E\",\"platform\":\"android\",\"events\":[{\"eventTime\":\"2026-09-16T05:00:00Z\"}]}"
iss $F "{\"id\":\"$F\",\"platform\":\"android\",\"events\":[],\"latest_event\":\"2026-09-16 01:30 UTC\"}"

out="$(bash "$ROOT/bin/scan-fix-commits.sh" "$ST" "$R" "$R/nonexistent" 3650 2>&1)"; rc=$?
st() { printf '%s' "$out" | jq -r --arg id "$1" '.mapped[$id].status // "（未映射）"' 2>/dev/null; }

h_assert_eq "0"        "$rc"       "⓪ 整脚本 rc=0（生产 shell 设置下不得踩 ERR）"
h_assert_eq "修了仍在" "$(st $A)" "① 明细为空、latest_event 晚于提交 → 修了仍在（⛔ 旧实现判成已修待验）"
h_assert_eq "修了仍在" "$(st $B)" "② eventTime 带引号也要能比（⛔ 旧实现字符串比较恒判待验）"
h_assert_eq "已修待验" "$(st $C)" "③ 两个来源都早于提交 → 已修待验（负向：不得一律报仍在）"
h_assert_eq "状态未知" "$(st $D)" "④ 两个来源都没有 → 状态未知（⛔ 不得默认已修待验）"
h_assert_eq "修了仍在" "$(st $E)" "⑤ 时区：05:00Z 晚于 10:00+08:00(=02:00Z) → 修了仍在（⛔ 旧字符串比较判反）"
h_assert_eq "已修待验" "$(st $F)" "⑥ 时区：01:30 UTC 早于 02:00Z → 已修待验"
rm -rf "$R" "$ST"
h_summary
