# crash-perf-table-exists-retry Specification

## Purpose
崩溃 & 性能日报在探测 BigQuery 数据表是否存在时，可靠地区分「表不存在」与「瞬时查询错误（限流/5xx/网络/超时）」，仅在前者时才回退或跳过，避免瞬时故障被误判为缺表而错误回退到停更数据源。

## Requirements

### Requirement: 表存在性探测区分「不存在」与「瞬时错误」

日报脚本的 `table_exists` 探测 MUST 仅将 BigQuery 明确返回的「Not found / 表不存在」错误判定为表不存在（返回假）；瞬时错误（429 限流、5xx、网络抖动、超时）MUST NOT 被当作「表不存在」。

#### Scenario: 表确实不存在

- **WHEN** `bq show` 返回「Not found / 表不存在」错误
- **THEN** `table_exists` 判定该表不存在（返回假），且不重试

#### Scenario: 瞬时错误不误判为缺表

- **WHEN** `bq show` 因 429 限流 / 5xx / 网络抖动 / 超时而失败（表实际存在）
- **THEN** `table_exists` 不将该失败判定为「表不存在」
- **AND** 版本放量段不因此回退到停更的批量表

### Requirement: 瞬时错误有界重试

`table_exists` 对瞬时错误 MUST 进行有界重试（至少 2 次、带退避间隔）；重试耗尽仍未确证「不存在」时，MUST 视为「存在」（返回真），交由后续查询自行失败并触发既有「数据未同步」告警，而非误判缺失触发错误回退。

#### Scenario: 瞬时限流后重试成功

- **WHEN** 首次 `bq show` 因瞬时限流失败、随后重试成功
- **THEN** `table_exists` 返回「存在」，日报使用目标数据表正常出数

#### Scenario: 持续瞬时错误重试耗尽

- **WHEN** 连续重试仍因瞬时错误失败、且从未收到「Not found」确证
- **THEN** `table_exists` 视为「存在」（返回真）
- **AND** 后续查询失败时由既有「数据未同步」告警兜底，不触发回退到批量表

### Requirement: 回退与跳过仅在表确证缺失时发生

版本放量 / 崩溃 / 性能各段 SHALL 仅当数据源表被确证「不存在」时才执行回退（放量回退批量表）或跳过（输出「表尚未同步」）；因瞬时错误导致的探测失败 MUST NOT 触发回退到停更的批量表。

#### Scenario: REALTIME 表确证缺失才回退

- **WHEN** `firebase_sessions.*_REALTIME` 表被确证「不存在」且批量表存在
- **THEN** 版本放量段回退到批量表并标注「REALTIME 表缺失，回退批量表」

#### Scenario: REALTIME 表瞬时不可达不回退

- **WHEN** `firebase_sessions.*_REALTIME` 表实际存在、但探测时遇瞬时错误
- **THEN** 版本放量段仍使用 REALTIME 表查询，MUST NOT 回退到批量表
