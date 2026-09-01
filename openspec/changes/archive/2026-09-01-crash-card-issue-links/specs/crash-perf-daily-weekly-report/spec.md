## MODIFIED Requirements

### Requirement: issue 级条目提供外部下钻入口

以单条 issue 为单位呈现的内容 MUST 提供指向该 issue 数据源控制台的直达入口。

卡片侧的可行性 MUST 按**载体**判定，⛔ MUST NOT 一刀切禁止——2026-09-01 实发实测：
markdown 块里的链接可点且不改变宽度；表格单元格不支持链接。

#### Scenario: 文档中的 issue 条目

- **WHEN** 文档呈现一条 issue
- **THEN** MUST 附直达链接
- **AND** 链接 MUST 使用完整 issue 标识构造

#### Scenario: 卡片中的 issue 条目

- **WHEN** issue 条目在卡片里以 markdown 块呈现
- **THEN** MUST 附直达链接
- **AND** 链接 MUST 以 issue 标识为锚文本（⛔ 不得裸露 URL——那才是会挤占宽度的形态）
- **AND** 理由：卡片是多数读者唯一会看的产物，最该能下钻的地方不能只给灰色文本

#### Scenario: 卡片的表格单元格中的 issue 条目

- **WHEN** issue 条目在卡片里以表格单元格呈现
- **THEN** MUST NOT 附外部链接
- **AND** 理由：实测 CardKit 表格单元格不渲染链接，写进去只会显示字面 markdown 并撑宽

#### Scenario: 卡片能力判断的证据要求

- **WHEN** 判断某种内容在卡片上是否可行
- **THEN** 结论 MUST 来自真实发送一张卡片的实测
- **AND** MUST NOT 由 DRY RUN、markdown 预览或类推得出
