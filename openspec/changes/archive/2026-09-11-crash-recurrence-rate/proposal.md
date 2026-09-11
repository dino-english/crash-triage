## Why

台账刚获得生命周期三态（新增 / 回归 / 长期，change `crash-report-correctness-fixes`），但「本周有几个 issue 回归」这个数没有被聚合出来——读者要自己数表格。

「回归」是唯一能观测到的**修复失效**信号：修复率依赖的 `crash:` commit 约定实测两个仓库近 120 天命中 0 条，恒为无效。

## What Changes

- L2 周报「一、本周变化」段增一行复发数。
- ⛔ **给分数不给百分比**。

## Non-goals

- ⛔ **不新增 SQL**，不重算三态——直接数已渲染的现状表。判定只在 `render-ledger.sh` 实现一次。
- ⛔ 不进 L1（生命周期基准由 L2 独占，L1 用的是另一套带版本过滤的基准，混用会误判）。
- ⛔ 不做修复率（`crash:` 约定命中 0 条，做出来恒为 0）。

## Capabilities

- `crash-perf-issue-lifecycle`（修改）：新增复发数的呈现要求。
