## REMOVED Requirements

### Requirement: 原生 table 组件承载崩溃与性能

**Reason**: 卡片首屏改为三档 + 健康度（change `crash-report-attention-tiers`）。单表回答「各指标是多少」，回答不了「谁今天要动什么」；且 table 单元格不渲染链接、不能进折叠面板（2026-10-11 实测 `ErrCode 200621`）。

**Migration**: 指标改由健康度面板呈现（spec `crash-perf-attention-tiers`「健康度面板按平台分判」）；完整指标表仍在文档「版本对照」段，文档行定义 `ROW_DEFS_DOC` 不受影响。

### Requirement: 顶部摘要只显示异常指标

**Reason**: 平铺的 🔴 / 🟡 摘要行由三档分档取代。实测 2026-10-11 摘要 4 条 🔴 全为慢性状态，掩盖了需开发处理的「修了仍在」。

**Migration**: 异常信号按 spec `crash-perf-attention-tiers` 分入 🚨 / ⏳ / 👀；「无异常」占位由「今日无需开发处理」取代。摘要行的三条既有规则（标版本 / 无值不判灯 / ANR 单端）迁移到健康度面板。

### Requirement: 纯展示层红线

**Reason**: 该要求是 CardKit v2 迁移那次 change 的范围约束（「本 change SHALL 为纯展示层重构」），不是长期契约；其「双副本一致」所指的 `scripts/crash-report/crash-daily.sh` 已不存在（2026-10-11 核）。

**Migration**: 无。数据链路的约束由各自的口径 spec 承担。

## MODIFIED Requirements

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
