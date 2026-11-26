-- 技术诊断报错：完整 MYT 日的签名日聚合，接口类 + 流程类（change crash-tech-diagnostics，L1 / L2 / 回填共用）。
--
-- 占位符：{{SUFFIXES}} 同 diag-hourly.sql（外壳层选好的表后缀；MYT D 日横跨 UTC D-1 与 D 两张表）；
--         {{DAY_FROM}} / {{DAY_TO}} = 'YYYY-MM-DD'（MYT，闭区间）——回填 28 天时一次查完，
--         29 张表各读一次（逐日查要读 56 张，扫描翻倍）；{{DIAG_API_PRED}} = 接口类谓词（bin/lib/bq.sh 唯一定义）。
--
-- ⛔ 不按版本过滤，全版本输出、版本作为一列：日级基线按签名跨版本算——只取最新 2 版的话，
--    新版本一上线所有签名基线归零、全部判成激增。「最新 2 版」在渲染层筛。
--
-- 流程类（kind=flow）：diagnostic_id × reason，只取 result=tech_fail 且 record_type=outcome（维护者 2026-11-26 定：
--   rejected / user_abort 多为业务正常态——无可恢复购买、不适用、用户取消——会占满头部，design 决策 2）；
--   排除 api_result / api_request_result / api_failure_context——那是接口层，已由接口类覆盖
--  （snapshot / metric / checkpoint 是同一过程的辅助记录，计入会让同一故障在多个签名里重复出现）。
WITH ev AS (
  SELECT
    TIMESTAMP_MICROS(event_timestamp) AS ts,
    platform AS plat, app_info.version AS ver, user_pseudo_id AS dev, NULLIF(user_id, '') AS uid,
    (SELECT value.string_value FROM UNNEST(event_params) WHERE key = 'diagnostic_id') AS did,
    (SELECT value.string_value FROM UNNEST(event_params) WHERE key = 'target') AS target,
    (SELECT COALESCE(value.string_value, CAST(value.int_value AS STRING)) FROM UNNEST(event_params) WHERE key = 'code') AS code,
    (SELECT COALESCE(value.string_value, CAST(value.int_value AS STRING)) FROM UNNEST(event_params) WHERE key = 'result') AS result,
    (SELECT value.string_value FROM UNNEST(event_params) WHERE key = 'reason') AS reason,
    (SELECT value.string_value FROM UNNEST(event_params) WHERE key = 'record_type') AS rt
  FROM `dino-english-497507.analytics_538991439.events_*`
  WHERE _TABLE_SUFFIX IN ({{SUFFIXES}})
    AND event_name = 'app_diagnostic'
    AND FORMAT_TIMESTAMP('%Y%m%d', TIMESTAMP_MICROS(event_timestamp)) = REGEXP_REPLACE(_TABLE_SUFFIX, r'^intraday_', '')
    AND DATE(TIMESTAMP_MICROS(event_timestamp), 'Asia/Kuala_Lumpur') BETWEEN DATE '{{DAY_FROM}}' AND DATE '{{DAY_TO}}'
), sig AS (
  SELECT FORMAT_DATE('%Y-%m-%d', DATE(ts, 'Asia/Kuala_Lumpur')) AS d, 'api' AS kind, plat, ver, dev, uid, IFNULL(target, '') AS s1, code AS s2 FROM ev
  WHERE {{DIAG_API_PRED}}
  UNION ALL
  SELECT FORMAT_DATE('%Y-%m-%d', DATE(ts, 'Asia/Kuala_Lumpur')), 'flow', plat, ver, dev, uid, did, IFNULL(reason, '') FROM ev
  WHERE did NOT IN ('api_result', 'api_request_result', 'api_failure_context')
    AND rt = 'outcome' AND result = 'tech_fail'
)
SELECT d, kind, plat, IFNULL(ver, '') AS ver, s1, s2,
  COUNT(DISTINCT dev) AS devices, COUNT(DISTINCT uid) AS users, COUNT(*) AS events
FROM sig
GROUP BY d, kind, plat, ver, s1, s2
ORDER BY d, kind, devices DESC
