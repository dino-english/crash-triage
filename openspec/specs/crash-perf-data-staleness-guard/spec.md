# crash-perf-data-staleness-guard Specification

## Purpose

日报各数据段（性能 / 版本放量 / 崩溃）在数据源停更或滞后导致查询窗口内无数据时，显式告警「数据未同步，最新截至 XX」而非输出空表，避免读者误读为空数据；同时把版本放量数据源切到 REALTIME 活表以消除停更空表。

## Requirements

### Requirement: 数据未同步显式告警

日报各数据段（性能 / 版本放量 / 崩溃）MUST 在「数据源表存在但查询窗口内 0 行」时，输出显式告警「⚠️ 数据未同步，最新截至 XX」而非静默空表。

#### Scenario: 表存在但窗口内无数据

- **WHEN** 某数据段的数据表存在、但按窗口查询返回 0 行
- **THEN** 该段输出「⚠️ 数据未同步，最新截至 XX」（XX 为该表最新 `event_timestamp`），MUST NOT 输出空表格
- **AND** 不因该段无数据而整体失败，其余段正常展示

#### Scenario: 表不存在

- **WHEN** 某数据段的数据表不存在
- **THEN** 该段输出「表尚未同步」告警并跳过，不整体失败（维持现状）

### Requirement: 版本放量数据源走 REALTIME 活表

版本放量段（各版本会话数 / 设备数）SHALL 从 `firebase_sessions` 的 REALTIME 表读取数据，而非停更的批量表。

#### Scenario: REALTIME 表就绪

- **WHEN** `firebase_sessions.*_REALTIME` 表存在
- **THEN** 版本放量查询使用 REALTIME 表
- **AND** 产出各版本会话数 / 设备数 / 最新数据日期

#### Scenario: REALTIME 表缺失时回退

- **WHEN** REALTIME 表不存在但批量表存在
- **THEN** 回退到批量表查询，并标注「REALTIME 表缺失，回退批量表」

### Requirement: 各段截止时间戳分别如实标注

日报 MUST 按各数据段各自的表，分别查询并显示其最新 `event_timestamp` 作为该段数据实际截止时间，MUST NOT 用单一 `DATA_UNTIL` 概括所有段。

#### Scenario: 多数据源各自标注

- **WHEN** 生成日报
- **THEN** 性能段标注 performance 表最新时间戳、放量段标注 sessions 表最新时间戳、崩溃段标注 crashlytics 表最新时间戳
- **AND** 卡片与文档均如实展示各段截止时间

### Requirement: 性能窗口容忍每日批量同步滞后

性能段查询窗口 SHALL 放宽到能覆盖 firebase_performance 约 2 天的每日批量同步滞后（默认近 3 天），避免窗口过窄导致的空表。

#### Scenario: 每日批量同步滞后 2 天

- **WHEN** firebase_performance 表最新数据滞后约 2 天
- **THEN** 性能段仍能在窗口内查到数据并展示
- **AND** 若窗口内仍无数据，触发「数据未同步显式告警」requirement
