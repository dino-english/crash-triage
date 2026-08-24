-- 无分母维度分布：页面 / 前后台 / 内存档等 **sessions 表里不存在的维度**。
--
-- 与 crash-dimensions.sql 的关系：那份**给率**，因为 `firebase_sessions` 恰好含
-- `device.model` 与 `operating_system.display_version` 两个业务维度，能除出该维度自身的会话数。
-- 本份**永远不给率**——sessions 表全字段实测只有 instance_id / session_id / first_session_id /
-- session_index / event_type / 双时间戳 / 双开关 / application.* / device.* / operating_system.*，
-- **无 screen、无 process_state、无用户标识**。页面级会话分母不是「暂时没做」，是数据源没有。
--
-- ⛔ 绝不可借 perf-screens.sql 的屏幕 trace 样本数当分母——那是另一套采样总体，
--    与拿 installation_uuid 去除 instance_id 是同一类错误（实测 JOIN 匹配 0 行）。
--
-- {{DIM}} 由调用方 sed 替换。⚠️ `custom_keys` 是 REPEATED RECORD，取值必须走标量子查询：
--   (SELECT value FROM UNNEST(custom_keys) WHERE key = 'current_screen' LIMIT 1)   崩溃页面
--   (SELECT value FROM UNNEST(custom_keys) WHERE key = 'mem_tier'       LIMIT 1)   内存档
-- {{ERROR_TYPES}} 也由调用方给：Android 用 'FATAL','ANR'；
--   ⚠️ iOS 必须用 'NON_FATAL'——实测 iOS 60 天仅 5 次致命崩溃，按致命口径出来是空表，
--   而「表里只有一行」与「iOS 很健康」在版面上长得一模一样。
WITH c AS (
  SELECT
    -- ⛔ 取不到的值渲染成 '(未知)' 并**照常参与排序**，不得丢弃：
    --    实测 Android 页面维度的 (未知) 桶按影响安装排第 2（19 事件 / 18 安装），
    --    丢掉它会让表格合计对不上事件总数，而读者不会发现少了什么。
    IFNULL(NULLIF({{DIM}}, ''), '(未知)') AS dim,
    COUNT(*)                              AS events,
    COUNT(DISTINCT installation_uuid)     AS users
  FROM `{{TABLE}}`
  WHERE error_type IN ({{ERROR_TYPES}})
    AND application.display_version IN ({{VERSIONS}})
    AND event_timestamp >= TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL {{DAYS}} DAY)
  GROUP BY dim
)
SELECT
  dim                                        AS dim,
  events                                     AS events,
  users                                      AS users,
  -- 集中度 = 事件 / 受影响安装。⚠️ 列位与 crash-dimensions.sql **刻意不同**（那份第 4/5 列是
  -- sessions / rate_pct），渲染层不可共用同一套列号，否则会把集中度读成会话数。
  ROUND(events / NULLIF(users, 0), 1)        AS concentration
FROM c
  -- 并列时补确定性 tie-breaker，否则两次跑批行序会互换（同 crash-issues.sql）
ORDER BY users DESC, events DESC, dim
LIMIT {{LIMIT}}
