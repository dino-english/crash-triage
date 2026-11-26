-- 技术诊断报错：接口类签名的小时聚合（change crash-tech-diagnostics，L0 每小时 + 基线回填共用）。
--
-- 占位符：{{SUFFIXES}} = 选好的表后缀（带引号的逗号列表，如 'intraday_20261126','20261125'），
--         由外壳层按「同一 UTC 日有日表取日表、否则取 intraday」选出——⛔ 同日两张不能都给：
--         日表生成后 intraday 约滞后一天才删，两张内容几乎一样，都读会重复计数、扫描量翻倍。
--
-- ⚠️ GA4 property 时区是 UTC（design 决策 4）：表按 UTC 0 点（= MYT 08:00）切分；小时按 MYT 归桶。
--    每行只取「事件时间所在 UTC 日 = 表日期」的事件：日表里有少量越过次日 0 点的晚到事件，
--    不过滤的话同一 MYT 小时会被两张表各写一份残缺值，回填与增量 upsert 时互相覆盖。
--
-- 签名口径：占位符 DIAG_API_PRED（bin/lib/bq.sh 的 SQL_DIAG_API_PRED，全仓唯一定义）。受影响设备 = user_pseudo_id 去重，用户 = user_id 去重（空值不计）。
--   普通成功请求有 10% 采样、失败全量——这里只数失败，不受采样影响。
WITH ev AS (
  SELECT
    TIMESTAMP_MICROS(event_timestamp) AS ts,
    platform AS plat,
    app_info.version AS ver,
    user_pseudo_id AS dev,
    NULLIF(user_id, '') AS uid,
    (SELECT value.string_value FROM UNNEST(event_params) WHERE key = 'diagnostic_id') AS did,
    (SELECT value.string_value FROM UNNEST(event_params) WHERE key = 'target') AS target,
    (SELECT COALESCE(value.string_value, CAST(value.int_value AS STRING)) FROM UNNEST(event_params) WHERE key = 'code') AS code
  FROM `dino-english-497507.analytics_538991439.events_*`
  WHERE _TABLE_SUFFIX IN ({{SUFFIXES}})
    AND event_name = 'app_diagnostic'
    AND FORMAT_TIMESTAMP('%Y%m%d', TIMESTAMP_MICROS(event_timestamp)) = REGEXP_REPLACE(_TABLE_SUFFIX, r'^intraday_', '')
)
SELECT
  FORMAT_DATETIME('%Y-%m-%d %H', DATETIME(ts, 'Asia/Kuala_Lumpur')) AS h,
  plat, IFNULL(ver, '') AS ver, IFNULL(target, '') AS target, code,
  COUNT(DISTINCT dev) AS devices,
  COUNT(DISTINCT uid) AS users,
  COUNT(*) AS events
FROM ev
WHERE {{DIAG_API_PRED}}
GROUP BY h, plat, ver, target, code
ORDER BY h, devices DESC
