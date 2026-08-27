-- 天级单日值（日历日锚定）：启动 P50/P95 + 慢帧/冻结平台级帧占比 + 接口错误率，供 DoD/WoW/sparkline 取数。
--
-- 口径与滚动窗口展示值（perf-traces/perf-screens/perf-network 的 3 天窗）显式分离（D2）：
-- 整日单值，字段带 _1d。{{TABLE}}=perf 表；{{DAY}}=**完整日日期**（YYYY-MM-DD，由 last_complete_day() 算出）。
-- ⛔ 不再用「距今 N 天」偏移（change crash-data-completeness）：表的最后一个日历日恒为 7 小时残日，
-- 按 MAX(DATE(event_timestamp)) 取「最新可用单日」正好取中它，于是 DoD 拿 7 小时切片去比完整天。
-- ⛔ 也不再用 CURRENT_DATE()：日期由 shell 算好显式传入，跨 UTC 零点时 BigQuery 与 shell 各自取「今天」会错位一天。
--
-- 慢帧/冻结取「平台级聚合帧级占比」（汇总该平台全部 SCREEN_TRACE 事件的 slow_frame_ratio / frozen_frame_ratio），
-- 非「最差页」单页值（D9）。Firebase 只导出帧级「比率」不导出原始帧数，故平台聚合 = 各渲染事件比率的均值，
-- 作为「汇总页面帧数后计算」的近似口径（与 perf-screens.sql 每页 AVG 同一套语义，此处不按页分组）。
-- net_err_pct_1d 汇总该平台全部 dinoenglish 网络请求（1d=全量）；滚动窗口展示值 perf-network.sql 取 top-10 端点
-- （HAVING n>=50 + LIMIT 10），两套取数人群不同（全量 vs 窗口 top10），不可直接混比。
SELECT
  (SELECT ROUND(APPROX_QUANTILES(trace_info.duration_us, 100)[OFFSET(50)] / 1000, 0)
     FROM `{{TABLE}}` WHERE event_type = 'DURATION_TRACE' AND event_name = '_app_start'
       AND app_display_version IN ({{VERSIONS}})
       AND DATE(event_timestamp) = '{{DAY}}') AS start_p50_1d,
  (SELECT ROUND(APPROX_QUANTILES(trace_info.duration_us, 100)[OFFSET(95)] / 1000, 0)
     FROM `{{TABLE}}` WHERE event_type = 'DURATION_TRACE' AND event_name = '_app_start'
       AND app_display_version IN ({{VERSIONS}})
       AND DATE(event_timestamp) = '{{DAY}}') AS start_p95_1d,
  (SELECT ROUND(AVG(trace_info.screen_info.slow_frame_ratio) * 100, 1)
     FROM `{{TABLE}}` WHERE event_type = 'SCREEN_TRACE'
       AND app_display_version IN ({{VERSIONS}})
       AND DATE(event_timestamp) = '{{DAY}}') AS slow_pct_1d,
  (SELECT ROUND(AVG(trace_info.screen_info.frozen_frame_ratio) * 100, 2)
     FROM `{{TABLE}}` WHERE event_type = 'SCREEN_TRACE'
       AND app_display_version IN ({{VERSIONS}})
       AND DATE(event_timestamp) = '{{DAY}}') AS frozen_pct_1d,
  (SELECT ROUND(SAFE_DIVIDE(COUNTIF(network_info.response_code >= 400), COUNT(*)) * 100, 2)
     FROM `{{TABLE}}` WHERE event_type = 'NETWORK_REQUEST' AND event_name LIKE '%dinoenglish%'
       AND app_display_version IN ({{VERSIONS}})
       AND DATE(event_timestamp) = '{{DAY}}') AS net_err_pct_1d
