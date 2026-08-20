## Purpose

崩溃数据源从 Firebase MCP `topIssues`（只返回 OPEN issue）迁移到 BigQuery `firebase_crashlytics` 事件级统计，并新增崩溃率计算，使崩溃统计不受 issue 开关状态影响。

## ADDED Requirements

### Requirement: 崩溃统计走 BigQuery 事件级
系统 SHALL 从 BigQuery `firebase_crashlytics` 表按事件聚合统计崩溃，而非读取 Firebase MCP `topIssues` 的 OPEN issue 列表。

#### Scenario: 被关闭的 issue 仍计入统计
- **WHEN** 某 crashlytics issue 在控制台被关闭（closed）
- **THEN** 日报仍按 `firebase_crashlytics` 表的事件统计该崩溃
- **AND** 不会因 issue 关闭而从统计中消失

#### Scenario: 单平台表缺失时降级
- **WHEN** 某平台（iOS 或 Android）的 `firebase_crashlytics` 表不存在或无数据
- **THEN** 日报跳过该平台的崩溃段
- **AND** 另一平台正常展示，不整体失败

### Requirement: 崩溃率计算
系统 SHALL 计算崩溃率 = 崩溃事件数（`firebase_crashlytics` 分子）/ 会话数（`firebase_sessions` 分母）。

#### Scenario: 分母与分子齐备
- **WHEN** `firebase_sessions` 与 `firebase_crashlytics` 双表均有数据
- **THEN** 日报展示崩溃率（分子/分母）
- **AND** 标注崩溃率口径（事件数 / 会话数，非 crash-free 精确口径）

#### Scenario: 分母为零
- **WHEN** 分母 `firebase_sessions` 会话数为 0 或表缺失
- **THEN** 崩溃率显示「无法计算」
- **AND** 不展示 0 以免误读为「无崩溃」

### Requirement: 崩溃数据截止时间如实标注
系统 SHALL 以 `firebase_crashlytics` 表最新 `event_timestamp` 标注崩溃数据实际截止时间。

#### Scenario: 打印真实截止时间戳
- **WHEN** 日报生成
- **THEN** 卡片打印崩溃数据的实际截止时间戳
- **AND** 不假设「截至昨天」
