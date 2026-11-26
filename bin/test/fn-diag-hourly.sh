#!/usr/bin/env bash
# L0 每小时诊断告警的端到端夹具（change crash-tech-diagnostics tasks 4.1–4.4）。
#
# 跑的是**真的 bin/diag-hourly.sh**（它自己就是 set -euo pipefail + errtrace + ERR trap 的生产设置），
# 只把两个外部命令换成桩：bq（按 SQL 里的表后缀回放夹具行）与 lark-cli（只记录调用）。
# 零 BigQuery 字节、零飞书调用。投递目标只能经 $STATE/local.env 给——这正是被测的约束之一。
#
# 夹具数据（MYT 2026-11-23 18 点判定，UTC 日 20261123；基线 UTC 日 20261116～20261122）：
#   /app/v2/onboarding-journey/bootstrap × http_409：前 7 天 18 点每天 2 台 → 当天 18 点 35 台、19 点 40 台（激增）
#   /app/v1/shop/purchase × biz_40010：每天 18 点 40 台 → 当天 42 台（平稳）
ROOT="${CRASH_REPORT_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}"
. "$ROOT/bin/test/harness.sh"

T="$(mktemp -d)"
trap '[ -n "${KEEP_T:-}" ] || rm -rf "$T"' EXIT
mkdir -p "$T/bin" "$T/state" "$T/fx"
unset HERMES_HOME OPENCLAW_HOME CRASH_REPORT_ALERT_CHAT_ID CRASH_REPORT_DIAG_ALERT_CHAT_ID CRASH_REPORT_BQ_CACHE

# ── 夹具行 ──
python3 - "$T/fx/rows.json" <<'PY'
import json, sys
rows = []
for d in range(16, 23):
    rows.append({"h": f"2026-11-{d} 18", "plat": "IOS", "ver": "2.1.1", "target": "/app/v2/onboarding-journey/bootstrap", "code": "http_409", "devices": "2", "users": "2", "events": "2"})
    rows.append({"h": f"2026-11-{d} 18", "plat": "IOS", "ver": "2.1.1", "target": "/app/v1/shop/purchase", "code": "biz_40010", "devices": "40", "users": "40", "events": "50"})
    rows.append({"h": f"2026-11-{d} 17", "plat": "IOS", "ver": "2.1.1", "target": "/app/v1/shop/purchase", "code": "biz_40010", "devices": "5", "users": "5", "events": "5"})
for h, n in (("17", 13), ("18", 35), ("19", 40)):
    rows.append({"h": f"2026-11-23 {h}", "plat": "IOS", "ver": "2.1.1", "target": "/app/v2/onboarding-journey/bootstrap", "code": "http_409", "devices": str(n), "users": str(n - 2), "events": str(n * 10)})
rows.append({"h": "2026-11-23 18", "plat": "IOS", "ver": "2.1.1", "target": "/app/v1/shop/purchase", "code": "biz_40010", "devices": "42", "users": "42", "events": "60"})
json.dump(rows, open(sys.argv[1], "w"))
PY
cat > "$T/fx/breakdown.json" <<'JSON'
[{"dim":"geo","sig":"/app/v2/onboarding-journey/bootstrap × http_409","k1":"IOS","k2":"Saudi Arabia","k3":"2.1.1","devices":"14","affected":"35"},
 {"dim":"cfg","sig":"/app/v2/onboarding-journey/bootstrap × http_409","k1":"experiment","k2":"2124743975533666306","k3":"","devices":"18","affected":"35"}]
JSON

# ── 桩：bq ──（按 SQL 里 _TABLE_SUFFIX IN (...) 的表回放；每次调用记一行到 bq.calls）
cat > "$T/bin/bq" <<'STUB'
#!/usr/bin/env bash
sql="$(cat)"
printf '%s\n' "$*" >> "$FAKE_DIR/bq.calls"
python3 - "$FAKE_DIR" "$sql" <<'PY'
import json, os, re, sys, datetime as dt
d, sql = sys.argv[1], sys.argv[2]
log = open(os.path.join(d, "bq.sql"), "a"); log.write(sql + "\n-----\n")
if "__TABLES__" in sql:
    want = re.findall(r"'(events_[a-z_0-9]+)'", sql)
    have = os.environ.get("FAKE_TABLES", "").split()
    print("table_id"); [print(t) for t in want if t in have]
    sys.exit(0)
sufs = re.search(r"_TABLE_SUFFIX IN \(([^)]*)\)", sql).group(1)
days = {s.strip().strip("'").replace("intraday_", "") for s in sufs.split(",")}
if "affected AS" in sql:
    print(open(os.path.join(d, "fx", "breakdown.json")).read()); sys.exit(0)
empty = set(os.environ.get("FAKE_EMPTY_DAYS", "").split())
if os.environ.get("FAKE_BQ_FAIL") == "1":
    sys.stderr.write("fake bq failure\n"); sys.exit(2)
def utcday(h):
    return (dt.datetime.strptime(h, "%Y-%m-%d %H") - dt.timedelta(hours=8)).strftime("%Y%m%d")
rows = [r for r in json.load(open(os.path.join(d, "fx", "rows.json"))) if utcday(r["h"]) in days and utcday(r["h"]) not in empty]
print(json.dumps(rows))
PY
STUB
# ── 桩：lark-cli ──（记录参数；FAKE_LARK_FAIL=1 时失败）
cat > "$T/bin/lark-cli" <<'STUB'
#!/usr/bin/env bash
printf '%s' "$*" | tr '\n' ' ' >> "$FAKE_DIR/lark.calls"; echo >> "$FAKE_DIR/lark.calls"   # 一次调用一行（卡片内容里有换行）
if [ "${FAKE_LARK_FAIL:-0}" = 1 ]; then echo '{"ok":false,"error":"fake"}'; exit 1; fi
echo '{"ok":true,"data":{"message_id":"om_fake123"}}'
STUB
chmod +x "$T/bin/bq" "$T/bin/lark-cli"
echo "PATH=\"$T/bin:$PATH\"" > "$T/state/path.env"
export FAKE_DIR="$T" CRASH_REPORT_STATE_DIR="$T/state" CRASH_REPORT_ROOT="$ROOT"
ALL_TABLES="$(for d in 16 17 18 19 20 21 22; do printf 'events_202611%s ' "$d"; done)events_intraday_20261123"
export FAKE_TABLES="$ALL_TABLES"

run() { # $1=小时 → 退出码；输出进 $T/last.log
  local rc=0
  CRASH_REPORT_DIAG_HOUR="$1" bash "$ROOT/bin/diag-hourly.sh" > "$T/last.log" 2>&1 || rc=$?
  return "$rc"
}
nlark() { [ -f "$T/lark.calls" ] && wc -l < "$T/lark.calls" | tr -d ' ' || echo 0; }
st() { jq -r "$1" "$T/state/diag/alerted.json"; }

echo "── ① 未配置投递目标：照常计算，跳过投递，不调 lark-cli（tasks 4.4）──"
# ⛔ 命令行给的同名变量必须被忽略：目标只从 local.env 读
rc=0; CRASH_REPORT_DIAG_ALERT_CHAT_ID=oc_should_be_ignored run "2026-11-23 18" || rc=$?
h_assert_eq "0" "$rc" "退出码 0"
h_assert_eq "0" "$(nlark)" "⛔ 没有任何 lark-cli 调用（命令行的 oc_ 目标被忽略）"
h_assert_contains "$(cat "$T/last.log")" "未设置 CRASH_REPORT_DIAG_ALERT_CHAT_ID" "日志写明跳过原因"
h_assert_eq "2026-11-23 18	null" "$(st '.["/app/v2/onboarding-journey/bootstrap × http_409"] | [.first, (.sent|tostring)] | @tsv')" \
  "状态记下本轮激增，但 sent 为空（没投递就不算发过）"
h_assert_eq "false" "$(st 'has("/app/v1/shop/purchase × biz_40010")')" "biz_40010 同小时基线 40 → 平稳，不进状态"
h_assert_eq "1" "$(grep -c 'onboarding-journey' "$T/state/diag/hits.jsonl" | tr -d ' ')" "命中记录写入 hits.jsonl"
h_assert_eq "true" "$(jq -r .ok "$T/state/health-diag.json")" "health-diag.json ok"
h_assert_contains "$(cat "$T/last.log")" "回填" "首次运行本地无基线 → 回填（⛔ 不当作基线为 0）"
h_assert_eq "0" "$(grep -c 'affected AS' "$T/bq.sql" | tr -d ' ')" "没有投递目标 → 不跑分布查询"
h_assert_eq "20261116 20261117 20261118 20261119 20261120 20261121 20261122 20261123" \
  "$(jq -r 'keys | join(" ")' "$T/state/diag/coverage.json")" "coverage 记下 8 个 UTC 日"
h_assert_contains "$(cat "$T/bq.calls")" "--maximum_bytes_billed=40000000000" "回填查询带 40 GB 计费上限"
h_assert_contains "$(cat "$T/bq.calls")" "--maximum_bytes_billed=10000000000" "当天查询带 10 GB 计费上限"
h_assert_contains "$(cat "$T/bq.calls")" "--max_rows=1000000" "⛔ 带 --max_rows（bq 默认只返回 100 行且不报错）"
h_assert_absent "$(cat "$T/last.log")" "以退出码" "⛔ 正常路径没有触发 ERR trap"

echo "── ② 配置私聊目标后重跑同一小时：发一张卡（上次没投递成功）──"
echo 'export CRASH_REPORT_DIAG_ALERT_CHAT_ID="ou_fixture"' > "$T/state/local.env"
: > "$T/bq.calls"; : > "$T/bq.sql"
rc=0; run "2026-11-23 18" || rc=$?
h_assert_eq "0" "$rc" "退出码 0"
h_assert_eq "1" "$(nlark)" "lark-cli 调用 1 次"
h_assert_contains "$(cat "$T/lark.calls")" "--user-id ou_fixture" "ou_ 走 --user-id"
h_assert_contains "$(cat "$T/lark.calls")" "Saudi Arabia" "卡片带国家分布"
h_assert_contains "$(cat "$T/lark.calls")" "2124743975533666306" "卡片带策略配置分布"
h_assert_eq "1795431600" "$(st '.["/app/v2/onboarding-journey/bootstrap × http_409"].sent')" "投递成功后 sent = 该小时结束时刻"
h_assert_absent "$(cat "$T/last.log")" "回填" "基线已完整 → 不再回填"
h_assert_eq "1" "$(grep -c 'affected AS' "$T/bq.sql" | tr -d ' ')" "分布查询 1 次（所有待发签名一次查完）"

echo "── ③ 同一小时第三次跑：去重，不发、不取分布 ──"
: > "$T/bq.sql"
rc=0; run "2026-11-23 18" || rc=$?
h_assert_eq "0	1" "$rc	$(nlark)" "退出码 0，lark-cli 仍只 1 次"
h_assert_eq "0" "$(grep -c 'affected AS' "$T/bq.sql" | tr -d ' ')" "不发就不跑分布查询（省 ~3 GB）"

echo "── ④ 下一小时仍激增：6 小时内不重复发，本轮首个小时沿用 18 点 ──"
rc=0; run "2026-11-23 19" || rc=$?
h_assert_eq "0	1" "$rc	$(nlark)" "退出码 0，不发"
h_assert_eq "2026-11-23 18	2026-11-23 19" "$(st '.["/app/v2/onboarding-journey/bootstrap × http_409"] | [.first, .last] | @tsv')" "first 沿用、last 前移"

echo "── ⑤ 表不存在：非零退出 + 失败告警只发私聊、只发一次（spec「检查失败不冒充平稳」）──"
rc=0; FAKE_TABLES="" run "2026-11-23 20" || rc=$?
h_assert_eq "1" "$rc" "非零退出"
h_assert_eq "false" "$(jq -r .ok "$T/state/health-diag.json")" "health-diag.json ok=false"
h_assert_eq "2" "$(nlark)" "发了 1 张失败告警"
h_assert_contains "$(tail -1 "$T/lark.calls")" "--user-id ou_fixture" "⛔ 失败告警走诊断告警目标，不回落日报群"
rc=0; FAKE_TABLES="" run "2026-11-23 21" || rc=$?
h_assert_eq "1	2" "$rc	$(nlark)" "持续失败：不再发第二张（只在成功→失败时发一次）"
rc=0; run "2026-11-23 19" || rc=$?
h_assert_eq "0" "$rc" "恢复成功"
h_assert_eq "absent" "$([ -e "$T/state/diag/.alerted-failure" ] && echo present || echo absent)" "成功后清掉失败标记"

echo "── ⑤b bq 查询失败：失败卡写具体原因，不是泛化的「未预期的失败」（审查 G6）──"
: > "$T/lark.calls"
rc=0; FAKE_BQ_FAIL=1 run "2026-11-23 20" || rc=$?
h_assert_eq "1	1" "$rc	$(nlark)" "非零退出，发 1 张失败卡"
h_assert_contains "$(cat "$T/lark.calls")" "取小时聚合失败" "失败卡里是 fail 的具体原因"
h_assert_absent "$(cat "$T/lark.calls")" "未预期的失败" "⛔ 不是子 shell 里 on_err 抢先发的泛化卡"
rm -f "$T/state/diag/.alerted-failure"
rc=0; run "2026-11-23 19" || rc=$?

echo "── ⑥ 投递失败：非零退出，sent 不写（下一小时再试）──"
jq -c 'del(.["/app/v2/onboarding-journey/bootstrap × http_409"])' "$T/state/diag/alerted.json" > "$T/a" && mv "$T/a" "$T/state/diag/alerted.json"
rc=0; FAKE_LARK_FAIL=1 run "2026-11-23 18" || rc=$?
h_assert_eq "1" "$rc" "非零退出"
h_assert_eq "true" "$(st '.["/app/v2/onboarding-journey/bootstrap × http_409"] == null')" "状态未写（失败前不落盘），下一小时照发"
rm -f "$T/state/diag/.alerted-failure"

echo "── ⑦ 当天整段无数据：卡片写「数据缺失」，不冒充平稳（tasks 4.3）──"
: > "$T/lark.calls"
rc=0; FAKE_EMPTY_DAYS=20261123 run "2026-11-23 18" || rc=$?
h_assert_eq "1	1" "$rc	$(nlark)" "⛔ 非零退出（spec：数据未更新不冒充平稳），只发 1 张卡（不叠泛化失败卡）"
h_assert_contains "$(cat "$T/lark.calls")" "数据缺失" "卡片写明数据缺失"
h_assert_eq "absent" "$(grep -q 'http_409' "$T/lark.calls" && echo present || echo absent)" "没有数据就不报任何签名激增"
h_assert_eq "false" "$(jq -r .ok "$T/state/health-diag.json")" "health-diag.json 留下失败记录"
rc=0; FAKE_EMPTY_DAYS=20261123 run "2026-11-23 18" || rc=$?
h_assert_eq "1	1" "$rc	$(nlark)" "同一小时重跑仍缺：非零退出，6 小时内不重复发卡（夹具只有 17 / 18 点的历史，19 点本就不判缺失）"
rm -f "$T/state/diag/.alerted-failure"

echo "── ⑧ 回填拿不到表：非零退出，⛔ 不当作基线为 0 ──"
rm -f "$T/state/diag/coverage.json" "$T/state/diag/hourly.jsonl"
rc=0; FAKE_TABLES="events_intraday_20261123" run "2026-11-23 18" || rc=$?
h_assert_eq "1" "$rc" "非零退出"
h_assert_contains "$(cat "$T/last.log")" "GA4 表不存在：events_202611" "日志写明缺哪张表"

h_summary
