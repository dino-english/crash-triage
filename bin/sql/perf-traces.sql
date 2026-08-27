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
  -- 完整日闭区间（change crash-data-completeness）：⛔ 不再锚在跑批时刻——
  -- 表每天只灌到 06:59 UTC，锚在跑批时刻会把最后那 7 小时（固定是东亚上午）掺进窗口。
  AND DATE(event_timestamp) BETWEEN '{{LCD_START}}' AND '{{LCD_END}}'
GROUP BY trace
ORDER BY n DESC
LIMIT 12
