#!/usr/bin/env bash
# 处置结论存储（change crash-ledger-disposition-store）的函数级回归，跑在生产 shell 设置下。
#
# 起因（2026-09-23 实测）：四条带 SIGNAL_REGRESSED 的 iOS NON_FATAL issue 复核后，
# 三条的「回归」是假警报（存量老版本事件让已关闭的 issue 重开）。这些结论**无处安放**——
# NON_FATAL 现状表是按受影响安装取头部的滚动榜单，而人工结论此前唯一的存续途径就是
# 「从上一版表格解析出来再写回去」：行一掉榜，结论静默蒸发，回榜时是白纸。
#
# ⛔ 本夹具最关键的两条：
#   ① 「读不到结论」与「这条没有结论」必须可分辨——都渲成空白等于用空白暗示「已复核无问题」
#   ② 掉榜不得丢结论——这正是独立存储相对「给表加两列」的全部价值
set -uo pipefail
SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; ROOT="$(cd "$SELF/../.." && pwd)"
# shellcheck disable=SC1091
. "$SELF/harness.sh"
# shellcheck disable=SC1091
. "$ROOT/bin/lib/csv.sh"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT

ID_A=359fadbc8e8167b952a39604ec72c578   # 有结论
ID_B=09ffca3100000000000000000000beef   # 无结论（不在存储里）

cat > "$T/dispo.json" <<'JSON'
{
  "359fadbc8e8167b952a39604ec72c578": {"first_seen":"2026-09-23","disposition":"✅已验证生效","note":"修复 847a280c 进 v1.7.0+，含修复正式包 0 次"},
  "baa9399369a4d284fe35d542bb811123": {"first_seen":"2026-09-23","disposition":"✅设计内·无需修复","note":"哨兵上报，不建议改判 expected"}
}
JSON

echo "── 存储契约（spec crash-perf-disposition-store）──"
h_assert_eq "true" "$(jq -c 'to_entries|all(.key|test("^[0-9a-f]{32}$"))' "$T/dispo.json")" \
  "⛔ 键必须是完整 32 位 issue_id——短 id 会在 issue 集合变化时撞车"
h_assert_eq "true" "$(jq -c 'to_entries|all(.value|has("first_seen") and has("disposition") and has("note"))' "$T/dispo.json")" \
  "三字段齐备（first_seen / disposition / note）"
h_assert_eq "0" "$(jq -r '[to_entries[]|.value.note,.value.disposition]|map(select(test("[|]")))|length' "$T/dispo.json")" \
  "⛔ 结论里不得含裸 | ——会把一行切成两列且无任何告警（同 csv2tsv 防的那类错）"

# ── 渲染层：nf_rows 的三态（有结论 / 无结论 / 存储不可得）──
# ⚠️ nf_rows 依赖 $DISPO_JSON / $DISPO_OK / $SNAPSHOT / issue_url_prefix，照抄生产接线。
echo "── nf_rows：有结论 / 无结论 / 不可得 三态可分辨（design D5）──"
h_load "$ROOT/bin/render-ledger.sh" nf_rows
issue_url_prefix() { printf ''; }
jq -n --arg a "$ID_A" --arg b "$ID_B" '{nonfatal:{ios:[
  {issue_id:$a,title:"T1",subtitle:"S1",n:155,users:60,latest:"2026-09-21"},
  {issue_id:$b,title:"T2",subtitle:"S2",n:2,users:2,latest:"2026-09-20"}]}}' > "$T/snap.json"
SNAPSHOT="$T/snap.json"

DISPO_JSON="$(jq -c . "$T/dispo.json")"; DISPO_OK=1
out="$(h_run nf_rows iOS ios)"
h_assert_contains "$out" '| ✅已验证生效 |' "有结论的行渲染出处置状态"
h_assert_contains "$out" '含修复正式包 0 次 |' "有结论的行渲染出备注"
h_assert_eq "9" "$(printf '%s\n' "$out" | head -1 | awk -F'|' '{print NF-2}')" \
  "⛔ 列数必须是 9（原 7 列机器数据 + 处置状态 + 备注）"
h_assert_contains "$(printf '%s\n' "$out" | sed -n '2p')" '2026-09-20 |  |  |' \
  "⛔ 无结论的行末两列留空——不是「不可得」，两者含义不同"

DISPO_JSON='{}'; DISPO_OK=0
out="$(h_run nf_rows iOS ios)"
h_assert_contains "$out" '结论存储不可得' "⛔ 存储不可得必须在表内写明，不能与「尚无结论」一样渲成空白"
h_assert_eq "2" "$(printf '%s\n' "$out" | grep -c '结论存储不可得')" \
  "不可得时每一行都带标注（读者不会只看第一行）"

echo "── ⛔ 掉榜不丢结论：存储与呈现解耦（design D1，本 change 的全部价值）──"
# 上一轮 A 在榜、B 不在；本轮 A 掉榜、B 入选——存储不参与任何写入，A 的结论原样留存。
jq -n --arg b "$ID_B" '{nonfatal:{ios:[{issue_id:$b,title:"T2",subtitle:"S2",n:2,users:2,latest:"2026-09-20"}]}}' > "$T/snap2.json"
_before="$(shasum "$T/dispo.json" | cut -d' ' -f1)"
SNAPSHOT="$T/snap2.json"; DISPO_JSON="$(jq -c . "$T/dispo.json")"; DISPO_OK=1
out="$(h_run nf_rows iOS ios)"
h_assert_absent "$out" '✅已验证生效' "A 掉榜后本轮确实不呈现"
h_assert_eq "$_before" "$(shasum "$T/dispo.json" | cut -d' ' -f1)" \
  "⛔ 渲染对存储只读：掉榜没有清除 A 的结论（旧做法在这里就把它丢了）"
SNAPSHOT="$T/snap.json"; out="$(h_run nf_rows iOS ios)"
h_assert_contains "$out" '✅已验证生效' "⛔ A 回榜后结论原样重新呈现，与掉榜前一致"

echo "── 周报正文 dd_block：结论行只在有结论时出现（spec：MUST NOT 以空白暗示无问题）──"
h_load "$ROOT/bin/crash-weekly.sh" dd_block
DD_MODEL_CONC_PCT=60
printf '%s\t✅已验证生效\t修复已验证\n' "$ID_A" > "$T/dispo.tsv"
DISPO_TSV="$T/dispo.tsv"
{ printf '%s,T1,S1,screen,ChatVC,6,1,1,6,1\n' "$ID_A"
  printf '%s,T2,S2,screen,HomeVC,2,1,1,2,1\n' "$ID_B"; } > "$T/dd.csv"
out="$(h_run dd_block "$T/dd.csv" iOS 'NON_FATAL' 1)"
h_assert_contains "$out" '人工结论' "有结论的 issue 带「人工结论」行"
h_assert_contains "$out" '非当期数据推导' "⛔ 必须标明是人工沉淀，否则读者分不清判断的时效来源"
h_assert_eq "1" "$(printf '%s\n' "$out" | grep -c '人工结论')" \
  "⛔ 无结论的 issue 一行都不输出——渲染一个空结论块等于暗示「已复核没问题」"

DISPO_TSV="$T/empty.tsv"; : > "$DISPO_TSV"
out="$(h_run dd_block "$T/dd.csv" iOS 'NON_FATAL' 1)"
h_assert_contains "$out" '| Issue | 场景 |' "⛔ 存储不可得时数据表照常产出，不中止周报"
h_assert_absent "$out" '人工结论' "不可得时不伪造结论行（段首标注负责说明为什么没有）"

echo "── 源码断言：接线点（漏一个就静默失效）──"
assert_src() { # $1=文件 $2=子串 $3=说明
  if grep -qF "$2" "$ROOT/$1"; then echo "  ✅ $3"; H_PASS=$((H_PASS+1))
  else echo "  ❌ $3 —— $1 里找不到：$2"; H_FAIL=$((H_FAIL+1)); fi
}
assert_src bin/crash-weekly.sh 'DISPO_FILE="$LEDGER_DIR/dispositions.json"' \
  '存储路径在 $STATE/ledger 下，与 LEDGER.md 同级（人工资产，随台账一起备份）'
assert_src bin/crash-weekly.sh '"$DISPO_FILE" \' \
  '⛔ 必须把路径传给 render-ledger.sh——漏传会把整张表渲成「无结论」'
assert_src bin/render-ledger.sh 'DISPO_FILE="${9:?' \
  '⛔ 渲染器把它设成必填：漏传当场炸，不静默用默认值（REPOS_ROOT 那次的失效形态）'
assert_src bin/crash-weekly.sh 'if [ "$DISPO_STATE" = "corrupt" ]; then' \
  '⛔ 损坏必须让整跑非零退出，不得静默当作空存储'
# ⛔ 日报一个字不许碰（design D4：L1 MUST NOT 呈现结论）
if grep -qE 'DISPO|dispositions' "$ROOT/bin/crash-daily.sh"; then
  echo "  ❌ crash-daily.sh 出现结论存储——⛔ L1 不得呈现处置结论（spec 职责边界）"; H_FAIL=$((H_FAIL+1))
else
  echo "  ✅ ⛔ crash-daily.sh 不碰结论存储（L1 只呈现当期数据）"; H_PASS=$((H_PASS+1))
fi

h_summary
