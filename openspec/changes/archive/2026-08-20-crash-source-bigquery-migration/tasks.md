## 1. 探明数据源

- [x] 1.1 探明 `firebase_crashlytics` 表 schema：字段名（issue_id / issue_title / event_timestamp 等）、分区/时间戳字段、双端表名
- [x] 1.2 确认双端表数据现状（iOS/Android 行数、事件时间范围），判断是否仍在回填期

## 2. SQL

- [x] 2.1 写 `sql/crash-issues.sql`：按 issue 聚合（issue_id / title / COUNT(*) / 最新 event_timestamp），双端各取
- [x] 2.2 写 `sql/crash-rate.sql`：分子 `firebase_crashlytics` 事件总数 / 分母 `firebase_sessions` 会话总数

## 3. 改脚本

- [x] 3.1 改 `crash-daily.sh` 崩溃段：用 BigQuery 统计（2.1/2.2）替换 MCP `topIssues` 数据源
- [x] 3.2 卡片口径标注：从「MCP 只返回 OPEN」改为「事件级统计 + 崩溃率口径（事件数/会话数）」
- [x] 3.3 崩溃数据截止时间改用 `firebase_crashlytics` 最新 `event_timestamp`
- [x] 3.4 `fetch-snapshot.sh` light 模式 MCP 崩溃抓取降级为对照/回退分支（保留，首验期对照用）

## 4. 首验与切换

- [x] 4.1 DRY RUN 跑 L1，人工核对 BigQuery vs MCP 崩溃数值，确认口径差异符合预期（事件级含 closed issue 故偏高）
  - 首验结果：BigQuery 事件级 **低于** MCP OPEN（iOS 2 vs 3、Android 25 vs 89），差异方向与「含 closed 偏高」相反——`firebase_crashlytics` REALTIME 表仍在回填（见 design R1）。已按 R1 标注「回填中」，待人工确认。
- [x] 4.2 确认一致后移除 MCP 崩溃抓取分支 — 2026-08-20 结项：**决定不移除**，理由已写入 CLAUDE.md「数据口径」段。崩溃**主源**已迁到 BigQuery 事件级（含已关闭 issue），但 `fetch-snapshot.sh` light 模式的 MCP 抓取仍有三个不可替代的用途：① 首验期数值对照；② 索引页「跟踪中的 issue」（BigQuery 是事件级，拿不到 OPEN/CLOSED 状态）；③ `fix_commit` 反查。移除它会丢掉这三项能力而非简化代码。原任务假设「迁移完成即可删旧路径」，实测证伪——两条路径职责不同，不是新旧关系
- [x] 4.3 回填 `dino-crash-perf-report` skill 的「数据源现状」描述（MCP → BigQuery 事件级 + 崩溃率）
