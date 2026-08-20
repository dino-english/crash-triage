# crash-perf-daily-card-v2 Specification

## Purpose

定义 Dino 崩溃 & 性能日报群卡片的 CardKit v2 展示结构契约：用 `schema:"2.0"` 原生 table 组件（崩溃表 + 性能表，行=指标、列=iOS/Android）承载指标数据，辅以单元格红绿灯分级、核心指标紧凑环比 DoD/WoW、顶部异常摘要与底部弱化口径说明，数据计算口径不变。

## Requirements

### Requirement: CardKit v2 卡片结构迁移

日报群卡片的 interactive 卡片 SHALL 从 CardKit v1 结构迁移到 v2 结构，MUST 显式声明 `schema:"2.0"`，元素置于 `body.elements` 下，并全量清理 v1 专有字段。

#### Scenario: 显式声明 schema 2.0

- **WHEN** 生成日报群卡片 JSON
- **THEN** 卡片根节点 MUST 含 `"schema": "2.0"` 显式声明
- **AND** MUST NOT 缺失该字段（缺省即按 1.0 解析，table 组件不可用）

#### Scenario: 元素置于 body.elements

- **WHEN** 组装卡片组件
- **THEN** 所有组件 MUST 放在 `body.elements` 数组下
- **AND** MUST NOT 使用 v1 的顶层 `elements` 字段或顶层 `i18n_elements`

#### Scenario: 宽度模式迁移

- **WHEN** 迁移 v1 的 `config.wide_screen_mode` 字段
- **THEN** MUST 删除 `wide_screen_mode`，改用 `config.width_mode:"fill"`（撑满聊天窗口宽度）
- **AND** MUST NOT 在 v2 卡片里残留 `wide_screen_mode`（v2 严格校验，残留即整卡报错）

#### Scenario: 废弃 note 组件改写

- **WHEN** 迁移 v1 的 `note` 备注组件
- **THEN** MUST 改写为 `div` 普通文本组件，并配置 `text_size:"notation"` 与灰色文字（替代 note 的 12px 灰字观感）
- **AND** MUST NOT 在 v2 卡片里使用 `note` 组件（v2 已废弃）

#### Scenario: v1 残留字段清零

- **WHEN** 完成 v2 迁移
- **THEN** 卡片 JSON MUST NOT 含任何 v1 专有字段（`wide_screen_mode`、顶层 `elements`、`note` 等）
- **AND** 违规时整卡 MUST 被官方校验拒绝（错误码 230099/200861），而非静默降级

### Requirement: 原生 table 组件承载崩溃与性能

崩溃段与性能段 SHALL 各使用一张 CardKit v2 原生 `table` 组件展示，行 = 指标、列 = 指标 | iOS | Android，指标列为 `text`、平台列为 `lark_md`。

#### Scenario: 两张 table 与行列结构

- **WHEN** 生成崩溃段与性能段
- **THEN** MUST 各输出一张 `tag:"table"` 组件（崩溃表 + 性能表）
- **AND** 行 MUST 为指标维度（崩溃表：崩溃次数、崩溃率、受影响安装；性能表：启动 P50、启动 P95、慢帧最差页、冻结率、接口错误率），列 MUST 为 `指标 | iOS | Android`
- **AND** 列键 `name`（如 `metric`/`ios`/`android`）MUST 与行数据键名一致

#### Scenario: 单元格数据类型

- **WHEN** 定义表格列
- **THEN** 指标列 MUST 用 `data_type:"text"`
- **AND** 平台列（iOS/Android）MUST 用 `data_type:"lark_md"`（承载单元格内彩色文本）
- **AND** 数值 MUST NOT 放进 `options` 类型单元格（长文本会截断）

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

### Requirement: 单元格红绿灯分级

崩溃率、慢帧占比、冻结率、启动 P95、接口错误率五个指标的单元格 SHALL 按阈值红/黄/绿三级着色，红色超阈值、黄色临近、正常不标注。

#### Scenario: 红档超阈值着色

- **WHEN** 某指标平台值超过红档阈值（崩溃率>1%、慢帧>50%、冻结率>1%、启动 P95>2000ms、接口错误率>1%）
- **THEN** 该单元格数值 MUST 用 `<font color=red>…</font>` 包红
- **AND** 该指标 MUST 同时进入顶部摘要告警（见「顶部摘要只显示异常指标」）

#### Scenario: 黄档临近着色

- **WHEN** 某指标平台值落在黄档（红档阈值 ≥ 值 > 黄档阈值，黄档初值采用脚本现值：崩溃率 0.5%、慢帧 30%、冻结 0.5%、启动 P95 1500ms、接口错误率 0.5%）
- **THEN** 该单元格数值 MUST 用 `<font color=orange>…</font>` 包黄
- **AND** 黄档阈值常量与注释 MUST 显式标注「待对齐」（Q2-a：采用现值着色，后续对齐仅微调常量）

#### Scenario: 正常不标注

- **WHEN** 某指标平台值 ≤ 黄档阈值
- **THEN** 该单元格数值 MUST 以裸值展示（主题自适应 default 色）
- **AND** MUST NOT 包裹任何 `<font color>` 标签

#### Scenario: 阈值集中可配

- **WHEN** 需要调整某指标红/黄档阈值
- **THEN** 只须改脚本顶部一处常量（如 `CRASH_RATE_RED`、`NET_ERR_RED`）
- **AND** 着色判定 MUST 读取常量而非散落硬编码
- **AND** 接口错误率红档 MUST 用 `NET_ERR_RED=1.0`（Q1-a：由 0 改为 1.0，与「>1% 红档」一致）

#### Scenario: 空值不误判

- **WHEN** 某指标平台值缺失或为「无法计算」
- **THEN** 该单元格 MUST NOT 被着色判为红/黄/绿任何一档
- **AND** MUST NOT 因空值误触发告警

### Requirement: 核心指标紧凑环比 DoD/WoW

崩溃率、慢帧占比、冻结率、启动 P95、接口错误率五个核心指标的单元格 SHALL 附紧凑环比（`数值 ↑/↓ 变化量`），DoD 与 WoW 各自独立按基准存在性展示，无基准的档隐藏而非显示「无基准」。

#### Scenario: 环比格式

- **WHEN** 展示核心指标的 DoD/WoW
- **THEN** 单元格 MUST 在当前值之后追加紧凑环比，形式为 `变化量 ↑/↓`（如 `+0.12pp ↑`、`-113ms ↓`）
- **AND** DoD 与 WoW MUST 各自可独立隐藏，MUST NOT 合并成单一「无基准」字符串

#### Scenario: WoW 无基准隐藏字段

- **WHEN** 某指标 WoW（同比上周同日）无基准（D-7 单日值缺失）
- **THEN** 该单元格 MUST 隐藏 WoW 字段，MUST NOT 渲染「WoW 无基准」字样
- **AND** DoD 字段仍正常展示

#### Scenario: DoD 无基准隐藏字段

- **WHEN** 某指标 DoD（环比昨日，或性能类为「最新可用单日值」）无基准
- **THEN** 该单元格 MUST 隐藏 DoD 字段，MUST NOT 渲染「DoD 无基准」字样
- **AND** WoW 字段仍正常展示

#### Scenario: 两端均无基准

- **WHEN** 某指标 DoD 与 WoW 均无基准
- **THEN** 该单元格 MUST 只显示当前值，不追加任何环比字段

#### Scenario: 复用既有环比计算

- **WHEN** 组装紧凑环比字符串
- **THEN** 变化量的符号（±pp / ±ms）、箭头方向（数值变大=变差=↑）、单位约定 MUST 复用既有 `_dod_wow` 的计算产出
- **AND** MUST NOT 重新计算或改变环比数值、箭头、单位（红线：不改数据计算）

#### Scenario: 环比日期不重复进表格

- **WHEN** 渲染表格单元格
- **THEN** 单元格 MUST NOT 携带「对比 X vs Y」之类的日期说明
- **AND** 环比实际对比日期 MUST 只在底部口径说明统一出现一次

#### Scenario: 环比与当前值同格同色

- **WHEN** 展示核心指标单元格
- **THEN** 环比变化量 MUST 与当前值同格展示，整体包裹同一红绿灯着色（由当前值阈值决定红/黄/裸值）
- **AND** MUST NOT 单独按环比变化方向（↑/↓）另行着色

### Requirement: 顶部摘要只显示异常指标

日报卡片顶部摘要 SHALL 只渲染触发阈值（红/黄档）的指标行，MUST NOT 全量罗列所有指标。

#### Scenario: 仅渲染异常行

- **WHEN** 生成顶部摘要
- **THEN** 摘要 MUST 只包含命中红档或黄档的指标行
- **AND** 正常指标 MUST NOT 出现在摘要中

#### Scenario: 无异常占位

- **WHEN** 没有任何指标命中红/黄档
- **THEN** 摘要 MUST 显示「✅ 无异常」占位
- **AND** MUST NOT 输出空白摘要

### Requirement: 受影响安装数并列与小样本提示

崩溃表 SHALL 在崩溃率旁并列展示受影响安装数；当某平台当日会话数低于阈值时，该平台相关单元格 SHALL 追加「⚠️ 样本量小」提示。

#### Scenario: 受影响安装数并列

- **WHEN** 展示崩溃表
- **THEN** 「受影响安装」MUST 作为独立指标行与崩溃率并列展示（如 `受影响安装 iOS 4 / Android 55`）
- **AND** MUST 沿用既有 `COUNT(DISTINCT installation_uuid)` 口径（红线：不重算）

#### Scenario: 小样本提示

- **WHEN** 某平台当日会话数 < 30（阈值可配）
- **THEN** 该平台相关指标单元格 MUST 追加「⚠️ 样本量小」提示
- **AND** 提示 MUST 只标注不省略数据

### Requirement: 底部口径说明弱化

日报卡片底部 SHALL 保留慢帧口径说明与三表截止时间戳，并以小字浅色分隔线区隔的方式弱化呈现。

#### Scenario: 保留口径说明

- **WHEN** 渲染卡片底部
- **THEN** MUST 保留「慢帧最差页百分比 = 慢帧(>16ms)帧数 ÷ 全部帧数（帧级占比，非会话占比）；冻结同理(>700ms)」的口径说明
- **AND** MUST 保留三表截止时间戳（性能/放量/崩溃截至）

#### Scenario: 小字浅色分隔

- **WHEN** 渲染底部口径说明
- **THEN** 说明 MUST 用 `div` 组件以 `notation` 字号、灰色文字展示
- **AND** MUST 以分隔线（`hr`）与正文区隔

### Requirement: 保留项（深色风格 / 三层结构 / 时间戳 / 详情链接）

迁移至 v2 时，深色风格、三大块分层结构、时间戳与详情跳转链接 SHALL 全部保留。

#### Scenario: 深色风格主题自适应

- **WHEN** 迁移 v2 后卡片在深色模式下展示
- **THEN** MUST 保持可读，通过主题自适应色实现（header template 色、`text_color:"default"`、`<font color>` 枚举色）
- **AND** MUST NOT 引入写死的浅色/深色专属 RGBA 色值

#### Scenario: 三层结构与详情链接保留

- **WHEN** 生成 v2 卡片
- **THEN** MUST 保留「崩溃 / 性能 / 放量」三大块分层结构
- **AND** MUST 保留彩色 header 标题栏（含日期与告警状态色切换）
- **AND** MUST 保留详情跳转链接（`__DETAIL_URL__` 占位符）

### Requirement: 纯展示层红线

本 change SHALL 为纯展示层重构，MUST NOT 改动任何 SQL 查询、指标取数、告警判定、快照与趋势箭头逻辑；唯一例外是接口错误率红档阈值常量（Q1-a 已拍板）。

#### Scenario: 数据链路零改动

- **WHEN** 实施 v2 迁移
- **THEN** `crash-rate.sql`、`crash-issues.sql`、`perf-*.sql`、`sessions-by-version.sql` 及天级单日值查询 MUST NOT 被修改
- **AND** `crash-daily.sh` 中取数、聚合、告警判定、快照、`_dod_wow` 环比计算逻辑 MUST NOT 被修改

#### Scenario: 唯一例外为阈值常量

- **WHEN** 对齐接口错误率红档阈值
- **THEN** 允许改 `NET_ERR_RED` 常量 `0 → 1.0`（Q1-a，requester 已拍板）
- **AND** 除此之外 MUST NOT 改任何阈值常量、SQL 或计算逻辑

#### Scenario: 双副本一致

- **WHEN** 实施 v2 迁移
- **THEN** `bin/crash-daily.sh` 与 `scripts/crash-report/crash-daily.sh` 两处副本 MUST 逐字节一致
- **AND** 验收 MUST 用 `diff` 复测两副本无差异
