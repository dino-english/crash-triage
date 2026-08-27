-- NON_FATAL（非致命异常）issue 聚合。结构对齐 crash-issues.sql，两处刻意不同：
--
-- ① **必须取 issue_subtitle**（2026-08-22 实测后加）：
--    iOS 的 NON_FATAL `issue_title` **恒为 Crashlytics SDK 的包装帧**
--    （`FIRCLSNonFatalError.m - -[FIRCLSNonFatalError initWithError:...]`），三条 top issue 标题一模一样、
--    毫无区分度；真正的信息全在 subtitle（`DinoEnglishKit.SafeDecodeFallback (1)` / `com.apple.coreaudio.avfaudio (-50)`）。
--    Android 两者互补：title 是位置（`MicrosoftRecognizer.releaseRecognizerLocked`）、
--    subtitle 是异常类型（`java.util.concurrent.TimeoutException`）。
--    故两列都出，由渲染层分列呈现——不做「哪个更有用」的启发式判断。
--
-- ② **一个 issue_id 可能对应多个 subtitle**（实测 iOS 同一 issue 有 3 个错误码变体）。
--    仍按 issue_id 分组（台账的追踪单位是 issue_id），subtitle 取**出现最多的那个**。
--    ⚠️ 不用 ANY_VALUE：它可能挑中一个只出现 1 次的边缘变体，让读者以为那是主要形态。
--
-- ⚠️ 两端数量级不可比：非致命异常由客户端主动上报（recordError / recordException），
-- 覆盖多少全看埋了多少收口点。实测 7 天内 iOS 1.5.3 有 618 条、Android 1.5.3 有 56 条，
-- 几乎肯定是收口点覆盖差异而非异常量差异——渲染处必须标注。
--
-- users 一并取出：台账的 NON_FATAL 现状表按影响面截断取 top N，需要它做排序依据。
SELECT
  issue_id                                                             AS issue_id,
  ANY_VALUE(issue_title)                                               AS title,
  APPROX_TOP_COUNT(issue_subtitle, 1)[SAFE_OFFSET(0)].value            AS subtitle,
  COUNT(*)                                                             AS n,
  COUNT(DISTINCT installation_uuid)                                    AS users,
  FORMAT_TIMESTAMP('%Y-%m-%d %H:%M UTC', MAX(event_timestamp))         AS latest
FROM `{{TABLE}}`
WHERE error_type = 'NON_FATAL'
  -- ⚠️ 下一行的占位符收的是**整条谓词**，不是只替换值：
  --   · 日报按版本分列 → 传 `AND application.display_version IN ("1.5.4")`
  --   · 台账跨版本追踪 → 传**空串**，⛔ 加了过滤会让「上一版修好、这版没复发」的 issue
  --     从现状表凭空消失、时间线断档。
  -- ⛔ 原来是「值占位符 + 台账侧用 sed 把整行删掉」——那种写法把「故意不过滤」藏在一条
  --    sed 表达式里，且绕过了 q_render 的漏传检查（change crash-lib-consolidation 3.5）。
  -- ⚠️ 注释里**不要写占位符字面量**：q_render 是全文字面替换，会把注释里那处也换掉。
  {{VER_FILTER}}
  AND event_timestamp >= TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL {{DAYS}} DAY)
GROUP BY issue_id
  -- 并列时补确定性 tie-breaker，否则两次跑批行序会互换（见 crash-issues.sql 同处注释）
ORDER BY users DESC, n DESC, issue_id
LIMIT {{LIMIT}}
