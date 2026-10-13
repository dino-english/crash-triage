# crash-perf-attention-tiers Specification

## Purpose
TBD - created by archiving change crash-report-attention-tiers. Update Purpose after archive.

## Requirements

### Requirement: 卡片与文档首屏按三档呈现

日报与周报的卡片、文档首屏 SHALL 把信号分为三档呈现：🚨 紧急（开发要修）、⏳ 等发版（日报）/ 🔧 修复进度（周报）、👀 观察（今天不用动）。

一个 issue MUST 只进一档，优先级 🚨 > ⏳ > 👀。

理由：2026-10-11 生产日报卡片的 4 条 🔴 全是慢性状态，而 3 个「修了仍在」与本周第一的崩溃 `8bc4b97e` 均未出现在卡片上——平铺的告警行无法回答「谁今天要动什么」。

#### Scenario: 存在紧急项

- **WHEN** 本轮至少有一条 🚨
- **THEN** 卡片标题 MUST 写明紧急条数，header 模板 MUST 为红色
- **AND** 🚨 段 MUST 位于卡片正文最前

#### Scenario: 无紧急项

- **WHEN** 本轮 🚨 为空
- **THEN** 卡片标题 MUST 写「今日无需开发处理」（周报：「本周无必修」），并给出 ⏳ / 👀 计数
- **AND** header 模板 MUST 按次高档取色（有 ⏳ 为橙，否则为绿）
- **AND** MUST NOT 留空白段落——空段会被读成取数失败

#### Scenario: 每条紧急项自带理由与入口

- **WHEN** 呈现一条 🚨
- **THEN** MUST 写明平台、标题、issue 短 id、一句「为什么紧急」与 7 天影响台数
- **AND** MUST 提供指向该 issue 控制台的直达按钮

### Requirement: 日报分档为确定性规则

日报的分档 MUST 由脚本确定性判定，MUST NOT 调用模型。判定对象 MUST 是报告版本集（最新 2 版 ∪ 告警判定版本）。

🚨 条件（任一）：
1. 修复状态为「修了仍在」，且报告版本集内 7 天影响台数 > 0；
2. 未修，生命周期为新增 / 暴涨 / 回归，且 7 天影响台数 ≥ `TIER_NEW_MIN`；
3. 未修，生命周期为长期，且 7 天影响台数 ≥ `TIER_LONG_MIN`；
4. 告警判定版本的崩溃率或 ANR 率命中红档；
5. 告警判定版本的性能指标相对上一版本退化超过门槛，且两版样本均过现有样本闸门。

⏳ 条件：修复状态为「已修未发版」、发版判定可得、issue 为 OPEN——与现 L1「代码已修但未发版」为同一判定。

阈值 `TIER_NEW_MIN` / `TIER_LONG_MIN` 与退化门槛 MUST 集中为脚本顶部常量。

#### Scenario: 修了仍在但近期无事件

- **WHEN** 某 issue 修复状态为「修了仍在」，但报告版本集内 7 天影响台数为 0
- **THEN** MUST NOT 进 🚨
- **AND** 理由：`new_build_events` 是修复提交以来的累计量，单独使用会让早已平息的 issue 长期占据紧急档

#### Scenario: 发版判定不可得

- **WHEN** 某 issue 的 `release_check` 不为 `ok`
- **THEN** MUST NOT 依据修复状态把它判入 🚨 或 ⏳
- **AND** MUST 沿用既有「修复发版判定不可得（N 条）」注记，MUST NOT 退回只比时间的判定

#### Scenario: 已修未发版按影响排序

- **WHEN** 呈现 ⏳ 段
- **THEN** 条目 MUST 按 7 天影响台数降序，且 MUST 列出 issue id 与修复提交标题首行
- **AND** MUST NOT 只给计数

#### Scenario: 日报不呈现人工结论

- **WHEN** 渲染日报任一档
- **THEN** MUST NOT 呈现人工处置结论或周报的 P0/P1 标签
- **AND** 修复提交标题属反扫得到的机器事实，MAY 呈现

### Requirement: 周报分档由分析层优先级契约驱动

周报的 🚨 SHALL 取自分析层产物 `priorities.json` 中的 P0 / P1 条目（P2 归 👀）。该产物 MUST 经脚本校验：数组；`issue_id` 为 32 位小写十六进制且出现在本轮 `snapshot.json`；`priority` ∈ {P0, P1, P2}。

`priorities.json` MUST NOT 成为分析层的成功判据。

#### Scenario: 契约合规

- **WHEN** `priorities.json` 校验通过且非空
- **THEN** 🚨 段 MUST 按 P0 → P1 呈现，每条带一句动作
- **AND** MUST 标注「模型分析 · 未经人工复核」

#### Scenario: 契约失效

- **WHEN** `priorities.json` 缺失、非法，或校验后为空而快照非空
- **THEN** 🚨 MUST 回落为日报分档规则（周口径数据）
- **AND** MUST 在卡片与文档显式标注「分析层优先级不可用（原因）——以下为规则判定」

#### Scenario: 编造的 issue

- **WHEN** 某条目的 `issue_id` 不在本轮快照中
- **THEN** 该条 MUST 被剔除并记日志
- **AND** MUST NOT 呈现

### Requirement: 健康度面板按平台分判

卡片 SHALL 以健康度面板呈现各端判定版本的整体指标，iOS 与 Android 分列。每个数字 MUST 独立判灯，MUST NOT 两端合用一盏灯。只有命中红 / 黄档的数字着色，正常值以裸值呈现。

#### Scenario: 一端红一端正常

- **WHEN** Android 启动 P95 为红档、iOS 为绿档
- **THEN** 只有 Android 的数字着红
- **AND** iOS 的数字 MUST NOT 着色

#### Scenario: 判定版本不是最新版

- **WHEN** 小样本回退使判定版本不同于最新版
- **THEN** 面板 MUST 另起一行呈现最新版的版本号、设备数与小样本提示
- **AND** MUST NOT 让最新版从卡片上消失

### Requirement: 慢帧与冻结以平台整体值判灯

慢帧与冻结的判灯值 MUST 为平台整体值（该平台全部 SCREEN_TRACE 的 `slow_frame_ratio` / `frozen_frame_ratio` 平均，与天级平台值同算法），窗口与性能段一致。最差页 MUST 继续取数并呈现，作为下钻线索，MUST NOT 参与判灯。

平台整体的窗口值与天级单日值 MUST 分开存储，MUST NOT 混入同一字段。

#### Scenario: 最差页超标而平台整体未超

- **WHEN** 最差页慢帧 87.8%、平台整体 43.6%（红档 50%）
- **THEN** 慢帧判黄档
- **AND** 最差页以括注呈现且 MUST NOT 着红

### Requirement: 红灯附下钻

健康度中命中红档的指标 SHALL 在卡片附一张下钻图，并配一句结论（哪部分拖的、占比）与一句历史（新问题 / 在改善 / 在恶化）。卡片上的下钻图 MUST NOT 超过 2 张；未命中红档的指标 MUST NOT 出图。

| 红灯 | 下钻维度 |
| --- | --- |
| 启动 P95 | 系统版本分桶 |
| 慢帧 / 冻结 | 页面 |
| 接口错误率 | 接口 |
| 崩溃率 | issue |

#### Scenario: 桶样本不足

- **WHEN** 某分桶样本数 < 20
- **THEN** 该桶 MUST NOT 呈现 P95，改标样本不足

#### Scenario: 不按机型下钻

- **WHEN** 选择性能下钻维度
- **THEN** MUST NOT 使用设备机型——单机型样本过少（实测 4–15），P95 退化为最大值

#### Scenario: 深色模式

- **WHEN** 渲染下钻图
- **THEN** 配色 MUST 使用主题自适应方案（`color_theme`），MUST NOT 写死浅色 / 深色专属色值

### Requirement: 卡片组件按内容选型

卡片组件 MUST 按下表选型。

| 内容 | 组件 |
| --- | --- |
| 🚨 条目 | `column_set` 色底块 + `button` |
| 次要列表（⏳ 其余、👀、修复进度明细） | `collapsible_panel`（默认收起）内的 markdown 表格语法 |
| 健康度 | 两列 `column_set` |

#### Scenario: 折叠面板内需要表格

- **WHEN** 折叠面板内需要对齐成列的列表
- **THEN** MUST 使用 markdown 块中的表格语法
- **AND** MUST NOT 使用 `{tag:"table"}`——飞书拒发（`ErrCode 200621`，2026-10-11 实测）

#### Scenario: 卡片能力判断的证据

- **WHEN** 判断某组件或写法在卡片上是否可行
- **THEN** 结论 MUST 来自真实发送一张卡片
- **AND** 链接可点性 MUST 在客户端点击确认，MUST NOT 以消息读回内容为准——读回会把 markdown 表格内的链接压平成文本
