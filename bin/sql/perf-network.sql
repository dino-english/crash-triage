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
  AND app_display_version IN ({{VERSIONS}})
  -- 完整日闭区间（change crash-data-completeness）：⛔ 不再锚在跑批时刻——
  -- 表每天只灌到 06:59 UTC，锚在跑批时刻会把最后那 7 小时（固定是东亚上午）掺进窗口。
  AND DATE(event_timestamp) BETWEEN '{{LCD_START}}' AND '{{LCD_END}}'
GROUP BY endpoint
HAVING n >= 50
ORDER BY p95_ms DESC
LIMIT 10
