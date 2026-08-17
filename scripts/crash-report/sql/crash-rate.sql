-- 崩溃率 = 崩溃事件数（firebase_crashlytics 分子）/ 会话数（firebase_sessions 分母）。
-- 受影响安装数 = COUNT(DISTINCT installation_uuid)，is_fatal=TRUE 且窗口内（与分子同表同窗口，口径一致）。
--
-- 口径：事件数 / 会话数（非 crash-free 精确口径）。crash-free 需 session 级关联
-- （firebase_crashlytics.firebase_session_id ↔ firebase_sessions.session_id），留待后续。
-- 分子分母都用 {{DAYS}} 窗口，保证可比。
-- 受影响安装数（installation_uuid）≠ session_id ≠ user.id：Android 不上报 user.id，
-- session 与 installation 是两套 ID，此处只统计安装维度，不做 crash-free 用户率（缺可靠总用户分母）。
SELECT
  (SELECT COUNT(*)
     FROM `{{TABLE}}`
    WHERE is_fatal = TRUE
      AND event_timestamp >= TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL {{DAYS}} DAY)) AS crash_events,
  (SELECT COUNT(DISTINCT session_id)
     FROM `{{SESSIONS_TABLE}}`
    WHERE event_timestamp >= TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL {{DAYS}} DAY)) AS sessions,
  (SELECT COUNT(DISTINCT installation_uuid)
     FROM `{{TABLE}}`
    WHERE is_fatal = TRUE
      AND event_timestamp >= TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL {{DAYS}} DAY)) AS affected_installs
