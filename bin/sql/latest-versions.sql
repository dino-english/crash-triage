-- 版本清单解析（日报唯一版本源）：返回窗口内各 display_version 的会话数 / 设备数。
--
-- 为什么用 sessions 而不是 crashlytics / performance：sessions REALTIME 是「线上正在跑什么版本」
-- 的活源，另两张表回答的是「这些版本出了什么事」。实测 2026-08-17：sessions 已有 1.5.4（383 会话），
-- crashlytics 一条 1.5.4 事件都没有，performance 批量表只有 199 条——各段各自解析版本必然错位。
--
-- 这里不排序、不 LIMIT：版本号语义排序（1.5.10 > 1.5.9）BigQuery 无原生支持，
-- 在 SQL 里拆数字段落既啰嗦又易错，交给脚本 `sort -V`（仓库既有做法）。
-- {{MIN_SESSIONS}} 滤掉噪声版本（个位数会话的灰度/内测残留），门槛由脚本常量控制。
SELECT
  application.display_version                AS version,
  COUNT(DISTINCT session_id)                 AS sessions,
  COUNT(DISTINCT instance_id)                AS devices
FROM `{{TABLE}}`
WHERE event_timestamp >= TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL {{DAYS}} DAY)
  AND application.display_version IS NOT NULL
GROUP BY version
HAVING sessions >= {{MIN_SESSIONS}}
