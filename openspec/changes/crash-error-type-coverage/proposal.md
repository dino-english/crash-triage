## Why

崩溃 SQL 的 `WHERE is_fatal = TRUE` 把数据源里**两类信号整体挡在报告之外**。实测近 14 天：

| 平台 | FATAL | **ANR** | **NON_FATAL** |
|---|---|---|---|
| Android | 105 | **93** | **131** |
| iOS | 4 | —（无此概念） | **1020** |

三个后果，严重度递减：

**① Android ANR 完全不可见。** 实测主力版本 ANR 率 **1.5.3 = 0.743%、1.5.1 = 0.794%**（ANR 事件 / 会话）。Google Play 的 Bad Behaviour 门槛是用户感知 ANR 率 0.47%（日活口径，与此处不同口径，但数量级已在阈值上方），超标会影响商店可见度与推荐。ANR 事件量几乎与崩溃持平（93 vs 105），**而 ANR 在本仓库的全部代码、SQL、spec、change 里出现次数为零**——从未被讨论过。

**② iOS 日报在说「0 崩溃」，同窗口有 1020 条非致命异常。** 技术上没错（FATAL=4，两个主力版本各 0），但读者的合理结论是「iOS 没问题」。这是取数口径造成的系统性误导，不是数字错误。

**③ 报告里有一行硬编码文案与实况相反。** [crash-daily.sh:1197](../../../bin/crash-daily.sh) 打印：

> 「**NON_FATAL**：iOS 通路已建但尚未合入发版分支，**线上仍为零上报**，两端数字暂不可比。」

iOS NON_FATAL 实测 **1020 条**。通路早已通了，这行静态文案还在说零上报。spec `crash-perf-daily-weekly-report` 的「NON_FATAL 维度展示」要求「通路发版后 THEN 替换为双端 NON_FATAL 事件量与 TOP issue」——**该替换从未发生**。这不是新需求，是既有要求未兑现。

**为什么会这样**：`crash-issues.sql` 的注释写明理由——「只统计 is_fatal=TRUE，**与 topIssues 的 FATAL 过滤一致**」。BigQuery 迁移时刻意保真了 MCP 的旧行为。但迁移的目的恰恰是摆脱 topIssues 的限制（只返回 OPEN issue）。**该继承的继承了，不该继承的也继承了。**

## What Changes

- **新增 ANR 段（Android）**：ANR 事件数、受影响安装数、ANR 率，按版本分列，进卡片与文档。新增红/黄阈值常量。
- **iOS 的 ANR 位置显式标注不对称**，不留空、不填 0：iOS 系统层无 ANR 概念，Firebase 也不产出该 `error_type`（实测 iOS 只有 FATAL / NON_FATAL 两类）。标注指向本流水线已有的近似信号——**冻结率与慢帧**（Firebase Performance）。
  ⚠️ 留空或填 0 会被读成「iOS 没有卡死问题」，与 ③ 是同一个错误。
- **新增 NON_FATAL 段（双端）**：事件数与 TOP issue，兑现 spec 既有要求。
- **删除 `crash-daily.sh:1197` 的静态文案**，改为按实测数据渲染。
- **崩溃次数 / 崩溃率 / 受影响安装三行保持 FATAL 口径不变**：历史 `metrics-history.jsonl` 与台账都按此口径积累，改动会让趋势断裂。ANR 与 NON_FATAL **单独成段**，不并入崩溃率。
- **SQL 增 `error_type` 维度**：`crash-issues.sql`（L1）与 `crash-issues-all.sql`（L2）。

## Non-goals

- **不改崩溃率定义**。crash-free 口径是独立议题（`firebase_session_id` 字段已确认存在且覆盖率近 100%），另开 change。
- **不做机型 / OS / 时段下钻**。那是「汇总段」的范畴，另开 change（`crash-impact-summary`）。
- ~~不改 L2 台账~~ → **NON_FATAL 进台账**（2026-08-22 由使用方拍板，推翻原 Non-goal）。实现方式见 design D7：台账 Issue 现状表**拆为 FATAL / NON_FATAL 两张表**，NON_FATAL 表**按受影响安装数取 top N 并显式标注截断**。⚠️ 不做截断则 iOS 的 1020 条会把 FATAL 信号整个淹没，台账将不可用。ANR 是否进台账仍未定，本 change 不做。
- **不对齐 Play Console 的 ANR 口径**（用户感知 ANR 率、日活分母）。本 change 用「ANR 事件 / 会话」，与既有崩溃率同分母、内部可比；与 Play 的差异**必须在报告上标注**，不假装等价。

## Capabilities

### New Capabilities

- `crash-perf-anr-monitoring`：Android ANR 的采集、阈值判定与呈现，含 iOS 侧的不对称标注要求。

### Modified Capabilities

- `crash-perf-daily-weekly-report`：兑现既有的「NON_FATAL 维度展示」要求——从静态占位文案改为按实测数据渲染，并移除「线上仍为零上报」这一与实况相反的断言。

## Impact

| 文件 | 变更 |
|---|---|
| `bin/sql/crash-anr.sql` | **新增** —— ANR 事件 / 受影响安装，按版本 |
| `bin/sql/crash-nonfatal.sql` | **新增** —— NON_FATAL 事件与 TOP issue，按版本 |
| `bin/sql/crash-issues.sql` · `crash-issues-all.sql` | 注释更新：说明 `is_fatal = TRUE` 是**刻意的 FATAL 口径**，ANR / NON_FATAL 由另外的 SQL 覆盖（现注释说的是「与 topIssues 一致」，那个理由已经失效） |
| [bin/crash-daily.sh](../../../bin/crash-daily.sh) | 取数 + 新增两段渲染 + 阈值常量 + **删除 1197 行静态文案** |
| [bin/crash-weekly.sh](../../../bin/crash-weekly.sh) | 主力版本表增 ANR 列 |
| `$STATE/metrics-history.jsonl` | 新增 ANR 字段；旧行无该键，读取端按「无数据」处理，不回填 |

**风险**：ANR 率首次进报告很可能直接触发红档告警（0.74% / 0.79%，若阈值取 0.47%）。这是**正确行为**——问题一直存在，只是不可见。但要预告，避免上线当天被当成流水线故障。
