-- 版本放量：按 app 版本统计会话数与设备数。
--
-- 用途：判断「新版本样本量够不够下结论」。崩溃数为 0 可能是修好了，也可能是没人用——
-- 没有这个分母就分不清。修复验证的判定线（如「累计 N 会话仍 0 崩溃才算生效」）依赖它。
--
-- 注意：这是 sessions 表不是 crashlytics 表，两者独立同步，可能有时间差。
--
-- 本文件**刻意不加版本过滤占位符**（与其余 8 个 SQL 相反）：日报正文的放量明细要回答
-- 「盘子里还剩多少旧版本」，过滤掉就看不见了。卡片与核心指标走版本过滤，此表须显式标注全版本口径。
-- 版本清单解析请用 latest-versions.sql，不要复用本文件（本文件的 LIMIT 6 是按会话量截断，会漏掉刚放量的新版本）。
SELECT
  application.display_version                            AS version,
  COUNT(DISTINCT session_id)                             AS sessions,
  COUNT(DISTINCT instance_id)                            AS devices,
  FORMAT_TIMESTAMP('%Y-%m-%d', MAX(event_timestamp))     AS latest
FROM `{{TABLE}}`
WHERE event_timestamp >= TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL {{DAYS}} DAY)
GROUP BY version
HAVING sessions >= 5
ORDER BY sessions DESC
LIMIT 6
