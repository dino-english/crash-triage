-- 崩溃时间分布：按**绝对小时**分桶（不是「一天中的第几小时」），用于日报「一、汇总」的「什么时候」。
--
-- **峰值与聚集是两件事，需要两种聚合，但一次查询就够**（design D4）：
--   · **峰值时段** = 按 hour_cst（一天中的第几小时）汇总 → 「什么时候最容易出」，常态分布的描述；
--   · **聚集** = 单个绝对小时桶的占比 → 「是不是发生了一次事故」，通常对应发版 / 配置推送 / 后端异常。
--
-- ⚠️ 只按 hour_cst 分桶**答不了聚集**：一次爆发会被摊进 24 个桶里看不出来。
--    故这里返回绝对小时桶，hour_cst 一并带出，由渲染层再汇总一次得到峰值。
--
-- ⛔ 聚集判定**不引入统计检验**：双端两周合计两百余事件，任何显著性检验都会给出不可靠结论。
--    渲染层用「最密集桶占比 vs 均匀分布期望」做粗糙比较即可，措辞用「存在时间聚集」而非「发生了事故」。
--
-- 时区固定 Asia/Shanghai：读者按本地作息判读（教育类 App 的上课 / 晚间时段），
-- UTC 分桶会把晚高峰劈成两半。渲染层标注时区，与报告既有的双时区惯例一致。
SELECT
  FORMAT_TIMESTAMP('%Y-%m-%d %H', event_timestamp, 'Asia/Shanghai')  AS bucket_cst,
  FORMAT_TIMESTAMP('%H', event_timestamp, 'Asia/Shanghai')           AS hour_cst,
  COUNT(*)                                                           AS events,
  COUNT(DISTINCT installation_uuid)                                  AS users
FROM `{{TABLE}}`
WHERE error_type IN ('FATAL', 'ANR')
  AND application.display_version IN ({{VERSIONS}})
  AND event_timestamp >= TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL {{DAYS}} DAY)
GROUP BY bucket_cst, hour_cst
ORDER BY events DESC
