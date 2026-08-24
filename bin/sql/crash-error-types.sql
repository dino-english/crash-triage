-- 三类事件（FATAL / ANR / NON_FATAL）的事件数、受影响安装数与**前后台分布**（按版本，单行）。
--
-- 为什么不能复用 crash-issues.sql / crash-rate.sql：那两份写的是 `is_fatal = TRUE`，
-- 而 **ANR 与 NON_FATAL 的 is_fatal 均为 FALSE**——沿用致命过滤会让这两类整体不可见。
-- 实测（2026-08-22，近 14 天）：Android FATAL 105 / ANR 93 / NON_FATAL 131；
-- iOS FATAL 4 / NON_FATAL 1020，**iOS 无 ANR 行**（系统层无此概念，数据源不产出）。
--
-- 一次查询取三类：各跑一条会让每版本每端多几次 bq 调用，整跑本已 5 分钟以上，能合就合。
--
-- ANR 率的分母是会话数（由调用方从 crash-rate.sql / sessions 取），与既有崩溃率同分母、内部可比。
-- ⚠️ 与 Play Console 的「用户感知 ANR 率」（日活用户分母）**口径不同，不可直接对照商店门槛**。
--
-- ── 前后台（2026-08-24 新增，change crash-fg-bg-split）──────────────────────────
-- ⛔ **归一化表达式全仓只此一处**：`SQL_FG_NORM`（bin/lib/bq.sh），本文件用 {{FG_NORM}} 引用。
-- 复制到别的 SQL 或渲染层
--    会变成「同一目的两份实现」——本仓库已因此把 1 个事件渲染成 11（见失效模式登记 F1）。
--    FATAL 的前后台也在本文件取，正是为了不必去动 crash-rate.sql（那会碰崩溃率与 crash-free 口径）。
-- 取值优先级：`process_state`（Crashlytics 一等字段，双端同名同枚举）→ 自埋 `app_foreground` 回落。
-- ⚠️ **两端 app_foreground 取值不同**：Android `true`/`false`，iOS `1`/`0`。方向经交叉验证（7d）：
--    iOS   BACKGROUND↔0 = 1068 · FOREGROUND↔1 = 14（一致率 99.2%）
--    Android FOREGROUND↔true = 162 · BACKGROUND↔false = 11
-- ⚠️ **前后台只有绝对数、没有率**：sessions 表无 process_state 字段，前后台的会话分母不存在。
-- ⚠️ 后台崩溃用户通常无感，但**不等于可以不修**——它会中断上传、推送与预加载。
--
-- ⚠️ 本文件的 WHERE 由 ('ANR','NON_FATAL') 放宽为含 FATAL：既有四列全是
--    COUNTIF(error_type=…) / COUNT(DISTINCT IF(error_type=…))，放宽扫描范围**不改变它们的取值**。
WITH e AS (
  SELECT
    error_type,
    installation_uuid,
    {{FG_NORM}} AS fg_state
  FROM `{{TABLE}}`
  WHERE error_type IN ('FATAL', 'ANR', 'NON_FATAL')
    AND application.display_version IN ({{VERSIONS}})
    AND event_timestamp >= TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL {{DAYS}} DAY)
)
SELECT
  -- ── 既有四列，位置与语义不变（下游按列序 cut，⛔ 不可插队）────────────
  COUNTIF(error_type = 'ANR')                                            AS anr_events,
  COUNT(DISTINCT IF(error_type = 'ANR', installation_uuid, NULL))        AS anr_installs,
  COUNTIF(error_type = 'NON_FATAL')                                      AS nonfatal_events,
  COUNT(DISTINCT IF(error_type = 'NON_FATAL', installation_uuid, NULL))  AS nonfatal_installs,
  -- ── 前后台，一律追加在末尾 ───────────────────────────────────────────
  -- unknown 单独成列：`0 前台` 是结论（确实没有前台事件），`未知` 是缺数，两者必须可区分。
  COUNTIF(error_type = 'FATAL'     AND fg_state = 'FOREGROUND')          AS fatal_fg,
  COUNTIF(error_type = 'FATAL'     AND fg_state = 'BACKGROUND')          AS fatal_bg,
  COUNTIF(error_type = 'FATAL'     AND fg_state IS NULL)                 AS fatal_unknown,
  COUNTIF(error_type = 'ANR'       AND fg_state = 'FOREGROUND')          AS anr_fg,
  COUNTIF(error_type = 'ANR'       AND fg_state = 'BACKGROUND')          AS anr_bg,
  COUNTIF(error_type = 'ANR'       AND fg_state IS NULL)                 AS anr_unknown,
  COUNTIF(error_type = 'NON_FATAL' AND fg_state = 'FOREGROUND')          AS nonfatal_fg,
  COUNTIF(error_type = 'NON_FATAL' AND fg_state = 'BACKGROUND')          AS nonfatal_bg,
  COUNTIF(error_type = 'NON_FATAL' AND fg_state IS NULL)                 AS nonfatal_unknown
FROM e
