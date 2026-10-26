## Why

2026-10-26 周报「本周必修」7 条里有 3 条（`29d4790c` / `4ade82c7` / `ed3883b1`，PAG finalizer）**本周窗口内零事件**——
BigQuery 实测末次事件在 10-18 03:15–09:01 UTC，早于周报窗口起点 10-18 21:40 UTC；同一张卡的「本周变化」把它们标成 ✅ 消失，
必修却给了 P1 并 @ 了负责人。

根因：`priorities_validate` 的白名单 = 数据层快照 ∪ 分析层 `analysis/snapshot.json`。后者来自 Firebase topIssues，
API 窗口按**自然日**（D-7 00:00 → 今天 23:59，≈8 天）；周报在周一 05:30 +08（= 周日 21:30 UTC）跑，比数据层的滚动 7×24h
多出近一整天。落在那一天里的 issue 只在分析层快照里，照样能被排进 P0/P1。
指纹：这类必修行的标题是「（标题未取到）」——标题只从数据层快照补。

## What Changes

- 防编造白名单不变（两份快照的并集）。
- **P0/P1 额外要求出现在数据层快照**；只在分析层快照里的条目降为 P2（👀 观察），理由改写为「本周窗口内无事件 · 原判 Px」，
  卡片来源注记写明降级条数。⛔ 不直接剔除：模型的信号保留可见，只是不派活、不 @ 人。
- 必修 / 观察行的标题：数据层快照没有时回落到分析层快照的标题。

## Capabilities

### Modified Capabilities

- `crash-perf-attention-tiers`：「周报分档由分析层优先级契约驱动」加窗口约束。

## Non-goals

- ⛔ 不改 topIssues 的取数窗口（API 只给自然日窗，prompt 里「用默认 7 天窗」也不动）。
- ⛔ 不改数据层快照的 LIMIT 20：在窗内但排在 20 名外的 issue 也会被降级，这是可接受的保守方向（宁可少派活）。

## Impact

- `bin/lib/core/tier.sh`（`priorities_validate` 加第 3 参：数据层快照 id）、`bin/crash-weekly.sh` 调用点与标题回落
- `bin/test/core-tier.sh` 夹具
