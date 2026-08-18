-- 天级单日值（日历日锚定）：崩溃事件数 + 受影响安装数，供 DoD/WoW/sparkline 取数。
--
-- 口径与滚动窗口展示值（crash-rate.sql / crash-issues.sql 的 7 天窗）显式分离（D2）：
-- 此处按整日 [D-{{DAYS}}, D-{{DAYS}}+1) 取「单日值」，字段带 _1d 标识，不可与窗口值混比。
-- {{TABLE}}=crashlytics 表；{{DAYS}}=距今天数（1=昨日）。is_fatal=TRUE，与 crash-rate.sql 分子同口径。
SELECT
  COUNT(*)                                   AS crash_events_1d,
  COUNT(DISTINCT installation_uuid)          AS affected_installs_1d
FROM `{{TABLE}}`
WHERE is_fatal = TRUE
  AND application.display_version IN ({{VERSIONS}})
  AND DATE(event_timestamp) = DATE_SUB(CURRENT_DATE(), INTERVAL {{DAYS}} DAY)
