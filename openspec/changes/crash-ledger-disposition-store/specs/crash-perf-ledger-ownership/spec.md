## MODIFIED Requirements

### Requirement: 台账采用四段式结构

台账 MUST 包含五个段落，顺序固定：项目常量、崩溃收口点登记、Issue 现状表、NON_FATAL 现状表、变更时间线。

理由（追加）：NON_FATAL 现状表自实现起即存在于台账中，但此前未被本 spec 定义，属既存漂移。iOS 主力版本 FATAL 常年为 0，其内容几乎全部落在该表——它不是可选的补充段，而是 iOS 侧的主段。

#### Scenario: 首次生成台账

- **WHEN** 本地台账源不存在
- **THEN** 生成含全部五段的台账
- **AND** Issue 现状表与 NON_FATAL 现状表各自以本轮取到的线上 issue 建立基线
- **AND** 不迁移任何历史台账内容

#### Scenario: 后续更新台账

- **WHEN** 本地台账源已存在
- **THEN** 保留项目常量与收口点登记两段的既有内容
- **AND** 只更新 Issue 现状表、NON_FATAL 现状表与变更时间线

#### Scenario: 某段本轮无内容

- **WHEN** 某现状表本轮取不到任何 issue
- **THEN** 该段仍然存在并标明本轮无数据
- **AND** MUST NOT 因此删除该段或改变五段顺序

## ADDED Requirements

### Requirement: NON_FATAL 现状表承载人工处置结论

NON_FATAL 现状表 MUST 在机器列之外呈现该 issue 的人工处置结论（处置状态与结论备注）。结论 MUST 取自独立的处置结论存储，MUST NOT 从表格自身的上一版解析获得。

#### Scenario: issue 已有处置结论

- **WHEN** 某 NON_FATAL issue 在结论存储中有记录
- **THEN** 其处置状态与备注随该行一并呈现
- **AND** 内容与存储中一致，未被任何自动流程改写

#### Scenario: issue 尚无处置结论

- **WHEN** 某 NON_FATAL issue 在结论存储中无记录
- **THEN** 该行结论列留空
- **AND** 机器列照常呈现

#### Scenario: issue 掉出头部后重新入选

- **WHEN** 某 NON_FATAL issue 上一轮未入选、本轮重新入选
- **THEN** 其既有结论照常呈现
- **AND** MUST NOT 因曾掉出表格而丢失结论

### Requirement: 现状表的人工结论不得依赖表格自身留存

任何承载人工结论的现状表，其结论 MUST 来自独立存储。MUST NOT 以「解析上一版表格」作为结论的唯一存续途径。上一版表格不可得时，MUST NOT 导致结论丢失。

#### Scenario: 上一版表格无法解析

- **WHEN** 台账源缺失、锚点失效或表格内容损坏
- **THEN** 结论仍可从独立存储取得并正常呈现
- **AND** MUST 显式报告表格解析失败
- **AND** MUST NOT 静默产出一张结论全空的表

#### Scenario: 首次启用独立存储

- **WHEN** 独立存储尚未建立而表格中已有历史结论
- **THEN** MUST 提供一次性迁移路径把既有结论移入存储
- **AND** 迁移完成前 MUST NOT 让结论在任一侧丢失
