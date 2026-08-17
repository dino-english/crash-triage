## Why

日报「版本放量」与「性能」两段连续空表（2026-08-15 实测：放量/性能表格全部空白），读者会误读为「无数据 / 无崩溃 / 没人用」。排查根因是双重的：

1. **脚本查了停更的数据表**：`firebase_sessions` 批量表（非 REALTIME）停更在 08-11（iOS/Android 双端，08-12 起 0 行），但同数据集的 **REALTIME 表数据正常到 08-15 01:15 UTC**，schema 完全一致——脚本却仍查停更的批量表。
2. **窗口过窄 + 无陈旧告警**：性能段用 `DAYS=1` 窗口，而 `firebase_performance` 是每日批量同步、滞后约 2 天（今早 07:00 跑日报时表里最新只有 08-12，窗口「近 1 天」内 0 行）。表存在但窗口内无数据时，脚本静默输出空表，不提示「数据未同步」。

空表是事故的温床：它无法区分「真没数据」和「数据没同步」。必须改为显式告警。

## What Changes

- 版本放量段数据源从 sessions **批量表**切到 **REALTIME 表**（活表、schema 一致，立即恢复数据）；REALTIME 表缺失时回退批量表并告警。
- 新增「数据陈旧检测」：性能/放量/崩溃各段在「表存在但窗口内 0 行」时，输出显式告警「⚠️ 数据未同步，最新截至 XX」，而非静默空表。
- 性能段窗口 `DAYS=1` → `DAYS=3`，容忍 firebase_performance 约 2 天的每日批量同步滞后。
- 卡片与文档如实标注各段数据截止时间戳（性能 / 放量 / 崩溃各取各表最新 `event_timestamp`，不再复用单一 `DATA_UNTIL`）。

## Capabilities

### New Capabilities

- `crash-perf-data-staleness-guard`: 日报数据陈旧检测与告警——各数据段在数据源停更/滞后导致窗口内无数据时显式告警「最新截至 XX」而非空表，并把版本放量数据源切到 REALTIME 活表。

### Modified Capabilities

<!-- 无：本 change 落地的是「数据未同步时告警」这一新行为契约，不修改既有 capability 的 requirement。既有 crash-perf-daily-weekly-report 的「数据截止时间如实标注」requirement 语义不变，本 change 是其实现强化。 -->

## Impact

- **代码**：`scripts/crash-report/crash-daily.sh`（放量段切 REALTIME 表 + 各段陈旧告警 + 窗口放宽 + 分表截止时间戳）；`scripts/crash-report/sql/sessions-by-version.sql`（源表参数化，兼容 REALTIME 表）。
- **数据**：版本放量读 `firebase_sessions.*_REALTIME`（活表）；性能读 `firebase_performance`（窗口 3 天）；崩溃不变。
- **运行**：L1 日报卡片/文档新增「数据未同步」告警路径；`dino-crash-perf-report` skill 的「已知坑」与「数据源现状」回填。
- **不涉及**：L2 周报链路、崩溃数据源（`firebase_crashlytics` 正常）、NON_FATAL 通路、飞书投递。
