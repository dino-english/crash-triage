## ADDED Requirements

### Requirement: 版本注记

报告 MUST 能为特定平台与版本挂一句人写的注记，用于说明**指标跳变的原因不在数据里**
（埋点变更、口径调整、上报开关等）。

注记 MUST 由人手维护，脚本 MUST NOT 覆写。注记源缺失或本次无命中时 MUST 静默跳过，
MUST NOT 报错、MUST NOT 影响其余模块产出。

注记 MUST 渲染在报告的摘要区，MUST NOT 进入表格单元格。

#### Scenario: 命中当前报告呈现的版本

- **WHEN** 注记的平台与版本落在该份报告正在呈现的版本集内
- **THEN** MUST 在摘要区渲染该注记
- **AND** MUST 在卡片、markdown 与文档三处同位置输出

#### Scenario: 日报与周报的版本集不同

- **WHEN** 某注记的版本在日报的版本集内、但不在周报的主力版本集内（或反之）
- **THEN** MUST 只在命中的那一份报告里出现
- **AND** MUST NOT 为求两份一致而渲染该报告并未呈现的版本的注记

#### Scenario: 命中条数超过上限

- **WHEN** 命中的注记多于渲染上限
- **THEN** MUST 按版本降序截断
- **AND** MUST 标注实际命中条数，MUST NOT 静默丢弃

#### Scenario: 注记源不存在

- **WHEN** 注记文件不存在或为空
- **THEN** MUST 跳过该模块并照常产出报告其余部分
