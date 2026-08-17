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
- [ ] 4.2 确认一致后移除 MCP 崩溃抓取分支（**待人工确认**：REALTIME 表回填完成前不执行）
- [x] 4.3 回填 `dino-crash-perf-report` skill 的「数据源现状」描述（MCP → BigQuery 事件级 + 崩溃率）
