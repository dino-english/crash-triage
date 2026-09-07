#!/usr/bin/env bash
# _mcp_split（crash-daily.sh 摘要行的 MCP OPEN 全版本三态拆分）
#
# ⛔ 本夹具的原始场景取自 2026-09-07 生产实况：63db031f 在 09-06 的 OPEN 列表里消失、
#    09-07 重现，正文表标「🔁回归」，而摘要行报「🔴 新增 1 个」——同一张卡自相矛盾。
ROOT="${CRASH_REPORT_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}"
. "$ROOT/bin/test/harness.sh"

T="$(mktemp -d)"
# 本轮 MCP OPEN（= 09-07 生产的 8 条里取 3 条代表）
cat > "$T/crash.json" <<'JSON'
{"ios":[{"id":"aaaaaaaa111122223333444455556666"}],
 "android":[{"id":"62f88f3900a1313c994871bf51c65f81"},
            {"id":"63db031f3bf602113122abbf58f9de46"},
            {"id":"bbbbbbbb111122223333444455556666"}]}
JSON
# 上一轮快照：62f88f39 在（长期），63db031f 不在（上一轮消失），bbbbbbbb 不在（真新增）
cat > "$T/snap.json" <<'JSON'
{"day":"2026-09-06","ios_ids":[],"android_ids":["62f88f3900a1313c994871bf51c65f81"]}
JSON
# 基准：63db031f 曾出现过（08-19），bbbbbbbb 从没见过
SEEN='{"63db031f3bf602113122abbf58f9de46":"2026-08-19"}'

h_load "$ROOT/bin/crash-daily.sh" _mcp_split

and_out="$(h_run _mcp_split android "$T/crash.json" "$T/snap.json" "$SEEN")"
ios_out="$(h_run _mcp_split ios     "$T/crash.json" "$T/snap.json" "$SEEN")"

h_assert_eq "1	1" "$and_out" "① Android：真新增 1（bbbbbbbb）+ 回归 1（63db031f）⛔ 旧实现在这里报「新增 2」"
h_assert_eq "1	0" "$ios_out" "② iOS：上一轮 ids 为空 → aaaaaaaa 算新增，基准里也没有"

# ⛔ 基准里有 = 回归，⛔ 不得再计进新增（这是本夹具的核心）
SEEN_ALL='{"63db031f3bf602113122abbf58f9de46":"2026-08-19","bbbbbbbb111122223333444455556666":"2026-08-20"}'
h_assert_eq "0	2" "$(h_run _mcp_split android "$T/crash.json" "$T/snap.json" "$SEEN_ALL")" \
  "③ 两条都在基准里 → 0 新增 / 2 回归"

# 基准为空 = 老行为（全算新增），由调用方改用「未区分」文案，⛔ 不在本函数里兜底
h_assert_eq "2	0" "$(h_run _mcp_split android "$T/crash.json" "$T/snap.json" '{}')" \
  "④ 基准为空 → 2 新增 0 回归（调用方据此走「本轮建立基准」文案）"

# ⚠️ 上一轮 ids 缺失（字段不存在）不得当成「全是新增之外的东西」——按空列表处理
echo '{"day":"2026-09-06"}' > "$T/snap-bare.json"
h_assert_eq "2	1" "$(h_run _mcp_split android "$T/crash.json" "$T/snap-bare.json" "$SEEN")" \
  "⑤ 上一轮无 *_ids 字段 → 三条全算「不在上一轮」，再按基准分列"

# ⛔ 平台不得串
h_assert_eq "0	1" "$(h_run _mcp_split ios "$T/crash.json" "$T/snap-bare.json" '{"aaaaaaaa111122223333444455556666":"2026-08-01"}')" \
  "⑥ iOS 单独判定，不受 android 条目影响"

# MCP 抓取失败（/dev/null）：⛔ 必须安静返回 0/0，不得触发 ERR trap
h_assert_eq "0	0" "$(h_run _mcp_split android /dev/null "$T/snap.json" "$SEEN")" "⑦ 本轮无数据 → 0/0"
h_assert_rc 0 _mcp_split android /dev/null "$T/snap.json" "$SEEN"
h_assert_rc 0 _mcp_split android "$T/crash.json" /nonexistent.json "$SEEN"

h_summary "_mcp_split"
