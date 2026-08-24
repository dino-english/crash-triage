## Why

2026-08-24 对「规格议定 vs 实际产出」做了一次对账，查到三处产物缺陷。三处互相独立，但都属于「报告在说不实的话」，合并为一个 change 处理。

### ① 周报 iOS 机型维度的事件数是错的

维度 CSV 原始行（`$STATE/runs/2026-08-24/L2/latest/dim-model-iOS-1.5.4.csv`）：

```
"Apple iPad7,11",1,1,0,,1.0
```

Apple 的 `device.model` 标识符**自带逗号**（`iPad7,11` / `iPhone14,3`），BigQuery 因此加了引号。`crash-weekly.sh` 的 `awk -F,` 按裸逗号切，渲染成：

```
- "Apple iPad7 · 11" 事件 / 1 人 · 集中度
```

**实际 1 个事件，报告上写 11**，集中度丢失。今日 iOS 机型行 1/1 命中。

⚠️ 同一份数据，L1 日报走 `md_csv_table` 的 Python `csv.reader`，解析正确、不受影响——**同源数据两条链路结果不一致**，且错的那条没有任何告警。

### ② 变更时间线追加无幂等，实测重复三遍

`crash-weekly.sh` 的 awk 在 `LEDGER:TIMELINE:END` 前无条件追加增量，不查重。台账里 2026-08-22 那批 6 条**原样重复了三遍**（同周多次跑批各追加一次）。

CLAUDE.md 写着「台账同步不需要幂等键（`block_replace` 本身幂等）」——该判断**只对现状表成立**，时间线是 append，不幂等。

连带问题：那 18 行里的周报链接全是字面量 `__REPORT_URL__`。回填由 `deliver.sh` 在投递成功后做，NO_DELIVER 跑批不回填，占位符就永久留在本地台账源里。

### ③ 「回归」态从未实现，spec 要求未兑现

spec `crash-perf-issue-lifecycle` 要求三态（新增 / 回归 / 长期），并写明理由：「回归意味着修复失效或场景重现，与全新问题的处置方式不同」。

`render-ledger.sh:75` 只有两态：

```
status_badge: (if $p == null then "🆕新增" else "🔁遗留" end)
```

台账 14 行全是 🔁遗留。且 issue 一旦消失就从现状表掉出，`first_seen` 随之丢失——再出现时会被记成「今天首次纳入」。

L1 日报**已有**完整三态 `life_tag()`（`crash-daily.sh:839`），基准 `issue_seen` 存在 `daily-snapshot.json`，保留 90 天。⛔ 但 **L2 不能直接复用**：L1 的 `crash-issues.sql` 带版本过滤、L2 的 `crash-issues-all.sql` 刻意不带，老版本上的 issue 从不进 L1 基准，复用会让它们永远被标成「新增」。L2 需要自己的基准。

## What Changes

- **CSV 解析收口**：`crash-weekly.sh` 三处 `awk -F,` 改为先经 CSV 正确解析再切。
- **时间线追加幂等**：追加前按「去掉周报链接后的条目正文」查重，已存在则跳过。
- **未投递不留占位符**：投递未发生时，条目不带悬空的 `__REPORT_URL__`。
- **一次性清理既有污染**：台账里重复的 18 行与悬空占位符。
- **L2 自有生命周期基准**：新增 `$STATE/issue-seen.json`（`{id:{first,last}}`，保留 90 天），`render-ledger.sh` 增第三态 🔁回归，`first_seen` 优先取基准而非上一版表格。

## Non-goals

- **不改 L1 的 `life_tag()`**，也不合并两套基准——版本过滤口径不同，合并会同时污染两边。
- **不动修复反扫机制**。`crash:` 约定在两个业务仓库近 120 天提交数为 0，反扫从未生效；那是流程问题不是代码问题，需使用方决定，另行处理。
- **不补 NON_FATAL / ANR 的维度与 TOP issue、不做性能下钻**——内容补全是另一件事。

## Capabilities

- `crash-perf-issue-lifecycle`（修改）：把三态要求落到台账，并规定 L2 基准与 L1 基准分离的理由。
