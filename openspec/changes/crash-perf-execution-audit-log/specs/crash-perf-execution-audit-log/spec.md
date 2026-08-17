## Purpose

定义 Dino 崩溃&性能日/周报管线的执行审计日志 sidecar 与投递幂等台账契约：以 append-only 事件流（`state/audit/<run_id>.events.jsonl`）记录每次运行的全部关键动作与决策，run_id 贯通 health 与报告头，投递事件并入审计流但分文件、以 `card_sent` 闸门实现同日补投幂等，顺带修复 metrics-history 同日基准漂移与 L2 基线提升顺序，使管线可审计、崩溃可续跑、重复投递可自检。

## ADDED Requirements

### Requirement: 执行事件日志 sidecar

每次运行 SHALL 产生一个 append-only 事件日志文件 `state/audit/<run_id>.events.jsonl`，同一 run 内全部事件共享该 run_id（取脚本时间戳 TS，形如 `YYYYMMDD-HHMMSS`），事件字段最小集为 `{seq, ts, run_id, attempt, type, step, payload}`。

#### Scenario: 每次运行产生独立事件文件

- **WHEN** 脚本（crash-daily.sh / crash-weekly.sh）开始运行
- **THEN** MUST 在 `state/audit/` 下创建一个以本次 run_id 命名的 JSONL 文件（`<run_id>.events.jsonl`）
- **AND** 同一 run 内所有事件 MUST 追加进该文件，不得跨 run 混写

#### Scenario: 事件 append-only 且每行一条完整 JSON

- **WHEN** 记录任意一条事件
- **THEN** 事件 MUST 以单行完整 JSON 追加（`>>` 原子追加），MUST NOT 跨行、MUST NOT 原地改写已写行
- **AND** 每行 MUST 至少含 `type` 与 `run_id` 字段，可被 `jq -c` 逐行解析

#### Scenario: 失败运行也留下事件流

- **WHEN** 脚本因任意原因提前退出（fail / 崩溃 / 超时）
- **THEN** 已写事件 MUST 保留在 `state/audit/<run_id>.events.jsonl` 中
- **AND** MUST NOT 因退出而删除或截断该事件文件

### Requirement: 查询级事件插桩

所有 bq 查询 MUST 经过插桩的汇聚点并落 `query` 事件，使每个卡片数字可回指到（SQL 文件、表、窗口天数、行数、耗时、返回码）。

#### Scenario: 四汇聚点全覆盖

- **WHEN** 脚本发起任意 bq 查询
- **THEN** 查询 MUST 经由 `q()`、`q1d()`、`qc()`、`table_exists()` 四个汇聚函数之一发出
- **AND** 每个汇聚函数 MUST 在调用后落一条 `query` 事件

#### Scenario: query 事件字段

- **WHEN** 落 `query` 事件
- **THEN** 事件 payload MUST 含 SQL 文件名、目标表、窗口天数、返回行数（或空/0 标记）、耗时、退出码
- **AND** 无数据（空表/0 行）时 MUST 仍落事件并如实标记行数（不落事件=无法区分「没查」与「查了没数据」）

#### Scenario: table_exists 重试留痕

- **WHEN** `table_exists()` 执行有界重试（3 次、2s/4s 退避）
- **THEN** MUST 落事件记录每次 attempt（attempt:N）与最终 verdict（存在/确证不存在/重试耗尽按存在处理）
- **AND** 「重试 2 次后成功」与「确证不存在」两者 MUST 在事件流中可区分

### Requirement: 步骤级与 run 生命周期事件

脚本 SHALL 记录 `run.start`、`step.start`、`step.end`、`run.end` 生命周期事件，并在失败路径补发带错误信息的 `run.end`。

#### Scenario: 生命周期事件序列

- **WHEN** 脚本运行
- **THEN** 起始 MUST 落 `run.start`（含 run_id/DAY/attempt/脚本版本）
- **AND** 每个步骤（对应脚本 `echo` 断点）MUST 落 `step.start` 与 `step.end`（含 step 名、耗时、返回码）

#### Scenario: 成功结束

- **WHEN** 脚本正常完成
- **THEN** MUST 落 `run.end` 且 `payload.ok = true`

#### Scenario: 失败路径补发 end

- **WHEN** 脚本经 `fail()` 提前退出
- **THEN** MUST 在退出前落 `run.end` 且 `payload.ok = false`、含错误信息（等价 dsh 的 end{interrupted} 合成标记）
- **AND** 该事件 MUST 与 health 文件中的 `{ok:false, error}` 一致

### Requirement: 决策与降级事件

版本放量选表决策与 MCP 对照降级 SHALL 各落结构化事件，使「为什么用了某个表/为什么降级」可查。

#### Scenario: 版本放量选表决策

- **WHEN** 脚本选择 sessions 数据源（REALTIME 活表 vs 批量回退表）
- **THEN** MUST 落 `table_select` 事件，记录平台、选中表、是否回退（`SESS_*_FALLBACK`）
- **AND** 回退发生时 MUST 明确标注「REALTIME 缺失，回退批量表」的决策原因

#### Scenario: MCP 对照降级/超时

- **WHEN** MCP 对照（fetch-snapshot.sh）成功、降级或超时
- **THEN** MUST 落 `fetch` 事件记录结果态（success/degraded/timeout）
- **AND** 降级/超时时 MUST 记录降级原因（而非仅 echo 一行警告）

### Requirement: 产出事件

报告与投递清单的产出 SHALL 落 `report` 与 `publish` 事件，使「本次 run 产出了什么、要投什么」可查。

#### Scenario: report 事件

- **WHEN** 组装完成日报/周报 markdown
- **THEN** MUST 落 `report` 事件，含报告路径与字节数

#### Scenario: publish 事件

- **WHEN** 产出投递清单 manifest.json
- **THEN** MUST 落 `publish` 事件，含 manifest 路径与投递项清单（日报/台账镜像/索引页/卡片等）

### Requirement: run_id 贯通 health 与报告头

本次运行的 run_id SHALL 写入 `health-daily.json`（日报）与 `health.json`（周报），并写入报告首部作为审计指针。

#### Scenario: health 文件带 run_id

- **WHEN** 脚本写 health 文件
- **THEN** `health-daily.json`（及周报 `health.json`）MUST 在既有字段（last_run/ok/data_until/changes）之外新增 `run_id` 字段
- **AND** 成功与失败两种路径（`:950` 与 `fail()`）写出的 health MUST 都含 `run_id`

#### Scenario: 报告头带审计指针

- **WHEN** 生成 `reports/<DAY>-daily.md`（及周报 `reports/<DAY>-weekly.md`）
- **THEN** 报告首部 MUST 含 `> 本次运行：<run_id> · 审计：state/audit/<run_id>.events.jsonl` 一行
- **AND** 该行随报告被飞书文档逐字引用，使文档自带审计指针

### Requirement: 中间产物保留

脚本 MUST NOT 在收尾时整目录删除中间查询产物，改为按 mtime 保留 30 天。

#### Scenario: $TMP 改 30d 清理

- **WHEN** 脚本收尾
- **THEN** MUST NOT 执行 `rm -rf "$TMP"` 整目录删除
- **AND** MUST 改为按 mtime 清理（`-mtime +30`），与现有 `crash-daily-*` 目录 30d 保留对齐

#### Scenario: 中间产物可审计

- **WHEN** 需要审计某个卡片数字的原始来源
- **THEN** 中间 CSV/JSON（start-*.csv、crash-*.json、rate-*.json 等）MUST 在 30 天内可从 `$TMP` 目录查到

### Requirement: 同日重复运行检测

同 DAY 内第二次运行 SHALL 显式落重复运行事件，使重复运行可被察觉。

#### Scenario: 同日二次运行落事件

- **WHEN** 同一 DAY 内脚本被第二次运行（手动重跑 / 崩溃后重跑）
- **THEN** MUST 落一条 `duplicate_run` 事件，记录当前 run_id、当日已存在的先前 run_id 与 DAY
- **AND** MUST NOT 因检测到重复而中止本次运行（仅记录）

### Requirement: 审计日志保留期

`state/audit/` 下的审计日志 SHALL 保留至少 60 天。

#### Scenario: 60 天保留

- **WHEN** 清理 `state/audit/` 目录
- **THEN** MUST 仅删除 mtime 超过 60 天的文件（`-mtime +60`）
- **AND** 60 天内的审计事件 MUST NOT 被删除

### Requirement: 投递台账分文件

投递事件 SHALL 并入审计流但写入独立文件 `state/audit/delivery-*.jsonl`，与脚本事件文件分离以避免多写者锁竞争。

#### Scenario: 投递事件分文件

- **WHEN** cron agent（L1/L2）记录投递动作
- **THEN** 投递事件 MUST 写入 `state/audit/delivery-*.jsonl`（非脚本的 `<run_id>.events.jsonl`）
- **AND** 脚本事件与投递事件 MUST NOT 混写同一文件

#### Scenario: 每个 lark-mcp 调用后立刻记台账

- **WHEN** 每次 lark-mcp 调用（docx_builtin_import / im_v1_message_create）返回后
- **THEN** MUST 立刻追加对应投递事件（如 `delivery.doc_created {label,url}`、`delivery.card_sent`），将「已建/未建」边界压缩到单次调用宽度内

### Requirement: 投递幂等与同日补投策略

投递 SHALL 在发起前查台账，已完成项复用 URL 跳过；同一 DAY 内二次运行仅在上次投递未完成（`card_sent=false`）时才补投。

#### Scenario: 查台账复用已完成项

- **WHEN** cron agent 准备建文档或发卡片
- **THEN** MUST 先查该 DAY 的投递台账
- **AND** 已存在且完整的投递项（`{DAY, daily_url, ledger_url, index_url, card_sent}`）MUST 复用既有 URL、跳过重复创建/发送

#### Scenario: 同日二次运行仅补投未完成项

- **WHEN** 同一 DAY 内第二次运行且上次投递未完成（`card_sent=false`）
- **THEN** MUST 补投未完成项（缺文档建文档、缺卡片发卡片），MUST NOT 重建已存在项
- **AND** 当上次投递已完成（`card_sent=true`）时，MUST 跳过全部投递，仅更新报告/索引渲染

#### Scenario: card_sent 为投递完成闸门

- **WHEN** 判定某 DAY 的投递是否完成
- **THEN** 仅当台账存在且 `card_sent=true` 才视为「已完成」
- **AND** `card_sent` 缺失或为 false MUST 视为「未完成」，触发补投路径

### Requirement: 台账损坏默认未投递

投递台账损坏或无法解析时，读取方 SHALL 按「未投递」处理并保留人工可见的审计记录。

#### Scenario: 台账损坏按未投递处理

- **WHEN** 投递台账无法解析或字段缺失
- **THEN** MUST 按「未投递」处理（允许重建/重发，而非静默跳过）
- **AND** MUST 在审计流中落一条可见记录，标注台账损坏、按未投递处理，供人工核对

### Requirement: metrics-history 按 day upsert

`state/metrics-history.jsonl` 的写入 SHALL 从「append + tail-7」改为按 `day` 键 upsert，同一 day 只保留最后写入的一行。

#### Scenario: 同日不产生两行

- **WHEN** 脚本持久化天级单日值到 metrics-history.jsonl
- **THEN** 同一 `day` MUST 只存在一行（后写覆盖先写）
- **AND** MUST 保持最近 7 天滚动窗口语义不变（仅对已存在的 day 做覆盖，不新增重复行）

#### Scenario: 基准口径一致

- **WHEN** 次日计算 DoD 基准时读取 `hist_val(.day == D)`
- **THEN** 每个 day MUST 至多返回一行，使 DoD/WoW 基准与 last-writer-wins 快照口径一致

### Requirement: L2 基线提升顺序修复

周报脚本 SHALL 先提升基线（`cp SNAP_NEW SNAP_LAST`）再写 manifest，使 manifest 永远对应已提升基线的 run。

#### Scenario: 先提升基线再写 manifest

- **WHEN** 周报脚本收尾
- **THEN** MUST 先执行 `cp "$SNAP_NEW" "$SNAP_LAST"` 提升基线
- **AND** MUST 在基线提升之后再写 `state/publish/manifest.json`
- **AND** MUST 落 `baseline_promoted` 事件记录基线已提升

#### Scenario: manifest 对应已提升基线的 run

- **WHEN** 下游消费 manifest.json
- **THEN** manifest MUST 对应一个已完成基线提升的 run
- **AND** 「写 manifest 后、提升基线前」崩溃 MUST 不再导致下周把旧 issue 全报成新增（2026-08-07 类事故不再发生）
