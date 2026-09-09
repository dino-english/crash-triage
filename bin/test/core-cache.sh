#!/usr/bin/env bash
# cache.sh 的断言（change crash-perf-functional-core，design D10）。

# ── cache_verdict：四种入参组合 + 「本次 < 上次」单列 ──────────────
assert_eq "new"    "$(cache_verdict 1 1 100 100)" \
  "强制重抓压过一切——文件在、计数没变也要 new"
assert_eq "new"    "$(cache_verdict 0 0 0 5)" \
  "文件不存在 → new（首次抓取）"
assert_eq "append" "$(cache_verdict 0 1 10 17)" \
  "计数变大 → append（有新事件，只抓增量）"
assert_eq "skip"   "$(cache_verdict 0 1 10 10)" \
  "计数相等 → skip（没有新事件）"

# ⚠️ 单列一条：滚动窗口内的 COUNT(*) 老事件出窗即下降，**不是单调量**。
# 计数下降只意味着没有新事件，跳过抓取是**正确的**；而观测字段（latest_event /
# last_synced / window_days）由外壳层每轮无条件刷新，不归本函数管——两个判定已于
# 2026-08-22（change crash-fact-cache-freshness）拆开。本用例钉住的是**修复后的正确行为**。
assert_eq "skip"   "$(cache_verdict 0 1 47 36)" \
  "本次 < 上次 → skip（窗口滑动导致计数下降，不是异常，也不该触发重抓）"
assert_eq "new"    "$(cache_verdict 1 1 47 36)" \
  "本次 < 上次但强制重抓 → 仍是 new（强制标志优先级最高）"

# ── doc_keep_predicate：日期键淘汰 + 固定键必须保留 ────────────────
DOCS='{"daily-2026-08-22":"a","daily-2026-05-01":"b","weekly-2026-08-18":"c","index":"i","ledger":"l"}'

assert_eq "daily-2026-08-22 index ledger weekly-2026-08-18" \
  "$(printf '%s' "$DOCS" | doc_keep_predicate 2026-08-01 | jq -r 'keys|join(" ")')" \
  "cutoff 内的日期键保留、早于 cutoff 的丢弃"

# ⛔ 全仓库最该有断言的一条：2026-08-18 实测 index / ledger 被误删，
#    下次运行重建了两份新飞书文档（固定 URL 因此漂移）。
assert_eq "index ledger" \
  "$(printf '%s' "$DOCS" | doc_keep_predicate 2099-01-01 | jq -r 'keys|join(" ")')" \
  "cutoff 晚于全部日期键时，无日期后缀的固定键 index / ledger 仍无条件保留"

assert_eq "daily-2026-05-01 daily-2026-08-22 index ledger weekly-2026-08-18" \
  "$(printf '%s' "$DOCS" | doc_keep_predicate 1970-01-01 | jq -r 'keys|join(" ")')" \
  "cutoff 极早 → 一条不丢"

assert_eq "index ledger" \
  "$(printf '%s' '{"index":"i","ledger":"l"}' | doc_keep_predicate 2026-08-01 | jq -r 'keys|join(" ")')" \
  "只有固定键时原样返回"

assert_eq "0" \
  "$(printf '%s' '{}' | doc_keep_predicate 2026-08-01 | jq 'length')" \
  "空台账 → 空结果，不报错"

# 边界：日期恰等于 cutoff 应保留（谓词是 >=，不是 >）
assert_eq "daily-2026-08-01" \
  "$(printf '%s' '{"daily-2026-08-01":"x"}' | doc_keep_predicate 2026-08-01 | jq -r 'keys|join(" ")')" \
  "日期恰等于 cutoff → 保留（谓词是 >= 不是 >）"

# ── 欠账补抓（change crash-fact-cache-events-backfill）────────────────
assert_eq "append" "$(cache_verdict 0 1 14 14 0)" \
  "计数为正而一条事件都没有 → 补抓（⛔ 不得判 skip：计数不涨就永远补不回来）"
assert_eq "skip"   "$(cache_verdict 0 1 29 29 5)" \
  "已存 5 · 计数 29 → 仍 skip（⛔ 不得加短缺比例判据：累积数组与滚动窗口不可比）"
assert_eq "skip"   "$(cache_verdict 0 1 10 10 10)" \
  "已存与计数相等 → skip（原语义不得回归）"
assert_eq "append" "$(cache_verdict 0 1 10 17 3)" \
  "计数上涨 → 仍 append（原语义不得回归）"
assert_eq "skip"   "$(cache_verdict 0 1 47 36 8)" \
  "计数下降且有事件 → skip（原语义不得回归）"
assert_eq "skip"   "$(cache_verdict 0 1 10 0 0)" \
  "线上计数为 0 → 无事可抓，skip（⛔ 欠账判据要求计数 > 0）"
assert_eq "skip"   "$(cache_verdict 0 1 10 10)" \
  "⛔ 省略第 5 参 → 退回旧行为，不得当成欠账（漏改的调用点不能变成每轮重抓）"
