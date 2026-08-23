## Why

卡片能说「崩了多少」，说不清**该谁接、是不是新的、整体健不健康**。使用方要的四项补充：

**① 该谁接** —— 实测 `blame_frame.owner` 有值且有区分度（Android 近 7 天）：

| owner | library | 事件 | 影响安装 |
|---|---|---|---|
| SYSTEM | com.prime.dino.english | 47 | 30 |
| SYSTEM | libutils.so | 30 | 23 |
| **DEVELOPER** | com.prime.dino.english | **23** | **18** |
| **THIRD_PARTY** | com.prime.dino.english | **11** | **9** |

现在报告只给 `[libutils.so] 41 次`，读者无从判断是不是自己的事。

**② 是不是新的** —— issue 明细只有事件数，新出现的、上周修过又回来的、长期存在的，长得一模一样。
L2 已有变化检测逻辑，L1 没用上。⚠️ 而且 L1 现有的新增判定**实际是死的**：
`daily-snapshot.json` 的 `ios_ids` / `android_ids` 都是空数组——它们来自 MCP，而 MCP 抓取长期失败。

**③ 集中在哪个系统版本** —— 汇总段已经算出来了（实测 Android 14 崩溃率 **3.16%** vs 16 的 **0.60%**），
但卡片上看不到。加分母后结论反转的那个洞察，只有翻文档才看得见。

**④ 整体健不健康** —— 卡片的 crash-free 只有**最新版**。实测 1.5.4 是 `94.29% (2/35)`——
35 个会话上的比率**没有意义**，却是卡片上唯一的 crash-free 数字。
全版本值是 **99.28%**，那才是「整体健不健康」，也才是能与 Firebase 控制台对照的量级。

## What Changes

- **新增归因维度**：按 `blame_frame.owner`（`DEVELOPER` / `THIRD_PARTY` / `SYSTEM`）聚合，进汇总段；
  卡片给一行「自家 / 三方 / 系统」的事件与影响安装分布。
- **issue 生命周期标记**：明细表每行标 `🆕新增` / `🔁回归` / `长期`。
  判定基准改用 **BigQuery issue id**（不再依赖已经失效的 MCP 通路），
  `daily-snapshot.json` 扩为 `{id: 末次出现日期}` 的滚动集合。
- **卡片增系统版本行**：崩溃率最高的系统版本及其率。
- **卡片增全版本 crash-free**：与最新版并列，两个数各自标注口径。

## Non-goals

- ⛔ **不做灰度关联**（`remote_config_feature_rollouts`）。实测近 30 天 **201 个事件中 0 个带 rollout 信息**——
  字段存在但恒空。此前把它评为「价值最高的后续候选」是**基于字段存在的错误推断，已撤回**。
  要用它得先确认客户端是否在用 Remote Config rollouts 并正确上报。
- **不改现有告警口径**（最新版触发那条仍待人工决策，见 `crash-error-type-coverage` findings F1）。
- **不做 owner 的根因断言**：`owner=SYSTEM` 不等于「不是我们的问题」——实测 47 个 SYSTEM 事件的
  library 正是自家包名，说明是系统帧被自家代码调用。**只给分布，不给结论。**

## Capabilities

### New Capabilities

- `crash-perf-blame-attribution`：崩溃归因分布（自家代码 / 三方 SDK / 系统）的采集与呈现边界。
- `crash-perf-issue-lifecycle`：issue 的新增 / 回归 / 长期标记，及其判定基准与数据源。

### Modified Capabilities

- `crash-perf-daily-card-v2`：卡片增系统版本行与全版本 crash-free。
- `crash-perf-latest-2-versions`：**取消版本清单的会话数门槛**。实测 Android 1.5.4 停止上报后
  （1d 会话 1 个），「最新 2 版」自动滑到 1.5.3/1.5.1，**卡片上一个字都没说 1.5.4 存在过**——
  而放量被叫停正是最该看见的事。改为不设门槛、小样本由单元格的「⚠️」标出。

## Impact

| 文件 | 变更 |
|---|---|
| `bin/sql/crash-blame.sql` | **新增** —— 按 owner + library 聚合 |
| `bin/sql/crash-rate.sql` | 全版本 crash-free 复用（去版本过滤的一次查询） |
| `bin/crash-daily.sh` | 归因取数与渲染 · 生命周期标记 · 卡片两行 · snapshot 结构 |
| `bin/crash-weekly.sh` | 归因分布进周报影响面段 |
| `$STATE/daily-snapshot.json` | 结构扩展：`issue_seen: {id: day}`，滚动保留 |

**风险**：`daily-snapshot.json` 结构变更。旧结构无 `issue_seen` 键 → 首轮全部判为「新增」会刷一屏。
必须**首轮只建基线不标新增**（沿用 L2 `last-snapshot.json` 的既定做法）。
