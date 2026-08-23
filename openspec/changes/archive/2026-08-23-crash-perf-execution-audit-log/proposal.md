## Why

崩溃 & 性能日/周报管线的每个卡片数字**无法回指到它的来源**：哪个 SQL 文件、哪张表、什么时间窗口、返回多少行、重试过几次。数字对不上时只能靠人重跑一遍 SQL 手工比对，而重跑时的窗口下界已经漂移（所有滚动窗口锚在跑批时刻），复现不了当时的查询。

`table_exists()` 的「重试 3 次后按存在处理」尤其不可见：它是一条**静默的降级路径**，日志里只有最终结果，事后无从判断那天的「数据未同步」告警是真缺数还是 429 被吞了。

> **本 proposal 于 2026-08-20 重写**。原版设计了一整套审计体系（事件流 sidecar + 查询插桩 + 投递幂等台账 + 四项顺带修复），其中约三分之二在后续 change 中已由**更简单的手段**解决——继续照原样描述会误导下一个读者。已解决部分连同其替代方案记录在下方「已被取代的原始范围」，本 change 收窄为**只做查询级审计**。

## What Changes

- **审计事件流 sidecar**：每次 run 落一个 append-only JSONL `$STATE/audit/<run_id>.events.jsonl`，事件字段 `{seq, ts, run_id, type, step, payload}`。写入失败不阻塞主链路（`|| true`）——审计是旁路，不是关键路径。
- **查询级插桩**：`q()` / `q1d()` / `qc()` / `table_max()` / `perf_day_offset()` 各落一条 `query` 事件（sql 文件、目标表、窗口天数、行数、耗时、rc），让每个卡片数字可回溯到具体查询。
- **`table_exists()` 的重试可见**：每次 attempt 各落一条 `query{type:table_exists, attempt:N, rc, verdict}`，把「重试 N 次后成功 / 确证不存在 / 有界重试后按存在处理」三种结局区分开。
- **run_id 贯通**：`health-daily.json` / `health.json` 加 `run_id` 字段，报告头部加一行审计文件指针，让报表（派生投影）与事件流（真相）的关系显式化。
- **保留期**：`$STATE/audit/` 按 mtime 保留 60 天，与日志一致。

## 已被取代的原始范围（不再实施）

| 原范围 | 现状 | 取代方案 |
|---|---|---|
| 投递幂等台账 / `card_sent` 闸门 / 同日补投策略 | cron job 已是 `no_agent=true`，投递由确定性脚本完成，无 agent prompt 可改 | `deliver.sh` 的 `--idempotency-key`（值 = `run_id`）+ 陈旧 manifest 闸门 |
| `metrics-history.jsonl` 同日两行 | 已修 | `crash-daily.sh:1365` 按 `day` 键 upsert |
| L2 基线提升顺序 | 已修 | `crash-weekly.sh:572` 先提升基线（`:653` 才写 manifest） |
| `bin/` 与 `scripts/crash-report/` 双副本同步 | 前提消失 | `scripts/crash-report/` 已删除，单一副本 |
| 步骤级 `step.start`/`step.end` 事件 | 收益不足 | 步骤边界已由 stdout 断点标出，日志保留 60 天；再加一层结构化事件对「数字溯源」这个目标没有增量 |

原范围里的 `duplicate_run` 检测与 `run.end{ok:false}` 保留在本 change 内——它们服务于「这次跑批到底发生了什么」，与查询溯源同源。

## Capabilities

- `crash-perf-query-audit`（新增）：查询级审计事件流，含 `table_exists` 重试可见性与 run_id 贯通。
