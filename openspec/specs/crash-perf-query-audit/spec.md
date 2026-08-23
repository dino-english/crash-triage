# crash-perf-query-audit Specification

## Purpose
定义崩溃 & 性能日/周报管线的**查询级审计**契约：以 append-only 事件流（`$STATE/audit/<run_id>.events.jsonl`）记录每次 bq 查询的来源与结果，使每个卡片数字可回指到（SQL 文件、表、时间窗口、行数、重试次数），并让 `table_exists()` 的静默降级路径变得可见。run_id 贯通 health 与报告头，使报表（派生投影）与事件流（真相）的指针关系显式化。

> **2026-08-20 收窄**：原契约还包含投递幂等台账、步骤级事件、metrics upsert、基线顺序四部分，均已由更简单的手段解决（见 proposal「已被取代的原始范围」）。审计是**旁路**，不承担投递决策与数据修复职责。

## Requirements

### Requirement: 审计事件流 sidecar

每次运行 SHALL 产生一个 append-only 事件日志 `$STATE/audit/<run_id>.events.jsonl`，同一 run 内全部事件共享该 run_id（取脚本时间戳 TS，形如 `YYYYMMDD-HHMMSS`），事件字段最小集为 `{seq, ts, run_id, type, step, payload}`。

#### Scenario: 事件流不阻塞主链路

- **WHEN** 审计事件写入失败（目录只读、磁盘满、jq 异常）
- **THEN** 主链路 MUST 继续执行且退出码不受影响
- **AND** 审计是旁路观测设施，MUST NOT 成为跑批的失败点

#### Scenario: 每行独立可解析

- **WHEN** 读取事件流
- **THEN** 每一行 MUST 是独立合法的 JSON（`jq -c` 可解析）
- **AND** 采用 append-only 写入，MUST NOT 重写或截断已有行

### Requirement: 查询级事件插桩

所有 bq 查询 MUST 经过插桩的汇聚点并落 `query` 事件，使每个卡片数字可回指到（SQL 文件、表、窗口天数、行数、耗时、返回码）。

#### Scenario: 汇聚点全覆盖

- **WHEN** 脚本发起任意 bq 查询
- **THEN** 查询 MUST 经由 `q()`、`q1d()`、`qc()`、`table_max()`、`perf_day_offset()`、`table_exists()` 汇聚函数之一发出
- **AND** 每个汇聚函数 MUST 在调用后落一条 `query` 事件

#### Scenario: query 事件字段

- **WHEN** 落 `query` 事件
- **THEN** 事件 payload MUST 含 SQL 文件名、目标表、窗口天数、返回行数（或空/0 标记）、耗时、退出码
- **AND** 无数据（空表/0 行）时 MUST 仍落事件并如实标记行数——不落事件就无法区分「没查」与「查了没数据」

#### Scenario: 窗口下界可复现

- **WHEN** 落滚动窗口查询的 `query` 事件
- **THEN** payload MUST 记录该次查询的窗口起点绝对时刻，而非仅记 `{{DAYS}}` 天数
- **AND** 理由：滚动窗口锚在跑批时刻，只记天数则事后无法复现当时的查询区间

### Requirement: table_exists 重试留痕

`table_exists()` 的有界重试 MUST 在事件流中留下每次 attempt 的痕迹，使三种结局互相可区分。

#### Scenario: 三种结局可辨

- **WHEN** `table_exists()` 执行有界重试（3 次、2s/4s 退避）
- **THEN** MUST 落事件记录每次 attempt（`attempt:N`）与最终 verdict
- **AND** 「重试 N 次后成功」「确证不存在」「重试耗尽按存在处理」三者 MUST 在事件流中可区分
- **AND** 理由：第三种是静默降级，事后无从判断当天的「数据未同步」告警是真缺数还是 429 被吞

### Requirement: run 生命周期事件

每次运行 MUST 落明确的开始与结束事件，失败路径同样要有终结事件。

#### Scenario: 成功与失败都有终结

- **WHEN** 脚本正常走完
- **THEN** MUST 落 `run.end{ok:true}`
- **WHEN** 脚本经 `fail()` 中止
- **THEN** MUST 先落 `run.end{ok:false, error}` 再写 health 并退出
- **AND** 没有 `run.end` 的事件流 MUST 被读作「运行被外部中断」（如 SIGTERM），与脚本自身失败区分开

### Requirement: run_id 贯通 health 与报告头

run_id MUST 出现在 health 文件与报告正文头部，使报表可反查其审计事件流。

#### Scenario: health 带 run_id

- **WHEN** 写出 `health-daily.json` / `health.json`（成功或失败路径）
- **THEN** 文件 MUST 含 `run_id` 字段

#### Scenario: 报告头带审计指针

- **WHEN** 生成日报 / 周报正文
- **THEN** 头部 MUST 含一行审计指针，指向 `$STATE/audit/<run_id>.events.jsonl`

### Requirement: 同日重复运行检测

同一天的第二次及以后运行 MUST 在事件流中显式可见，但 MUST NOT 因此中止。

#### Scenario: 记录而不阻断

- **WHEN** `$STATE/audit/` 下已存在同 `$DAY` 前缀的其它 `.events.jsonl`
- **THEN** MUST 落 `duplicate_run` 事件并记录先前 run_id 列表
- **AND** 本次运行 MUST 继续执行——重跑是正当操作，审计只负责让它可见

### Requirement: 审计日志保留期

`$STATE/audit/` MUST 按 mtime 清理，保留至少 60 天，与日志保留期一致。

#### Scenario: 与日志同期清理

- **WHEN** 跑批收尾执行清理
- **THEN** MUST 删除 `$STATE/audit/` 下 mtime 超过 60 天的文件
- **AND** 清理 MUST 挂在投递收尾而非「新建」路径上——稳态下每天都是覆盖，新建路径根本不执行
