# crash-perf-data-analysis-split Specification

## Purpose

L2 周报的取数与分析分属两层：数据层是确定性聚合（BigQuery + git），分析层需要模型。本能力规定两层的边界、降级行为，以及产出中如何让读者看见「本周有没有分析」。

存在的理由是一次实测事故：数据层原先绑在 `claude -p` 上，2026-08-19 18:21 与 08-20 09:30 两次 Anthropic 429 导致 `crash-weekly.sh` 整跑失败，飞书群里什么都收不到——而那些数字本就躺在 BigQuery 里。

## Requirements

### Requirement: 数据层不依赖模型

L2 的崩溃快照 `snapshot.json` MUST 由纯脚本产出，取数过程 MUST NOT 调用任何大模型或 MCP。

数据层 MUST 产出与模型路径一致的结构 `{"ios":[...],"android":[...]}`，每条至少含 `id` / `title` / `events` / `users` / `fix_commit` / `fix_branches`，使下游（变化检测、台账渲染、卡片）无需感知数据来源。

#### Scenario: 模型完全不可用时数据层照常产出

- **WHEN** 模型额度耗尽（HTTP 429）、模型服务不可达，或显式设置 `CRASH_REPORT_SKIP_ANALYSIS=1`
- **THEN** 数据层 MUST 正常产出 `snapshot.json`
- **AND** 变化检测、修复状态反扫、台账现状表与变更时间线 MUST 正常产出
- **AND** `crash-weekly.sh` MUST 以退出码 0 结束并产出完整投递清单

#### Scenario: 数据层取数失败必须显式失败

- **WHEN** BigQuery 查询在 iOS 与 Android 两端均未返回任何 issue
- **THEN** 数据层 MUST 以非零退出码中止
- **AND** MUST NOT 产出「本周零崩溃」这类看起来正常的报告——把取数故障渲染成业务结论是最坏的错误报告

### Requirement: 数据层按 issue 跨版本追踪

数据层的取数 MUST NOT 施加版本过滤。

台账按 issue 追踪一条崩溃的完整生命周期，版本过滤会让「上一版修好、这版没复发」的 issue 从现状表中凭空消失，导致变更时间线断档。该口径与它替代的 Firebase MCP `topIssues`（无版本过滤能力）一致。

#### Scenario: 旧版本仍在崩的 issue 不因版本过滤而消失

- **WHEN** 某 issue 的事件只出现在非最新版本上
- **THEN** 该 issue MUST 仍出现在 `snapshot.json` 与台账现状表中

### Requirement: 分析层失败只降级不中止

分析层（根因、风险分级、修复方案）MUST 是可选产物。分析层超时、失败或被显式跳过时，跑批 MUST 继续完成投递。

#### Scenario: 分析超时

- **WHEN** 分析层运行超过 `TRIAGE_TIMEOUT`
- **THEN** 跑批 MUST 继续，周报少一章分析
- **AND** 产出 MUST 标注超时为缺失原因

### Requirement: 产出显式标注分析层状态

周报与群卡片 MUST 显式标注本轮有无深度分析；无分析时 MUST 同时给出原因，并声明数据与台账不受影响。

缺分析与无异常是两件完全不同的事。若不标注，读者会把「本周没有根因分析」读成「本周没有问题」——这是比缺失本身更严重的后果。

#### Scenario: 无分析时的标注

- **WHEN** 本轮未产出分析报告
- **THEN** 周报 MUST 含形如「⚠️ 本周无深度分析 — <原因>」的声明
- **AND** 群卡片的口径行 MUST 同样可见该声明（卡片读者多数不会点进文档）
- **AND** 声明 MUST 说明数据、台账与变化检测不受影响

#### Scenario: 有分析时的标注

- **WHEN** 本轮产出了分析报告
- **THEN** 产出 MUST 标注根因与修复方案未经人工复核、落地前须验证

### Requirement: 事实层缓存判定由脚本执行

事实层缓存的命中判定 MUST 在脚本中完成，MUST NOT 依赖模型按提示词自觉执行。

判定依据 MUST 是可确定性求值的条件（缓存文件是否存在、已记录事件计数与本次是否一致）。`CRASH_REPORT_FORCE_REFETCH=1` MUST 跳过命中判定强制重写。

#### Scenario: 二次跑批全部命中

- **WHEN** 同一批 issue 的事件计数相对上次跑批没有变化
- **THEN** 缓存 MUST 全部判定为命中并跳过重写

#### Scenario: 强制重抓

- **WHEN** 设置 `CRASH_REPORT_FORCE_REFETCH=1`
- **THEN** 所有 issue 的缓存文件 MUST 被重新写入，忽略命中判定

### Requirement: 不同来源的缓存互不覆盖

脚本路径与模型路径写入同一 issue 的缓存文件时 MUST 可区分来源，且 MUST NOT 相互破坏对方独有的字段。

脚本路径拿不到事件明细，只能落聚合事实；模型路径能落完整事件数组。若不加区分，脚本路径会把模型辛苦抓来的事件明细覆盖成一个计数。

#### Scenario: 脚本路径写入缓存

- **WHEN** 数据层写入 `$STATE/issues/<32位id>.json`
- **THEN** 文件 MUST 标记来源为 `bigquery`
- **AND** MUST NOT 删除或改写模型路径写入的事件明细字段
