## Why

崩溃&性能日/周报管线跑在 shell 脚本 + Hermes cron agent 上，但整个执行过程**没有审计痕迹**：每个卡片数字无法回指到（SQL 文件、表、时间窗口、行数）；脚本成功但 agent 中途崩（文档建了、卡片没发）会留下重复文档+重复卡片而系统完全不自知；`state/metrics-history.jsonl` 无同日去重，2026-08-17 当天 07:00 与 08:44 两次运行已实测产生两行、DoD 基准口径静默漂移。2026-08-17 的重跑就是活例——系统无法回答「这次重跑有没有把 3 份文档+卡片再投一遍」。

## What Changes

- **执行事件日志 sidecar（T0 可审计）**：每次 run 落一个 append-only JSONL 事件流 `state/audit/<run_id>.events.jsonl`，事件字段 `{seq, ts, run_id, attempt, type, step, payload}`；run_id 进 `health-daily.json` 与 report 头部，报表（派生投影）与事件流（真相）的指针关系显式化。
- **查询级插桩（4 个 bq 汇聚点）**：`q()`（crash-daily.sh:77）、`table_exists()`（:87）、`q1d()`（:197）、`qc()`（:335）各加一条 `query` 事件（sql 文件、表、窗口天数、行数、耗时、rc、attempt），让每个卡片数字可回溯源；`table_exists` 的「重试 N 次后成功 / 确证不存在」从此可查。
- **步骤级 + 生命周期事件**：`run.start`/`step.start`/`step.end`/`run.end`；`fail()` 路径补发 `run.end{ok:false,error}`（dsh 的 end{interrupted} 合成标记语义）；版本放量选表决策（REALTIME vs 批量回退 `SESS_*_FALLBACK`）落 `table_select` 事件；MCP 对照降级/超时落 `fetch` 事件；报告与投递清单落 `report`/`publish` 事件。
- **中间产物 30d 保留**：`crash-daily.sh:951` 的 `rm -rf "$TMP"` 改为按 mtime 清理（对齐 crash-daily-* 目录 30d），中间 CSV/JSON 成为每个数字最直接的审计物证。
- **同日重复 run 检测事件**：同 DAY 内第二次运行显式记 `duplicate_run` 事件，重复运行从此可见。
- **投递幂等台账（T1）**：投递事件并入审计流但**分文件** `state/audit/delivery-*.jsonl`（脚本事件与投递事件分文件避免锁）；L1/L2 cron prompt 增加「查台账 → 建文档 → 立刻记台账」步骤，`card_sent` 作闸门。
- **同日二次运行投递策略（Q1=c）**：仅上次投递未完成（`card_sent=false`）才补投，已完成项复用 URL 跳过；台账损坏默认「未投递」+ 人工看审计流确认（避免静默漏投）。
- **数据步骤全量重跑（Q2）**：崩溃后重跑数据步骤全量重跑（新鲜度优先，不做 skip-if-done）；审计日志对数据步骤的职责是记录（输入/窗口/行数），不是 gating。
- **`metrics-history.jsonl` 按 day upsert**（T1 顺带修）：append+tail-7 改为按 `day` 键 upsert（保留最后一行），根治 0.4 节的同日两行基准漂移。
- **L2 基线提升顺序修复（Q4 顺带修）**：`crash-weekly.sh` 改为先 `cp SNAP_NEW SNAP_LAST` 提升基线、再写 manifest，使 manifest 永远对应已提升基线的 run，根治 2026-08-07 类「下周把旧 issue 全报成新增」事故。
- **审计日志 60d+ 保留（Q3）**：`state/audit/` 按 mtime 清理，保留至少 60 天。
- **明确出界（Q6/T2）**：断点跳过数据步骤、事件压缩（compaction）、跨 run 检索不在本 change 范围。

## Capabilities

### New Capabilities

- `crash-perf-execution-audit-log`: 崩溃&性能日/周报管线的执行审计日志 sidecar 与投递幂等台账契约——append-only 事件流（run/step/query/table_select/fetch/report/publish/delivery.*）、run_id 贯通 health 与 report 头、中间产物 30d 保留、同日重复 run 检测、投递台账分文件、同日补投策略、metrics-history 按 day upsert、L2 基线提升顺序修复、审计日志 60d+ 保留；T2（断点跳过/压缩/跨 run 检索）明确出界

### Modified Capabilities

<!-- 无。本次为新增审计/幂等行为，不修改既有已归档能力（当前 openspec/specs/ 仅 crash-perf-table-exists-retry）。
     `crash-perf-daily-weekly-report`（主链路契约）尚属未归档的进行中 change（in-progress），不在 openspec/specs/ 内，
     无法作为 MODIFIED delta 的基准（openspec 要求 MODIFIED 引用 openspec/specs/<cap> 的既有路径）。
     本次对 metrics-history.jsonl 写入语义（append→按 day upsert）与 L2 manifest/基线顺序的改动是「新增能力驱动的一致性修复」，
     随本 change 的 ADDED capability 一并落地，归档顺序约束与衔接见 Impact 与 design.md Migration Plan。 -->

## Impact

**代码**：

- `bin/crash-daily.sh`：`q()`（:77）、`table_exists()`（:87）、`q1d()`（:197）、`qc()`（:335）四处插桩 `query` 事件；`run.start`/`step.start`/`step.end`/`run.end` 生命周期事件；`fail()`（:68）补发 `run.end{ok:false,error}`；版本放量选表（:277-284）落 `table_select`；MCP 对照（:527-535）落 `fetch`；报告（:537-588）落 `report`；投递清单（:869-907）落 `publish`；`:951` `rm -rf "$TMP"` 改 30d mtime 清理；`:950` health-daily.json 加 `run_id`；`:933-937` metrics-history 改按 day upsert；同日重复 run 检测。
- `bin/crash-weekly.sh`：探活/同步/快照/变化检测/组装/收尾各步骤落步骤事件；`:188`（写 manifest）与 `:193`（`cp SNAP_NEW SNAP_LAST`）顺序对调为「先提升基线再写 manifest」；health.json 加 `run_id`。
- `~/.hermes/cron/jobs.json`：L1（`4b0c7362063b`）/L2（`1190a07e345c`）prompt 增加「查台账 → 建文档 → 立刻记台账」步骤与 `card_sent` 闸门（投递完成才置 true）。

**数据源 / SQL**：零改动。所有 `*.sql` 与 bq 查询口径不动，仅在被调用处加事件记录（不改查询本身）。

**契约**：新增 `openspec/specs/crash-perf-execution-audit-log/spec.md`（归档后）。

**衔接 / 归档顺序**：`metrics-history.jsonl` 写入语义由 append 改为按 day upsert，属对未归档 `crash-perf-daily-weekly-report` 主链路行为的一致性修复；L2 manifest/基线顺序同样落在那条主链路。归档顺序约束：`crash-perf-daily-weekly-report` 须先于本 change 归档；若顺序相反，本 change 归档时其 spec 需在 Purpose 注明「审计能力驱动的 metrics-history upsert 与 L2 基线顺序修复」做一致性对账（见 design.md Migration Plan）。

**风险**：投递台账由 cron agent（LLM）写，可能漏写/写错，读取方必须容错（默认「未投递」）；`docx_builtin_import` 只建不更、飞书端无法枚举本 bot 文档，故「建文档后、写台账前」崩溃会产生一份孤儿文档（窗口压到单个调用宽度，无法归零，Q5 已拍板接受）；多写者（L1/L2/手动重跑）通过分文件避免锁竞争。
