# crash-source-bigquery-migration Specification

## Purpose

崩溃数据源从 Firebase MCP `topIssues`（只返回 OPEN issue）迁移到 BigQuery `firebase_crashlytics` 事件级统计，并新增崩溃率计算，使崩溃统计不受 issue 开关状态影响。

## Requirements

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

### Requirement: issue 开关状态不可得，且必须登记为不可得

报告与台账 MUST NOT 呈现 issue 的开关状态（OPEN / CLOSED），MUST NOT 提供任何暗示该状态可得的图例或占位。

理由：BigQuery Crashlytics 导出的 schema 中与 issue 相关的字段只有 `issue_id`、`issue_title`、`issue_subtitle`，**不含任何 state / closed / regressed 字段**（2026-09-01 实测 `bq show --schema`）。唯一能给出开关状态的通路是 MCP `topIssues`，而它只返回 OPEN issue——关闭即从列表消失，正是本 capability 迁离该数据源的原因；且 2026-08-06 曾因自动化越权写操作误关线上 issue。

⛔ 不得基于「字段应该存在」推断可用——先查有没有值，与 `remote_config_feature_rollouts` 恒空那条同源。

#### Scenario: 需要判断 issue 是否已关闭

- **WHEN** 有需求要在报告中体现 issue 已被关闭
- **THEN** MUST 登记为不可得并说明数据源缺失
- **AND** MUST NOT 为此重新引入只返回 OPEN issue 的采集通路

#### Scenario: 读者可能误读的替代表述

- **WHEN** 呈现「消失」这一状态
- **THEN** MUST 标注其含义为滚动窗口内无事件
- **AND** MUST NOT 使读者理解为 issue 已被关闭或已修复
