-- 崩溃 issue 聚合（事件级）：firebase_crashlytics 表按 issue 分组统计致命崩溃事件数。
--
-- 与旧 MCP topIssues 的口径差异（见 openspec change crash-source-bigquery-migration）：
--   1. 事件级不受 issue 开关状态影响——closed 的 issue 只要有事件仍被计入（这正是迁移的动机）；
--   2. 只统计 is_fatal=TRUE，与 topIssues 的 FATAL 过滤一致，NON_FATAL 不在此列；
--   3. 窗口由 {{DAYS}} 控制（日报 7，与 topIssues 默认 7 天窗一致）。
SELECT
  issue_id                                                       AS issue_id,
  issue_title                                                    AS title,
  COUNT(*)                                                       AS n,
  FORMAT_TIMESTAMP('%Y-%m-%d %H:%M UTC', MAX(event_timestamp))   AS latest
FROM `{{TABLE}}`
WHERE is_fatal = TRUE
  AND event_timestamp >= TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL {{DAYS}} DAY)
GROUP BY issue_id, issue_title
ORDER BY n DESC
LIMIT 20
