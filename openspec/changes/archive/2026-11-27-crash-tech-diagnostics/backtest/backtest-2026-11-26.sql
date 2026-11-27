-- 回测聚合：MYT 2026-10-20 ~ 2026-11-25（前 7 天作基线），一次扫描出小时 / 日两种粒度
-- 接口类两种口径各成一类（apiA / apiB），同一次扫描、字节数不变
WITH ev AS (
  SELECT
    TIMESTAMP_MICROS(event_timestamp) ts, platform, CAST(NULL AS STRING) ver, user_pseudo_id dev, NULLIF(user_id,'') uid,
    (SELECT value.string_value FROM UNNEST(event_params) WHERE key='diagnostic_id') did,
    (SELECT COALESCE(value.string_value, CAST(value.int_value AS STRING)) FROM UNNEST(event_params) WHERE key='code') code,
    (SELECT value.string_value FROM UNNEST(event_params) WHERE key='target') target,
    (SELECT COALESCE(value.string_value, CAST(value.int_value AS STRING)) FROM UNNEST(event_params) WHERE key='result') result,
    (SELECT value.string_value FROM UNNEST(event_params) WHERE key='reason') reason,
    (SELECT value.string_value FROM UNNEST(event_params) WHERE key='record_type') rt
  FROM `dino-english-497507.analytics_538991439.events_*`
  WHERE _TABLE_SUFFIX BETWEEN '20261019' AND '20261125'
    AND event_name = 'app_diagnostic'
    AND FORMAT_TIMESTAMP('%Y%m%d', TIMESTAMP_MICROS(event_timestamp)) = _TABLE_SUFFIX
), sig AS (
  -- 口径 A（spec 原文）：target × code，code 非空且非 2xx
  SELECT ts, platform, ver, dev, uid, 'apiA' kind, target s1, code s2 FROM ev
  WHERE did = 'api_result' AND IFNULL(code,'') != '' AND NOT REGEXP_CONTAINS(code, r'^http_2\d\d$')
  UNION ALL
  -- 口径 B（候选）：result 非 success / user_abort；code 为空或 2xx 时用 reason 当错误码
  SELECT ts, platform, ver, dev, uid, 'apiB', target,
    IF(IFNULL(code,'') = '' OR REGEXP_CONTAINS(code, r'^http_2\d\d$'), IFNULL(reason,'(none)'), code) FROM ev
  WHERE did = 'api_result' AND IFNULL(result,'') NOT IN ('success','user_abort')
  UNION ALL
  SELECT ts, platform, ver, dev, uid, 'flow', did, IFNULL(reason,'(none)') FROM ev
  WHERE did NOT IN ('api_result','api_request_result','api_failure_context') AND rt = 'outcome' AND IFNULL(result,'') != 'success'
), b AS (
  SELECT *, DATETIME(ts, 'Asia/Kuala_Lumpur') myt FROM sig
  WHERE DATE(ts, 'Asia/Kuala_Lumpur') BETWEEN '2026-10-20' AND '2026-11-25'
)
SELECT 'h' g, FORMAT_DATETIME('%F %H', myt) bucket, kind, platform, '' ver, s1, s2,
  COUNT(DISTINCT dev) devices, COUNT(DISTINCT uid) users, COUNT(*) events
FROM b WHERE kind != 'flow' GROUP BY 1,2,3,4,5,6,7
UNION ALL
SELECT 'd', FORMAT_DATETIME('%F', myt), kind, platform, IFNULL(ver,''), s1, s2,
  COUNT(DISTINCT dev), COUNT(DISTINCT uid), COUNT(*)
FROM b GROUP BY 1,2,3,4,5,6,7
