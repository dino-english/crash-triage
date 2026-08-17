-- 天级单日值（日历日锚定）：启动 P50/P95 + 慢帧/冻结平台级帧占比 + 接口错误率，供 DoD/WoW/sparkline 取数。
--
-- 口径与滚动窗口展示值（perf-traces/perf-screens/perf-network 的 3 天窗）显式分离（D2）：
-- 整日单值，字段带 _1d。{{TABLE}}=perf 表；{{DAYS}}=距今天数（性能批量表滞后 ~2 天，脚本按「最新可用单日」的偏移传入，D7）。
--
-- 慢帧/冻结取「平台级聚合帧级占比」（汇总该平台全部 SCREEN_TRACE 事件的 slow_frame_ratio / frozen_frame_ratio），
-- 非「最差页」单页值（D9）。Firebase 只导出帧级「比率」不导出原始帧数，故平台聚合 = 各渲染事件比率的均值，
-- 作为「汇总页面帧数后计算」的近似口径（与 perf-screens.sql 每页 AVG 同一套语义，此处不按页分组）。
-- net_err_pct_1d 汇总该平台全部 dinoenglish 网络请求（1d=全量）；滚动窗口展示值 perf-network.sql 取 top-10 端点
-- （HAVING n>=50 + LIMIT 10），两套取数人群不同（全量 vs 窗口 top10），不可直接混比。
SELECT
  (SELECT ROUND(APPROX_QUANTILES(trace_info.duration_us, 100)[OFFSET(50)] / 1000, 0)
     FROM `{{TABLE}}` WHERE event_type = 'DURATION_TRACE' AND event_name = '_app_start'
       AND DATE(event_timestamp) = DATE_SUB(CURRENT_DATE(), INTERVAL {{DAYS}} DAY)) AS start_p50_1d,
  (SELECT ROUND(APPROX_QUANTILES(trace_info.duration_us, 100)[OFFSET(95)] / 1000, 0)
     FROM `{{TABLE}}` WHERE event_type = 'DURATION_TRACE' AND event_name = '_app_start'
       AND DATE(event_timestamp) = DATE_SUB(CURRENT_DATE(), INTERVAL {{DAYS}} DAY)) AS start_p95_1d,
  (SELECT ROUND(AVG(trace_info.screen_info.slow_frame_ratio) * 100, 1)
     FROM `{{TABLE}}` WHERE event_type = 'SCREEN_TRACE'
       AND DATE(event_timestamp) = DATE_SUB(CURRENT_DATE(), INTERVAL {{DAYS}} DAY)) AS slow_pct_1d,
  (SELECT ROUND(AVG(trace_info.screen_info.frozen_frame_ratio) * 100, 2)
     FROM `{{TABLE}}` WHERE event_type = 'SCREEN_TRACE'
       AND DATE(event_timestamp) = DATE_SUB(CURRENT_DATE(), INTERVAL {{DAYS}} DAY)) AS frozen_pct_1d,
  (SELECT ROUND(SAFE_DIVIDE(COUNTIF(network_info.response_code >= 400), COUNT(*)) * 100, 2)
     FROM `{{TABLE}}` WHERE event_type = 'NETWORK_REQUEST' AND event_name LIKE '%dinoenglish%'
       AND DATE(event_timestamp) = DATE_SUB(CURRENT_DATE(), INTERVAL {{DAYS}} DAY)) AS net_err_pct_1d
