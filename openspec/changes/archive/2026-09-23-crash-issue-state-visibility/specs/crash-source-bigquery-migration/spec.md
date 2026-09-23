## MODIFIED Requirements

### Requirement: issue 开关状态不可得，且必须登记为不可得

⚠️ 本条整体重写：**前提已被实测推翻**。原条文断言「唯一能给出开关状态的通路是
MCP `topIssues`，而它只返回 OPEN issue」——2026-09-11 引入的
`crashlytics_get_issue` 逐个查询不受此限，2026-09-22 实测 12 个 id 全部取到
（7 CLOSED / 4 OPEN / 1 MUTED）。⛔ 原条文与现网代码（`render-ledger.sh` 自
2026-09-11 起渲染「✅已关闭」）已经矛盾。

新条文（标题改为「issue 开关状态经确定性查询可得，但不得回到只返回 OPEN 的通路」）：

报告与台账 MAY 呈现 issue 的开关状态，前提是该状态经**逐个确定性查询**取得。

崩溃的**统计口径** MUST 保持不受开关状态影响——事件计数、崩溃率、受影响安装
MUST 继续来自 BigQuery 事件级数据，MUST NOT 因 issue 被关闭而排除其事件。

⛔ MUST NOT 重新引入只返回 OPEN issue 的采集通路（`topIssues`）作为开关状态的判据：
「不在列表里」同时意味着已关闭、已静音、排不进 top-N、窗口内无事件四件事，不可区分。

⛔ MUST NOT 基于「字段应该存在」推断可用——BigQuery 导出的 schema 中确实
不含任何 state / closed / regressed 字段，这一条原样成立。

#### Scenario: 需要判断 issue 是否已关闭

- **WHEN** 有需求要在报告中体现 issue 已被关闭
- **THEN** 状态 MUST 由逐个 issue 的确定性查询取得
- **AND** MUST NOT 为此重新引入只返回 OPEN issue 的采集通路

#### Scenario: 已关闭的 issue 窗口内仍有事件

- **WHEN** 某 issue 状态为 CLOSED，且滚动窗口内仍有事件
- **THEN** 其事件 MUST 照常计入所有统计与排序
- **AND** 其开关状态 MUST 被标注出来
- **AND** MUST NOT 因已关闭而从明细中剔除

#### Scenario: 状态查询失败

- **WHEN** 某 issue 的状态查询失败或从未同步
- **THEN** MUST 渲染为与三种已知状态都不同的缺失态
- **AND** MUST NOT 当作 OPEN，MUST NOT 当作 CLOSED
- **AND** MUST NOT 因此中止跑批

#### Scenario: 读者可能误读的替代表述

- **WHEN** 呈现「消失」这一状态
- **THEN** MUST 标注其含义为滚动窗口内无事件
- **AND** MUST NOT 使读者理解为 issue 已被关闭或已修复
