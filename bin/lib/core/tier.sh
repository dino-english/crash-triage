#!/usr/bin/env bash
# 核心层（Functional Core）——三档分档判定（change crash-report-attention-tiers）
#
# ⛔ 本层是**纯函数**：所有输入经位置参数传入，输出经 stdout 返回；不读写文件、不查数据、
#    不引用任何脚本全局变量（check-scripts 的 core 边界 lint 守着这条）。
#
# 三档：urgent（🚨 开发要修）/ release（⏳ 代码已修，等发版）/ watch（👀 今天不用动）。
# 一个 issue 只进一档，优先级 urgent > release > watch（spec crash-perf-attention-tiers）。

# tier_classify：issue 级分档。
#   $1 = issue 列表 JSON：[{plat:"ios|android", id:<32位>, title, users:<7天台数>, by_ver:"1.8.2 1 台 · …",
#                          life:"🆕新增|🔁回归|📈暴涨|长期|"(空=基线轮；暴涨只有周报给), state:"OPEN|CLOSED|MUTED|"}]
#        ——只含**报告版本集内有 FATAL 事件**的 issue
#   $2 = fixmap JSON（整份，取 .mapped；{} 表示反扫不可用）
#   $3 = 开关状态映射 JSON {<32位>: OPEN|CLOSED|MUTED}
#   $4 = TIER_NEW_MIN  $5 = TIER_LONG_MIN
# → JSON 数组，每条 {tier, plat, id, title, users, by_ver, life, state, fix_status, fix_subject, fix_commit, fixed_in, why}
#   排序：urgent → release → watch，同档按台数降序。
#
# 判据（design D1）：
#   ⛔ 「修了仍在」只有在报告版本集内 7 天仍有事件（users>0）时才进 urgent——fixmap 的
#      new_build_events 是修复提交以来的**累计量**（fix-release-builds.sql 无时间上界），单独用会让
#      早已平息的 issue 长期占据紧急档。
#   ⛔ release_check != ok 时**不依据修复状态**判 urgent / release（spec「发版判定不可得」），
#      只按台数与生命周期判——此时 why 不说「未修」，只说事实。
#   ⏳ 的来源是 fixmap 里全部「已修未发版 + ok + OPEN」，**不要求本窗口有事件**——与现 L1
#      「代码已修但未发版」计数同一判定；本窗口无事件的 users 记 0。
#   🔕 MUTED 一律 watch：静音是人做过的处置决定，不该再被顶到紧急档。
tier_classify() {
  jq -cn --argjson iss "$1" --argjson fm "$2" --argjson st "$3" \
         --argjson nmin "$4" --argjson lmin "$5" '
    ($fm.mapped // {}) as $m
    | def fx($i): ($m[$i] // {});
      def ok($i): (fx($i).release_check // "") == "ok";
      def fs($i): (fx($i).status // "");
      def subj($i): ((fx($i).subject // "") | split("\n")[0] | .[0:60]);
      def cmt($i): (fx($i).commit // "");
      def fin($i): (fx($i).fixed_in_version // "");
      def stt($i): ($st[$i] // "");
      def rank: if .tier == "urgent" then 0 elif .tier == "release" then 1 else 2 end;
    ( [ $iss[] | . as $x | $x.id as $i
        | ($x.users // 0 | tonumber) as $u
        | ($x.life // "") as $life
        | (if (stt($i) == "MUTED") then {tier:"watch", why:"已静音"}
           elif ok($i) and fs($i) == "修了仍在" and $u > 0 then
             {tier:"urgent",
              why:("修了仍在：修复 " + cmt($i)
                   + (if fin($i) != "" then " 已随 " + fin($i) + " 发版" else " 已发版" end)
                   + "，新包仍崩")}
           elif ok($i) and fs($i) == "已修未发版" then {tier:"release", why:"代码已修，含修复的版本未上线"}
           elif ok($i) and fs($i) == "已发版待验" then {tier:"watch", why:"已发版待验"}
           else
             # 走到这里 = 无修复映射，或有映射但发版判定不可得。⛔ 后者不能说「未修复」。
             (if ($m[$i] != null) and (ok($i) | not) then "修复发版判定不可得 · " else "未修复 · " end) as $fx
             | if ($life == "🆕新增" or $life == "🔁回归" or $life == "📈暴涨") and $u >= $nmin then
                 {tier:"urgent", why:((if $life == "🆕新增" then "新增" elif $life == "📈暴涨" then "暴涨" else "回归（曾消失又重现）" end) + " · " + $fx + "7 天 \($u) 台")}
               elif $u >= $lmin then
                 {tier:"urgent", why:((if $life == "长期" then "长期 · " else "" end) + $fx + "7 天 \($u) 台")}
               else {tier:"watch", why:("7 天 \($u) 台")}
               end
           end) as $t
        | $x + $t + {users:$u, fix_status:fs($i), fix_subject:subj($i), fix_commit:cmt($i), fixed_in:fin($i), state:stt($i)} ]
    ) as $a
    | ([ $a[].id ]) as $seen
    # ⏳ 补齐：本窗口无事件、但 fixmap 判「已修未发版 + ok」且 OPEN 的
    | ( [ $m | to_entries[]
          | select(.value.status == "已修未发版" and (.value.release_check // "") == "ok")
          | select(($st[.key] // "") == "OPEN")
          | select(.key as $k | $seen | index($k) | not)
          | {tier:"release", plat:(.value.platform // ""), id:.key, title:"", users:0, by_ver:"", life:"",
             state:"OPEN", fix_status:.value.status, fix_subject:((.value.subject // "") | split("\n")[0] | .[0:60]),
             fix_commit:(.value.commit // ""), fixed_in:(.value.fixed_in_version // ""),
             why:"代码已修，含修复的版本未上线"} ]
      ) as $extra
    # ⏳ 档里 CLOSED 的不计（与现 FIXED_PENDING 只数 OPEN 同一判定）
    | [ ($a + $extra)[] | select(.tier != "release" or .state == "OPEN") ]
      + [ $a[] | select(.tier == "release" and .state != "OPEN") | .tier = "watch" | .why = "代码已修（issue 非开启状态）" ]
    | sort_by([rank, -(.users)])
  '
}

# priorities_validate：周报分析层优先级契约的校验（design D2）。
#   $1 = priorities.json 原文（文件缺失时传空串）
#   $2 = 本轮快照里出现过的完整 issue id 数组 JSON（数据层 ∪ 分析层快照）
# → {ok, reason, dropped, items:[{plat, id, priority, action, why}]}，items 按 P0→P2 排序
# 校验：顶层数组；每条 issue_id 为 32 位小写十六进制**且在快照里**（防编造）；priority ∈ P0/P1/P2；
#       platform ∈ ios/android。不合规的条目剔除并计入 dropped，⛔ 不让单条坏数据作废整份。
#       action / why 超长截断不报错（模型常写长句，截断比丢弃信息量大）。
priorities_validate() {
  jq -cn --arg raw "$1" --argjson ids "$2" '
    (try ($raw | fromjson) catch null) as $p
    | if $raw == "" then {ok:false, reason:"priorities.json 缺失", dropped:0, items:[]}
      elif $p == null then {ok:false, reason:"priorities.json 不是合法 JSON", dropped:0, items:[]}
      elif ($p | type) != "array" then {ok:false, reason:"priorities.json 顶层不是数组", dropped:0, items:[]}
      else
        [ $p[] | select(type == "object")
          | {id:((.issue_id // "") | tostring | ascii_downcase),
             plat:((.platform // "") | tostring | ascii_downcase),
             priority:((.priority // "") | tostring | ascii_upcase),
             action:((.action // "") | tostring | .[0:40]),
             why:((.why // "") | tostring | .[0:40])} ] as $all
        | [ $all[] | select((.id | test("^[0-9a-f]{32}$"))
                            and (.priority == "P0" or .priority == "P1" or .priority == "P2")
                            and (.plat == "ios" or .plat == "android"))
                   | select(.id as $i | $ids | index($i)) ] as $okk
        | {ok:true, reason:"", dropped:(($p | length) - ($okk | length)), items:($okk | sort_by(.priority))}
      end'
}

# tier_counts：$1=tier_classify 的输出 → "urgent<TAB>release<TAB>watch"
tier_counts() {
  printf '%s' "$1" | jq -r '[([.[]|select(.tier=="urgent")]|length), ([.[]|select(.tier=="release")]|length), ([.[]|select(.tier=="watch")]|length)] | @tsv'
}

# perf_regressed：性能版本退化判定（design Q3）。
#   $1=判定版本值 $2=上一版本值 $3=黄档阈值 $4=退化门槛（百分比，如 20）→ 「1」或空
# 三个条件同时成立才算退化：两侧有值；判定版本已达黄档以上（挡住 0.01%→0.02% 这种
# 相对值翻倍、绝对值无意义的噪音）；相对上一版变差 ≥ 门槛。样本闸门由调用方先过。
perf_regressed() {
  { [ -n "$1" ] && [ -n "$2" ]; } || { printf ''; return 0; }
  awk -v c="$1" -v p="$2" -v y="$3" -v th="$4" \
    'BEGIN{ if (c+0 > y+0 && p+0 > 0 && (c-p)/p*100 >= th+0) print "1" }'
}

# os_label：系统主版本号 → 人读标签。$1=plat(ios|and) $2=主版本号
# Android 的 os_version 是 API level，读者认的是「Android 12」；映射表外的原样给「API n」。
os_label() {
  if [ "$1" = ios ]; then printf 'iOS %s' "$2"; return 0; fi
  case "$2" in
    36) printf 'Android 16';; 35) printf 'Android 15';; 34) printf 'Android 14';; 33) printf 'Android 13';;
    32) printf 'Android 12L';; 31) printf 'Android 12';; 30) printf 'Android 11';; 29) printf 'Android 10';;
    28) printf 'Android 9';; 27) printf 'Android 8.1';; 26) printf 'Android 8.0';;
    *) printf 'API %s' "$2";;
  esac
}

# startup_drill_summary：启动 P95 下钻的结论句。
#   $1=TSV 行（os_major n p95_ms slow，制表符分隔；无表头——调用方先过 csv2tsv，⛔ 本仓库禁 awk -F, 切 bq CSV）
#   $2=红线 ms $3=桶 P95 的样本闸门
# → TSV「主版本号列表(空格分隔)  启动占比%  慢启动占比%  拖后腿桶的慢启动数  全部慢启动数」或空
#   （标签映射与成句交给调用方：os_label 按平台映射，句式属于呈现层）
# 「拖后腿的桶」= 样本过闸门且 P95 超红线。没有这样的桶时返回空，由调用方只出图不出结论。
startup_drill_summary() {
  printf '%s\n' "$1" | awk -F'\t' -v red="$2" -v gate="$3" '
    NF>=4 && $2 ~ /^[0-9]+$/ { N+=$2; S+=$4
      if ($2+0 >= gate+0 && $3+0 > red+0) { bn+=$2; bs+=$4; lst = lst (lst==""?"":" ") $1 } }
    END { if (lst=="" || N==0 || S==0) exit
          printf "%s\t%.0f\t%.0f\t%d\t%d", lst, bn/N*100, bs/S*100, bs, S }'
}
