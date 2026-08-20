## Why

`firebase_crashlytics` BigQuery 表已出表（REALTIME，iOS/Android 双端均可见），但日/周报的崩溃数据仍走 Firebase MCP `topIssues`，它只返回 OPEN issue——被误关的 issue（曾发生 `3fd09886` 误关事故）会从统计里消失并显示「0 崩溃」。同时崩溃率长期缺分子。迁到 BigQuery 事件级统计能消除「误关即消失」，并顺势补上崩溃率 SQL。

## What Changes

- L1 日报崩溃段：数据源从 MCP `topIssues` 换成 BigQuery `firebase_crashlytics` 事件级统计（不受 issue 开关状态影响）
- 新增崩溃率查询：分母 `firebase_sessions`（已就绪）+ 分子 `firebase_crashlytics`
- 改 `crash-daily.sh` 崩溃段、`fetch-snapshot.sh` 的崩溃抓取，新增 `sql/` 崩溃查询
- 卡片口径标注从「MCP 只返回 OPEN」改为「事件级统计，数据截止 = 表最新 event_timestamp」

## Capabilities

### New Capabilities

- `crash-source-bigquery-migration`: 崩溃数据源从 Firebase MCP 迁移到 BigQuery `firebase_crashlytics` 事件级，并新增崩溃率统计。

### Modified Capabilities

<!-- 无（原 crash-perf-daily-weekly-report 的 D4 过渡决策由本 change 落地为事件级，但原 capability 尚未归档，此处以新 capability 承接，避免跨 change 纠缠） -->

## Impact

- **代码**：`scripts/crash-report/crash-daily.sh`（崩溃段）、`fetch-snapshot.sh`（light 模式崩溃抓取）、新增 `sql/` 崩溃与崩溃率查询
- **数据**：依赖 BigQuery `firebase_crashlytics`（已出表）+ `firebase_sessions`（分母已就绪）；崩溃口径从「OPEN issue 数」变为「事件级统计」
- **运行**：L1 日报崩溃段与卡片口径标注同步更新；`dino-crash-perf-report` skill 的「数据源现状」描述回填
- **不涉及**：L2 周报快照链路、性能三块、NON_FATAL 通路
