-- 崩溃 issue 聚合（事件级）：firebase_crashlytics 表按 issue 分组统计致命崩溃事件数。
--
-- 与旧 MCP topIssues 的口径差异（见 openspec change crash-source-bigquery-migration）：
--   1. 事件级不受 issue 开关状态影响——closed 的 issue 只要有事件仍被计入（这正是迁移的动机）；
--   2. **只统计致命崩溃**。`is_fatal = TRUE` 等价于 `error_type = 'FATAL'`。
--      ⚠️ 原注释写的理由是「与 topIssues 的 FATAL 过滤一致」——**那个理由已失效**：
--      topIssues 早已不是数据源。现在的理由是口径独立：本文件刻意只要 FATAL，
--      ANR 与 NON_FATAL 由 crash-error-types.sql / crash-nonfatal-issues.sql 覆盖
--      （两者的 is_fatal 均为 FALSE，沿用此过滤会让它们整体不可见）。
--      崩溃次数 / 崩溃率 / 受影响安装三项的历史序列按 FATAL 口径积累，不得混入其它类型；
--   3. 窗口由 {{DAYS}} 控制（日报 7，与 topIssues 默认 7 天窗一致）。
--
-- **按受影响安装数排序，不按事件数**（change crash-impact-summary D3）：
-- 事件数相同的两个 issue 影响面可能差一个数量级。实测 `Google Pixel 8 Pro` 一台设备贡献 9 次崩溃，
-- 按事件数排能挤到第二位，实际只影响一个人；而 `OPPO CPH2591` 的 14 次影响 7 台设备。
-- 排在第一位的 issue 会被当成最该修的——排序口径直接改变读者行为，不是显示细节。
-- 事件数列保留：读者需要自己判断的空间，尤其在影响人数相同时。
SELECT
  issue_id                                                       AS issue_id,
  issue_title                                                    AS title,
  COUNT(*)                                                       AS n,
  COUNT(DISTINCT installation_uuid)                              AS users,
  FORMAT_TIMESTAMP('%Y-%m-%d %H:%M UTC', MAX(event_timestamp))   AS latest
FROM `{{TABLE}}`
WHERE is_fatal = TRUE
  AND application.display_version IN ({{VERSIONS}})
  AND event_timestamp >= TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL {{DAYS}} DAY)
GROUP BY issue_id, issue_title
-- ⚠️ **必须有确定性 tie-breaker**：并列时 BigQuery 不保证行序。
-- 实测两次跑批之间，events 与 users 都相同的两个 issue 位置互换了——
-- 报告里 issue 顺序无故跳动，读者会以为「排名变了」；等价性 diff 也会被这种伪差异污染。
ORDER BY users DESC, n DESC, issue_id
LIMIT 20
