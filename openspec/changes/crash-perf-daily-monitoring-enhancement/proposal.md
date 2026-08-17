## Why

日报现在只报「今天多少崩溃、启动多慢」，缺「环比昨天 / 同比上周」的对比——一个指标从 0.8% 涨到 1.2% 是「新增异常」还是「长期如此」完全看不出；也没有用户维度的「受影响安装数」来抵消少数用户反复崩溃造成的误判；告警只有「接口错误率 >0 即 🔴」一条硬编码 if，崩溃率/慢帧/冻结/启动 P95 都没有红黄绿阈值。本 change 补上 DoD/WoW 环比、受影响安装数、统一阈值红绿灯、小样本提示、慢帧定义注释、7 日趋势 sparkline 六个缺口，让日报从「报数」升级为「判势」。

## What Changes

- **环比对比 DoD/WoW**（R1）：崩溃率、接口错误率、启动 P50/P95、慢帧占比、冻结率 五个指标补「环比昨日 DoD / 同比上周同日 WoW」两档，iOS/Android 分开；百分比类指标用 `±X.Xpp`、启动耗时用 `±Xms` 绝对差（D2 已拍板）。
- **受影响安装数**（R2）：崩溃统计新增「受影响安装数」口径 `COUNT(DISTINCT installation_uuid)`（is_fatal=TRUE 窗口内，D1 已拍板），与事件数/会话数并列，抵消少数用户反复崩溃的放大。
- **统一阈值红绿灯**（R3）：崩溃率/慢帧/冻结/启动 P95/接口错误率 统一红黄绿三档（红档 D3 已拍板，黄绿待对齐），全部做成脚本顶部可配置常量；接口错误率现有「>0 即 🔴」并入统一框架，不保留独立硬编码分支。
- **小样本量提示**（R4）：某平台（iOS/Android）当日会话数 < 阈值（默认 30，可配）时，该行数据追加「⚠️ 样本量小，仅供参考」。
- **慢帧定义注释**（R5）：「慢帧最差页」的帧级占比语义写进注释区，避免非技术成员误读。
- **7 日趋势 sparkline**（R6）：崩溃率/接口错误率/启动 P95 三指标的 7 日 Unicode 方块字符迷你图。
- **每日全指标持久化 + 7 日滚动历史**（前置依赖）：现有快照只存 3 个窗口值，需扩展为全指标天级单日值并保留最近 7 天，作为 DoD/WoW/sparkline 的统一数据基准。

## Capabilities

### New Capabilities

- `crash-perf-daily-monitoring`: 日报监控增强——环比 DoD/WoW、受影响安装数、统一阈值红绿灯、小样本提示、慢帧定义注释、7 日 sparkline，以及支撑它们的每日指标持久化与 7 日滚动历史

### Modified Capabilities

<!-- 无。本次为新增监控行为，不修改既有已归档能力（当前 openspec/specs/ 仅 crash-perf-table-exists-retry）。
     `crash-perf-daily-card`（卡片展示契约）与 `crash-perf-daily-weekly-report`（主链路契约）尚属未归档的
     进行中 change（crash-perf-card-beautify / crash-perf-daily-weekly-report 均 in-progress），不在 openspec/specs/ 内，
     无法作为 MODIFIED delta 的基准（openspec 要求 MODIFIED 引用 openspec/specs/<cap> 的既有路径）。
     且本次对卡片/告警的改动是「新增内容与新增判定」，非对既有 requirement 的行为改写，属 ADDED 语义。
     统一阈值框架取代「接口错误率 >0 即 🔴」独立分支的衔接，见 Impact 与 design.md 迁移计划。 -->

## Impact

**代码**：

- `scripts/crash-report/crash-daily.sh` + `bin/crash-daily.sh`（git 源副本 + 运行副本，改动必须一致）：新增 DoD/WoW 计算、受影响安装数提取、阈值红绿灯判定、小样本提示、sparkline 渲染、每日指标持久化与 metrics-history 读写
- `bin/sql/crash-rate.sql`：新增「受影响安装数」第三子查询（`COUNT(DISTINCT installation_uuid)`）
- 新增天级单日值查询（日历日锚定，供 DoD/WoW/sparkline 取数）
- `state/daily-snapshot.json` 扩展全指标 + 新增 `state/metrics-history.jsonl`（7 日滚动历史，原子写）

**数据源 / 口径**：崩溃率分子分母、受影响安装数、接口错误率、慢帧、冻结、启动 P50/P95、平台会话数纳入每日持久化；DoD/WoW 用「天级单日值」口径，与现有「滚动窗口展示值」口径显式区分。

**契约**：新增 `openspec/specs/crash-perf-daily-monitoring/spec.md`（归档后）。

**衔接**：统一阈值框架取代 `crash-perf-daily-weekly-report`（未归档）里「告警判定 → 接口错误率 >0 即 🔴」的独立分支。归档顺序约束：本 change 须先于 `crash-perf-daily-weekly-report` 归档；否则该 change 归档时必须同步改写其「接口错误率异常」scenario 做一致性对账（见 design.md 迁移计划）。

**风险**：性能表滞后约 2 天，perf 类指标 DoD 在 07:00 常无昨日数据，需「无基准/回退」分支；WoW/sparkline 冷启动前 7 天无基准，预期内，勿当故障。
