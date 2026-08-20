## Context

崩溃数据现状：L1 日报崩溃段走 `fetch-snapshot.sh` light 模式抓 Firebase MCP `topIssues`，只返回 OPEN issue；被误关的 issue 从统计消失（曾发生 `3fd09886` 事故）。`firebase_crashlytics` BigQuery 表已于近期出表（REALTIME，iOS 2 行 / Android 48 行，非每日批）。`firebase_sessions` 已就绪（版本放量分母）。动机见 proposal.md - Why。

约束：
- 管线只读、无人值守（Mac mini + launchd），改动须保守、可降级
- `firebase_crashlytics` 当前只有 REALTIME 表，行数少（可能仍在回填期）
- 崩溃率此前完全缺分子，口径从未定过

## Goals / Non-Goals

**Goals:**
- L1 崩溃段改从 BigQuery `firebase_crashlytics` 事件级统计，摆脱 issue 开关状态依赖
- 补崩溃率（事件数 / 会话数），标注口径

**Non-Goals:**
- 不改 L2 周报 triage 链路（仍走 claude + firebase-crash-triage）
- 不做 crash-free 精确口径（需 session 级关联，留待后续）
- 不改性能三块、版本放量、NON_FATAL 通路
- 不做 streaming export / 准实时（沿用现有导出粒度）

## Decisions

### D1. 事件级统计按 issue 维度聚合
**选择**：`firebase_crashlytics` 按 `issue_id` 分组 `COUNT(*)` 得每 issue 事件数，按事件数排序取 TOP。
**理由**：表里每条记录是一个 crash 事件（含 `issue_id` / `issue_title` / `event_timestamp`），按 issue 聚合即得「每 issue 崩溃量」，且天然不受 issue 开关状态影响——closed 的 issue 只要有事件仍被计入。
**备选**：直接 `COUNT(*)` 总数（丢 issue 明细，卡片无标题）；按 `event_timestamp` 天粒度（日报只需总量，无必要）。

### D2. 崩溃率口径 = 事件数 / 会话数
**选择**：崩溃率 = `firebase_crashlytics` 事件总数 / `firebase_sessions` 会话总数，卡片标注「事件数/会话数，非 crash-free」。
**理由**：分子分母均已就绪，无需 session 级关联即可算；crash-free（`1 - 崩溃会话数/总会话数`）需 `firebase_crashlytics` 带 `session_id` 且关联 `firebase_sessions`，属精确口径，留待后续。
**备选**：crash-free 精确口径（准确但依赖字段关联，v1 不做）；去重 issue 数/会话数（低估，弃）。

### D3. 数据源用当前 REALTIME 表，不等待每日批表
**选择**：直接查 `firebase_crashlytics` 现有表（REALTIME），数据截止 = 表最新 `event_timestamp`。
**理由**：每日批表未确认存在，REALTIME 已可查；卡片反正要打印真实截止时间戳（spec 要求），滞后多少由时间戳自证，不靠「表类型」假设。
**备选**：等每日批表出齐再迁（无限期阻塞，弃）。

### D4. 渐进切换：BigQuery 为主，MCP 保留对照
**选择**：L1 崩溃段改为 BigQuery 统计，`fetch-snapshot.sh` light 模式的 MCP 抓取降级为「对照/回退」——首验期同跑 MCP 与 BigQuery 两套数值人工核对，确认一致后移除 MCP 抓取。
**理由**：无人值守管线改口径有风险，保留对照可在一轮内发现聚合口径差异（如事件去重、时区）。
**备选**：一次性切掉 MCP（快但无对照，出错难发现）。

## Risks / Trade-offs

- **R1. REALTIME 表行数少（iOS 2 / Android 48），可能仍在回填** → 首验期对照 MCP 数值，偏差大则暂缓切换并标注「事件级数据回填中」
- **R2. 事件级与 MCP OPEN 口径天然不一致**（事件级含 closed issue，数值会更高）→ 这是预期行为，spec 已要求；卡片口径标注同步更新，避免「崩溃变多」误读
- **R3. 崩溃率口径被误读为 crash-free** → 卡片强制标注「事件数/会话数」，spec 已约束
- **R4. `firebase_crashlytics` 表结构字段名需实测确认** → 首步先 `bq ls` + schema 探明，再写 SQL

## Migration Plan

1. 探明 `firebase_crashlytics` 表 schema（字段名、分区/时间戳字段）
2. 新增 `sql/crash-issues.sql`（按 issue 聚合）与 `sql/crash-rate.sql`（分子/分母）
3. 改 `crash-daily.sh` 崩溃段：BigQuery 统计为主，MCP 抓取降级为对照
4. 首验：DRY RUN 跑一遍，人工核对 BigQuery vs MCP 数值
5. 确认一致后，移除 MCP 崩溃抓取，`dino-crash-perf-report` skill 回填「数据源现状」

**回滚**：保留 MCP 抓取分支（D4 对照期），BigQuery 出问题直接切回 MCP 口径即可，无需回滚脚本。

## Open Questions

- `firebase_crashlytics` REALTIME 表是否最终会切换到每日批表（若是，D3 需在批表出齐后复评）
- 崩溃率最终口径是否升级为 crash-free（依赖 `session_id` 字段关联，待表结构确认）
