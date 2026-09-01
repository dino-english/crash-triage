## ADDED Requirements

### Requirement: 口径注解分层呈现

报告正文中随表呈现的口径注解 MUST 限于判读该表所必需的内容。设计理由、实现约束、历史教训 MUST 移至文末的口径章节，MUST NOT 与判读须知混排。

任何一条既有口径注解的内容 MUST NOT 因本要求被删除，只调整其位置。

理由：实测 2026-08-31 周报总字符 9299，其中 3712 字位于口径提示块内，占 40%；16 个提示块对应 54 行数据。判读须知与设计备忘在版面上权重相同，读者无法分辨哪些是读数前必须知道的。

#### Scenario: 一段内重复出现的口径说明

- **WHEN** 同一口径说明在多个段落重复出现
- **THEN** MUST 收敛为表头角标或单次说明
- **AND** MUST NOT 在每段各重复一遍完整文字

#### Scenario: 有记录理由的口径标注

- **WHEN** 某标注是既有硬约束（样本量括注、窗口两端标注、单位与分母说明）
- **THEN** MUST 保留在正文
- **AND** MUST NOT 以精简为由移除

### Requirement: 首屏只回答单一问题

报告的首屏内容 MUST 只回答「本轮有没有需要立刻关注的变化」，MUST NOT 在首屏并列多套口径。

#### Scenario: 首屏呈现

- **WHEN** 渲染报告首屏
- **THEN** MUST 只使用一套口径且不展开解释
- **AND** 其余口径的内容 MUST 经正文段落呈现

### Requirement: issue 级条目提供外部下钻入口

以单条 issue 为单位呈现的内容 MUST 提供指向该 issue 数据源控制台的直达入口。

#### Scenario: 文档中的 issue 条目

- **WHEN** 文档呈现一条 issue
- **THEN** MUST 附直达链接
- **AND** 链接 MUST 使用完整 issue 标识构造

#### Scenario: 卡片中的 issue 条目

- **WHEN** 内容进入卡片
- **THEN** MUST NOT 附外部链接
- **AND** 理由：卡片单元格宽度有限，链接会挤占并触发截断
