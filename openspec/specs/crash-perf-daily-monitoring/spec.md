# crash-perf-daily-monitoring Specification

## Purpose

定义 Dino 崩溃 & 性能日报的监控增强契约：环比 DoD/WoW、受影响安装数、统一阈值红绿灯、小样本提示、慢帧定义注释与 7 日 sparkline，以及支撑它们的每日指标持久化与 7 日滚动历史，让日报从「报数」升级为「判势」。

## Requirements

### Requirement: 环比对比 DoD/WoW

崩溃率、接口错误率、启动 P50/P95、慢帧占比、冻结率 五个指标 SHALL 在日报中补「环比昨日 DoD / 同比上周同日 WoW」两档对比，iOS 与 Android 分开呈现。

#### Scenario: 百分比指标用百分点

- **WHEN** 展示崩溃率、接口错误率、慢帧占比或冻结率的 DoD/WoW
- **THEN** 对比值 MUST 用「±X.Xpp ↑/↓」形式（如 `0.20% DoD -0.05pp ↓ | WoW +0.12pp ↑`）
- **AND** 箭头方向 MUST 沿用「数值变大 = 变差 = ↑」的现有约定

#### Scenario: 耗时指标用毫秒绝对差

- **WHEN** 展示启动 P50/P95 的 DoD/WoW
- **THEN** 对比值 MUST 用「±Xms」绝对差形式（如 `266ms DoD -8ms ↓ | WoW +12ms ↑`）
- **AND** MUST NOT 用百分比形式表达启动耗时的环比

#### Scenario: 双端分开呈现

- **WHEN** 某指标 iOS 与 Android 均有数据
- **THEN** DoD/WoW MUST 按 iOS / Android 分别计算与呈现
- **AND** MUST NOT 把两端合并成一个对比值

#### Scenario: 性能指标滞后回退

- **WHEN** 计算启动 P50/P95、慢帧占比、冻结率等性能类指标的 DoD
- **THEN** MUST 取「最新可用单日值」与其前一单日值对比（性能批量表滞后约 2 天，昨日值常未到齐）
- **AND** MUST 在展示中标注实际对比日期，不把「最新可用日」冒充「昨日」
- **AND** 历史里仅有一个可用日时 MUST 显示「无基准」
- **AND** 崩溃/放量（REALTIME）不受此影响，严格按「昨日」单日值对比

#### Scenario: 慢帧冻结环比用平台聚合

- **WHEN** 计算慢帧占比、冻结率的 DoD/WoW
- **THEN** MUST 用平台级聚合帧级占比（iOS/Android 各自汇总页面帧数后计算）作对比
- **AND** MUST NOT 用「最差页」单页值做跨天环比（最差页每天可能不同，跨天对比语义失真）
- **AND** 卡片「最差页」今日展示（含页名）保持不变，仅作现状，不参与环比

#### Scenario: 无基准不显示对比

- **WHEN** 某指标无任何历史基准可比（首日运行、WoW 的 D-7 尚无历史、或该指标数据源完全不可得）
- **THEN** 该档对比 MUST 显示「无基准」或省略
- **AND** MUST NOT 用 0 或空值硬算出一个误导性的环比

### Requirement: 受影响安装数口径

崩溃统计 SHALL 新增「受影响安装数」指标，口径为 `COUNT(DISTINCT installation_uuid)`，与现有「事件数 / 会话数」并列展示。

#### Scenario: 口径计算

- **WHEN** 计算某平台崩溃的受影响安装数
- **THEN** MUST 统计 crashlytics 表中 `is_fatal = TRUE` 且时间在报告窗口内的 `COUNT(DISTINCT installation_uuid)`
- **AND** MUST 与崩溃率分子同表同窗口，保证口径一致

#### Scenario: 与事件数会话数并列

- **WHEN** 展示崩溃统计
- **THEN** 受影响安装数 MUST 与「事件数 / 会话数」并列呈现（如 `受影响安装 iOS N / Android M`）
- **AND** MUST NOT 用 `session_id` 或 `user.id` 冒充安装数（Android 无 `user.id`，session 与 installation 是两套 ID）

#### Scenario: 不做 crash-free 用户率

- **WHEN** 需要表达用户维度的崩溃率
- **THEN** MUST NOT 声称「Crash-Free Users Rate」
- **AND** 理由：缺乏可靠的「总用户数」分母（sessions.`instance_id` 与 crashlytics.`installation_uuid` 是两套 ID，对不上）

### Requirement: 统一阈值红绿灯

崩溃率、慢帧占比、冻结率、启动 P95、接口错误率 五个指标 SHALL 统一使用红/黄/绿三档阈值判定，阈值做成脚本顶部可配置常量，不再散落硬编码。

#### Scenario: 红档判定

- **WHEN** 任一指标超过红档阈值（初值：崩溃率 >1%、慢帧占比 >50%、冻结率 >1%、启动 P95 >2000ms）
- **THEN** 日报 MUST 输出该指标的红色告警（🔴）
- **AND** 接口错误率首版沿用现行为「>0 即 🔴」（纳入框架后红档阈值 = >0，黄绿待对齐）

#### Scenario: 阈值可配置

- **WHEN** 需要调整某指标阈值
- **THEN** 只须改脚本顶部一处常量（如 `CRASH_RATE_RED=1.0`）
- **AND** MUST NOT 在判定逻辑里出现散落的硬编码阈值

#### Scenario: 黄档标注待对齐

- **WHEN** 黄档/绿档阈值尚未与 requester 对齐
- **THEN** 对应常量与注释 MUST 显式标注「待对齐」
- **AND** MUST NOT 把未对齐的建议值当作已确认的阈值口径

#### Scenario: 接口错误率纳入统一框架

- **WHEN** 判定接口错误率告警
- **THEN** MUST 走统一阈值框架，而非保留独立的「>0 即 🔴」硬编码分支
- **AND** 首版红档阈值沿用 >0，行为不倒退

### Requirement: 小样本量提示

当某平台（iOS/Android）当日会话数低于阈值时，该行数据 SHALL 追加「⚠️ 样本量小，仅供参考」提示，阈值做成可配置常量。粒度钉死为平台级（与崩溃/性能卡片行同为 iOS/Android 平台级），不按版本细分。

#### Scenario: 低于阈值追加提示

- **WHEN** 某平台当日会话数 < 阈值（默认 30，可配置）
- **THEN** 该行指标数据后 MUST 追加「⚠️ 样本量小，仅供参考」
- **AND** 提示 MUST 只标注不省略数据（数据仍展示）

#### Scenario: 会话数来源

- **WHEN** 判定小样本量
- **THEN** 会话数 MUST 取自 sessions 表按平台（iOS/Android）分组的天级单日值（与 DoD/WoW 同口径）
- **AND** MUST NOT 用 7 天滚动窗口会话数冒充当日会话数
- **AND** MUST NOT 按版本细分会话数（崩溃/性能卡片行为平台级，小样本提示与之对齐）

### Requirement: 慢帧最差页指标定义注释

日报 SHALL 在注释区说明「慢帧最差页」的百分比含义，避免把帧级占比误读为会话占比。

#### Scenario: 帧级占比说明

- **WHEN** 展示慢帧最差页的百分比
- **THEN** 注释区 MUST 说明该百分比是「该页面渲染期间慢帧（>16ms）帧数 ÷ 全部帧数」的帧级占比
- **AND** MUST NOT 表述为「出现慢帧的会话占比」
- **AND** 冻结帧同理 MUST 注明为「>700ms 帧级占比」

### Requirement: 7 日趋势 sparkline

崩溃率、接口错误率、启动 P95 三个指标 SHALL 提供 7 日趋势迷你图（sparkline），帮助判断问题是「新增」还是「持续」。

#### Scenario: 三指标范围

- **WHEN** 生成 sparkline
- **THEN** MUST 覆盖崩溃率、接口错误率、启动 P95 三个指标
- **AND** 慢帧、冻结、启动 P50 不在 sparkline 范围（但仍在 DoD/WoW 范围）

#### Scenario: 字符渲染

- **WHEN** 渲染 sparkline
- **THEN** MUST 使用 Unicode 方块字符（`▁▂▃▄▅▆▇█`）在 markdown 内原生渲染
- **AND** MUST NOT 依赖图片或外部图表服务

#### Scenario: 冷启动按已有天数

- **WHEN** 历史不足 7 天（上线初期）
- **THEN** sparkline MUST 按已有天数渲染，MUST NOT 用空值补齐伪装成 7 天
- **AND** MUST NOT 因历史不足而报错或中断日报

### Requirement: 每日指标持久化与 7 日滚动历史

系统 SHALL 每日持久化全指标「天级单日值」，并保留最近 7 天滚动历史，作为 DoD/WoW/sparkline 的统一数据基准。

#### Scenario: 全指标单点持久化

- **WHEN** 每次日报运行结束
- **THEN** MUST 把崩溃率分子分母、受影响安装数、接口错误率、慢帧占比、冻结率、启动 P50/P95、平台会话数的天级单日值持久化
- **AND** 持久化字段 MUST 带口径标识（区分天级单日值与滚动窗口展示值）

#### Scenario: 7 日滚动保留

- **WHEN** 持久化每日指标
- **THEN** MUST 只保留最近 7 天记录，超出部分截断
- **AND** 每日追加一行（append），不清空历史

#### Scenario: 原子写入

- **WHEN** 写历史文件
- **THEN** MUST 用临时文件 + 原子替换（mv）方式写入
- **AND** MUST NOT 出现半行或文件截断导致后续运行读坏历史
