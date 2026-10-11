-- 慢帧 / 冻结的「平台整体」窗口值（change crash-report-attention-tiers，design D3）：判灯用。
--
-- 与 daily-perf-1d.sql 的 slow_pct_1d / frozen_pct_1d **同一算法**（全部 SCREEN_TRACE 的比率均值），
-- 只是窗口换成性能段的完整日闭区间（与 perf-screens.sql 同窗）。
-- ⛔ 与 1d 值**分开存**（字段名不同），不可混入 metrics-history.jsonl 的 *_1d 字段——两套口径不可混比。
-- ⛔ 不按页分组：「最差页」由 perf-screens.sql 给，只作下钻线索，不参与判灯
--    （单页长期超标会让大盘灯永远红，实测 Android SplashActivity 87.8% vs 平台 43.6%，2026-10-11）。
SELECT
  COUNT(*)                                                         AS samples,
  ROUND(AVG(trace_info.screen_info.slow_frame_ratio)   * 100, 1)   AS slow_pct,
  ROUND(AVG(trace_info.screen_info.frozen_frame_ratio) * 100, 2)   AS frozen_pct
FROM `{{TABLE}}`
WHERE event_type = 'SCREEN_TRACE'
  AND app_display_version IN ({{VERSIONS}})
  AND DATE(event_timestamp) BETWEEN '{{LCD_START}}' AND '{{LCD_END}}'
HAVING samples > 0
