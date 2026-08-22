-- 天级单日值（日历日锚定）：崩溃事件数 + 受影响安装数，供 DoD/WoW/sparkline 取数。
--
-- 口径与滚动窗口展示值（crash-rate.sql / crash-issues.sql 的 7 天窗）显式分离（D2）：
-- 此处按整日 [D-{{DAYS}}, D-{{DAYS}}+1) 取「单日值」，字段带 _1d 标识，不可与窗口值混比。
-- {{TABLE}}=crashlytics 表；{{DAYS}}=距今天数（1=昨日）。is_fatal=TRUE，与 crash-rate.sql 分子同口径。
--
-- ANR 与 NON_FATAL 的单日值一并取出：同表、同窗口，**不增加任何查询次数**，
-- 只是把过滤从 WHERE 挪进 COUNTIF。
-- ⚠️ `crash_events_1d` / `affected_installs_1d` 的口径**一字未变**：
--    `is_fatal = TRUE` 等价于 `error_type = 'FATAL'`，COUNTIF(is_fatal) 与旧的
--    `COUNT(*) WHERE is_fatal=TRUE` 逐值相同。历史序列不能断，这两列必须保持可比。
SELECT
  COUNTIF(is_fatal)                                                     AS crash_events_1d,
  COUNT(DISTINCT IF(is_fatal, installation_uuid, NULL))                 AS affected_installs_1d,
  COUNTIF(error_type = 'ANR')                                           AS anr_events_1d,
  COUNT(DISTINCT IF(error_type = 'ANR', installation_uuid, NULL))       AS anr_installs_1d,
  COUNTIF(error_type = 'NON_FATAL')                                     AS nonfatal_events_1d,
  -- crash-free 的分子（天级）。同一会话内崩多次只计一次。
  COUNT(DISTINCT IF(is_fatal AND firebase_session_id != '', firebase_session_id, NULL)) AS crash_sessions_1d
FROM `{{TABLE}}`
WHERE application.display_version IN ({{VERSIONS}})
  AND DATE(event_timestamp) = DATE_SUB(CURRENT_DATE(), INTERVAL {{DAYS}} DAY)
