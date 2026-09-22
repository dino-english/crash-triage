-- L2 数据层：ANR issue 级聚合（台账跟踪用，change crash-ledger-anr-tracking）。
--
-- 与 `crash-issues-all.sql` 的唯一差别是过滤条件：那份是 `is_fatal = TRUE`，这份是
-- `error_type = 'ANR'`。⛔ **不把两者合成一份带 error_type 占位符的模板**：
-- ⚠️ 这句话本身踩过一次坑——原文在这里写了那个占位符的字面量（双花括号形式），
-- 而 q_render 的未替换占位符检查**不区分注释与代码**，当场判「调用方漏传」，
-- 取数返回空、jq 拿到空串、L2 数据层整个失败。⛔ SQL 注释里不许出现双花括号字面量。
-- `crash-issues-all.sql` 的 `is_fatal = TRUE` 被崩溃口径依赖（事件计数 / 崩溃率 / 受影响安装
-- 都按它积累了 90 天历史），给它加参数等于给一条稳定口径开一个可被误传的口子。
-- 复制 30 行比这个风险便宜——同 `crash-issues.sql` 与 `crash-issues-all.sql` 的既有取舍。
--
-- ⚠️ **ANR 仅 Android**：iOS 系统层无此概念，数据源不产出该 error_type，本查询在 iOS 表上
-- 自然返回 0 行。⛔ 不在 SQL 里按平台分叉（同 `crash-rate.sql` 的 affected_users，Android 恒 0）。
--
-- ⛔ **不加版本过滤**：台账按 issue 跨版本追踪生命周期，加过滤会让「上一版修好、这版没复发」
-- 的 issue 从现状表凭空消失、时间线断档（同 `crash-issues-all.sql`）。
--
-- ⛔ **入选阈值不在这里**：本查询返回全量（末尾那个 LIMIT 只是安全上界），
-- 「受影响安装 ≥ 阈值」的过滤与「未入选有几条」的计数都在渲染层做。
-- 在 SQL 里 HAVING 会把未入选数量一并丢掉，而台账的既有纪律是**未呈现的数量必须标注**。
-- ⚠️ 返回行数等于该上界时视为可能被截断，注解须改成「至少 N 条」。
--
-- users = 受影响安装数（installation_uuid 去重）。⚠️ 跨版本不可相加，故版本维度只给事件数 n。
WITH base AS (
  SELECT issue_id, issue_title, installation_uuid, event_timestamp,
         COALESCE(application.display_version, '(未知)') AS version
  FROM `{{TABLE}}`
  WHERE error_type = 'ANR'
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
-- ⚠️ **必须有确定性 tie-breaker**：今天 34 条里 32 条 users 完全并列，
-- 没有 issue_id 兜底时两次跑批的行序会互换（同 crash-issues.sql 同处注释）。
ORDER BY i.users DESC, i.events DESC, i.issue_id
LIMIT {{LIMIT}}
