# Explore Notes — crash-perf-daily-monitoring-enhancement（日报监控增强）

> 本文件由 explorer 需求结晶产出，供 propose 阶段（架构师）作为唯一需求依据。所有 material ambiguity 已由 requester 付玉佳拍板（见「已拍板决策」），无待答问题。
> 现状基准：`bin/crash-daily.sh`（运行副本，与 `scripts/crash-report/crash-daily.sh` git 源副本逐字节一致，diff 实测 IDENTICAL）+ `bin/sql/*.sql` + `state/daily-snapshot.json`。

---

## 1. 结晶后的需求（6 项 + 保留项）

### R1 环比对比 DoD/WoW（最高优先级，当前完全缺失）

崩溃率、接口错误率、启动耗时 P50/P95、慢帧占比、冻结率 五个指标都要补两档对比：

- **DoD（Day over Day）**：环比昨日
- **WoW（Week over Week）**：同比上周同一天
- iOS / Android 分开呈现。

展示格式（D2 已拍板单位）：

- 百分比类指标（崩溃率 / 接口错误率 / 慢帧占比 / 冻结率）：`指标值 DoD ±X.Xpp ↑/↓ | WoW ±X.Xpp ↑/↓`
  - 例：`0.20% DoD -0.05pp ↑ | WoW +0.12pp ↓`
- 耗时类指标（启动 P50/P95）：绝对值差 `±Xms`
  - 例：`266ms DoD -8ms ↑ | WoW +12ms ↓`

判断优先级（告警/解读口径，非展示格式）：

- **WoW 是「是否真的变差」的主判据**——工作日/周末流量结构差异会导致 DoD 抖动，WoW 同比上周同一天可滤掉该噪声；
- **DoD 是「今天是否有突发异常」的辅助信号**。

箭头方向沿用现状约定：数值变大 = 变差 = `↑`（崩溃数、耗时、慢帧率、错误率均越小越好）。

### R2 崩溃统计补「受影响安装数」口径

- 与现有「事件数 / 会话数」并列展示，新增「受影响安装数」；
- 动机：少数用户反复崩溃会拉高整体崩溃率造成误判，需一个用户维度的并列口径辅助读表；
- 口径已拍板（D1）：`COUNT(DISTINCT installation_uuid)`，crashlytics 表、`is_fatal=TRUE`、窗口内。

### R3 统一阈值红绿灯

崩溃率、慢帧占比、冻结率、启动 P95 四个指标都设红/黄/绿三档阈值（现状只有接口错误率有 `>0 即 🔴` 告警，且是硬编码 if 逻辑）：

- 红档初值已拍板（D3）：崩溃率 >1%、慢帧占比 >50%、冻结率 >1%、启动 P95 >2000ms；
- 黄档初值建议见「阈值红绿灯完整初值表」，全部标注「待对齐」（requester 只拍了红档）；
- 接口错误率现有「>0 即告警」逻辑一并纳入统一阈值框架（不保留独立硬编码分支）；
- 全部阈值做成**脚本顶部可配置常量**（集中一处，便于调参），不再散落硬编码。

### R4 小样本量提示

- 某平台/版本当日会话数 < 30（阈值做成可调常量）时，该行数据后追加「⚠️ 样本量小，仅供参考」；
- 会话数来源：sessions 表（平台级或版本级粒度，propose 定；现成 `sessions-by-version.sql` 是版本粒度）。

### R5 指标定义补充说明

- 「慢帧最差页」的百分比含义写进注释区，避免非技术成员误读；
- 语义已核实：`slow_frame_ratio` = 该页面渲染期间「慢帧（>16ms）帧数 ÷ 全部帧数」的**帧级占比**（不是「出现慢帧的会话占比」）；`frozen_frame_ratio` = 冻结帧（>700ms）帧级占比。现有 `perf-screens.sql` 取 `ROUND(AVG(...))`。

### R6 7 日趋势迷你图（sparkline）

- 崩溃率、接口错误率、启动 P95 三个指标的 7 日 sparkline，帮助判断问题是「新增」还是「持续」；
- 形式建议（propose 采纳与否自定）：Unicode 方块字符（`▁▂▃▄▅▆▇█`），markdown 原生渲染，无需图片；
- 注意：sparkline 只点名 3 个指标（崩溃率/接口错误率/启动 P95）；慢帧、冻结、P50 不在 sparkline 范围（但仍在 DoD/WoW 范围）。

### R0 保留不动项（明确不修改）

1. 崩溃/性能/放量三大板块分层结构（报告与卡片均保持）；
2. 各板块数据截止时间戳标注方式（性能/放量/崩溃三表分别取 `MAX(event_timestamp)` 分列标注）；
3. 崩溃口径注释习惯（BigQuery 事件级、含已关闭 issue、回填中提示）；
4. 详情跳转链接（卡片末尾 `__DETAIL_URL__` 占位回填机制）。

---

## 2. 已拍板决策记录（D1/D2/D3）

### D1｜受影响安装数口径 = 受影响安装数 = `COUNT(DISTINCT installation_uuid)`

- 条件：crashlytics 表、`is_fatal=TRUE`、窗口内；
- 理由：Android 不上报 `user.id`（实测 59 事件 0 个有值），跨平台唯一一致身份是 `installation_uuid`；
- **不做** Crash-Free Users Rate：缺可靠「总用户数」分母（sessions.`instance_id` 与 crashlytics.`installation_uuid` 是两套 ID，对不上）。

### D2｜启动耗时环比单位 = 绝对差值 ±Xms

- 启动 P50/P95 的 DoD/WoW 用 `±Xms`（如 `266ms DoD -8ms↑ | WoW +12ms↓`）；
- 百分比指标（崩溃率/错误率/慢帧/冻结）才用 `±X.Xpp`。

### D3｜阈值红档初值（做成可配置常量）

| 指标 | 🔴 红档（拍板） |
|---|---|
| 崩溃率 | > 1% |
| 慢帧占比 | > 50% |
| 冻结率 | > 1% |
| 启动 P95 | > 2000ms |

- 接口错误率现有「>0 即告警」逻辑一并纳入统一阈值框架；
- 黄档未拍板，explore 建议值见第 5 节（全部标「待对齐」）。

---

## 3. 数据源事实（已核实）

### 3.1 表与字段

| 数据域 | REALTIME 表名（活源） | 关键字段 |
|---|---|---|
| 崩溃 | `dino-english-497507.firebase_crashlytics.com_prime_dino_english_{IOS,ANDROID}_REALTIME` | `installation_uuid`、`firebase_session_id`、`user.id`（仅 iOS 有值）、`is_fatal`、`issue_id`、`issue_title`、`event_timestamp` |
| 会话 | `dino-english-497507.firebase_sessions.com_prime_dino_english_{IOS,ANDROID}_REALTIME` | `instance_id`、`session_id`、`application.display_version`、`event_timestamp` |
| 性能 | `dino-english-497507.firebase_performance.com_prime_dino_english_{IOS,ANDROID}`（批量，滞后 ~2 天） | `event_type`（DURATION_TRACE / SCREEN_TRACE / NETWORK_REQUEST）、`trace_info.duration_us`、`trace_info.screen_info.slow_frame_ratio`、`frozen_frame_ratio`、`network_info.response_completed_time_us`、`response_code` |

### 3.2 慢帧 / 冻结语义（R5 依据）

- `slow_frame_ratio` = 该页面渲染期间「慢帧（>16ms）帧数 ÷ 全部帧数」的**帧级占比**，非「出现慢帧的会话占比」；
- `frozen_frame_ratio` = 冻结帧（>700ms）帧级占比；
- 现有 `perf-screens.sql` 已按页面取 `ROUND(AVG(slow_frame_ratio)*100, 1)` / `ROUND(AVG(frozen_frame_ratio)*100, 2)`。

### 3.3 现有 SQL 与口径（DoD/WoW 改造的出发点）

| SQL | 窗口 | 产出 | 备注 |
|---|---|---|---|
| `crash-issues.sql` | CRASH_DAYS=7 | 按 issue 聚合的事件数（is_fatal=TRUE） | 卡片「N 类 M 次」、ios_ids/android_ids 来源 |
| `crash-rate.sql` | CRASH_DAYS=7 | 崩溃事件数 / 会话数（分子分母同窗口） | 崩溃率口径 = 事件数/会话数（非 crash-free） |
| `perf-traces.sql` | PERF_DAYS=3 | `_app_start` 等 trace 的 P50/P95(ms) | 性能表滞后 ~2 天，窗口放宽到 3 天补偿 |
| `perf-screens.sql` | PERF_DAYS=3 | 页面 slow_pct / frozen_pct / P50 停留 | 卡片取 head -1 最差页 |
| `perf-network.sql` | PERF_DAYS=3 | 按 endpoint 的 P50/P95/err_pct | 卡片用 `neterr()` 加权聚合全部 endpoint 的错误率 |
| `sessions-by-version.sql` | DAYS=1 | 版本 × 会话数/设备数 | 放量分母；HAVING sessions >= 5 |

### 3.4 快照现状（7 日历史的前置依赖）

`state/daily-snapshot.json` 当前只存「昨日单点」：

```json
{ "day": "2026-08-16", "ios_events": 4, "android_events": 54,
  "start_p50": 266, "ios_ids": [...], "android_ids": [...] }
```

- 覆盖指标仅 3 个：ios_events / android_events / start_p50（+ issue id 数组用于「新增 issue」判定）；
- **未存**：崩溃率分子分母、接口错误率、慢帧、冻结、启动 P95、会话数、受影响安装数；
- 现有 `arrow()/prev()` 机制的对比基准是「**近 N 天滚动窗口值**」（如 ios_events 是 7 天窗口的事件数），不是「昨日单日值」——语义与 R1 的「昨日环比」不同（窗口重叠会钝化变化），propose 阶段须明确 DoD 用「天级口径」而非沿用窗口口径；
- 结论：**现有快照机制只能作 DoD 的骨架（读写/prev 模式），覆盖指标与口径都必须扩展**。

---

## 4. 核心指标 DoD/WoW/sparkline 可行性结论

统一前提：**7 日滚动历史存储是 WoD/WoW/sparkline 的公共前置依赖**。现有快照只存昨日单点 3 个值，要支持「全指标 DoD（昨日值）+ WoW（7 天前值）+ sparkline（7 日序列）」必须：

- 把每日持久化从 3 个值扩展为**全指标单点**（崩溃率分子分母、受影响安装数、接口错误率、慢帧、冻结、启动 P50/P95、平台会话数）；
- 新增 **7 日滚动历史**（建议 `state/metrics-history.jsonl`：每天 append 一行，保留最近 7 天，原子写 = 临时文件 + mv）。DoD 只需昨日值（现有快照机制扩展即可），WoW 需 D-7 值，sparkline 需 7 日序列。

| 指标 | 今日值数据源 | 今日值现状 | DoD（昨日环比） | WoW（上周同日） | 7 日 sparkline |
|---|---|---|---|---|---|
| 崩溃率 | `crash-rate.sql`（crashlytics ÷ sessions，7 天窗） | ✅ 有 | ⚠️ 需扩展：分子分母未入快照，且现为窗口口径，需天级值 | ⚠️ 需 7 日历史 | ✅ 需求点名，需 7 日历史 |
| 接口错误率 | `perf-network.sql` + `neterr()` 聚合（3 天窗） | ✅ 有 | ⚠️ 需昨日值 → 扩展持久化 | ⚠️ 需 7 日历史 | ✅ 需求点名，需 7 日历史 |
| 启动 P50 | `perf-traces.sql` `_app_start`（3 天窗） | ✅ 有（已入快照，窗口口径） | ⚠️ 快照仅 1 值且窗口口径 → 需天级值 | ⚠️ 需 7 日历史 | 需求未点名（不做） |
| 启动 P95 | `perf-traces.sql` `_app_start`（3 天窗） | ✅ 有（未入快照） | ⚠️ 需昨日值 → 扩展持久化 | ⚠️ 需 7 日历史 | ✅ 需求点名，需 7 日历史 |
| 慢帧占比 | `perf-screens.sql` 最差页 slow_pct（3 天窗） | ✅ 有 | ⚠️ 需昨日值 → 扩展持久化 | ⚠️ 需 7 日历史 | 需求未点名（不做） |
| 冻结率 | `perf-screens.sql` frozen_pct（3 天窗） | ✅ 有 | ⚠️ 需昨日值 → 扩展持久化 | ⚠️ 需 7 日历史 | 需求未点名（不做） |
| 受影响安装数 | **无现成 SQL**，需新增 | ❌ 无 | ⚠️ 需昨日值 → 持久化 | ⚠️ 需 7 日历史 | 需求未点名（不做） |

要点结论：

1. **没有任何指标现在就能算「昨日环比」DoD**——现有 `arrow()` 是滚动窗口值的环比，语义不同；所有 DoD 都依赖「昨日单日值」持久化（或天级窗口 SQL）。
2. **受影响安装数**：crashlytics 表（`com_prime_dino_english_{IOS,ANDROID}_REALTIME`）、`is_fatal=TRUE`、窗口内 `COUNT(DISTINCT installation_uuid)`。实现位置建议**并入 `crash-rate.sql` 作为第三个子查询**（与分子分母同表同窗口，天然口径一致），或独立 SQL（propose 定）。
3. **性能类指标的 DoD 有数据延迟风险**：性能批量表滞后约 2 天（现用 3 天窗补偿），07:00 运行时「昨日」数据可能未到齐 → DoD 须处理「性能表截止早于昨日」情况（显示无基准或回退到最新可用日），不能硬算。
4. **WoW 冷启动**：上线后前 7 天无 D-7 值，显示「无基准」（沿用现有「首日无基准不显示箭头」习惯）。
5. **小样本量提示（R4）**：判定需平台级（或版本级）当日会话数，来源 sessions 表；现成 `sessions-by-version.sql` 为版本粒度、`crash-rate.sql` 的 sessions 为 7 天窗口 → 同样需天级取值（并入持久化）。

---

## 5. 阈值红绿灯完整初值表

红档 = D3 拍板；黄档 = explore 建议（**全部待对齐**，requester 未拍板）；绿档 = explore 建议。阈值一律做成脚本顶部可配置常量。

| 指标 | 🟢 绿（建议） | 🟡 黄（待对齐） | 🔴 红（D3 拍板） |
|---|---|---|---|
| 崩溃率 | < 0.5% | 0.5% – 1% | > 1% |
| 接口错误率 | = 0% | (0, 0.5%] | > 0.5%（待对齐；现行为 >0 即 🔴，纳入框架后首版建议沿用） |
| 慢帧占比（最差页） | ≤ 30% | 30% – 50% | > 50% |
| 冻结率 | < 0.5% | 0.5% – 1% | > 1% |
| 启动 P95 | ≤ 1500ms | 1500 – 2000ms | > 2000ms |

补充：

- 黄档建议值仅供 propose 阶段参考，须在文档/代码注释中显式标注「待对齐」，避免被当作已确认阈值；
- R4 小样本量阈值 `会话数 < 30` 同样做成可配置常量（如 `SAMPLE_SESSION_MIN=30`）；
- 红绿灯的呈现方式（告警块追加条目 vs 卡片指标着色 vs 仅状态标签）属设计决策，由 propose 阶段在 design.md 定夺，本次探索未拍板（属设计细节，非需求歧义）。

---

## 6. 风险与 unknowns（propose/implement 需注意，非待答问题）

1. **crashlytics 仅 REALTIME 表且仍在回填**：受影响安装数与崩溃率 DoD 首验期数值可能偏低，注释须沿用「回填中」标注，勿据 DoD 突降判断「崩溃变少」。
2. **性能表滞后**：启动 P95 / 慢帧 / 冻结的昨日 DoD 在 07:00 常无昨日数据，需「无基准/回退」分支，避免显示误导性 DoD。
3. **口径混用**：窗口口径（现状展示值）与天级口径（DoD/WoW）不能混着比；注释与代码须显式区分，持久化字段名要带口径标识。
4. **历史文件写并发/原子性**：`metrics-history.jsonl` 每日 append + 截断保留 7 天，须原子写（临时文件 + mv）；L1 是唯一写者，冲突风险低但不可省。
5. **WoW 冷启动 7 天**：上线初期 WoW 与 sparkline 无基准，预期内，勿当故障。
6. **双副本同步**：`bin/crash-daily.sh` 与 `scripts/crash-report/crash-daily.sh` 改动必须一致（现状 diff IDENTICAL，implement 验收须复测）。

---

## 7. 保留项清单（明确不改动）

| # | 保留项 | 现状依据 |
|---|---|---|
| 1 | 崩溃/性能/放量三大板块分层结构 | 报告 `## 崩溃 / ## 版本放量 / ## 性能`；卡片 column_set bisect 分栏 |
| 2 | 各板块数据截止时间戳标注 | 三表分别 `table_max()` 分列（性能/放量/崩溃各一行） |
| 3 | 崩溃口径注释习惯 | 「BigQuery 事件级（含已关闭 issue）」「事件数/会话数（非 crash-free）」「回填中」等 |
| 4 | 详情跳转链接 | 卡片末尾 `📄 [详情](__DETAIL_URL__)` 占位由 agent 建文档后回填 |

---

## OPEN QUESTIONS

无（requester 已全部拍板）
