-- 天级单日值（日历日锚定）：平台会话数（非版本细分），供崩溃率分母、小样本量提示、DoD/WoW 取数。
--
-- 口径与滚动窗口值分离（D2）：整日单值，字段带 _1d。{{TABLE}}=sessions 表；{{DAYS}}=距今天数（1=昨日）。
-- 粒度钉死平台级（iOS/Android 各自全平台），与崩溃/性能卡片行同粒度（R4 小样本提示不用版本细分）。
SELECT
  COUNT(DISTINCT session_id) AS sessions_1d
FROM `{{TABLE}}`
WHERE DATE(event_timestamp) = DATE_SUB(CURRENT_DATE(), INTERVAL {{DAYS}} DAY)
  AND application.display_version IN ({{VERSIONS}})
