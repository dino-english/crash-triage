-- 崩溃 → 模块归属的信号（change crash-owner-mention）。⛔ 只取数不判定——判定在 bin/lib/core/owner.sh。
--
-- 每个 issue 一行：
--   owner / symbol / file / library —— 该 issue **最近一次事件**的责任帧（同 issue 的责任帧几乎恒定）
--   screen —— custom key current_screen 在该 issue 事件里的众数（空值不计；并列取字典序最小，结果稳定）
--
-- 占位符：TABLE = crashlytics 表全名；DAYS = 窗口天数；IDS = 逗号分隔、带双引号的 32 位 issue id
--         （调用方已校验十六进制，只替换值）。⚠️ 注释里不写占位符的花括号字面量（F56）。
WITH e AS (
  SELECT issue_id, event_timestamp AS t, blame_frame AS bf,
         (SELECT ck.value FROM UNNEST(custom_keys) ck WHERE ck.key = 'current_screen' LIMIT 1) AS scr
  FROM `{{TABLE}}`
  WHERE issue_id IN ({{IDS}})
    AND event_timestamp >= TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL {{DAYS}} DAY)
),
b AS (
  SELECT issue_id,
         ARRAY_AGG(STRUCT(CAST(bf.owner AS STRING) AS owner, bf.symbol AS symbol, bf.file AS file, bf.library AS library)
                   ORDER BY t DESC LIMIT 1)[OFFSET(0)] AS f
  FROM e GROUP BY issue_id
),
s AS (
  SELECT issue_id, ARRAY_AGG(scr ORDER BY n DESC, scr LIMIT 1)[OFFSET(0)] AS screen
  FROM (SELECT issue_id, scr, COUNT(*) AS n FROM e WHERE scr IS NOT NULL AND scr != '' GROUP BY issue_id, scr)
  GROUP BY issue_id
)
SELECT b.issue_id, b.f.owner AS owner, b.f.symbol AS symbol, b.f.file AS file, b.f.library AS library, s.screen
FROM b LEFT JOIN s USING (issue_id)
