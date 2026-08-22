-- 崩溃归因分布：责任帧属于谁（自家代码 / 三方 SDK / 系统），以及被归因的代码库。
--
-- ⚠️ **owner 与 library 必须一起看，任一列单独看都会得出错误结论**（design D1）。
-- 实测 Android 近 7 天最有信息量的一行是：
--     SYSTEM · com.prime.dino.english · 47 事件 / 30 安装
-- 归因方是「系统」，被归因的库却是**自家包名**——那是系统帧被自家代码调用。
-- 只看 owner 会读成「系统的问题，与我无关」；只看 library 会读成「自家代码崩了」。两者都不对。
--
-- ⛔ **owner 标识的是崩溃栈中被判定为责任帧的那一帧属于谁，不是「谁触发了这次崩溃」。**
-- 报告不得因 owner 是 SYSTEM / THIRD_PARTY 就表述为「非自家问题」或「无需处理」。
--
-- 未归因（owner 为 NULL）归入显式类目而非丢弃——静默丢弃会让分布的总数对不上事件总数。
SELECT
  IFNULL(blame_frame.owner,   '(未归因)')      AS owner,
  IFNULL(blame_frame.library, '(未知库)')      AS library,
  COUNT(*)                                     AS events,
  COUNT(DISTINCT installation_uuid)            AS users
FROM `{{TABLE}}`
WHERE error_type IN ('FATAL', 'ANR')
  AND application.display_version IN ({{VERSIONS}})
  AND event_timestamp >= TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL {{DAYS}} DAY)
GROUP BY owner, library
  -- 并列时补确定性 tie-breaker，否则两次跑批行序会互换（见 crash-issues.sql 同处注释）
ORDER BY users DESC, events DESC, owner, library
LIMIT {{LIMIT}}
