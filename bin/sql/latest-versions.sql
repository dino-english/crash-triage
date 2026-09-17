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
  COUNT(DISTINCT instance_id)                AS devices,
  -- 内部构建判据（2026-09-17）。⛔ **不在 SQL 里按平台分叉**：同一份 SQL 双端共用，
  -- 各自跑出该端可用的那一列，由渲染层决定用哪条（与 crash-rate.sql 的 affected_users 同构）。
  --  · iOS 用 devs_perf_on：上架包采集全开、内部 adhoc 包全关（实测 30 天双向干净）。
  --    ⚠️ Android 该字段恒 false，这一列在 Android 上恒为 0，⛔ 不可据此判 Android。
  --  · Android 用 max_build_tail3：versionCode = 版本号基数 + CI 分配的 build number
  --    （见业务仓 build_config.yml 的 version_code_from_version_name），末三位 000 = 未过 CI 的本地包。
  --    ⚠️ SAFE_CAST：iOS 的 build_version 形如 1.8.0.28 不是整数，转不动返回 NULL，正合预期。
  --    ⛔ 它只分得出「本地包 vs CI 包」，分不出「内部分发 vs 上架」——实测 1.6.0 的 160015~160019
  --    都是 CI 包却只有 3~9 台设备。故仅用于**标注**，⛔ 不可用来过滤版本。
  COUNT(DISTINCT IF(performance_data_collection_enabled, instance_id, NULL)) AS devs_perf_on,
  MAX(MOD(SAFE_CAST(application.build_version AS INT64), 1000))              AS max_build_tail3
FROM `{{TABLE}}`
WHERE event_timestamp >= TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL {{DAYS}} DAY)
  AND application.display_version IS NOT NULL
GROUP BY version
