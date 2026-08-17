## Context

L1 日报脚本 `scripts/crash-report/crash-daily.sh`（418 行）当前各数据段的行为（2026-08-15 实测）：

- **性能段** `perf_section`：`table_exists` 通过后直接查 SQL，窗口 `DAYS`（默认 1）；窗口内 0 行时 `awk` 输出空表头（无数据行），**不提示未同步**。
- **版本放量段** `adoption_section`：查 `firebase_sessions` **批量表**（非 REALTIME），窗口 `DAYS`；同样空表静默。
- **数据截止** `DATA_UNTIL`：单一变量，只查 `firebase_performance.IOS` 的 MAX，覆盖不了 sessions / crashlytics 各自截止。

实测数据源状态（2026-08-15 09:14 +0800）：

| 表 | 最新 event_timestamp | 状态 |
|---|---|---|
| `firebase_sessions.*`（批量） | 08-11 06:50/06:58 UTC | ❌ 停更 4 天，08-12 起 0 行 |
| `firebase_sessions.*_REALTIME` | 08-15 01:15 UTC | ✅ 正常，schema 与批量表一致 |
| `firebase_performance.*` | 08-14 06:59 UTC（07:00 跑时仅 08-12） | ⚠️ 每日批量同步，滞后约 2 天 |
| `firebase_crashlytics.*_REALTIME` | 08-14 16:xx UTC | ✅ 正常 |

关键结论：sessions 批量表停更是 Firebase→BigQuery 每日批量导出链路故障（REALTIME 流式导出正常）；performance 表是结构性滞后（每日批量导出，非实时）。脚本侧能做的兜底是：切 REALTIME 活表 + 陈旧告警 + 窗口放宽。

## Goals / Non-Goals

**Goals:**

- 放量段立即恢复数据（切 REALTIME 表）。
- 任何段「窗口内 0 行」时显式告警而非空表。
- 各段截止时间戳各自如实标注。

**Non-Goals:**

- 不修复 Firebase→BigQuery 导出链路（那是数据源侧，需人工在 Firebase 控制台排查，脚本只能兜底）。
- 不改 L2 周报、崩溃数据源、NON_FATAL 通路、飞书投递。
- 不做「固定 ID 覆盖」索引页/台账（既有待办，与本 change 无关）。

## Decisions

**D1 — 放量段切 REALTIME 表，回退批量表。**
`sessions-by-version.sql` 的源表由 `{{TABLE}}` 参数化（现状已参数化），脚本把 `SESS_IOS`/`SESS_AND` 指向 `*_REALTIME` 表；若 REALTIME 表不存在则回退批量表并标注。
- 理由：REALTIME 表数据到 08-15 01:15（活表），schema 与批量表完全一致，切换零 SQL 改动；批量表停更是数据源故障，等人工修复期间放量段不可持续空表。
- 备选：等 Firebase 批量导出修复——不可控，不可接受。

**D2 — 陈旧检测放各 section 内，判定「窗口内 0 行」。**
每个 section（perf/adoption/crash）在查询后检查结果是否空：空则改输出「⚠️ 数据未同步，最新截至 XX」。
- 理由：`table_exists` 只能判「表在不在」，判不了「表在但数据停更」；真正要防的是后者。
- 「最新截至 XX」取该表 `MAX(event_timestamp)`，一次轻量查询即可。
- 备选：全局统一判定——但各表停更/滞后程度不同，全局一刀切会误报。

**D3 — 性能窗口 `DAYS=1` → `DAYS=3`，独立变量 `PERF_DAYS`。**
- 理由：firebase_performance 每日批量同步滞后约 2 天，`DAYS=1` 在每天 07:00 跑时必然空表。3 天窗口覆盖滞后且保留「日报近况」语义。
- 备选：动态按「表最新时间戳」反推窗口——过度设计，固定 3 天足够，且 D2 的陈旧告警兜底「窗口内仍无数据」的极端情况。

**D4 — 分表截止时间戳。**
新增 `PERF_UNTIL` / `ADOPTION_UNTIL`，与既有 `DATA_UNTIL`（性能）和 `CRASH_UNTIL`（崩溃）分离；放量段独立取 sessions 表 MAX。
- 理由：三张表同步节奏不同（性能滞后 2 天、sessions REALTIME 实时、crashlytics REALTIME 实时），单一截止时间戳会误导。
- 实际落地：`DATA_UNTIL` 沿用性能表 MAX（语义不变），新增 `ADOPTION_UNTIL` 查 sessions 表 MAX，崩溃沿用 `CRASH_UNTIL`。

## Risks / Trade-offs

- **[REALTIME 表数据可能不如批量表完整/稳定]** → REALTIME 是流式导出，可能有轻微延迟或重传，但对「版本放量（会话/设备计数）」足够；且批量表已停更，REALTIME 是唯一活源。
- **[窗口 3 天使「日报」语义变宽]** → 报告头部已注明「窗口：性能近 3 天」，且卡片各指标仍是最新窗口内聚合，可接受。
- **[告警噪音]** → 仅当「表存在但窗口内 0 行」才告警（真停更），正常同步时不触发；不会常态化刷屏。
- **[REALTIME 表 schema 未来变化]** → 与批量表同 schema 现状已核实；若未来漂移，`sessions-by-version.sql` 只取 `application.display_version` / `session_id` / `instance_id` / `event_timestamp` 四字段，稳定。

## Migration Plan

1. 改 `crash-daily.sh`（放量切 REALTIME + 陈旧告警 + `PERF_DAYS=3` + 分表截止）与 `sessions-by-version.sql`（确认参数化，无需改）。
2. DRY RUN 跑 L1，核对：放量表有数据、截止时间戳各段正确、窗口 3 天。
3. 私聊验证 → 换群。
4. 回填 `dino-crash-perf-report` skill 的「已知坑」表（新增「sessions 批量表停更 / REALTIME 表是活源」一条）。
5. 回滚：`git` 还原脚本即可（只读 clone 约束不涉及业务仓库）。

## Open Questions

- 无。
