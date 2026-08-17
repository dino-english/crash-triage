## Why

`crash-daily.sh` 的 `table_exists()` 用 `bq show --format=none "${1/./:}" >/dev/null 2>&1` 探测数据表是否存在，把所有错误（包括 429 限流 / 5xx / 网络抖动 / 超时）都吞掉并一律返回「不存在」。2026-08-15 实测暴露：09:31–09:45 连续密集跑脚本时撞上 BigQuery 瞬时限流，`bq show` 瞬时失败被误判成「REALTIME 表不存在」，版本放量段于是错误回退到停更的批量表，日报重新出现「放量 0 会话 · 最新截至 08-11」的空表假象（10:03 重跑又恢复正常，印证是瞬时而非真的缺表）。

后果是：`crash-perf-data-staleness-guard` 刚修掉的「空表假象」，会在 bq 瞬时故障时随机复现，且无法区分「真没数据」与「数据没同步」。

## What Changes

- `table_exists()` 改为可靠探测：仅将 bq 明确返回的「Not found / 表不存在」判定为不存在；瞬时错误（429/5xx/网络/超时）不再当作「不存在」。
- 对瞬时错误做有界重试（多次、带退避）；重试耗尽仍未确证「不存在」时，视为「存在」（返回 true），让后续查询自行失败并触发既有「数据未同步」告警，而非误判缺失触发错误回退。
- 保持既有回退/跳过语义不变：仅当数据表**确证不存在**时才回退批量表 / 输出「表尚未同步」。

## Capabilities

### New Capabilities

- `crash-perf-table-exists-retry`: 崩溃 & 性能日报的表存在性探测可靠性——`table_exists` 区分「表不存在」与「瞬时查询错误」，对瞬时错误有界重试，确保回退/跳过仅发生在表确证缺失时。

### Modified Capabilities

<!-- 无：本 change 新增「表存在性探测可靠性」契约；既有 crash-perf-data-staleness-guard 的「REALTIME 表缺失时回退」语义不变（本 change 只是界定「缺失」=确证不存在，而非瞬时不可达）。 -->

## Impact

- **代码**：`bin/crash-daily.sh` 的 `table_exists()`（同步到 `scripts/crash-report/crash-daily.sh`，两份保持一致）。
- **数据**：无数据源变更；仍是 REALTIME 活表 + 批量表回退，只是回退触发条件收紧为「确证不存在」。
- **运行**：L1 日报在 bq 瞬时限流/抖动时不再误回退到停更批量表，放量段保持 REALTIME 活表出数。
- **不涉及**：L2 周报链路（crash-weekly.sh 无 `table_exists`）、SQL 文件、飞书投递、崩溃数据源。
