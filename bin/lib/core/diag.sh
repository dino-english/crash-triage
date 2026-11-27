#!/usr/bin/env bash
# 核心层（Functional Core）——技术诊断报错的激增判定、告警去重与卡片（change crash-tech-diagnostics）
#
# ⛔ 本层是**纯函数**：所有输入经位置参数传入，输出经 stdout 返回；不读写文件、不查数据、
#    不引用任何脚本全局变量（check-scripts 的 core 边界 lint 守着这条）。
#
# 小时聚合行（diag-hourly.sql 的输出、本地 hourly.jsonl 的一行）：
#   {h:"YYYY-MM-DD HH"(MYT), plat, ver, target, code, devices, users, events}
# 签名 = target × code；判定在签名级做：同签名各平台 × 版本的设备数相加
#（一台设备只属于一个平台；同一小时内升级版本的设备会被数两次，量级可忽略）。
#
# 去重状态（本地 alerted.json）：{<签名>: {sent:<上次投递 epoch 秒|null>, first:"<本轮激增首个小时>", last:"<最近一次激增的小时>"}}

# 激增规则与去重规则的唯一实现（jq def）。下面各函数都从这里取——
# ⛔ 不要在别处再写一遍：同一判据两份实现是失效模式 F1。
#   基线不足 1 时按 1 计（spec「基线不足时不放大」：0 → 3 台不能判成无穷倍），同时仍受下限约束。
#   去重：从未投递 → 发；距上次投递 ≥ 窗口 → 发（恰好 6 小时算已出窗口）。
_DIAG_JQ_DEFS='
def diag_spike($d; $b; $min; $mult):
  if ($d >= $min) and ($d >= ([$b, 1] | max) * $mult) then "spike" else "flat" end;
def diag_send($sent; $now; $w):
  if $sent == null or ($now - $sent) >= $w then "send" else "skip" end;
def hour_shift($h; $n): ($h + ":00" | strptime("%Y-%m-%d %H:%M") | mktime + $n * 3600 | strftime("%Y-%m-%d %H"));
def day_shift($d; $n): ($d | strptime("%Y-%m-%d") | mktime + $n * 86400 | strftime("%Y-%m-%d"));
# 签名级判定（小时级 / 日级共用，⛔ 不要再写第二份）：$tk = 时间字段名（h / d），$t = 被判定的时间桶，
# $prev = 基线时间桶列表（前 7 天同小时 / 前 7 天）。基线 = 这些桶签名级设备数之和 / 桶数（缺桶按 0）。
def diag_eval($cur; $hist; $tk; $t; $prev; $min; $mult):
  def key: .target + " × " + .code;
  ( [ $hist[] | select(.[$tk] as $x | $prev | index($x)) ]
    | group_by(key)
    | map({key: (.[0] | key), value: ((map(.devices) | add) / ($prev | length))})
    | from_entries ) as $base
  | [ $cur[] | select(.[$tk] == $t) ]
  | group_by(key)
  | map(. as $g | ($g[0] | key) as $k
        | ($g | map(.devices) | add) as $d
        | ($base[$k] // 0) as $b
        | {sig: $k, target: $g[0].target, code: $g[0].code,
           devices: $d, users: ($g | map(.users) | add), events: ($g | map(.events) | add),
           baseline: (($b * 10 | round) / 10), verdict: diag_spike($d; $b; $min; $mult)})
  | sort_by(-.devices);
'

# diag_spike <设备数> <基线> <下限> <倍数> → spike | flat
diag_spike() {
  jq -rn --argjson d "$1" --argjson b "$2" --argjson min "$3" --argjson mult "$4" \
    "$_DIAG_JQ_DEFS"' diag_spike($d; $b; $min; $mult)'
}

# diag_dedupe <alerted.json 内容> <签名> <当前 epoch 秒> <窗口秒> → send | skip
diag_dedupe() {
  local a="${1:-}"
  [ -n "$a" ] || a='{}'
  jq -rn --argjson a "$a" --arg k "$2" --argjson now "$3" --argjson w "$4" \
    "$_DIAG_JQ_DEFS"' diag_send(($a[$k] // {}).sent; $now; $w)'
}

# diag_evaluate <当前小时行 JSON 数组> <历史行 JSON 数组> <小时 "YYYY-MM-DD HH"> <下限> <倍数>
# → JSON 数组 [{sig, target, code, devices, users, events, baseline, verdict}]，按设备数降序
#   基线 = 前 7 天同一小时签名级设备数的均值；历史里没有那一天那一小时的行按 0 计。
#   ⚠️ 「历史完整」由调用方保证（不足 7 天先回填，回填失败非零退出）——这里分辨不了
#      「那小时确实是 0」与「本地聚合缺了那小时」，所以不能把补齐责任交给本函数。
diag_evaluate() {
  jq -cn --argjson cur "$1" --argjson hist "$2" --arg h "$3" \
         --argjson min "$4" --argjson mult "$5" "$_DIAG_JQ_DEFS"'
    diag_eval($cur; $hist; "h"; $h; [range(1; 8) | hour_shift($h; -24 * .)]; $min; $mult)'
}

# diag_evaluate_days <日 "YYYY-MM-DD"> <下限> <倍数>，stdin = 日聚合行 JSON 数组（含当日与前 7 天） → 同 diag_evaluate
#   ⚠️ 行数据走 stdin 不走位置参数：7 天日聚合约 0.7 MB、35 天约 3 MB，作为参数传给 jq 会撞
#      macOS 1 MB 的参数长度上限（ARG_MAX，2026-11-26 回填实测「Argument list too long」）。
#   行 = diag-daily.sql 的输出（{d, kind, plat, ver, s1, s2, devices, users, events}），**只判接口类**（kind=api）：
#   日级阈值只对接口类回测过（tasks 1.3）；流程类不判激增（design 决策 2）。
#   签名级 = 跨平台、跨版本相加（同日升级版本的设备会被数两次，量级可忽略）；基线 = 前 7 天均值。
diag_evaluate_days() {
  jq -c --arg d "$1" --argjson min "$2" --argjson mult "$3" "$_DIAG_JQ_DEFS"'
    [ .[] | select(.kind == "api") | . + {target: .s1, code: .s2} ] as $rows
    | diag_eval($rows; $rows; "d"; $d; [range(1; 8) | day_shift($d; -.)]; $min; $mult)'
}

# diag_daily_table <日> <kind: api|flow> <版本 JSON {"IOS":[…],"ANDROID":[…]}> <条数> <diag_evaluate_days 输出>，
#   stdin = 日聚合行 JSON 数组（含当日与前 7 天；走 stdin 的理由同 diag_evaluate_days）
# → CSV（无表头）：平台,版本,签名,设备,用户,前 7 日均值,激增
#   行 = 平台 × 版本 × 签名，只取给定版本，按设备数降序取前 N。
#   「前 7 日均值」是**这一行（同平台同版本同签名）**的均值——新版本上线头几天自然偏低，这是事实不是缺陷。
#   「激增」按签名级判（跨平台跨版本，同 diag_evaluate_days）：命中写「🚨 全版本 X 台 vs 均值 Y」，否则「—」；
#   流程类写「不判」（未回测，design 决策 2）。
diag_daily_table() {
  jq -r --arg d "$1" --arg kind "$2" --argjson vers "$3" --argjson n "$4" --argjson ev "$5" "$_DIAG_JQ_DEFS"'
    . as $cur | . as $hist
    | def plat: if . == "IOS" then "iOS" elif . == "ANDROID" then "Android" else . end;
    def rk: [.plat, .ver, .s1, .s2] | join("\u0001");
    ([range(1; 8) | day_shift($d; -.)]) as $prev
    | ([ $hist[] | select(.kind == $kind and (.d as $x | $prev | index($x))) ]
       | group_by(rk) | map({key: (.[0] | rk), value: ((map(.devices) | add) / 7)}) | from_entries) as $base
    | ([ $ev[] | select(.verdict == "spike") | {key: .sig, value: .} ] | from_entries) as $sp
    | [ $cur[] | select(.d == $d and .kind == $kind)
        | select(.plat as $p | .ver as $v | ($vers[$p] // []) | index($v)) ]
    | sort_by(-.devices) | .[:$n][]
    | (.s1 + " × " + .s2) as $sig
    | [ (.plat | plat), .ver, $sig, (.devices | tostring), (.users | tostring),
        ((($base[rk] // 0) * 10 | round) / 10 | tostring),
        (if $kind != "api" then "不判"
         elif $sp[$sig] then "🚨 全版本 \($sp[$sig].devices) 台 vs 均值 \($sp[$sig].baseline)"
         else "—" end) ]
    | @csv'
}

# diag_plan <alerted.json 内容> <diag_evaluate 输出> <小时> <当前 epoch 秒> <窗口秒>
# → {send:[<evaluate 条目> + {first}], state:<新的 alerted.json>}
#   本轮激增的首个小时：状态里最近一次激增落在 [上一小时, 下一小时]（下一小时 = 先复判、再判本小时时，
#   或同一小时重跑时状态已前移一小时）→ 沿用 first（取与本小时较早的那个），否则就是本小时。
#   last 只前移不后退：复判上一小时不能把 last 拉回去、丢掉更早的 first。
#   状态比本小时新一小时以上（回放旧小时）→ 状态条目原样保留：⛔ 不把不连续的激增并成一段（审查 2026-11-27 #3）。
#   ⚠️ 这里**不改 sent**：投递成功后才由 diag_mark_sent 写入——未配置目标或投递失败时，
#      下一小时仍在激增就会再试，不会因为「记成已发」而整整 6 小时没人知道。
#   状态里 last 早于 7 天的条目清掉，文件不无限增长。
diag_plan() {
  local a="${1:-}"
  [ -n "$a" ] || a='{}'
  jq -cn --argjson a "$a" --argjson ev "$2" --arg h "$3" --argjson now "$4" --argjson w "$5" \
    "$_DIAG_JQ_DEFS"'
    hour_shift($h; -1) as $h1
    | hour_shift($h; 1) as $h2
    | hour_shift($h; -24 * 7) as $old
    | [ $ev[] | select(.verdict == "spike")
        | ($a[.sig] // {}) as $p
        | ($p.last // "") as $pl
        | (if $pl >= $h1 and $pl <= $h2 and $p.first != null then ([$p.first, $h] | min) else $h end) as $first
        | . + {first: $first,
               st: (if $pl > $h2 then $p else {sent: ($p.sent // null), first: $first, last: ([$pl, $h] | max)} end),
               decision: diag_send($p.sent // null; $now; $w)} ] as $sp
    | { send: [ $sp[] | select(.decision == "send") | del(.decision, .st) ],
        state: ( ($a | with_entries(select((.value.last // "") >= $old)))
                 + ( [ $sp[] | {key: .sig, value: .st} ] | from_entries ) ) }'
}

# diag_mark_sent <alerted.json 内容> <签名 JSON 数组> <当前 epoch 秒> → 新的 alerted.json
diag_mark_sent() {
  jq -cn --argjson a "$1" --argjson ks "$2" --argjson now "$3" '
    reduce $ks[] as $k ($a; .[$k] = ((.[$k] // {}) + {sent: $now}))'
}

# diag_pick <时间字段名 d|h>，stdin = 行 JSON 数组（日或小时聚合，带 plat / ver / src；没有 src 的旧行按 ga4 算）
# → 每个「平台 × 版本 × MYT 日」只留一个数据源的行（JSON 数组）：取该桶设备数之和较大的那边，相等取 posthog。
#   为什么不按版本号划分界（design 决策 8，11-27 审查推翻了初版）：App 从 iOS 2.1.2、Android 2.1.1 起改发 PostHog，
#   但还没合入迁移的开发分支照样发 GA4——Android 2.2.0 在 GA4 一直有数据、PostHog 里没有（11-27 实测）。
#   「版本号越大越晚迁移」不成立，按数据在哪边就取哪边。⛔ 不两边相加：分界前后的 QA / 内部包两边都可能有零星数据。
#   按天选、不按整段选：同一版本迁移前后几天两边都有，按天取多的一边，基线不会被另一边的零星数据带偏。
#   ⚠️ 行数据走 stdin（35 天日聚合约 3 MB，理由同 diag_evaluate_days）。
diag_pick() {
  jq -c --arg tk "$1" '
    def bucket: [.plat, .ver, (.[$tk] | .[0:10])] | join("\u0001");
    map(. + {src: (.src // "ga4")}) as $rows
    | ($rows | group_by(bucket)
       | map({key: (.[0] | bucket),
              value: ( (map(select(.src == "posthog") | .devices) | add // 0) as $p
                     | (map(select(.src == "ga4") | .devices) | add // 0) as $g
                     | if $p >= $g then "posthog" else "ga4" end )})
       | from_entries) as $win
    | [ $rows[] | select(.src == $win[bucket]) ]'
}

# diag_day_gaps <MYT 日 JSON 数组 ["YYYY-MM-DD",…]>，stdin = 日聚合行 JSON 数组（**未经 diag_pick**，带 src）
# → 「来源@日」（空格分隔，空串 = 没有断数）：该来源这一天 0 行，而前 7 天每天都有行。
#   某天 0 行也会被记成「取过」（PostHog 摄入中断时接口照样回 200 + 空结果），两个来源合在一起看，
#   一边的 0 会被另一边的行盖住、谁都发现不了（审查 #4）。稀疏的来源（新版本刚放量）前 7 天凑不齐，不会误报。
diag_day_gaps() {
  jq -r --argjson ds "$1" "$_DIAG_JQ_DEFS"'
    map(. + {src: (.src // "ga4")}) as $rows
    | ([ $rows[] | [.src, .d] | join("@") ] | unique) as $have
    | [ $ds[] as $d | ("ga4", "posthog") as $s
        | select(($have | index($s + "@" + $d)) == null)
        | select([range(1; 8) | day_shift($d; -.)] | all(. as $x | ($have | index($s + "@" + $x)) != null))
        | $s + "@" + $d ]
    | join(" ")'
}

# diag_pick_suffix <已存在的表名（换行分隔）> <UTC 日期 YYYYMMDD> → 表后缀（日表优先）或空串
#   ⛔ 同一 UTC 日日表与 intraday 并存时只能取一张（intraday 约滞后一天才删，内容几乎一样）。
diag_pick_suffix() {
  if printf '%s\n' "$1" | grep -qx "events_$2"; then printf '%s' "$2"
  elif printf '%s\n' "$1" | grep -qx "events_intraday_$2"; then printf 'intraday_%s' "$2"
  fi
  return 0
}

# diag_missing <历史行 JSON 数组（含当前小时，**未经 diag_pick**，带 src）> <小时> → 断数的来源（空格分隔，如 "ga4"；空串 = 正常）
#   按来源分别判（design 决策 8）：该来源本小时与上一小时都没有任何行，而前 7 天同一小时**每天**都有行 → 断数。
#   ⛔ 不能两边合起来判：GA4 导出中断会被 PostHog 的行盖住（11-27 双向测试）。
#   「每天都有」而不是「任一天有」：来源的量一小（新版本刚放量的 PostHog、用户迁走后的 GA4），
#   夜里连续两小时为 0 是常态，「任一天有」会天天误报（审查 #3）；量大的来源每小时都有，照样抓得到中断。
#   代价：一次中断后的 7 天里，同一小时再断不报（基线那天缺着）。
diag_missing() {
  jq -rn --argjson rows "$1" --arg h "$2" "$_DIAG_JQ_DEFS"'
    [ ("ga4", "posthog") as $s
      | ([ $rows[] | select((.src // "ga4") == $s) | .h ] | unique) as $have
      | def has($x): ($have | index($x)) != null;
      select((has($h) or has(hour_shift($h; -1))) | not)
      | select([range(1; 8) | hour_shift($h; -24 * .)] | all(has(.)))
      | $s ]
    | join(" ")'
}

# diag_card <待发条目 JSON（diag_plan 的 send，每条可带 geo/cfg 分布）> <小时> <ok | 断数来源的显示名，如「GA4」> <下限> <倍数> [recheck]
# → 飞书卡片 JSON（schema 2.0）
#   第 6 个参数为 recheck = 复判补报卡：<小时> 是上一小时，整点后 5 分钟判定时没到阈值、整点后 1 小时 5 分钟复判才到
#  （晚到事件）。标题、表头与脚注第一句随之改写，其余版式相同。
#   geo = [{k1:plat, k2:country, k3:ver, devices, affected}]；cfg = [{k1:source_type, k2:data_id, devices, affected}]
#   ⛔ 只给分布，不写根因（spec「每小时激增告警」）。「共同点」只是把各签名的分布并起来数，不是结论。
#   版式（2026-11-27 按读卡顺序重排）：标题带签名数 → 共同点一行 → 一张表（设备 / 账号 / 基线 / 倍数）
#   → 每个签名一行分布（按「平台 版本」分组）→ 灰字脚注（数字偏低的原因、判定规则、来源）。
#   ⚠️ 倍数 = 设备 / max(基线, 1)，与判定口径一致（基线不足 1 按 1 计）。
#   ⚠️ 配置分布写「受影响 M 台里 N 台上报」不写构成比：一台设备同一小时可拿到多份配置，相加会超过 100%。
diag_card() {
  jq -cn --argjson s "$1" --arg h "$2" --arg miss "$3" --argjson min "$4" --argjson mult "$5" --arg mode "${6:-}" '
    ($mode == "recheck") as $re
    | def plat: if . == "IOS" then "iOS" elif . == "ANDROID" then "Android" else . end;
    def ratio: (.devices / ([.baseline, 1] | max)) as $r | if $r >= 10 then ($r | round | tostring) else (($r * 10 | round) / 10 | tostring) end;
    def hm: .[11:13] + ":00";
    def country: if . == "" then "未知" else . end;
    # 某签名的分布：取设备数前 6 的「平台 × 国家 × 版本」，按「平台 版本」分组，组按组内最大值排序
    def geo_line:
      ((.geo // []) | sort_by(-.devices) | .[:6]) as $g
      | if ($g | length) == 0 then "分布：无"
        else ($g | group_by([.k1, .k3]) | sort_by(-(map(.devices) | max))
              | map((.[0].k1 | plat) + " " + .[0].k3 + "：" + (map((.k2 | country) + " " + (.devices | tostring)) | join(" · ")))
              | join("｜")) end;
    def cfg_line:
      if (.cfg // []) | length > 0 then
        "策略配置：受影响 " + ((.cfg[0].affected // .devices) | tostring) + " 台里 "
        + ([.cfg[].devices] | add | tostring) + " 台次上报 · "
        + ([ (.cfg | sort_by(-.devices) | .[:3])[] | .k1 + " " + .k2 + " " + (.devices | tostring) + " 台" ] | join(" · "))
      elif has("cfg") then "策略配置：受影响设备" + (if $re then "该小时" else "本小时" end) + "没有上报"
      else "" end;
    # 共同点：多个签名时，把分布并起来看（平台、错误码相同就点出来；设备最多的版本、国家）
    def common:
      ([ $s[].geo // [] | .[] ]) as $all
      | if ($s | length) < 2 or ($all | length) == 0 then ""
        else ([ $all[].k1 ] | unique) as $ps
        | ([ $s[].code ] | unique) as $cs
        | ($all | group_by(.k3) | map({k: .[0].k3, n: (map(.devices) | add)}) | max_by(.n) | .k) as $v
        | ($all | group_by(.k2) | map({k: (.[0].k2 | country), n: (map(.devices) | add)}) | max_by(.n) | .k) as $c
        | "共同点：" + ([ (if ($ps | length) == 1 then "都在 " + ($ps[0] | plat) else empty end),
                          (if ($cs | length) == 1 then "都是 " + $cs[0] else empty end),
                          "设备最多的版本 " + $v + "、国家 " + $c ] | join(" · "))
        end;
    ($s | length) as $n
    | {schema: "2.0", config: {width_mode: "fill"},
       header: {template: (if $n > 0 then "red" else "orange" end),
                title: {tag: "plain_text",
                        content: (if $n > 0 and $re then "🚨 技术诊断报错激增（复判补报）· " + $h + ":00（MYT）· " + ($n | tostring) + " 个接口"
                                  elif $n > 0 then "🚨 技术诊断报错激增 · " + $h + ":00（MYT）· " + ($n | tostring) + " 个接口"
                                  else "⚠️ 技术诊断数据缺失 · " + $h + ":00（MYT）" end)}},
       body: {elements: (
         (if $n > 0 then
            (common as $cm | if $cm == "" then [] else [{tag: "markdown", content: ("**" + $cm + "**")}] end)
            + [{tag: "markdown", content: (
                 "| 接口 × 错误码 | " + (if $re then "该小时" else "本小时" end) + " | 前 7 天同小时 | 倍数 |\n|---|---|---|---|\n"
                 + ([ $s[] | "| " + .target + " × " + .code
                      + " | **" + (.devices | tostring) + " 台** · " + (.users | tostring) + " 账号"
                      + " | " + (.baseline | tostring) + " | " + ratio + "×"
                      + (if (.first // $h) < $h then "（从 " + (.first | hm) + " 起持续）" else "" end) + " |" ] | join("\n")))},
               {tag: "hr"}]
            + [ $s[] | {tag: "markdown", content: (
                  "**" + .target + " × " + .code + "**\n" + geo_line
                  + (cfg_line as $l | if $l == "" then "" else "\n" + $l end))} ]
          else [] end)
         + (if $miss != "ok" then
              [{tag: "markdown", content: ("**数据缺失**：" + $h + ":00 与前一小时 " + $miss + " 一侧没有任何接口类诊断数据，而前 7 天同一小时每天都有——不是「平稳」，可能是上报或导出中断")}]
            else [] end)
         + [{tag: "div", text: {tag: "plain_text", text_size: "notation", text_color: "grey",
              content: ((if $re then "复判补报：这一小时在整点后 5 分钟那次没有判成激增（通常是晚到事件还没进表），整点后 1 小时 5 分钟用更完整的数据复判才达到，所以晚报一小时"
                         else "「本小时」是整点后 5 分钟判定时已入表的量，晚到事件只会让它更大（实测曾只到完整数据的一半）；下一小时会复判一次，补报漏掉的签名" end)
                        + " · 激增 = ≥" + ($min | tostring) + " 台且 ≥" + ($mult | tostring) + "× 前 7 天同小时均值，同一签名 6 小时内只报一次"
                        + (if [ $s[] | select(.users == 0) ] | length > 0 then " · 0 账号 = 这些设备都没登录" else "" end)
                        + " · 来源：app_diagnostic · api_result（物理请求），GA4 与 PostHog Logs 同一版本取设备多的一边（PostHog 只算 production、无国家）"
                        + " · 只给分布，不判断根因")}}])}}'
}

# diag_need_dates <coverage.json 内容> <UTC 日期 JSON 数组 ["YYYYMMDD",…]> → 还要取的日期（空格分隔）
#   coverage.json = {<YYYYMMDD>: {src:"daily"|"intraday", at:<取数 epoch 秒>}}
#   取自日表 → 完整；取自 intraday 且取数时刻 ≥ 次日 UTC 00:05 → 视为完整（晚到事件只差几分钟，
#   design 决策 4）；否则（没取过 / 取的时候那天还没过完）→ 要取。
diag_need_dates() {
  local c="${1:-}"
  [ -n "$c" ] || c='{}'
  jq -rn --argjson c "$c" --argjson ds "$2" '
    [ $ds[] | . as $d | ($c[$d] // null) as $e
      | select($e == null
               or (($e.src // "") != "daily"
                   and ($e.at // 0) < (($d | strptime("%Y%m%d") | mktime) + 86400 + 300))) ]
    | join(" ")'
}

# diag_need_days <daily-coverage.json 内容> <MYT 日 JSON 数组 ["YYYY-MM-DD",…]> → 还要取的日（空格分隔）
#   daily-coverage.json = {<YYYY-MM-DD>: <取数 epoch 秒>}；该日 MYT 次日 00:05 之后取的才算完整
#  （MYT 日结束 = UTC 当日 16:00，那时两张 UTC 表里这一天的事件都已进表；晚到事件只差几分钟）。
diag_need_days() {
  local c="${1:-}"
  [ -n "$c" ] || c='{}'
  jq -rn --argjson c "$c" --argjson ds "$2" '
    [ $ds[] | . as $d
      | select(($c[$d] // 0) < (($d | strptime("%Y-%m-%d") | mktime) - 8 * 3600 + 86400 + 300)) ]
    | join(" ")'
}

# diag_weekly <跑批日 D "YYYY-MM-DD"> <版本 JSON {"IOS":[…],"ANDROID":[…]}> <条数> <新签名下限> <高位下限>，
#   stdin = 日聚合行 JSON 数组（覆盖跑批日前 35 天，约 3 MB——必须走 stdin，理由同 diag_evaluate_days）
# → {week:[起,止], prev:[起,止], top:[…], new:[…], high:[…]}（周报「技术诊断报错」一节，spec「周报呈现技术诊断报错」）
#   本周 = D-7 … D-1，上周 = D-14 … D-8，前 4 周 = D-35 … D-8（均为完整 MYT 日）。
#   ⚠️ 周内的去重设备数**不能**由日数相加得到，这里一律给「日均受影响设备」= 7 天日值之和 / 7（缺日按 0）。
#   top：**签名级**（跨平台跨版本相加）两类各取前 N，按本周日均降序；wow = 环比 %（上周为 0 → null）；
#        by_ver = 该签名在给定版本（周报主力版本）里的本周日均分布。
#        ⛔ 不按「平台 × 版本」算环比：新版本上周还没放量，环比会算出 +50289% 这种数字，
#           读者会当成故障（2026-11-26 W1 实测：strategy_invalid_resource 在 iOS 2.1.0 上 957 vs 1.9）。
#   new：签名级（跨平台跨版本）在前 4 周**一行都没有**、本周单日峰值 ≥ 新签名下限；给首次出现日与峰值。
#   high：只看接口类，签名级本周与上周日均都 ≥ 高位下限（流程类常年几千台，进来只会每周刷屏）。
diag_weekly() {
  jq -c --arg D "$1" --argjson vers "$2" --argjson n "$3" \
        --argjson nmin "$4" --argjson hmin "$5" "$_DIAG_JQ_DEFS"'
    . as $rows
    | def sig: .s1 + " × " + .s2;
    def r1: (. * 10 | round) / 10;
    def plat: if . == "IOS" then "iOS" elif . == "ANDROID" then "Android" else . end;
    day_shift($D; -7) as $w0 | day_shift($D; -1) as $w1
    | day_shift($D; -14) as $p0 | day_shift($D; -8) as $p1
    | day_shift($D; -35) as $h0
    | def inw: .d >= $w0 and .d <= $w1;
      def inp: .d >= $p0 and .d <= $p1;
      def inh: .d >= $h0 and .d <= $p1;
      def avg($xs): (($xs | map(.devices) | add) // 0) / 7;
    ( $rows | group_by([.kind, sig])
      | map(. as $g | {kind: $g[0].kind, sig: ($g[0] | sig),
                       this_avg: (avg([ $g[] | select(inw) ]) | r1), prev_avg: (avg([ $g[] | select(inp) ]) | r1),
                       by_ver: ([ $g[] | select(inw) | select(.plat as $p | .ver as $v | ($vers[$p] // []) | index($v)) ]
                                | group_by([.plat, .ver])
                                | map({plat: (.[0].plat | plat), ver: .[0].ver, this_avg: (avg(.) | r1)})
                                | map(select(.this_avg > 0)) | sort_by(-.this_avg))})
      | map(select(.this_avg > 0) | . + {wow: (if .prev_avg > 0 then ((.this_avg - .prev_avg) / .prev_avg * 100 | round) else null end)})
      | sort_by(-.this_avg)
      | (map(select(.kind == "api")) | .[:$n]) + (map(select(.kind == "flow")) | .[:$n]) ) as $top
    | ( $rows | group_by([.kind, sig])
        | map(. as $g
              | ([ $g[] | select(inw) ] | group_by(.d) | map({d: .[0].d, dev: (map(.devices) | add)})) as $wd
              | {kind: $g[0].kind, sig: ($g[0] | sig), hist: ([ $g[] | select(inh) ] | length),
                 first: ($wd | map(.d) | min), peak: (($wd | map(.dev) | max) // 0),
                 this_avg: (avg([ $g[] | select(inw) ]) | r1), prev_avg: (avg([ $g[] | select(inp) ]) | r1)}) ) as $s
    | {week: [$w0, $w1], prev: [$p0, $p1], top: $top,
       new: [ $s[] | select(.hist == 0 and .peak >= $nmin) | {kind, sig, first, peak, this_avg} ] | sort_by(-.peak),
       high: [ $s[] | select(.kind == "api" and .this_avg >= $hmin and .prev_avg >= $hmin) | {sig, this_avg, prev_avg} ] | sort_by(-.this_avg)}'
}

# diag_l0_line <ok: true|false> <error 文本> <上次运行 epoch 秒> <当前 epoch 秒> <最长间隔秒>
# → L1 卡片上的一行（L0 健康时为空串）。
#   L0 停摆没有别的东西会发现：cron 没触发时 L0 根本不跑，它自己的失败告警也就发不出来；
#   锁被残留占住时每轮「跳过」也不更新 health。所以由每天必跑的 L1 看一眼 health-diag.json。
#   调用方只在 health-diag.json **存在**时调用（不存在 = L0 未启用，卡片保持原样）。
diag_l0_line() {
  local ok="$1" err="$2" last="$3" now="$4" max="$5" age
  age=$(( now - last ))
  if [ "$age" -gt "$max" ]; then
    printf '⚠️ L0 每小时诊断告警已 %s 小时没有运行——定时任务可能停了，期间的接口激增不会告警' "$(( age / 3600 ))"
  elif [ "$ok" != true ]; then
    printf '⚠️ L0 每小时诊断告警最近一次失败：%s' "$(printf '%s' "$err" | cut -c1-80)"
  fi
  return 0
}
