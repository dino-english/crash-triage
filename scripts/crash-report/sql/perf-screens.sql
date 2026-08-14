-- 页面渲染性能：慢帧率 / 冻结帧率 / 停留时长
-- 样本量阈值 20 用于滤掉长尾页面（样本太少时比率不可信）
SELECT
  REPLACE(event_name, '_st_', '')                                              AS screen,
  COUNT(*)                                                                     AS samples,
  ROUND(AVG(trace_info.screen_info.slow_frame_ratio)   * 100, 1)               AS slow_pct,
  ROUND(AVG(trace_info.screen_info.frozen_frame_ratio) * 100, 2)               AS frozen_pct,
  ROUND(APPROX_QUANTILES(trace_info.duration_us, 100)[OFFSET(50)] / 1e6, 1)    AS p50_dwell_s
FROM `{{TABLE}}`
WHERE event_type = 'SCREEN_TRACE'
  AND event_timestamp >= TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL {{DAYS}} DAY)
GROUP BY screen
HAVING samples >= 20
ORDER BY slow_pct DESC
LIMIT 10
