# crash-perf-data-staleness-guard Specification

## Purpose

日报各数据段（性能 / 版本放量 / 崩溃）在数据源停更或滞后导致查询窗口内无数据时，显式告警「数据未同步，最新截至 XX」而非输出空表，避免读者误读为空数据；同时把版本放量数据源切到 REALTIME 活表以消除停更空表。

## Requirements

### Requirement: 数据未同步显式告警

日报各数据段（性能 / 版本放量 / 崩溃）MUST 在「数据源表存在但查询窗口内 0 行」时，输出显式告警「⚠️ 数据未同步，最新截至 XX」而非静默空表。

#### Scenario: 表存在但窗口内无数据

- **WHEN** 某数据段的数据表存在、但按窗口查询返回 0 行
- **THEN** 该段输出「⚠️ 数据未同步，最新截至 XX」（XX 为该表最新 `event_timestamp`），MUST NOT 输出空表格
- **AND** 不因该段无数据而整体失败，其余段正常展示

#### Scenario: 表不存在

- **WHEN** 某数据段的数据表不存在
- **THEN** 该段输出「表尚未同步」告警并跳过，不整体失败（维持现状）

### Requirement: 版本放量数据源走 REALTIME 活表

版本放量段（各版本会话数 / 设备数）SHALL 从 `firebase_sessions` 的 REALTIME 表读取数据，而非停更的批量表。

#### Scenario: REALTIME 表就绪

- **WHEN** `firebase_sessions.*_REALTIME` 表存在
- **THEN** 版本放量查询使用 REALTIME 表
- **AND** 产出各版本会话数 / 设备数 / 最新数据日期

#### Scenario: REALTIME 表缺失时回退

- **WHEN** REALTIME 表不存在但批量表存在
- **THEN** 回退到批量表查询，并标注「REALTIME 表缺失，回退批量表」

### Requirement: 各段截止时间戳分别如实标注

日报 MUST 按各数据段各自的表，分别查询并显示其最新 `event_timestamp` 作为该段数据实际截止时间，MUST NOT 用单一 `DATA_UNTIL` 概括所有段。

#### Scenario: 多数据源各自标注

- **WHEN** 生成日报
- **THEN** 性能段标注 performance 表最新时间戳、放量段标注 sessions 表最新时间戳、崩溃段标注 crashlytics 表最新时间戳
- **AND** 卡片与文档均如实展示各段截止时间

### Requirement: 性能窗口容忍每日批量同步滞后

性能段查询窗口 SHALL 放宽到能覆盖 firebase_performance 约 2 天的每日批量同步滞后（默认近 3 天），避免窗口过窄导致的空表。

#### Scenario: 每日批量同步滞后 2 天

- **WHEN** firebase_performance 表最新数据滞后约 2 天
- **THEN** 性能段仍能在窗口内查到数据并展示
- **AND** 若窗口内仍无数据，触发「数据未同步显式告警」requirement

### Requirement: 性能窗口只取完整日

性能段的取数窗口 SHALL 只包含**完整的日历日**，窗口锚点 MUST 为「最后一个完整日」（`LAST_COMPLETE_DAY = DATE(表最新事件时间戳) − 1`），MUST NOT 锚在跑批时刻。

理由：firebase_performance 每天只灌到 06:59 UTC，**表里最后一个日历日恒为 7 小时的残日**（2026-08-27 实测 iOS：08-25 有 24 小时 44420 行，08-26 只有 7 小时 3988 行）。窗口锚在跑批时刻时，这半天既掺进滚动窗口，又被环比当成「今日」去和完整天比。⚠️ 由于跑批时刻固定，残日恒为 00:00–07:00 UTC（东亚上午），是**系统性构成偏差而非随机噪声**。

本 requirement 与既有「性能窗口容忍每日批量同步滞后」**并存不冲突**：放宽窗口是为了够得着数据，只取完整日是为了别把半天掺进来。

#### Scenario: 残日不得进入滚动窗口

- **WHEN** 性能表最新事件日只有部分小时的数据
- **THEN** 该日 MUST NOT 计入性能段的滚动窗口
- **AND** 窗口 MUST 为整日闭区间 `[LCD−(N−1), LCD]`

#### Scenario: 环比两端必须同为完整日

- **WHEN** 计算性能指标的日环比或周环比
- **THEN** 两端 MUST 都取完整日（`LCD` vs `LCD−1`；`LCD` vs `LCD−7`）
- **AND** MUST NOT 以「该版本最新可用单日」为环比一端——那一端可能是残日，差值将由窗口长度差异主导而非真实变化

#### Scenario: 完整日无法确定时降级

- **WHEN** 性能表取不到最新事件时间戳，完整日无法算出
- **THEN** 性能段 MUST 走既有缺数判定，MUST NOT 猜一个窗口继续取数

#### Scenario: 完整性判据不依赖分区元数据

- **WHEN** 判定某日数据是否已灌完
- **THEN** MUST 使用「表中存在 D+1 的事件 ⇒ D 已完整」这一判据
- **AND** MUST NOT 依据 `INFORMATION_SCHEMA.PARTITIONS`——性能表按**摄取时间**分区，`partition_id` 与事件日不是一回事（实测存在「无该日分区、按事件日却有数千行」的情况）
- **AND** 判据 MUST 复用既有的表最新时间戳查询，MUST NOT 为此新增 BigQuery 查询

### Requirement: 窗口口径切换必须留痕且跨口径比较必须标注

历史记录 SHALL 标记其性能字段取自哪套窗口口径；跨口径的环比 MUST 在报告上显式标注，MUST NOT 静默给出差值。

理由：口径切换后，旧行存的是含残日的值、新行存的是完整日值，两者相减得到的差里混着「窗口形状变了」这一项。这与「滚动窗口展示值与天级单日值分离存储、不可混比」是同一条纪律。

#### Scenario: 新写入的历史行标记口径

- **WHEN** 写入性能历史记录
- **THEN** MUST 带 `window_mode` 标记（`legacy` / `complete_day`）
- **AND** 取值 MUST 反映**本轮是否真的取到了完整日窗口**，MUST NOT 仅因代码版本而标为新口径

#### Scenario: 历史不回填不重算

- **WHEN** 口径切换生效
- **THEN** 既有历史行 MUST NOT 被回填或重算
- **AND** 读取侧 MUST 把缺少 `window_mode` 的行视为 `legacy`

#### Scenario: 跨口径环比必须标注

- **WHEN** 环比基准行的口径与本轮不同
- **THEN** MUST 在该环比处标注跨口径及口径切换日期
- **AND** 标注 MUST 在基准行口径与本轮一致后自动消失，MUST NOT 依赖人工摘除
