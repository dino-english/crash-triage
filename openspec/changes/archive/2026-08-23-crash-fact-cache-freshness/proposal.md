## Why

事实层缓存的命中判定 `[ "$events" -gt "$prev" ]`（[fetch-snapshot-bq.sh:117](../../../bin/fetch-snapshot-bq.sh)）假设 `events` 单调递增。**这个假设在 BigQuery 迁移后不再成立**：`crash-issues-all.sql` 的 `events` 是 `COUNT(*)` 在滚动窗口内的取值（`event_timestamp >= TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL {{DAYS}} DAY)`），老事件出窗即下降。

判定从 MCP topIssues 时代原样搬来，迁移 change `crash-source-bigquery-migration` 的 design 讨论了崩溃率口径（R2/R3）却**未提事实层计数口径**。现行 spec `crash-perf-issue-fact-cache` 的三条 Scenario 只覆盖「相等」与「线上更大」，**「线上更小」未定义**，实现落进 `hit` 分支——不回写任何字段。

后果按严重度：

| | 影响 |
|---|---|
| **`latest_event` 冻结** | 台账「最近一次发生」停在历史峰值那天。台账是给人做处置判断的，这条直接误导 |
| `last_synced` 冻结 | 正在衰减（= 正在被修好）的 issue 看起来像「数据停更」，**把好消息读成故障** |
| `events_count_last_seen` 名不副实 | 实际存的是「历史最大窗口计数」 |
| `CACHED_HIT` 虚高 | 运行统计失真 |

已在模型路径显形：`3e827b74` 的 `events` 数组长 **65**，而 `events_count_last_seen` = **47**——累积数组已超过窗口计数 18。BigQuery 侧尚未显形（6 条记录、最早 2026-08-20，窗口还没滑过去），**是定时炸弹不是已爆的**，趁数据量小修最便宜。

## What Changes

核心是**把一个 if/else 里挤着的两个判定拆开**：

- **「要不要抓取事件明细」（fetch decision）** —— 保持现状。它省的是真钱：模型路径的 `crashlytics_list_events` 是一次昂贵 MCP 调用，prompt 里写明「这是本次判定的核心目的：0 次额外 MCP 调用」。线上计数下降意味着没有新事件，跳过抓取是**正确的**。
- **「要不要更新观测字段」（record decision）** —— 改为**每轮无条件执行**。`latest_event` / `last_synced` / 计数是对当前观测的记录，不是抓取结果；跳过它们省不下任何东西，却在制造陈旧数据。

  ⚠️ **BigQuery 路径的 `hit` 分支本来就省不了任何东西**：那一行数据已经在 `$SNAP` 里（就是 bq 查询的结果），跳过只避免了一次 `jq` + `mv`。该路径的命中判定是无收益的优化，却是有害的数据策略。

- **`latest_event` 取 `max(已存, 本次观测)`**。窗口内的 `MAX(event_timestamp)` 同样非单调——最新事件出窗后，剩余事件的 MAX 会**变小**。取 max 保证该字段单调不倒退。
- **新增 `window_days` 字段**，让计数可解释：一个「7 天窗口内 3 次」与「30 天窗口内 3 次」是不同的事实，现在无从区分。
- **模型路径的 prompt 同步**（`fetch-snapshot.sh` 的第 ③ 段）：同样拆开两个判定，措辞与 shell 实现对齐。

## Non-goals

- **不改字段名 `events_count_last_seen`**。一旦改为每轮无条件更新，这个名字就变准确了（它真的成了「上次看到的计数」）。改名要迁移 18 个现存文件，收益为零。
- **不迁移现存 18 个文件**。下一轮跑批自然覆盖观测字段，`latest_event` 取 max 保证不倒退。
- **不统一「模型路径 prompt 与 shell 实现的策略重复」**。这是登记在 `crash-perf-functional-core` design D10 的已知缺口（跨执行模型的重复，lint 抓不到），本 change 只保证两处措辞一致，不做结构性统一。
- **不改 `events` 累积数组的语义**。它是累积事实（只 append 不改写），与窗口计数是两个不同的量——本 change 让这个区别显式，不合并它们。

## Capabilities

### Modified Capabilities

- `crash-perf-issue-fact-cache`：拆分「抓取判定」与「记录判定」；补齐「线上计数小于本地」这一未定义分支；要求观测字段每轮无条件更新且 `latest_event` 单调不倒退。

## Impact

| 文件 | 变更 |
|---|---|
| [bin/fetch-snapshot-bq.sh](../../../bin/fetch-snapshot-bq.sh) | 第 105-127 行的 while 循环：拆开两个判定，观测字段无条件写；`latest_event` 取 max；新增 `window_days` |
| [bin/fetch-snapshot.sh](../../../bin/fetch-snapshot.sh) | 第 ③ 段 prompt（约 80-95 行 / 124-137 行两份）：措辞对齐 |
| `$STATE/issues/*.json` | 结构增一个 `window_days` 键；无迁移 |

**与 `crash-perf-functional-core` 的关系**：那个 change 把 `cache_verdict` 上移核心层并加用例（钉住当前行为、注释标注已知缺陷）。**两者顺序无强制依赖**，但**先做 functional-core 更划算**——本 change 的正确性届时有用例兜底。若本 change 先落地，functional-core 的用例期望值需相应改写。

**风险**：观测字段改为无条件写，意味着每轮跑批都会重写全部命中 issue 的 JSON 文件（当前 18 个，量级可忽略）。`CACHED_HIT` 的语义随之变为「跳过抓取」而非「跳过写入」，日志措辞需同步。
