#!/usr/bin/env bash
# docs.json 不得被写入空值（2026-09-22 生产事故）。
#
# 当天我在生产机上跑了一次分流验证，lark 写操作因非交互 ssh 拿不到凭证而全挂，
# 于是 publish_doc 拿着空 URL 调 doc_put，把 `crash-triage|index` 与
# `crash-triage|daily-2026-09-22` 两个键抹成了 ""。
# ⚠️ 后果不是「少记一条」：下一轮 doc_get 拿到空 → 走新建分支 → 建出另一份索引页，
# 而卡片、台账、群里的历史链接全指向旧的那一份，**且没有任何告警**。
# ⛔ 这不是分流特有的——生产上任何一次瞬时失败（飞书 5xx / 网络抖动）都会触发。
set -uo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SELF_DIR/../.." && pwd)"
# shellcheck disable=SC1091
. "$SELF_DIR/harness.sh"

h_load "$ROOT/bin/deliver.sh" doc_put

CACHE_NS="t"; DOC_STORE="$(mktemp)"
printf '{"t|index":"https://old/index"}\n' > "$DOC_STORE"
val() { jq -r --arg k "t|$1" '.[$k] // "<缺>"' "$DOC_STORE"; }

echo "── ⛔ 空值必须被拒绝，且**保留原值** ──"
h_run doc_put index "" >/dev/null 2>&1
h_assert_eq "https://old/index" "$(val index)" "⛔ 固定 URL 不许被抹成空——这正是当天的事故"
h_run doc_put "daily-2026-09-22" "" >/dev/null 2>&1
h_assert_eq "<缺>" "$(val daily-2026-09-22)" "⛔ 原本不存在的键也不许被创建成空值"

echo "── 正常值照常写入 ──"
h_run doc_put index "https://new/index" >/dev/null 2>&1
h_assert_eq "https://new/index" "$(val index)" "非空值正常覆盖"
h_run doc_put "daily-2026-09-22" "https://new/daily" >/dev/null 2>&1
h_assert_eq "https://new/daily" "$(val daily-2026-09-22)" "新键正常写入"

echo "── ⛔ 拒绝时不得中断投递（返回 0）──"
h_assert_rc 0 doc_put index "" '空值拒绝要 return 0——上游已经打过 ❌，这里再失败会盖掉真正的原因'

echo "── 源码断言：守卫必须在**写入点**而不是各调用点 ──"
SRC="$(cat "$ROOT/bin/deliver.sh")"
h_assert_contains "$SRC" '拒绝把空值写进 docs.json' '⛔ doc_put 自身必须有空值守卫'
rm -f "$DOC_STORE"
h_summary
