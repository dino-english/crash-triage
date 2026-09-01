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
--
-- **只统计致命崩溃**：`is_fatal = TRUE` 等价于 `error_type = 'FATAL'`。ANR 与 NON_FATAL 的
-- is_fatal 均为 FALSE，由 crash-error-types.sql / crash-nonfatal-issues.sql 覆盖。
-- 台账的 FATAL 现状表源自本文件；NON_FATAL 现状表源自 crash-nonfatal-issues.sql，两表分列。
-- **版本构成**（change crash-report-issue-identity）：events 是跨版本合计，只给合计会让
-- 「新版占了多少」不可见——实测 2026-08-31 段一打印「暴涨 13 事件」，实为 1.5.4 的 8 加 1.5.6 的 5，
-- 而 1.5.6 当天承载 93% 会话。⛔ 不把结构塞进带分隔符的字符串再切（`iPad7,11` 那类坑的同源）：
-- 本查询走 `bqq json`，直接用嵌套数组表达。⚠️ users 是去重安装数，**跨版本不可相加**，
-- 故版本维度只给事件数 n，不给 users。
WITH base AS (
  SELECT issue_id, issue_title, installation_uuid, event_timestamp,
         COALESCE(application.display_version, '(未知)') AS version
  FROM `{{TABLE}}`
  WHERE is_fatal = TRUE
    AND event_timestamp >= TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL {{DAYS}} DAY)
),
per_issue AS (
  SELECT issue_id, issue_title,
         COUNT(*)                                                     AS events,
         COUNT(DISTINCT installation_uuid)                            AS users,
         FORMAT_TIMESTAMP('%Y-%m-%d %H:%M UTC', MAX(event_timestamp)) AS latest
  FROM base GROUP BY issue_id, issue_title
),
per_version AS (
  SELECT issue_id, issue_title,
         ARRAY_AGG(STRUCT(version, n) ORDER BY n DESC, version) AS versions
  FROM (SELECT issue_id, issue_title, version, COUNT(*) AS n
        FROM base GROUP BY issue_id, issue_title, version)
  GROUP BY issue_id, issue_title
)
SELECT
  i.issue_id    AS id,
  i.issue_title AS title,
  i.events      AS events,
  i.users       AS users,
  i.latest      AS latest,
  v.versions    AS versions
FROM per_issue i
LEFT JOIN per_version v USING (issue_id, issue_title)
  -- 并列时补确定性 tie-breaker，否则两次跑批行序会互换（见 crash-issues.sql 同处注释）
ORDER BY i.events DESC, i.issue_id
LIMIT {{LIMIT}}
