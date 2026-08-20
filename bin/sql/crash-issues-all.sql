-- L2 数据层：崩溃 issue 全版本聚合（事件级）。
--
-- 与 crash-issues.sql（L1 日报用）的唯一差别是**刻意不加版本过滤**，理由同
-- sessions-by-version.sql：台账按 issue 跨版本追踪一条崩溃的生命周期，
-- 加版本过滤会让「上一版修好、这版没复发」的 issue 凭空消失，时间线断档。
-- 这也与它替代的 MCP topIssues 口径一致（topIssues 无版本过滤能力）。
--
-- users = 受影响安装数（installation_uuid 去重），不等于 session 数，
-- 也不等于 user.id（Android 不上报 user.id）。
--
-- 取 {{LIMIT}} 条：与 topIssues 一样只关心头部，长尾进台账只会稀释信噪比。
SELECT
  issue_id                                                       AS id,
  issue_title                                                    AS title,
  COUNT(*)                                                       AS events,
  COUNT(DISTINCT installation_uuid)                              AS users,
  FORMAT_TIMESTAMP('%Y-%m-%d %H:%M UTC', MAX(event_timestamp))   AS latest
FROM `{{TABLE}}`
WHERE is_fatal = TRUE
  AND event_timestamp >= TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL {{DAYS}} DAY)
GROUP BY issue_id, issue_title
ORDER BY events DESC
LIMIT {{LIMIT}}
