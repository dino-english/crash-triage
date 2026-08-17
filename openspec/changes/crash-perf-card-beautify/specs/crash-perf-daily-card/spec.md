## Purpose

定义 Dino 崩溃 & 性能日报群卡片的展示结构契约：三大块彩色分区、双端分栏、崩溃率独立醒目指标，且数据计算口径不变。

## ADDED Requirements

### Requirement: 结构化卡片分区

日报群卡片 SHALL 使用飞书 interactive 卡片的结构化元素（彩色 `header`、`hr`、`column_set`、`note`），MUST NOT 只用一个无格式的 markdown 元素堆叠全部内容。

#### Scenario: 三大块彩色分区

- **WHEN** 生成日报群卡片
- **THEN** 卡片 MUST 按「崩溃 / 性能 / 放量」三大块分区展示
- **AND** 每块 MUST 有独立的彩色小标题与分隔线，区分度足以扫读定位

#### Scenario: 双端左右分栏

- **WHEN** 崩溃段与性能段同时存在 iOS 与 Android 数据
- **THEN** 卡片 MUST 用 `column_set` 把 iOS 与 Android 左右并排分栏展示
- **AND** 任一端无数据时，该端列 MUST 显示明确的「无数据 / 数据未同步」占位而非空白

#### Scenario: 顶部彩色标题栏

- **WHEN** 生成日报群卡片
- **THEN** 卡片 MUST 含彩色 `header` 标题栏展示日期与状态
- **AND** 存在告警时标题栏色 MUST 与「有异常」状态区分（如红色），无告警时用中性/绿色

### Requirement: 崩溃率独立展示

崩溃率 SHALL 作为独立的醒目指标展示在卡片崩溃块中，MUST NOT 以括号附注形式藏匿于崩溃计数行内。

#### Scenario: 崩溃率口径不变

- **WHEN** 计算卡片上的崩溃率
- **THEN** 崩溃率 MUST 沿用既有口径「崩溃事件数 / 会话数」（非 crash-free 精确口径）
- **AND** MUST NOT 引入 session 级关联或改动 `crash-rate.sql` 的计算逻辑

#### Scenario: 崩溃率展示形式

- **WHEN** 崩溃率分子与分母均可得且分母非零
- **THEN** 卡片 MUST 独立一行展示两端崩溃率，形式含百分比与原始分数（如 `崩溃率 iOS 0.2% (2/1017) · Android 1.6% (39/2500)`）
- **AND** 百分比仅是展示层换算（分子/分母×100），不改变计算

#### Scenario: 分母为零

- **WHEN** 任一端会话数为零或不可得
- **THEN** 该端崩溃率 MUST 显示「无法计算」而非误读为「无崩溃」

### Requirement: 数据计算方式不变

卡片美化 SHALL NOT 改变任何数据计算逻辑；所有 BigQuery 查询、指标提取、告警判定、快照与趋势箭头逻辑 MUST 保持不变。

#### Scenario: 计算链路零改动

- **WHEN** 实施卡片美化
- **THEN** `crash-rate.sql`、`crash-issues.sql`、`perf-*.sql`、`sessions-by-version.sql` 及 `crash-daily.sh` 中所有取数、聚合、告警、快照代码 MUST NOT 被修改
- **AND** 仅 `CARD` 组装与卡片 JSON 渲染代码允许改动

#### Scenario: 指标数值一致性

- **WHEN** 美化前后分别生成卡片
- **THEN** 崩溃数、崩溃率分子分母、启动耗时、慢帧率、冻结率、接口错误率、放量会话数等所有指标数值 MUST 完全一致

### Requirement: 脚本产出卡片结构

日报群卡片的 JSON 结构 SHALL 由 `crash-daily.sh` 确定性产出（写入投递清单），投递 agent MUST 原样读取并发送，MUST NOT 手写或改写卡片 JSON。

#### Scenario: 确定性产出

- **WHEN** 脚本运行
- **THEN** 卡片 content JSON MUST 由脚本以确定性方式（jq 组装）产出并写入 `state/publish/`
- **AND** 相同数据下多次运行产出 MUST 字节一致（除时间戳等固有变量）

#### Scenario: agent 原样投递

- **WHEN** cron agent 投递日报
- **THEN** agent MUST 读取脚本产出的卡片 JSON 原文，调用 `im_v1_message_create` 原样发送
- **AND** MUST NOT 增删、改写、总结卡片内容或自行拼接卡片结构
