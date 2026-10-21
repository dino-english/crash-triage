#!/usr/bin/env bash
# 核心层（Functional Core）——崩溃的模块归属与负责人解析（change crash-owner-mention）
#
# ⛔ 本层是**纯函数**：所有输入经位置参数传入，输出经 stdout 返回；不读文件、不查数据、
#    不引用任何脚本全局变量。取数与读内容文件在 bin/lib/owner.sh。

# owner_attach：给条目补上模块归属与负责人。
#   $1 = 条目 JSON 数组 [{plat:"ios|android", id:<32位>, fix_subject?}]（日报 tier / 周报必修共用）
#   $2 = fixmap 的 mapped JSON {<32位>: {subject}}（{} = 反扫不可用）；条目自带 fix_subject 时优先用它
#   $3 = 信号 JSON {<32位>: {owner, symbol, file, library, screen}}（{} = 取数失败）
#   $4 = notes/module-rules.tsv 原文   $5 = notes/owners.tsv 原文
# → 原条目 + {owner_mod, owner_src, owner_id, owner_note}
#   owner_src ∈ 修复 scope / 责任帧 / SDK / 页面 / 兜底
#   owner_note：空 = 正常；「平台兜底」= 模块负责人未配置；「负责人未配置」= 连兜底都取不到（⛔ 必须可见，不得静默）
# 优先级（design D2）：scope > own > lib > screen > crash_fallback；同信号内按规则行序。
owner_attach() {
  jq -cn --argjson items "$1" --argjson fm "$2" --argjson sig "$3" --arg rules "$4" --arg owners "$5" '
    def rows($t): $t | split("\n") | map(select(test("^\\s*(#|$)") | not) | split("\t"));
    (rows($rules) | map(select(length >= 3) | {s:.[0], re:.[1], mod:.[2]})) as $R
    | (rows($owners) | map(select(length >= 3)) | map({key:(.[0] + "/" + .[1]), value:.[2]}) | from_entries) as $O
    | def hit($s; $v): if ($v // "") == "" then null
                       else [ $R[] | select(.s == $s) | select(. as $r | $v | test($r.re)) | .mod ][0] end;
      def pk: if .plat == "ios" then "ios" else "and" end;
      def own($m; $p): $O[$m + "/" + $p] // "";
    [ $items[] | . as $x
      | ($sig[$x.id] // {}) as $g
      | ((($x.fix_subject // "") | if . == "" then ($fm[$x.id].subject // "") else . end)
         # ⚠️ jq 的 `"" | split("\n")` 是 []（不是 [""]），[0] 得 null——必须补 // ""
         | (split("\n")[0] // "") | (capture("^[a-zA-Z]+\\((?<s>[^)]+)\\)") // {s:""}).s) as $scope
      | (if ($g.owner // "") == "DEVELOPER" then (($g.symbol // "") + " " + ($g.file // "")) else "" end) as $ownv
      | ((($g.library // "") + " " + ($g.symbol // "")) | if . == " " then "" else . end) as $libv
      | (if (hit("scope"; $scope)) then {mod:hit("scope"; $scope), src:"修复 scope"}
         elif (hit("own"; $ownv)) then {mod:hit("own"; $ownv), src:"责任帧"}
         elif (hit("lib"; $libv)) then {mod:hit("lib"; $libv), src:"SDK"}
         # ⛔ 第三方 SDK 帧不看页面：SDK 规则没认领的第三方崩溃归兜底（负责人表：第三方 SDK → crash_fallback）。
         #    2026-10-21 回放：PAG nativeFinalize 跑在 GC 回收线程，崩时停在哪页是巧合，按页面会错 @。
         elif ($g.owner // "") != "THIRD_PARTY" and (hit("screen"; $g.screen)) then {mod:hit("screen"; $g.screen), src:"页面"}
         else {mod:"crash_fallback", src:"兜底"} end) as $a
      | ($x | pk) as $p
      | (if own($a.mod; $p) != "" then {id:own($a.mod; $p), note:""}
         elif own("platform_fallback"; $p) != "" then {id:own("platform_fallback"; $p), note:"平台兜底"}
         else {id:"", note:"负责人未配置"} end) as $o
      | $x + {owner_mod:$a.mod, owner_src:$a.src, owner_id:$o.id, owner_note:$o.note} ]'
}

# owner_coverage_line：$1 = owner_coverage 的输出  $2 = 给建议的最低受影响台数 → 周报一行（无设备时空串）
#   ⛔ 只给分数不给百分比（样本小，百分比是伪精度）。
#   ⛔ 某端台数 < $2 时只给分数、不给补埋点建议（用户 2026-10-21）：10-21 影子跑 iOS 0/3 台就触发了建议，
#      3 台的「过半归不到」说明不了埋点缺失（同 F50：小样本不得当结论）。
owner_coverage_line() {
  printf '%s' "$1" | jq -r --argjson min "$2" '
    def frac($p; $n): if .[$p].all > 0 then "\($n) \(.[$p].hit)/\(.[$p].all) 台" else "\($n) 无受影响设备" end;
    if (.ios.all + .android.all) == 0 then ""
    else "🧭 模块归属覆盖（近 7 天受影响设备）：" + frac("ios"; "iOS") + " · " + frac("android"; "Android")
      + ([ ("ios","android") as $p | select(.[$p].all >= $min and (.[$p].hit * 2) < .[$p].all)
           | (if $p == "ios" then "iOS" else "Android" end) ] as $low
         | if ($low | length) > 0
           then "；⚠️ " + ($low | join("、")) + " 过半归不到模块，建议在崩溃 custom keys 补模块 / 路由字段"
                + (if ($low | index("Android")) then "（Android 的 current_screen 现几乎恒为 MainActivity，分不出页面）" else "" end)
           else "" end)
    end'
}

# owner_coverage：$1 = owner_attach 的输出（条目需带 users）→ {"ios":{all,hit},"android":{all,hit}}
#   hit = 归到具体模块（非兜底）的台数之和。周报覆盖率一行用（design D5）。
owner_coverage() {
  printf '%s' "$1" | jq -c '
    def agg($p): [ .[] | select(.plat == $p) ] as $a
      | {all:([$a[].users // 0 | tonumber] | add // 0),
         hit:([$a[] | select(.owner_src != "兜底") | .users // 0 | tonumber] | add // 0)};
    {ios:agg("ios"), android:agg("android")}'
}
