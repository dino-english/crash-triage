-- GA4 导出表是否存在（change crash-tech-diagnostics）：只读元数据，扫描 0 字节（2026-11-26 dry-run 实测）。
-- 占位符：{{TABLE_IDS}} = 带引号的表名列表，如 'events_20261125','events_intraday_20261125'
-- 用途：外壳层按 UTC 日选表（core/diag.sh 的 diag_pick_suffix：日表优先，⛔ 同日两张不能都读）。
SELECT table_id
FROM `dino-english-497507.analytics_538991439.__TABLES__`
WHERE table_id IN ({{TABLE_IDS}})
