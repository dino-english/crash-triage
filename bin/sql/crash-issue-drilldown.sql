-- 单个 issue 的多维下钻：每个 issue × 每个维度取占比最高的那个取值，附该维度的取值基数与 issue 总量。
-- 供「TOP N 事件下钻」块使用，回答「这个 issue 影响谁、集中在哪」。
--
-- 输出一行一个 (issue_id, dim, value, events, users, n_distinct, total_events, total_users)：
--   dim ∈ screen / model / os / mem / fgbg / blame
--   n_distinct = 该 issue 在该维度上的**取值基数**——⛔ 这一列是「机型是不是噪音」的唯一判据，
--     不可省：实测 per-issue 的唯一机型数 ≈ 影响安装数（一设备一机型），
--     此时「top 机型」等于随机挑了一台设备当结论。占比 19%–33% 与 100% 必须能分开。
--
-- ⚠️ `{{ERROR_TYPES}}` 按端给：Android `'FATAL','ANR'`，iOS `'NON_FATAL'`
--    （实测 iOS 60 天仅 5 次致命崩溃，按致命口径这里出不来三个 issue）。
-- ⚠️ **本文件自己选 top N**（`{{TOP_N}}`），不从外部灌 issue id——外部灌意味着上游要先跑一次
--    issue 聚合，而 L2 快照只有 FATAL（`crash-issues-all.sql` 带 is_fatal 过滤），
--    **ANR 整个不在里面**。实测 Android 按受影响安装排第一的恰恰是个 ANR
--    （`15c1049c` 21 事件 / 14 安装，比任何 FATAL 都大）——从快照取 id 会让它消失。
-- ⛔ 排序按**受影响安装**降序，与 `crash-issues.sql` 及台账口径一致：
--    「排在第一位的会被当成最该修的，排序口径直接改变读者行为」。
--    ⚠️ 不按集中度排——集中度 = 事件/安装，分母越小值越大，按它排会选出一个全是单设备的榜单
--    （实测集中度 top3 的受影响安装数全是 1）。
-- ⛔ 输出含机型（`iPad7,11` 自带逗号）与责任帧库名，**解析必须走 csv2tsv**，裸 awk -F, 会错列。
--
-- ⚠️ 各维度占比的分母是**该 issue 的事件数**，⛔ 不是该维度的崩溃率——
--    页面 / 前后台 / 内存档都没有会话分母（sessions 表无对应字段）。
--    占比高只说明「这个 issue 集中在这里」，不说明「这里更容易崩」。
WITH src AS (
  SELECT *
  FROM `{{TABLE}}`
  WHERE error_type IN ({{ERROR_TYPES}})
    AND application.display_version IN ({{VERSIONS}})
    AND event_timestamp >= TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL {{DAYS}} DAY)
), top AS (
  -- ⛔ title 与 subtitle **都要给，由渲染层组合**——两者互补且各自都可能是噪音：
  --    · iOS NON_FATAL：title 恒为 Crashlytics SDK 包装帧（零区分度），信息在 subtitle
  --    · Android ANR：subtitle 恒为 `Root cause for this ANR is unknown`（占位噪音），信息在 title
  --    · Android FATAL：title = 崩溃位置，subtitle = 异常类型，**合起来才完整**
  --    ⚠️ 任选其一都会在某一类上丢信息——2026-08-24 首版只取 subtitle，把那条 ANR 的标题
  --    渲染成了「Root cause for this ANR is unknown」。
  SELECT issue_id,
         APPROX_TOP_COUNT(issue_title, 1)[OFFSET(0)].value    AS title,
         APPROX_TOP_COUNT(IFNULL(issue_subtitle, ''), 1)[OFFSET(0)].value AS subtitle
  FROM src GROUP BY issue_id
  ORDER BY COUNT(DISTINCT installation_uuid) DESC, COUNT(*) DESC, issue_id
  LIMIT {{TOP_N}}
), e AS (
  SELECT
    src.issue_id,
    installation_uuid,
    IFNULL(NULLIF((SELECT value FROM UNNEST(custom_keys) WHERE key = 'current_screen' LIMIT 1), ''), '(未知)') AS d_screen,
    IFNULL(NULLIF(CONCAT(device.manufacturer, ' ', device.model), ' '), '(未知)')                              AS d_model,
    IFNULL(NULLIF(operating_system.display_version, ''), '(未知)')                                             AS d_os,
    IFNULL(NULLIF((SELECT value FROM UNNEST(custom_keys) WHERE key = 'mem_tier' LIMIT 1), ''), '(未知)')       AS d_mem,
    IFNULL({{FG_NORM}}, '(未知)')                                                                              AS d_fgbg,
    IFNULL(NULLIF(CONCAT(blame_frame.owner, ' · ', blame_frame.library), ' · '), '(未知)')                     AS d_blame,
    -- 业务场景（自埋）。⚠️ iOS 的 issue_title 恒为 108 字符的 SDK 包装帧、三条 issue 逐字相同，
    -- 而 scene 实测覆盖 99.7%、4 个取值、与 issue 近 1:1——把 190 字符压到 20 字符且是业务语义。
    -- ⚠️ Android 侧覆盖率仅 52% 且只有单一取值，渲染层对 Android 不用它。
    IFNULL(NULLIF((SELECT value FROM UNNEST(custom_keys) WHERE key = 'scene' LIMIT 1), ''), '(未知)')          AS d_scene
  FROM src JOIN top USING (issue_id)
), tot AS (
  SELECT issue_id, COUNT(*) AS total_events, COUNT(DISTINCT installation_uuid) AS total_users
  FROM e GROUP BY issue_id
), long AS (
  SELECT issue_id, 'screen' AS dim, d_screen AS v, installation_uuid FROM e
  UNION ALL SELECT issue_id, 'model', d_model, installation_uuid FROM e
  UNION ALL SELECT issue_id, 'os',    d_os,    installation_uuid FROM e
  UNION ALL SELECT issue_id, 'mem',   d_mem,   installation_uuid FROM e
  UNION ALL SELECT issue_id, 'fgbg',  d_fgbg,  installation_uuid FROM e
  UNION ALL SELECT issue_id, 'blame', d_blame, installation_uuid FROM e
  UNION ALL SELECT issue_id, 'scene', d_scene, installation_uuid FROM e
), agg AS (
  SELECT issue_id, dim, v, COUNT(*) AS events, COUNT(DISTINCT installation_uuid) AS users
  FROM long GROUP BY issue_id, dim, v
), ranked AS (
  SELECT *,
    -- 并列时按取值名排序补确定性 tie-breaker，否则两次跑批选出的 top 会互换
    ROW_NUMBER() OVER (PARTITION BY issue_id, dim ORDER BY events DESC, users DESC, v) AS rn,
    COUNT(*)     OVER (PARTITION BY issue_id, dim)                                     AS n_distinct
  FROM agg
)
SELECT r.issue_id, tp.title, tp.subtitle, r.dim, r.v, r.events, r.users, r.n_distinct, t.total_events, t.total_users
FROM ranked r
JOIN tot t  USING (issue_id)
JOIN top tp USING (issue_id)
WHERE r.rn = 1
-- 行序：issue 按受影响安装降序（与 top 的排序一致），维度按可行动性排（页面最前）
ORDER BY t.total_users DESC, t.total_events DESC, r.issue_id,
         CASE r.dim WHEN 'scene' THEN 0 WHEN 'screen' THEN 1 WHEN 'fgbg' THEN 2 WHEN 'model' THEN 3
                    WHEN 'os' THEN 4 WHEN 'mem' THEN 5 ELSE 6 END
