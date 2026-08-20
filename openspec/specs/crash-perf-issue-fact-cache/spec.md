# crash-perf-issue-fact-cache Specification

## Purpose

定义崩溃事件事实层的落盘、命中判定与增量抓取语义。崩溃事件是不可变的历史事实，一次抓取应永久可用，避免每轮重复抓取同一批历史事件。

## Requirements

### Requirement: 事实层按 issue 落盘并永久保留

每个 issue 的完整事件详情 MUST 以该 issue 的完整标识落盘保存，且不参与任何按时间的自动清理。

#### Scenario: 首次抓取某 issue

- **WHEN** 某 issue 的事实层记录不存在
- **THEN** 抓取其事件详情并落盘
- **AND** 落盘内容包含分析所需字段：堆栈帧、设备型号、系统版本、可用内存、进程状态、崩溃前屏幕、操作轨迹、构建标识

#### Scenario: 跑批产物清理执行

- **WHEN** 按期清理过期跑批产物
- **THEN** 事实层记录不被删除

### Requirement: 已有事实优先读本地

跑批时 MUST 先判定本地事实层是否已覆盖所需事件，命中则不重复抓取。

#### Scenario: 事实层已完整覆盖

- **WHEN** 某 issue 的本地事件数与线上事件数一致
- **THEN** 直接读取本地事实层
- **AND** 不发起该 issue 的事件详情抓取

#### Scenario: 线上有新增事件

- **WHEN** 某 issue 的线上事件数大于本地已存事件数
- **THEN** 只抓取新增部分并合并入本地事实层
- **AND** 既有事件记录不被改写

#### Scenario: issue 已关闭且计数未变

- **WHEN** 某 issue 在线上已关闭且事件数与本地一致
- **THEN** 完全跳过该 issue 的抓取

### Requirement: 支持强制重抓

MUST 提供显式开关，在事实层疑似损坏或口径变更时打掉本地缓存重新抓取。

#### Scenario: 开启强制重抓

- **WHEN** 强制重抓开关被启用
- **THEN** 忽略本地事实层，对全部 issue 重新抓取
- **AND** 重抓结果覆盖本地记录

#### Scenario: 未开启强制重抓

- **WHEN** 强制重抓开关未启用
- **THEN** 按命中判定决定是否抓取

### Requirement: 事实层缺失不阻断分析降级

事实层抓取失败时， MUST 以已有本地内容继续，而非整段失败。

#### Scenario: 部分 issue 抓取失败

- **WHEN** 某些 issue 的事件详情抓取失败
- **AND** 另一些已有本地事实
- **THEN** 分析基于可用事实继续
- **AND** 报告显式标明哪些 issue 的事实不完整

#### Scenario: 区分「查过没有」与「未查」

- **WHEN** 某项事实经查证确实不存在
- **THEN** 记录为已查证的空值
- **AND** 不与「未查」混同呈现
