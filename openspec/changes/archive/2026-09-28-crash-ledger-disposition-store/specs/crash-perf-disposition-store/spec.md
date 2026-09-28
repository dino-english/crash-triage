## Purpose

定义 issue 处置结论的持久化契约：人工对某个 issue 得出的判断（首次纳入、处置状态、结论备注）以 `issue_id` 为键独立保存，其存活不依赖该 issue 本轮是否被任何表格呈现，从而让「掉出榜单」不再等于「结论丢失」。

## ADDED Requirements

### Requirement: 处置结论以 issue 标识为键独立存储

处置结论 MUST 存储在独立于任何呈现表格的位置，键为 `issue_id`。存储 MUST NOT 按 `error_type`、平台或所属表格分区——同一个键空间服务全部 issue。

#### Scenario: 写入某 issue 的结论

- **WHEN** 人工为某 issue 记录处置状态与备注
- **THEN** 该结论以其 `issue_id` 为键保存
- **AND** 保存位置不随该 issue 属于 FATAL、ANR 还是 NON_FATAL 而不同

#### Scenario: 同一标识在不同类型间迁移

- **WHEN** 某 issue 的 `error_type` 在数据源侧发生变化
- **THEN** 其既有结论仍按同一 `issue_id` 可读
- **AND** MUST NOT 因类型变化而丢失或重建

### Requirement: 结论的存活与呈现解耦

结论的生命周期 MUST 独立于呈现。某 issue 未出现在本轮任何表格中时，其结论 MUST 原样保留；重新出现时 MUST 自动重新呈现。

#### Scenario: issue 掉出头部榜单

- **WHEN** 某 issue 本轮未进入按影响面取头部的表格
- **THEN** 其结论在存储中原样保留
- **AND** MUST NOT 被清除、置空或标记失效

#### Scenario: issue 重新进入榜单

- **WHEN** 先前掉榜的 issue 本轮重新入选
- **THEN** 其既有结论随该行一并呈现
- **AND** 呈现内容与掉榜前一致

#### Scenario: 存储中存在已不再出现的 issue

- **WHEN** 存储中某 `issue_id` 长期不出现在任何表格中
- **THEN** 该条目 MUST 保留
- **AND** 渲染 MUST NOT 因存在无对应行的条目而失败

### Requirement: 结论写入权属归人工，跑批只读

处置结论 MUST 只由人工写入。跑批流程 MUST 只读取该存储，MUST NOT 创建、修改或删除其中任何结论字段。

#### Scenario: 跑批渲染台账

- **WHEN** 跑批渲染含处置结论的表格
- **THEN** 只读取结论用于呈现
- **AND** 存储内容在跑批前后逐字节一致

#### Scenario: 机器可判定字段与结论字段共存

- **WHEN** 某字段可由代码提交事实推导（如修复提交标识）
- **THEN** 该字段 MUST NOT 写入本存储
- **AND** 结论字段 MUST NOT 被任何自动对账覆盖

### Requirement: 结论存储不可得时必须显式降级

结论存储缺失、为空或无法解析时，渲染 MUST 继续产出表格的机器列，MUST NOT 中止跑批；同时 MUST 在产出中显式标明结论不可得，MUST NOT 让空白结论与「该 issue 尚无结论」无法区分。

#### Scenario: 存储文件不存在

- **WHEN** 首次启用或存储文件丢失
- **THEN** 表格照常渲染机器列，结论列留空
- **AND** 产出中标明结论存储不可得
- **AND** 跑批不因此失败

#### Scenario: 存储内容无法解析

- **WHEN** 存储文件存在但内容损坏
- **THEN** MUST 报错并标明损坏，MUST NOT 静默当作空存储
- **AND** MUST NOT 以空内容覆写该存储

#### Scenario: 某 issue 尚无结论

- **WHEN** 存储可读但其中无该 `issue_id`
- **THEN** 该行结论列留空
- **AND** 该情形 MUST 可与「整个存储不可得」区分

### Requirement: 结论存储属人工资产，须纳入备份

结论存储 MUST 被当作不可重算的人工资产对待，MUST 纳入与其他不可重建运行状态同等的备份与迁移范围。MUST NOT 被视为可由线上数据重新生成的派生产物。

#### Scenario: 换机或重建运行环境

- **WHEN** 运行环境迁移或重建
- **THEN** 结论存储随其他不可重建状态一并迁移
- **AND** MUST NOT 依赖「重跑一次即可恢复」

#### Scenario: 清理派生数据

- **WHEN** 清理可重算的缓存或快照
- **THEN** 结论存储 MUST NOT 被一并清除
