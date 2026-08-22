-- ANR 与 NON_FATAL 的事件数与受影响安装数（按版本，单行）。
--
-- 为什么不能复用 crash-issues.sql / crash-rate.sql：那两份写的是 `is_fatal = TRUE`，
-- 而 **ANR 与 NON_FATAL 的 is_fatal 均为 FALSE**——沿用致命过滤会让这两类整体不可见。
-- 实测（2026-08-22，近 14 天）：Android FATAL 105 / ANR 93 / NON_FATAL 131；
-- iOS FATAL 4 / NON_FATAL 1020，**iOS 无 ANR 行**（系统层无此概念，数据源不产出）。
--
-- 一次查询取两类：ANR 与 NON_FATAL 各跑一条会让每版本每端多一次 bq 调用，
-- 整跑本已 5 分钟以上，能合就合。
--
-- ANR 率的分母是会话数（由调用方从 crash-rate.sql / sessions 取），与既有崩溃率同分母、内部可比。
-- ⚠️ 与 Play Console 的「用户感知 ANR 率」（日活用户分母）**口径不同，不可直接对照商店门槛**。
SELECT
  COUNTIF(error_type = 'ANR')                                                  AS anr_events,
  COUNT(DISTINCT IF(error_type = 'ANR', installation_uuid, NULL))              AS anr_installs,
  COUNTIF(error_type = 'NON_FATAL')                                            AS nonfatal_events,
  COUNT(DISTINCT IF(error_type = 'NON_FATAL', installation_uuid, NULL))        AS nonfatal_installs
FROM `{{TABLE}}`
WHERE error_type IN ('ANR', 'NON_FATAL')
  AND application.display_version IN ({{VERSIONS}})
  AND event_timestamp >= TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL {{DAYS}} DAY)
