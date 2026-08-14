-- 版本放量：按 app 版本统计会话数与设备数。
--
-- 用途：判断「新版本样本量够不够下结论」。崩溃数为 0 可能是修好了，也可能是没人用——
-- 没有这个分母就分不清。修复验证的判定线（如「累计 N 会话仍 0 崩溃才算生效」）依赖它。
--
-- 注意：这是 sessions 表不是 crashlytics 表，两者独立同步，可能有时间差。
SELECT
  application.display_version                            AS version,
  COUNT(DISTINCT session_id)                             AS sessions,
  COUNT(DISTINCT instance_id)                            AS devices,
  FORMAT_TIMESTAMP('%Y-%m-%d', MAX(event_timestamp))     AS latest
FROM `{{TABLE}}`
WHERE event_timestamp >= TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL {{DAYS}} DAY)
GROUP BY version
HAVING sessions >= 5
ORDER BY sessions DESC
LIMIT 6
