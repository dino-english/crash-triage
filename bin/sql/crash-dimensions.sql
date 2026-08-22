-- 崩溃影响面维度分布：机型 / 系统版本 / 时段。用于日报「一、汇总」段的「集中在哪 / 什么时候」。
--
-- **给率不给绝对数**（design D6 + task 0.2）：`firebase_sessions` 实测含 `device.model`
-- 与 `operating_system.display_version`，因此每个维度值都能除以该维度自身的会话数。
-- ⚠️ 只给绝对数会让「Android 16 有 51 次崩溃」被读成「Android 16 适配差」——
-- 实际可能只是用它的人多（实测该系统版本 51 事件 / 44 安装，集中度 1.16，分布很广）。
-- **没有分母就没有结论。**
--
-- ⚠️ 有了率**也不等于**有了根因：某机型崩溃率高仍可能源自该机型用户的网络环境或功能路径。
-- 汇总段只给可定位对象与取证方向，不出根因（与性能段同一条硬约束）。
--
-- {{DIM}} 取以下之一（由调用方 sed 替换）：
--   CONCAT(device.manufacturer,' ',device.model)   机型
--   operating_system.display_version               系统版本
-- {{SESS_DIM}} 是 sessions 表里的对应表达式（字段路径两表一致，但表名不同故分开占位）。
WITH c AS (
  SELECT {{DIM}} AS dim,
         COUNT(*) AS events,
         COUNT(DISTINCT installation_uuid) AS users
  FROM `{{TABLE}}`
  WHERE error_type IN ('FATAL', 'ANR')
    AND application.display_version IN ({{VERSIONS}})
    AND event_timestamp >= TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL {{DAYS}} DAY)
  GROUP BY dim
), s AS (
  SELECT {{SESS_DIM}} AS dim,
         COUNT(DISTINCT session_id) AS sessions
  FROM `{{SESSIONS_TABLE}}`
  WHERE application.display_version IN ({{VERSIONS}})
    AND event_timestamp >= TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL {{DAYS}} DAY)
  GROUP BY dim
)
SELECT
  c.dim                                                              AS dim,
  c.events                                                           AS events,
  c.users                                                            AS users,
  IFNULL(s.sessions, 0)                                              AS sessions,
  -- 崩溃率：该维度值的事件数 ÷ 该维度值的会话数。分母为 0 时给 NULL，由渲染层显示「无法计算」，
  -- **不能显示 0**（与既有崩溃率同一条规矩）。
  IF(IFNULL(s.sessions, 0) = 0, NULL, ROUND(c.events / s.sessions * 100, 2))  AS rate_pct,
  -- 集中度 = 事件 / 受影响安装。9 次崩溃影响 1 台设备（集中度 9.0）与 14 次影响 7 台（2.0），
  -- 严重度完全不同，而只看事件数两者长得一样。
  ROUND(c.events / NULLIF(c.users, 0), 1)                            AS concentration
FROM c LEFT JOIN s USING(dim)
  -- 并列时补确定性 tie-breaker，否则两次跑批行序会互换（见 crash-issues.sql 同处注释）
ORDER BY c.users DESC, c.events DESC, c.dim
LIMIT {{LIMIT}}
-- ⛔ **不在 SQL 里按样本量过滤**（2026-08-22 实测后改）：Android 机型碎片化到无法过滤——
-- 该版本 7 天内最大的机型桶只有 75 个会话，门槛设 50 只剩 1 行、设 100 一行不剩，
-- 维度整个消失；而设 20 留下的 `OPPO CPH2591 26.09%`（46 会话）在统计上毫无意义。
-- 结论：**两个维度的率可靠性完全不同**——
--   · 系统版本：桶大（实测 2657 / 1221 / 715 会话），率可靠，**给率**；
--   · 机型：桶小（最大 75），率不可靠，**给绝对数 + 影响安装 + 集中度**，
--     率列由渲染层在 sessions < {{MIN_SESSIONS}} 时替换为「样本不足」，
--     并标注「未除以装机量，不代表该机型更易崩」。
-- 过滤放在渲染层而不是 SQL：过滤掉就看不见影响面了，而影响面（users）恰恰是机型维度的价值所在。
