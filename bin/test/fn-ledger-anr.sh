#!/usr/bin/env bash
# 台账收 ANR（change crash-ledger-anr-tracking）。
#
# 起因（2026-09-22 实测）：台账里一条 ANR 都没有，而当天 Android 按受影响安装排第一的
# 就是个 ANR——4d05f9e7 nativePollOnce，20 事件 / 16 安装 / 跨三个版本 / 当天仍在发生，
# 影响面是头号 FATAL（fb6588bb 11 次 / 8 台）的两倍。
#
# ⛔ 本夹具最关键的一条是**判据不能是 top N**：当天 34 条 ANR 里 32 条受影响安装数为 1，
# 完全并列 ⇒ 谁进 top N 由 issue_id 字典序决定，新条目一出现就把旧的挤出去，
# 台账随即报「消失」、下轮报「🔁回归」——纯人造的变化（残余风险 R2 的最坏形态）。
set -uo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SELF_DIR/../.." && pwd)"
# shellcheck disable=SC1091
. "$SELF_DIR/harness.sh"

# 生产里的过滤表达式（fetch-snapshot-bq.sh 的 anrpass）复刻一份，逐条断言。
anr() { # $1=users 列表(逗号分隔) $2=阈值 $3=上界 → "入选/未入选/截断"
  jq -rn --argjson mins "$2" --argjson lim "$3" --arg us "$1" '
    ($us | split(",") | map({users: .})) as $rows
    | def anrpass: map(select((.users | tonumber) >= $mins));
      "\($rows | anrpass | length)/\(($rows | length) - ($rows | anrpass | length))/\(($rows | length) >= $lim)"'
}

echo "── 实测分布：16 / 2 / 32 个 1（阈值 2）──"
h_assert_eq "2/32/false" "$(anr "16,2,$(printf '1%.0s,' $(seq 1 31))1" 2 50)" \
  "⛔ 入选 2 条、未入选 32 条——这就是 2026-09-22 的真实分布"

echo "── ⛔ 未入选数量不得静默丢弃 ──"
h_assert_eq "0/5/false" "$(anr "1,1,1,1,1" 2 50)" "全是单设备 → 一条不入选，但 5 这个数必须给出来"
h_assert_eq "3/0/false" "$(anr "9,4,2" 2 50)"    "全部过阈值 → 未入选 0"

echo "── 阈值边界（>=，不是 >）──"
h_assert_eq "1/1/false" "$(anr "2,1" 2 50)" "等于阈值必须入选"
h_assert_eq "0/2/false" "$(anr "1,1" 2 50)" "低于阈值不入选"

echo "── 安全上界命中必须可见（⛔ 不得把被截断的结果当全量）──"
h_assert_eq "1/2/true"  "$(anr "5,1,1" 2 3)"  "返回行数 = 上界 → 截断标志为真"
h_assert_eq "1/2/false" "$(anr "5,1,1" 2 50)" "未命中上界 → 假"

echo "── 源码断言：四个接线点（漏一个就静默失效）──"
assert_src() { # $1=文件 $2=子串 $3=说明
  if grep -qF "$2" "$ROOT/$1"; then echo "  ✅ $3"; H_PASS=$((H_PASS+1))
  else echo "  ❌ $3 —— $1 里找不到：$2"; H_FAIL=$((H_FAIL+1)); fi
}
assert_src bin/render-ledger.sh 'build_rows "Android" android ANR' \
  '⛔ 现状表必须渲染 ANR 行'
assert_src bin/render-ledger.sh '((.anr.ios) // [])[], ((.anr.android) // [])[]' \
  '⛔ 生命周期基准必须收 ANR——不收则每轮 $s 为 null，永远判「🆕新增」'
assert_src bin/fetch-snapshot-bq.sh '(.anr.ios     // [])' \
  '⛔ 事实层写入循环必须纳入 ANR，否则反扫与状态同步都够不着它'
assert_src bin/test/assert-fact-cache.sh '((.anr.ios) // [])[].id' \
  '⛔ 产物断言必须覆盖 ANR，否则新增一批无新鲜度校验的记录'
assert_src bin/sql/crash-anr-issues.sql "error_type = 'ANR'" \
  'ANR 取数按 error_type，⛔ 不是 is_fatal（ANR 的 is_fatal 恒为 FALSE）'
assert_src bin/sql/crash-issues-all.sql 'WHERE is_fatal = TRUE' \
  '⛔ crash-issues-all.sql 的致命过滤一个字不许改——崩溃口径的 90 天历史依赖它'

echo "── ⛔ 卡片与文档的注解必须分开（NOTE_MD 被卡片逐字节共用）──"
# 初版把 200 多字的判据解释塞进了 NOTE_MD，实测整条糊进 card.json——
# 卡片读者要的是「有没有、几条」，不是为什么这么筛（F37 同源：共享变量的消费点没数清）。
_w="$ROOT/bin/crash-weekly.sh"
if grep -n 'ANR_LEDGER_NOTE="\$(printf' "$_w" | grep -q 'top N'; then
  echo "  ❌ 卡片用的短版里出现了长文本——它会整条进 card.json"; H_FAIL=$((H_FAIL+1))
else
  echo "  ✅ 卡片短版不含判据长文"; H_PASS=$((H_PASS+1))
fi
assert_src bin/crash-weekly.sh '[ -n "$ANR_LEDGER_LONG" ] && printf' \
  '⛔ 长版必须接在文档侧，否则写了等于没写'
if grep -nE '^\s*--arg.*ANR_LEDGER_LONG|CARD_JSON.*ANR_LEDGER_LONG' "$_w" >/dev/null 2>&1; then
  echo "  ❌ 长版被喂给了卡片"; H_FAIL=$((H_FAIL+1))
else
  echo "  ✅ 长版没有出现在卡片的 jq 参数里"; H_PASS=$((H_PASS+1))
fi
# ⛔ 长版结尾必须补换行：$(printf …) 吞尾换行，不补会和「本次运行」那行粘成同一个
# callout（md2docx「连续 > 合成一个」），排障信息被塞进 ANR 判据的 💡 框里。
# ⚠️ 2026-09-22 **实发才看出来**——本地 markdown 只是少一个空行，看不出所以然。
_needle="printf '%s\\n' \"\$ANR_LEDGER_LONG\""
assert_src bin/crash-weekly.sh "$_needle" \
  '⛔ 长版输出必须带 \\n，否则与「本次运行」粘成同一个 callout'

echo "── ⛔ ANR 带修复提交的处置状态（6.5：生产至今无样本，改用夹具喂）──"
# 起因：6.5 挂着「ANR 带修复提交的处置状态」未验，而它要等一个**真实样本**——
# 2026-09-28 生产首轮 fixmap 命中 9 条全是 FATAL/非致命，唯一的 ANR 是「未处理」。
# ⛔ 「等样本」等于永远不验。build_rows() 对 FATAL 与 ANR 的处置状态判定是**同一段 jq**
#    （只有「取哪个数组」和「类型」列取值随 etype 变），所以喂一个带 fixmap 命中的 ANR
#    就能把那条路径走完，不必等线上。
_T="$(mktemp -d)"; trap 'rm -rf "$_T"' EXIT
h_load "$ROOT/bin/render-ledger.sh" build_rows
issue_url_prefix() { printf ''; }
issue_url() { printf ''; }
DAY=2026-09-28
PREV_JSON='{}'; SEEN_JSON='{}'; SEEN_PREV_DAY=""; LIFECYCLE_OK=0; STATES_JSON='{}'
jq -n '{anr:{android:[{id:"4d05f9e74e77520b418eac3a355108f1",title:"nativePollOnce",events:20}]}}' > "$_T/snap.json"
SNAPSHOT="$_T/snap.json"

jq -n '{mapped:{"4d05f9e74e77520b418eac3a355108f1":{platform:"Android",status:"⚠️修了仍在",commit:"abc12345",subject:"fix(anr): 收敛主线程等待"}}}' > "$_T/fixmap.json"
FIXMAP="$_T/fixmap.json"
out="$(h_run build_rows Android android ANR)"
h_assert_contains "$out" '| ANR |'        '⛔ 类型列必须是 ANR（喂的是 anr 数组）'
h_assert_contains "$out" '⚠️修了仍在'      '⛔ 反扫命中时处置状态取 fixmap 的 status，ANR 与 FATAL 同一套'
h_assert_contains "$out" 'abc12345 fix(anr): 收敛主线程等待' '备注写 commit + subject'

# ⛔ 已关闭优先于反扫（失效模式 R4）——这条对 ANR 同样必须成立
STATES_JSON='{"4d05f9e74e77520b418eac3a355108f1":"CLOSED"}'
out="$(h_run build_rows Android android ANR)"
h_assert_contains "$out" '✅已关闭（abc12345）' '⛔ CLOSED 压过反扫结论，否则把关掉的 ANR 标成待跟进'
h_assert_absent  "$out" '修了仍在'          '⛔ 已关闭时不得再渲染反扫的待办文案'

# ⛔ MUTED 是第三态，不得并进 CLOSED 也不得落回「未处理」
STATES_JSON='{"4d05f9e74e77520b418eac3a355108f1":"MUTED"}'
out="$(h_run build_rows Android android ANR)"
h_assert_contains "$out" '🔕已静音（abc12345）' '⛔ MUTED 单独成态，ANR 侧同样适用'

# 负向：无反扫命中时回落「未处理」，⛔ 不得凭空出现修复文案
STATES_JSON='{}'
echo '{"mapped":{}}' > "$_T/fixmap.json"
out="$(h_run build_rows Android android ANR)"
h_assert_contains "$out" '| 未处理 |' '无命中 → 未处理'
h_assert_absent  "$out" 'abc12345'   '⛔ 不得残留上一次的修复信息'

h_summary
