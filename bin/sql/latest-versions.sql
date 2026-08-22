-- 版本清单解析（日报唯一版本源）：返回窗口内各 display_version 的会话数 / 设备数。
--
-- 为什么用 sessions 而不是 crashlytics / performance：sessions REALTIME 是「线上正在跑什么版本」
-- 的活源，另两张表回答的是「这些版本出了什么事」。实测 2026-08-17：sessions 已有 1.5.4（383 会话），
-- crashlytics 一条 1.5.4 事件都没有，performance 批量表只有 199 条——各段各自解析版本必然错位。
--
-- 这里不排序、不 LIMIT：版本号语义排序（1.5.10 > 1.5.9）BigQuery 无原生支持，
-- 在 SQL 里拆数字段落既啰嗦又易错，交给脚本 `sort -V`（仓库既有做法）。
-- **不设会话数门槛**（2026-08-22 起）：门槛会把**刚开始放量或已被叫停的新版**静默剔除——
-- 而那恰恰是最该盯的时刻。实测 Android 1.5.4 停止上报后（1d 会话 1 个），
-- 报告的「最新 2 版」自动滑到 1.5.3/1.5.1，**卡片上一个字都没说 1.5.4 存在过**。
-- 小样本由渲染层的 SAMPLE_SESSION_MIN 打「⚠️」提示，**标出来而不是藏起来**。
--
-- ⚠️ 残余风险：版本号更高的内测/灰度包（哪怕只有 1 个会话）会成为「最新版」并占据报告。
-- 这是刻意接受的——一个内测包出现在线上数据里，本身就是要看见的事。
SELECT
  application.display_version                AS version,
  COUNT(DISTINCT session_id)                 AS sessions,
  COUNT(DISTINCT instance_id)                AS devices
FROM `{{TABLE}}`
WHERE event_timestamp >= TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL {{DAYS}} DAY)
  AND application.display_version IS NOT NULL
GROUP BY version
