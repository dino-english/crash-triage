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

### Requirement: 单元格红绿灯分级

崩溃率、慢帧占比、冻结率、启动 P95、接口错误率五个指标 SHALL 按阈值红/黄/绿三级着色，红色超阈值、黄色临近、正常不标注。着色载体为健康度面板中的各端数字。

判灯 MUST 按平台逐个数字独立进行，MUST NOT 两端合用一盏灯。慢帧与冻结的判灯值 MUST 为平台整体值，最差页不参与判灯。

#### Scenario: 红档超阈值着色

- **WHEN** 某指标某端值超过红档阈值（崩溃率>1%、慢帧>50%、冻结率>1%、启动 P95>2000ms、接口错误率>1%）
- **THEN** 该端该数字 MUST 用 `<font color=red>…</font>` 包红
- **AND** 另一端 MUST 按其自身值判定，MUST NOT 被连带着色

#### Scenario: 黄档临近着色

- **WHEN** 某指标某端值落在黄档（红档阈值 ≥ 值 > 黄档阈值，黄档初值采用脚本现值：崩溃率 0.5%、慢帧 30%、冻结 0.5%、启动 P95 1500ms、接口错误率 0.5%）
- **THEN** 该数字 MUST 用 `<font color=orange>…</font>` 包黄
- **AND** 黄档阈值常量与注释 MUST 显式标注「待对齐」

#### Scenario: 正常不标注

- **WHEN** 某指标某端值 ≤ 黄档阈值
- **THEN** 该数字 MUST 以裸值展示（主题自适应 default 色）
- **AND** MUST NOT 包裹任何 `<font color>` 标签

#### Scenario: 阈值集中可配

- **WHEN** 需要调整某指标红/黄档阈值
- **THEN** 只须改脚本顶部一处常量（如 `CRASH_RATE_RED`、`NET_ERR_RED`）
- **AND** 着色判定 MUST 读取常量而非散落硬编码

#### Scenario: 空值不误判

- **WHEN** 某指标某端值缺失或为「无法计算」
- **THEN** 该数字 MUST NOT 被着色判为红/黄/绿任何一档
- **AND** MUST NOT 因空值误触发分档

#### Scenario: 最差页不判灯

- **WHEN** 呈现慢帧或冻结的最差页
- **THEN** 最差页值以括注呈现
- **AND** MUST NOT 着红或着黄

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

### Requirement: 受影响安装数并列与小样本提示

卡片 SHALL 为每条 issue 级条目给出 7 天影响台数（受影响安装，沿用 `COUNT(DISTINCT installation_uuid)` 口径）；当某平台判定版本或最新版会话数低于阈值时，相关数字 SHALL 追加「⚠️ 样本小」提示。

#### Scenario: 受影响安装数并列

- **WHEN** 卡片呈现一条 issue（任一档）
- **THEN** MUST 给出该 issue 的 7 天影响台数
- **AND** MUST 沿用既有 `COUNT(DISTINCT installation_uuid)` 口径（不重算）

#### Scenario: 小样本提示

- **WHEN** 某平台版本当日会话数 < `SAMPLE_SESSION_MIN`（可配）
- **THEN** 该版本相关数字 MUST 追加「⚠️ 样本小」提示
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

卡片 SHALL 保留深色风格自适应、分层结构、时间戳与详情跳转链接。分层结构为「三档（🚨 / ⏳ / 👀）+ 健康度」。

#### Scenario: 深色风格主题自适应

- **WHEN** 卡片在深色模式下展示
- **THEN** MUST 保持可读，通过主题自适应色实现（header template 色、`text_color:"default"`、`<font color>` 枚举色、`column_set` 背景枚举色、图表 `color_theme`）
- **AND** MUST NOT 引入写死的浅色/深色专属色值（含图表 spec 内的 hex 色值）

#### Scenario: 三层结构与详情链接保留

- **WHEN** 生成卡片
- **THEN** MUST 按「三档 + 健康度」分层
- **AND** MUST 保留彩色 header 标题栏（含日期，颜色随最高档切换）
- **AND** MUST 保留详情跳转链接（`__DETAIL_URL__` 占位符）

### Requirement: 卡片承载影响集中信息

卡片 MUST 呈现影响集中信息：受影响最多的若干设备型号及各自受影响的安装数，以及崩溃率最高的系统版本及其率。该信息 MAY 置于 👀 折叠面板内，以 markdown 表格呈现。

系统版本维度的会话桶足够大，其率可靠；设备型号维度不可靠（碎片化导致单型号会话量过小），两者 MUST NOT 合并为一行。

该信息 MUST 只呈现头部若干条目，MUST NOT 展开完整分布——完整分布属于文档的汇总段。

#### Scenario: 存在受影响设备

- **WHEN** 窗口内存在崩溃事件
- **THEN** 卡片呈现受影响最多的若干设备型号与各自的受影响安装数
- **AND** 完整维度分布不在卡片呈现，由详情链接指向文档

#### Scenario: 无崩溃事件

- **WHEN** 窗口内无崩溃事件
- **THEN** 该信息不输出，而非输出空值或零

#### Scenario: 系统版本分布可用

- **WHEN** 某端存在崩溃事件且系统版本维度的会话量足以给出可靠的率
- **THEN** 卡片呈现崩溃率最高的系统版本及其率
- **AND** 设备型号不呈现率——该维度的率不可靠

### Requirement: 卡片并列呈现最新版与全版本的整体健康指标

卡片 MUST 同时呈现最新版本与全版本口径的整体健康指标（crash-free 会话率），两者 MUST 各自标注口径。

理由：新版本刚放量时会话量极小，其比率不具统计意义，却是卡片上唯一的健康数字——读者会据此判断整体健康，而那是错的。全版本值才回答「整体健不健康」，也才是与外部控制台数量级可对照的那个。

#### Scenario: 新版本样本极小

- **WHEN** 最新版本的会话数低于小样本阈值
- **THEN** 其比率仍呈现但带小样本提示
- **AND** 全版本比率并列呈现，使读者不会把小样本值当作整体健康

#### Scenario: 两个口径并列

- **WHEN** 卡片同时呈现两个口径
- **THEN** 各自标注是最新版本还是全版本
- **AND** MUST NOT 让读者误以为是同一口径的两个数

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
