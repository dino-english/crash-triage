## ADDED Requirements

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
