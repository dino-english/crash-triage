## 1. 先验 iOS（本 change 的实测数据全来自 Android）

- [x] 1.1 iOS 实测完成（2026-08-22，30 天窗）：FATAL 4 事件 / 4 会话；`firebase_session_id` 覆盖 **4/4 = 100%**；
      `session_id` JOIN 命中 3/4（样本太小无统计意义）；**`installation_uuid` ↔ `instance_id` 同样 0 匹配**——
      确认用户率不可得是系统性的，不是 Android 个例。总会话 4779，crash-free 会话率 ≈ 99.92%
- [x] 1.2 iOS 覆盖率与 Android 一致（均近 100%），无需额外标注；但 **iOS 崩溃样本极小**（30 天仅 4 条），
      crash-free 会长期显示 ~99.9%，读数意义有限——由既有的 `SAMPLE_SESSION_MIN` 小样本提示兜底即可

## 2. SQL

- [x] 2.1 ~~新建 `crash-free-sessions.sql`~~ → **改为给 `crash-rate.sql` 加一列 `crash_sessions`**：该文件本就同时查两张表，加一个标量子查询即可，**零额外查询**。原文：新建 `bin/sql/crash-free-sessions.sql`：`COUNT(DISTINCT firebase_session_id)` WHERE `error_type='FATAL'` + 版本过滤（嵌套 `application.display_version`）+ 窗口
- [x] 2.2 **不写 JOIN**（design D1）——分母复用现有 `sessions-by-version.sql` 的会话数。JOIN 会让 83.9% 的命中率变成误差并**高估** crash-free，方向最坏
- [x] 2.3 手工验证：`sed` 替换占位符喂 `bq query`，Android 近 7 天结果应接近 崩溃会话 61 / 总会话 8498 → 99.28%
- [x] 2.4 `bin/sql/README.md` 增说明

## 3. 渲染与阈值

- [x] 3.1 阈值常量 `CRASH_FREE_RED=99.0` / `CRASH_FREE_YELLOW=99.5`
- [x] 3.2 ✅ **阈值方向已处理**：不改 `traffic_light()`（`crash-perf-functional-core` 还要把它移进核心层），改为**用坏方向值判定、好方向值展示**——判定传「崩溃会话率」与 `100 − 阈值`，展示 crash-free。原文：阈值方向反转（design D4）：`traffic_light()` 现有语义是「大于红线 → red」，crash-free 越大越好。**直接套用会把 100% 判成红档，且不会报错、只会安静地把最健康的版本标红**。传入 `100 − 值` 或给函数加方向参数
- [x] 3.3 版本对照表增行「Crash-free 会话率」，对比列方向 `higher_better`
- [x] 3.4 既有「崩溃率 = 事件数/会话数」行**保持不动**（spec 要求两者并存，历史序列不能断）
- [x] 3.5 L2 主力版本表增列
- [x] 3.6 `metrics-history.jsonl` 增字段；旧行按「无数据」处理

## 4. 标注（与数字同时上线，缺一不可）

- [x] 4.1 报告与卡片口径行标注：本值为**会话**口径，与控制台首屏的**用户**口径不同，**不可直接对照**
- [x] 4.2 标注本值为**下界估计**，真实值不低于所示数字（design D1 的失真方向）
- [x] 4.3 口径说明中写明 crash-free 用户率不可得及其原因：两个数据源的用户标识不同源（`installation_uuid` 64 字符十六进制 vs `instance_id` 22 字符 base64url，实测 JOIN 匹配 0 行）
- [x] 4.4 **不可得时逐种情形各自注明原因**（spec 新增要求），四种情形文案不可混用：
  - 用户率不可得 → 「两个数据源用户标识不同源，无法关联」（永久性说明）
  - 分母为零 → 「无法计算（该版本窗口内无会话）」。⛔ **不得呈现 100%**——零崩溃除以零会话不是「完全干净」
  - 数据源未同步 → 走既有缺数三态（表未同步 / 数据未同步）
  - 有会话且零崩溃 → 呈现 100%，这是结论不是缺数；会话数低于 `SAMPLE_SESSION_MIN` 时附小样本提示
- [x] 4.5 ⛔ **不得以会话率冒充用户率**——包括在任何简称、图例、卡片缩写中写成「Crash-free」而不带口径

## 5. 验证

- [x] 5.1 `bash bin/check-scripts.sh` 通过
- [x] 5.2 阈值方向验证 ✅ 四个值全部符合预期：100%→green（**不是 red**）、99.6%→green、99.2%→yellow、98%→red
- [x] 5.3 L1 整跑 ✅：iOS 100.00% (0/2141)、Android 1.5.3 **99.64%** (24/6387)、1.5.1 **97.96%**、1.5.4 94.29% (2/35)。量级符合预期
- [x] 5.4 既有崩溃率三行未受影响：`crash-rate.sql` 只**新增**一个标量子查询列，三条原有列的 SQL 一字未动
- [x] 5.5 `CRASH_REPORT_NO_DELIVER=1 CRASH_REPORT_SKIP_ANALYSIS=1 bash bin/crash-weekly.sh` 整跑

## 6. 收尾

- [x] 6.1 `CLAUDE.md` 的「数据口径」更新：删掉「crash-free 需 session 级关联，**未做**」这句（前提已变），改为记录 crash-free 会话率的算法、两条限制、以及**用户率为何不可得**
- [x] 6.2 记录本 change 的实测数据（覆盖率、命中率、ID 格式对比），供将来复查
