## MODIFIED Requirements

### Requirement: 原生 table 组件承载崩溃与性能

卡片 SHALL 使用**一张** CardKit v2 原生 `table` 组件承载简报指标，行 = 指标、列 = `指标 | iOS | Android`，指标列为 `text`、平台列为 `lark_md`。

卡片承载的行集合 MUST 是简报口径的子集，MUST NOT 与文档共用同一份行定义——卡片回答「今天要不要管」，文档回答「具体是什么」，两者的完备性要求不同。

版本标识与放量规模 MUST 并入表头，MUST NOT 各占独立行。

#### Scenario: 两张 table 与行列结构

- **WHEN** 生成卡片表格
- **THEN** MUST 输出**一张** `tag:"table"` 组件，承载崩溃类与性能类简报指标
- **AND** 行 MUST 为指标维度，列 MUST 为 `指标 | iOS | Android`
- **AND** 列键 `name`（如 `metric`/`ios`/`android`）MUST 与行数据键名一致
- **AND** 崩溃类与性能类指标 MUST NOT 拆成两张表——拆表会使卡片高度翻倍，与简报目的相悖

#### Scenario: 卡片行集合与文档分离

- **WHEN** 定义卡片与文档的指标行
- **THEN** 两者 MUST 使用各自独立的行定义
- **AND** 收缩卡片行集合 MUST NOT 影响文档呈现的完备性

#### Scenario: 版本与放量并入表头

- **WHEN** 呈现版本维度
- **THEN** 平台列表头 MUST 标明所对比的两个版本及各自会话规模
- **AND** 会话数 MUST NOT 另占一行

#### Scenario: 单元格数据类型

- **WHEN** 定义表格列
- **THEN** 指标列 MUST 用 `data_type:"text"`
- **AND** 平台列（iOS/Android）MUST 用 `data_type:"lark_md"`（承载单元格内彩色文本）
- **AND** 数值 MUST NOT 放进 `options` 类型单元格（长文本会截断）

#### Scenario: 单元格内承载值与对比

- **WHEN** 某指标存在版本间对比
- **THEN** 单元格 MUST 同时承载当期值与对比指示
- **AND** 对比 MUST NOT 另占一列——独立对比列会使列数随平台数翻倍

#### Scenario: 分页规避

- **WHEN** 表格行数可能超过 CardKit 默认每页 5 行
- **THEN** MUST 显式设置 `page_size: 10`
- **AND** 行数不超过 10 时 MUST NOT 出现分页

#### Scenario: 表格放置位置

- **WHEN** 放置 table 组件
- **THEN** table MUST 放在卡片 `body.elements` 根节点下
- **AND** MUST NOT 嵌套在 `column_set` 或其他容器组件内（官方禁止）

#### Scenario: 表头样式

- **WHEN** 渲染表头
- **THEN** 表头 MUST 用 `header_style` 配置加粗（`bold:true`）与灰色底（`background_style:"grey"`）以区分数据行
- **AND** 表头文字色 MUST 用主题自适应色（`text_color:"default"` 或省略），MUST NOT 写死浅色/深色专属色值

## ADDED Requirements

### Requirement: 卡片承载影响集中信息

卡片 MUST 呈现一行影响集中信息：受影响最多的若干设备型号及各自受影响的安装数。

理由：卡片的职责之一是突发状况感知。「哪些设备受影响、影响多少人」是突发的第一落点，而事件总数回答不了这个问题。

该行 MUST 只呈现头部若干条目，MUST NOT 展开完整分布——完整分布属于文档的汇总段。

#### Scenario: 存在受影响设备

- **WHEN** 窗口内存在崩溃事件
- **THEN** 卡片呈现受影响最多的若干设备型号与各自的受影响安装数
- **AND** 完整维度分布不在卡片呈现，由详情链接指向文档

#### Scenario: 无崩溃事件

- **WHEN** 窗口内无崩溃事件
- **THEN** 该行不输出，而非输出空值或零
