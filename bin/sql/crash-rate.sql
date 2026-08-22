-- 崩溃率 = 崩溃事件数（firebase_crashlytics 分子）/ 会话数（firebase_sessions 分母）。
-- 受影响安装数 = COUNT(DISTINCT installation_uuid)，is_fatal=TRUE 且窗口内（与分子同表同窗口，口径一致）。
--
-- 口径：事件数 / 会话数（非 crash-free 精确口径）。
--
-- **crash-free 会话率一并取出**（2026-08-22 起）：分子是崩溃会话数 `COUNT(DISTINCT firebase_session_id)`，
-- 分母复用同一句里的会话数。**刻意不做 JOIN**：实测 crashlytics 的 session_id 只有 83.9% 能在
-- sessions 表里找到对应会话，JOIN 会让那 16% 的崩溃会话从分子里消失、**高估** crash-free——
-- 而高估是最坏的方向（报告说「99.4% 干净」实际更低）。两表各自按版本过滤即可，不 JOIN 则
-- 失真方向变成**低估**（分子可能含分母外的会话），保守可接受，渲染层标注为「下界估计」。
--
-- ⛔ **crash-free 用户率做不了**：`crashlytics.installation_uuid`（64 字符十六进制）与
-- `sessions.instance_id`（22 字符 base64url）是两个 ID 体系，实测 JOIN 匹配 **0 行**。
-- 而 Firebase 控制台首屏给的正是**用户**率——两者数值不同（用户率通常更低），**不可直接对照**。
-- 分子分母都用 {{DAYS}} 窗口，保证可比。
-- 受影响安装数（installation_uuid）≠ session_id ≠ user.id：Android 不上报 user.id，
-- session 与 installation 是两套 ID，此处只统计安装维度，不做 crash-free 用户率（缺可靠总用户分母）。
SELECT
  (SELECT COUNT(*)
     FROM `{{TABLE}}`
    WHERE is_fatal = TRUE
      AND application.display_version IN ({{VERSIONS}})
      AND event_timestamp >= TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL {{DAYS}} DAY)) AS crash_events,
  (SELECT COUNT(DISTINCT session_id)
     FROM `{{SESSIONS_TABLE}}`
    WHERE application.display_version IN ({{VERSIONS}})
      AND event_timestamp >= TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL {{DAYS}} DAY)) AS sessions,
  (SELECT COUNT(DISTINCT installation_uuid)
     FROM `{{TABLE}}`
    WHERE is_fatal = TRUE
      AND application.display_version IN ({{VERSIONS}})
      AND event_timestamp >= TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL {{DAYS}} DAY)) AS affected_installs,
  -- crash-free 的分子。**只计致命崩溃**（与行业既有 crash-free 定义一致；ANR 有自己的率）。
  -- 同一会话内崩多次只计一次——这正是它与「事件数/会话数」互补的地方。
  (SELECT COUNT(DISTINCT firebase_session_id)
     FROM `{{TABLE}}`
    WHERE is_fatal = TRUE
      AND firebase_session_id IS NOT NULL AND firebase_session_id != ''
      AND application.display_version IN ({{VERSIONS}})
      AND event_timestamp >= TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL {{DAYS}} DAY)) AS crash_sessions
