-- 修复发版判定的取数（change crash-fix-release-status）。⛔ 只取数，不判定——四态判定在
-- bin/lib/core/fixrelease.sh（纯函数），这里给它原料。
--
-- 两类行，用 kind 区分：
--   ev  —— 每个 (issue, build)：修复提交**之后**该 issue 在这个 build 上的事件数，附 build 首现与上架特征
--   rel —— 上架包清单（性能采集设备数 > 0 的 build），供 iOS 判「含修复的包已上线」
--
-- ⚠️ 事件取 crashlytics **批量表 ∪ REALTIME** 按 event_id 去重（design D3）：
--    REALTIME 只留 30 天（2026-10-06 实测两端最早 09-06），只查它会漏掉早于 30 天的修复之后的事件——
--    a34175e5 / ce481263（修复 08-19）在 REALTIME 里 0 次，批量表里 1 / 7 次。
-- ⚠️ build 首现取四张表最早（design D4）：sessions 批量表 08-11 停更、REALTIME 09-06 起，
--    08-11 ~ 09-06 首现且没崩过的 build 会被推迟到 09-06——只会推迟「已上线」，不会提前。
-- ⚠️ 上架特征只看 sessions REALTIME 的 performance_data_collection_enabled（iOS 上架全开、adhoc 全关，
--    口径文档已记录 30 天双向干净）。⛔ Android 该字段恒 false，rel 行对 Android 无意义，判定层不读。
-- ⛔ 不用关联子查询：BigQuery 不支持「引用其他表的关联子查询」（2026-10-06 实测报错），一律 JOIN。
--
-- 占位符：{{FIXES}} = 逗号分隔的 STRUCT("<32位id>" AS id, TIMESTAMP_SECONDS(<epoch>) AS ct)，
--         只替换值（调用方已校验 id 为十六进制）；四个 *_TABLE 为完整表名。
WITH fx AS (
  SELECT * FROM UNNEST([{{FIXES}}])
),
src AS (
  SELECT application.build_version AS b, application.display_version AS v, event_timestamp AS t FROM `{{SESS_RT_TABLE}}`
  UNION ALL SELECT application.build_version, application.display_version, event_timestamp FROM `{{SESS_TABLE}}`
  UNION ALL SELECT application.build_version, application.display_version, event_timestamp FROM `{{CRASH_TABLE}}`
  UNION ALL SELECT application.build_version, application.display_version, event_timestamp FROM `{{CRASH_RT_TABLE}}`
),
first_seen AS (
  SELECT b, ANY_VALUE(v) AS v, MIN(t) AS fs FROM src WHERE b IS NOT NULL GROUP BY b
),
adopt AS (
  SELECT application.build_version AS b,
         COUNT(DISTINCT IF(performance_data_collection_enabled, instance_id, NULL)) AS perf_on
  FROM `{{SESS_RT_TABLE}}` GROUP BY b
),
ev AS (
  SELECT DISTINCT event_id, issue_id, application.build_version AS b,
         application.display_version AS v, event_timestamp AS t
  FROM (
    SELECT event_id, issue_id, application, event_timestamp FROM `{{CRASH_TABLE}}`
    UNION ALL
    SELECT event_id, issue_id, application, event_timestamp FROM `{{CRASH_RT_TABLE}}`
  )
  WHERE issue_id IN (SELECT id FROM fx)
)
SELECT 'ev' AS kind, ev.issue_id, ev.b AS build, ANY_VALUE(ev.v) AS version,
       UNIX_SECONDS(ANY_VALUE(f.fs)) AS first_seen, IFNULL(ANY_VALUE(a.perf_on), 0) AS perf_on,
       COUNT(*) AS events
FROM ev
JOIN fx ON fx.id = ev.issue_id AND ev.t > fx.ct
LEFT JOIN first_seen f ON f.b = ev.b
LEFT JOIN adopt a ON a.b = ev.b
GROUP BY ev.issue_id, ev.b
UNION ALL
SELECT 'rel', '', f.b, f.v, UNIX_SECONDS(f.fs), a.perf_on, 0
FROM first_seen f JOIN adopt a ON a.b = f.b
WHERE a.perf_on > 0
