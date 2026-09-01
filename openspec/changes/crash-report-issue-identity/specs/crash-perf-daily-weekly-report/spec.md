## ADDED Requirements

### Requirement: issue 级条目必须可被唯一标识

任何以单条 issue 为单位呈现的内容 MUST 携带该 issue 的标识。覆盖面包括：日报 issue 明细、周报变化摘要、周报 issue 下钻、台账 Issue 现状表与 NON_FATAL 现状表、台账变更时间线。

标识 MUST 在各产物间形态一致，使读者能跨产物比对同一条 issue。

理由：标题不是稳定的标识。同一条崩溃在责任帧命名（`AudioPlaybackService.ensureMediaSession`）与人工描述（「Media3 初始化 NoSuchMethodError」）之间不可互推。实测 2026-09-01 的一次人工比对因此把两份产物中的同一条 issue 判为两条不同的崩溃。

#### Scenario: 变化摘要条目

- **WHEN** 周报变化摘要输出一条新增 / 回归 / 暴涨 / 消失
- **THEN** 该条目 MUST 携带 issue 标识

#### Scenario: 台账时间线条目

- **WHEN** 台账变更时间线追加一条记录
- **THEN** 该条目 MUST 携带 issue 标识

#### Scenario: 卡片

- **WHEN** 内容进入飞书卡片
- **THEN** MUST NOT 加入外部链接
- **AND** 理由：单元格宽度有限，链接会挤占并触发截断

### Requirement: 跨版本聚合数必须标明版本构成

当某 issue 的事件数是跨多个版本的合计值时，呈现 MUST 同时给出版本构成，MUST NOT 只给合计数。

理由：合计数与单版本数在版面上无法区分。实测 2026-08-31 周报变化摘要输出「暴涨 13 事件」，实际为 1.5.4 的 8 与 1.5.6 的 5——读者无从判断新版占了多少，而这正是发版期最需要的信息。

#### Scenario: issue 只出现在一个版本

- **WHEN** 某 issue 在窗口内只有一个版本有事件
- **THEN** MUST NOT 输出版本构成括注
- **AND** 理由：单版本时括注与主数字重复，只增噪音
