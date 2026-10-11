-- 启动 P95 红灯下钻：`_app_start` 按系统版本分桶（change crash-report-attention-tiers，design D5）。
--
-- 为什么按系统版本、不按机型：机型太碎——2026-10-11 实测 Android 1.8.2 慢启动最多的机型只有 7 次，
-- 单机型 4–15 个样本，P95 ≈ 最大值。`_app_start` 没有 custom_attributes（同日实查 0 行），内存档位取不到。
-- 分桶用主版本号：Android 的 os_version 是 API level（36/35/…），iOS 是「26.0.1」形式，取点号前一段。
-- {{SLOW_MS}} = 启动 P95 红线（毫秒），用来数「慢启动」次数——桶的 P95 在 n<20 时退化成最大值，
-- 慢启动计数不受此影响，结论句用它。⛔ 桶的 P95 是否呈现由调用方按样本闸门决定，这里照实输出。
SELECT
  SPLIT(os_version, '.')[SAFE_OFFSET(0)]                                         AS os_major,
  COUNT(*)                                                                       AS n,
  ROUND(APPROX_QUANTILES(trace_info.duration_us, 100)[OFFSET(95)] / 1000, 0)     AS p95_ms,
  COUNTIF(trace_info.duration_us > {{SLOW_MS}} * 1000)                           AS slow
FROM `{{TABLE}}`
WHERE event_type = 'DURATION_TRACE'
  AND event_name = '_app_start'
  AND app_display_version IN ({{VERSIONS}})
  AND DATE(event_timestamp) BETWEEN '{{LCD_START}}' AND '{{LCD_END}}'
GROUP BY os_major
ORDER BY SAFE_CAST(os_major AS INT64) DESC
