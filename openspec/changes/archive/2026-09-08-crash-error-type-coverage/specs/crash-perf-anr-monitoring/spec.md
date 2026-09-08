## Purpose

让 Android 的 ANR（应用无响应）成为日/周报的一等指标，并要求 iOS 侧因系统层无此概念而产生的空缺被显式标注，而非以空值或零值呈现——后者会被读成「该端没有卡死问题」。

## ADDED Requirements

### Requirement: Android ANR 采集与呈现

日报与周报 MUST 呈现 Android 的 ANR 事件数、受影响安装数与 ANR 率，按版本分列，口径与既有崩溃指标一致（同一时间窗、同一版本集合、同一分母来源）。

ANR 事件 MUST 从崩溃数据源中按事件类型标识识别，MUST NOT 依赖「是否致命」标志——ANR 的致命标志为假，沿用崩溃段的致命过滤会使其整体不可见。

#### Scenario: 主力版本存在 ANR

- **WHEN** 某 Android 版本在统计窗口内存在 ANR 事件
- **THEN** 报告呈现该版本的 ANR 事件数、受影响安装数与 ANR 率
- **AND** 该版本的崩溃次数、崩溃率、受影响安装三项**不包含** ANR，保持既有致命口径

#### Scenario: 某版本窗口内无 ANR

- **WHEN** 某 Android 版本在窗口内无 ANR 事件，且该版本有会话数据
- **THEN** 呈现为零值——「这版没有 ANR」是结论本身
- **AND** 不呈现为缺数

### Requirement: ANR 率的阈值判定与告警

ANR 率 MUST 参与红/黄/绿阈值判定，判定方式与既有指标一致（空值与「无法计算」不判定），红档 MUST 进入摘要行并触发告警。

告警 MUST 仅由最新版本触发，与既有告警口径一致。

#### Scenario: ANR 率超过红线

- **WHEN** 最新 Android 版本的 ANR 率高于红线阈值
- **THEN** 摘要行呈现该项并标明版本号
- **AND** 卡片进入告警态

#### Scenario: 上一版本 ANR 率超过红线

- **WHEN** 仅上一个版本的 ANR 率超过红线，最新版本未超
- **THEN** 该单元格着色，但不触发告警

### Requirement: ANR 口径与外部标准的差异必须标注

报告呈现的 ANR 率 MUST 标注其分母口径。当该口径与应用商店用于质量门槛判定的口径不一致时，MUST 显式说明差异，MUST NOT 让读者误以为可直接对照商店门槛判定是否达标。

#### Scenario: 报告呈现 ANR 率

- **WHEN** 报告呈现 ANR 率
- **THEN** 同时标明其分母（会话数）与统计窗口
- **AND** 标注该口径与商店质量门槛所用口径（按日活用户计的用户感知 ANR 率）不同，不可直接比对

### Requirement: iOS 的 ANR 空缺必须显式标注

iOS 系统层无 ANR 概念，数据源不产出该类事件。iOS 侧的 ANR 位置 MUST 呈现为显式说明，MUST NOT 呈现为空值、横杠或零。

该说明 MUST 指向本流水线中已有的近似信号（冻结率与慢帧），使读者知道去哪里看 iOS 的卡顿情况。

#### Scenario: 双端并列呈现

- **WHEN** 报告并列呈现双端 ANR
- **THEN** iOS 位置呈现「无此概念」的说明与近似信号的指向
- **AND** 不呈现零值或空值——两者都会被读成「iOS 没有卡死问题」

#### Scenario: 摘要行的 ANR 项

- **WHEN** ANR 进入摘要行
- **THEN** 摘要行只呈现 Android 一端，不为 iOS 补一个无意义的占位值
