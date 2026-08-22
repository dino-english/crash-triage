## 1. SQL

- [x] 1.1 ~~新建 `crash-anr.sql`~~ → **合并为 `crash-error-types.sql`**（一次查询同时取 ANR 与 NON_FATAL 的事件数与安装数）。理由：分开会让每版本每端多一次 bq 调用，整跑本已 5 分钟以上。原文：新建 `bin/sql/crash-anr.sql`：`error_type = 'ANR'`，按版本聚合事件数与 `COUNT(DISTINCT installation_uuid)`，占位符沿用 `{{TABLE}}` / `{{DAYS}}` / `{{VERSIONS}}`（crashlytics 系版本路径是嵌套 `application.display_version`，勿套用 perf 系的顶层路径）
- [x] 1.2 新建 `bin/sql/crash-nonfatal-issues.sql`。⚠️ **实施中发现必须加 `issue_subtitle`**：iOS 的 NON_FATAL `issue_title` 恒为 Crashlytics SDK 包装帧，三条 top issue 标题完全相同、零区分度；信息全在 subtitle。Android 两者互补（title=位置、subtitle=异常类型），故两列都出。同一 issue_id 多 subtitle 时取 `APPROX_TOP_COUNT` 头部，不用 `ANY_VALUE`。原文：新建 `bin/sql/crash-nonfatal.sql`：`error_type = 'NON_FATAL'`，按版本聚合事件数 + TOP issue（`issue_id` / `issue_title` / 事件数 / 最新时间），`LIMIT` 沿用 `{{LIMIT}}`
- [x] 1.3 更新 `crash-issues.sql` 与 `crash-issues-all.sql` 的注释：`is_fatal = TRUE` 的理由从「与 topIssues 的 FATAL 过滤一致」（已失效——topIssues 已不是数据源）改为「刻意只取 FATAL，ANR 与 NON_FATAL 由 crash-anr.sql / crash-nonfatal.sql 覆盖」，并注明 `is_fatal=TRUE ⟺ error_type='FATAL'`
- [x] 1.4 `bin/sql/README.md` 增两行说明
- [x] 1.5 两条新 SQL 手工验证：按 CLAUDE.md 的 `sed` 替换占位符喂 `bq query`，双端各跑一次，数值与本 change proposal 里的实测表对得上

## 2. L1 日报：取数与渲染

- [x] 2.1 阈值常量：`ANR_RATE_RED=0.47` / `ANR_RATE_YELLOW=0.24`。⚠️ 注释必须写明「0.47 参考 Play 门槛，但**我们的分母是会话数、Play 是日活用户**，口径不同；取此值是因为没有更好的锚且宁可偏严」（design D4）——不写会让下一个人以为已对齐
- [x] 2.2 `collect_window()` 增 ANR 与 NON_FATAL 取数，落进 `$TMP/m-<key>.json`
- [x] 2.3 版本对照表增行：`anr_count`（ANR 次数）/ `anr_rate`（ANR 率）/ `nonfatal_count`（非致命次数）。**崩溃三行不动**
- [x] 2.4 `cell()` / `delta_of()` 增对应分支；ANR 率走 `cell_color`，对比列 `lower_better`
- [x] 2.5 **iOS 的 ANR 两行渲染成「无此概念 · 见冻结率」**，不是 `—`、不是 `0`（design D3）。⚠️ 这两个错误填法各自会被读成「数据没取到」与「iOS 没有卡死问题」
- [x] 2.6 摘要行：ANR 红档进 `red_line()`，**只呈现 Android 一端**，不给 iOS 补占位值（沿用既有「无值的端降级成括注」逻辑，但 iOS 这里连括注都不要——它不是「无数据」）
- [x] 2.7 明细段增 NON_FATAL TOP issue 表（双端分列）
- [x] 2.8 **删除 `crash-daily.sh:1197` 的静态文案**，改为按实测渲染。⚠️ **保留其中「两端数字暂不可比」的语义**，只去掉已失实的「线上仍为零上报」（design D5）——那行里唯一还成立的部分就是不可比
- [x] 2.9 NON_FATAL 并列处标注两端收口点覆盖差异（iOS 1020 vs Android 131 差 7.8 倍，几乎肯定是埋点覆盖差异不是异常量差异）
- [x] 2.10 ANR 率呈现处标注分母与窗口，并写明与 Play Console 口径不同、不可直接对照门槛判定（design D2，spec 的硬要求）

## 3. L2 周报

- [x] 3.1 主力版本表增 ANR 事件数与 ANR 率列
- [x] 3.2 `crash-issues-all.sql` 侧同步：周报的 NON_FATAL 呈现（是否含 TOP issue 视版面，至少给事件量）
- [x] 3.3 口径段补充 ANR 与 NON_FATAL 的分母与限制说明

## 3b. L2 台账（已拍板：NON_FATAL 进台账）

- [x] 3b.1 台账「Issue 现状表」拆为两张：FATAL 现状表（保持原样）+ **NON_FATAL 现状表**（design D7）
- [x] 3b.2 NON_FATAL 表**按受影响安装数取 top 10**，表下标注「共 M 条，按影响面取前 10」。⚠️ **不截断则 iOS 的 1020 条会淹没 FATAL 的十几条，台账直接不可用**——截断不是打折执行，是让决策可用
- [x] 3b.3 `sync_ledger()` 增一次标题定位（「NON_FATAL 现状表」），走 `block_replace`。⚠️ 标题定位取**最后一个**匹配——正文可能有同名文字的引用块（2026-08-20 因此把四段结构重复 append 两遍）
- [x] 3b.4 `render-ledger.sh` 产出该表；本地源 `LEDGER.md` 同步新增该段
- [ ] 3b.5 台账同步验证：确认 FATAL 表未被扰动、NON_FATAL 表正确替换、时间线历史未丢失（全程不得 overwrite）。
  **闸门已收窄，现在开发机可验**（findings F4 后续）——原闸门「非群一律不同步」改为「非群**且**目标是
  `docs.json` 里那份生产台账才不同步」，四种情形已逐一验证。执行方式：
  ```bash
  CRASH_REPORT_LEDGER_DOC_ID=<另建一份测试文档的 id> bash bin/deliver.sh <weekly manifest>
  ```
  ⚠️ 仍需**先建一份测试文档**并人工在其中加入「Issue 现状表」与「NON_FATAL 现状表」两个标题
  各带一张占位表格——否则会走 bootstrap 分支（append 全文），验不到 block_replace 那条路径。

## 4. 历史与状态

- [x] 4.1 `metrics-history.jsonl` 的写入增 ANR / NON_FATAL 字段。**实现方式：扩展 `daily-crash-1d.sql` 而非新增 SQL**——同表同窗口，把过滤从 `WHERE` 挪进 `COUNTIF`，**零额外查询**。⚠️ 已实测验证 `crash_events_1d` / `affected_installs_1d` 两列与旧口径逐值相同（Android 1.5.3 昨日：新旧均为 3,3），历史序列不断裂
- [x] 4.2 读取端对旧行（无该键）按「无数据」处理，**不回填、不丢弃整行**——与现有 `versions` 键缺失的处理方式一致
- [x] 4.3 DoD/WoW 环比覆盖新指标。ANR 率与崩溃率同分母（当日会话数）；**iOS 不输出 ANR 行**（整行不出，而非输出一行「—」——后者会被读成「数据没取到」）；非致命用 `n` 单位不是 `pp`（它是计数不是百分比，用 pp 会渲染成「+3.00pp」）

## 5. 验证

- [x] 5.1 `bash bin/check-scripts.sh` 通过
- [x] 5.2 `CRASH_REPORT_NO_DELIVER=1 bash bin/crash-daily.sh` 整跑，检查：ANR 行有数字、iOS 的 ANR 行是说明不是 `—`/`0`、NON_FATAL 段有数字、1197 行的旧文案已消失但「不可比」还在
- [x] 5.3 数值验证：ANR/NON_FATAL 各 SQL 双端实跑过，报告数字与直查一致（Android 1.5.3 ANR 48 次 0.76%、非致命 57 次）。**未与 Firebase 控制台人工对照**——需要有控制台权限的人做一次，记入 findings
- [x] 5.4 崩溃三行口径未变：`crash-issues.sql` / `crash-rate.sql` / `crash-issues-all.sql` **git diff 确认仅注释变更**；`daily-crash-1d.sql` 是功能变更但已实测新旧口径逐值相同（Android 1.5.3 昨日均为 3,3）
- [x] 5.5 `CRASH_REPORT_NO_DELIVER=1 bash bin/crash-weekly.sh`（加 `CRASH_REPORT_SKIP_ANALYSIS=1`）整跑验证

## 6. 上线预告与收尾

- [x] 6.1 ~~预告 ANR 红档告警~~ → **预测错误，实测不告警**。见 `findings.md` F1：告警只由最新版触发，而 Android 1.5.4 刚发布（35 会话、0 ANR），主力版 1.5.3 的 0.76% 只着色不告警。**本 change 的核心目的（让 ANR 可见）在摘要行上没达成**，处置需人工决定（findings 给了三个选项）
- [x] 6.2 `CLAUDE.md` 的「数据口径」增：`is_fatal=TRUE ⟺ error_type='FATAL'`；ANR / NON_FATAL 各自的 SQL 与分母；iOS 无 ANR 概念及其近似信号
- [x] 6.3 `CLAUDE.md` 的阈值段增 ANR 红黄线及其口径警告
- [x] 6.4 记录 Open Question 的处置：**NON_FATAL 已拍板进台账**（见 3b）；**ANR 是否进台账仍未定**，本 change 不做
