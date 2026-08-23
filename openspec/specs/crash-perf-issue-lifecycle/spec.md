# crash-perf-issue-lifecycle Specification

## Purpose
让每个崩溃 issue 在报告中带上生命周期状态——新出现、曾消失又回来、持续存在——使读者无需比对历史即可判断哪些需要立刻关注。

## Requirements

### Requirement: issue 生命周期标记

崩溃 issue 明细 MUST 为每个 issue 标注其生命周期状态：本轮首次出现、曾出现过但上一轮未出现（回归）、以及连续出现（长期）。

判定基准 MUST 来自与崩溃统计**同一数据源**的 issue 标识集合，MUST NOT 依赖另一条独立且可能失效的采集通路。

#### Scenario: 首次出现的 issue

- **WHEN** 某 issue 的标识从未在历史基准中出现
- **THEN** 标注为新增

#### Scenario: 曾消失又出现的 issue

- **WHEN** 某 issue 曾出现在历史基准中，但上一轮未出现，本轮又出现
- **THEN** 标注为回归
- **AND** 该状态与「新增」区分呈现——回归意味着修复失效或场景重现，与全新问题的处置方式不同

#### Scenario: 连续出现的 issue

- **WHEN** 某 issue 上一轮与本轮都出现
- **THEN** 标注为长期存在

### Requirement: 首轮建立基线不标新增

当历史基准不存在或不含生命周期所需结构时，本轮 MUST 只建立基线，MUST NOT 将全部 issue 标注为新增。

理由：首轮把每个 issue 都标成新增会刷满整屏，且与「新增」这个词要传达的信息相反——它应当表示变化，而首轮没有变化可言。

#### Scenario: 基准缺失或结构陈旧

- **WHEN** 历史基准文件不存在，或不含生命周期所需的结构
- **THEN** 本轮建立基线并照常呈现 issue 明细
- **AND** 不标注任何 issue 为新增或回归

### Requirement: 基准保留期有界

生命周期基准 MUST 有明确的保留期，超出保留期的 issue 标识 MUST 被清理。

理由：基准是「见过哪些 issue」的集合，不设上界会无限增长；且过于久远的一次出现，再次出现时更接近新问题而非回归。

#### Scenario: 基准中存在超期条目

- **WHEN** 某 issue 标识的末次出现时间超出保留期
- **THEN** 该标识从基准中清理
- **AND** 该 issue 若再次出现，按新增处理
