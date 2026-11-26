-- 技术诊断报错：待发签名在某 MYT 小时的分布（change crash-tech-diagnostics，L0 告警卡片附件）。
--
-- 占位符：{{SUFFIXES}} 同 diag-hourly.sql（外壳层选好的表后缀）；{{HOUR}} = 'YYYY-MM-DD HH'（MYT）；
--         {{SIG_KEYS}} = 待发签名「target × code」的带引号逗号列表——一次查完本小时所有待发签名，
--         10-29 那种 8 个签名同时命中时只扫一次表（单表约 2.8 GB）。
--         ⚠️ 外壳层负责转义单引号与反斜杠，值来自数据不可信。
--
-- 输出两类行（dim 列区分），按签名（sig 列）分组，分母都是该小时该签名的受影响设备数（affected）：
--   geo：plat × 国家 × 版本 的设备数
--   cfg：受影响设备**同一小时**上报的 strategy_config_result 里 config_source_type × config_data_id 的设备数
--        ⚠️ 只取带配置字段的记录（checkpoint 记录不带，实测 11-23 18 点 35 台全有一条空配置）；
--        ⚠️ 一台设备同一小时可拿到多份配置，各行占比相加可超过 100%——渲染层写「N / 受影响 M 台」，不写构成比。
WITH ev AS (
  SELECT
    TIMESTAMP_MICROS(event_timestamp) AS ts,
    platform AS plat, app_info.version AS ver, geo.country AS country, user_pseudo_id AS dev,
    (SELECT value.string_value FROM UNNEST(event_params) WHERE key = 'diagnostic_id') AS did,
    (SELECT value.string_value FROM UNNEST(event_params) WHERE key = 'target') AS target,
    (SELECT COALESCE(value.string_value, CAST(value.int_value AS STRING)) FROM UNNEST(event_params) WHERE key = 'code') AS code,
    (SELECT value.string_value FROM UNNEST(event_params) WHERE key = 'config_source_type') AS cst,
    (SELECT COALESCE(value.string_value, CAST(value.int_value AS STRING)) FROM UNNEST(event_params) WHERE key = 'config_data_id') AS cdi
  FROM `dino-english-497507.analytics_538991439.events_*`
  WHERE _TABLE_SUFFIX IN ({{SUFFIXES}})
    AND event_name = 'app_diagnostic'
    AND FORMAT_DATETIME('%Y-%m-%d %H', DATETIME(TIMESTAMP_MICROS(event_timestamp), 'Asia/Kuala_Lumpur')) = '{{HOUR}}'
), hit AS (
  SELECT *, CONCAT(IFNULL(target, ''), ' × ', code) AS sig FROM ev
  WHERE did = 'api_result' AND CONCAT(IFNULL(target, ''), ' × ', code) IN ({{SIG_KEYS}})
), affected AS (
  SELECT sig, COUNT(DISTINCT dev) AS n FROM hit GROUP BY sig
), geo AS (
  SELECT sig, plat AS k1, IFNULL(country, '') AS k2, IFNULL(ver, '') AS k3, COUNT(DISTINCT dev) AS devices
  FROM hit GROUP BY sig, k1, k2, k3
), cfg AS (
  SELECT h.sig, e.cst AS k1, e.cdi AS k2, '' AS k3, COUNT(DISTINCT e.dev) AS devices
  FROM ev e JOIN (SELECT DISTINCT sig, dev FROM hit) h USING (dev)
  WHERE e.did = 'strategy_config_result' AND e.cst IS NOT NULL
  GROUP BY h.sig, k1, k2
)
SELECT 'geo' AS dim, g.*, a.n AS affected FROM geo g JOIN affected a USING (sig)
UNION ALL
SELECT 'cfg', c.*, a.n FROM cfg c JOIN affected a USING (sig)
ORDER BY sig, dim, devices DESC
