-- 自定义 / 内置耗时 trace。关注 _app_start（冷启动）；
-- _app_in_foreground / _app_in_background 是会话时长，不是性能指标，展示时应过滤。
SELECT
  event_name                                                                        AS trace,
  COUNT(*)                                                                          AS n,
  ROUND(APPROX_QUANTILES(trace_info.duration_us, 100)[OFFSET(50)] / 1000, 0)        AS p50_ms,
  ROUND(APPROX_QUANTILES(trace_info.duration_us, 100)[OFFSET(95)] / 1000, 0)        AS p95_ms
FROM `{{TABLE}}`
WHERE event_type = 'DURATION_TRACE'
  AND event_name NOT IN ('_app_in_foreground', '_app_in_background')
  AND app_display_version IN ({{VERSIONS}})
  AND event_timestamp >= TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL {{DAYS}} DAY)
GROUP BY trace
ORDER BY n DESC
LIMIT 12
