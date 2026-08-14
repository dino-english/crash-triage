-- 自家 API 网络性能：P50 / P95 延迟与错误率
-- 只看 dinoenglish 域：三方 SDK（AppsFlyer / PostHog / Facebook）的延迟不是我们能控的，
-- 计入会淹没自家接口的信号。
SELECT
  event_name                                                                            AS endpoint,
  COUNT(*)                                                                              AS n,
  ROUND(APPROX_QUANTILES(network_info.response_completed_time_us, 100)[OFFSET(50)] / 1000, 0) AS p50_ms,
  ROUND(APPROX_QUANTILES(network_info.response_completed_time_us, 100)[OFFSET(95)] / 1000, 0) AS p95_ms,
  COUNTIF(network_info.response_code >= 400)                                            AS errors,
  ROUND(COUNTIF(network_info.response_code >= 400) / COUNT(*) * 100, 2)                 AS err_pct
FROM `{{TABLE}}`
WHERE event_type = 'NETWORK_REQUEST'
  AND event_name LIKE '%dinoenglish%'
  AND event_timestamp >= TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL {{DAYS}} DAY)
GROUP BY endpoint
HAVING n >= 50
ORDER BY p95_ms DESC
LIMIT 10
