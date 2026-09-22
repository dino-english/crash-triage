## Why

**台账里一条 ANR 都没有**（2026-09-22 实测 `grep -c ANR` = 0），而当天 Android
按受影响安装排第一的就是个 ANR：

| issue | 类型 | 事件 | 受影响安装 | 版本 | 最近 |
| --- | --- | --- | --- | --- | --- |
| `4d05f9e7` Native method - MessageQueue.nativePollOnce | **ANR** | 20 | **16** | 1.5.6 / 1.7.0 / 1.7.1 | 09-21 |
| `fb6588bb` ShapeableImageView.onDraw | FATAL | 11 | 8 | 1.7.0 / 1.7.1 | 09-20 |

头号 ANR 的影响面是头号 FATAL 的**两倍**，跨三个版本、当天还在发生——而台账跟踪了后者，
对前者**没有任何处置跟踪通路**（无首次纳入、无处置状态、无变更时间线）。

⚠️ ANR 并非完全不可见：周报的 TOP N 下钻与维度表用 `'FATAL','ANR'` 取数，正文看得到。
缺的是**跟踪**。`crash-issue-drilldown.sql` 的文件头注释早就写明了根因——
「L2 快照只有 FATAL（`crash-issues-all.sql` 带 `is_fatal` 过滤），**ANR 整个不在里面**」，
当时的绕法是让下钻自己选 top N，台账那条口子没补。

## ⛔ 判据必须是影响面阈值，不是 top N

2026-09-22 实测 Android ANR 7 天分布：

| 受影响安装 | issue 数 | 事件 |
| --- | --- | --- |
| 16 | 1 | 20 |
| 2 | 1 | 2 |
| **1** | **32** | 35 |

34 条里 **32 条是单设备长尾**。套用 FATAL 那套 `LIMIT 20` 会得到「2 条真的 + 18 条并列单设备」，
而 32 条在 `users` 上完全并列 ⇒ **谁进榜单由 `issue_id` 的字典序决定**。新单设备一出现就把老的
挤出去，台账当场报「消失」、下轮报「🔁回归」——**纯人造的变化**。这正是残余风险 R2
（「issue 总数逼近 LIMIT 时，掉出榜单再回来会被误计为回归」）最坏的形态，且 ANR 已经越过它。

⇒ 入选判据改为**受影响安装 ≥ 阈值**（默认 2）。今天入选 2 条，噪音为零。
⛔ 未入选的数量必须标注，不静默丢弃。

## What Changes

- **新增** `bin/sql/crash-anr-issues.sql`：ANR 的 issue 级聚合（结构对齐 `crash-issues-all.sql`，
  含版本构成）。⛔ 不改 `crash-issues-all.sql`——它的 `is_fatal = TRUE` 被崩溃口径依赖。
- `fetch-snapshot-bq.sh`：快照增 `anr.{ios,android}`（过阈值的）与 `anr_below.{ios,android}`
  （未入选计数）；事实层写入循环纳入过阈值的 ANR。
- `render-ledger.sh`：ANR 行进**同一张现状表**，`type` 列取 `ANR`（该列今天硬编码 `"FATAL"`，
  本就是为多类型留的扩展点）；表下标注未入选数量与 iOS 无此概念。
- `assert-fact-cache.sh`：断言遍历纳入 ANR。
- **MODIFIED** `crash-perf-anr-monitoring` / `crash-perf-ledger-ownership` 两份 spec。

## Non-goals

- ⛔ **ANR 不进变化检测**（`DIFF` 的 新增/回归/消失/暴涨）、不进复发率、不进卡片变化行。
  那套按平台键遍历顶层 FATAL 数组，接 ANR 要动卡片渲染与复发率口径，是另一个 change。
  ⚠️ 但**处置状态变更会自动进时间线**——那一段按 id 遍历 fixmap、不分平台，
  ANR 进了事实层就自动带上。
- ⛔ **不给未过阈值的 32 条单设备 ANR 建事实层记录**：事实层「一次抓永久留、不参与清理」，
  为长尾建档会让它无限膨胀。
- ⛔ **不进模型路径**（`fetch-snapshot.sh` full 的事件明细抓取）：ANR 记录是
  `source: "bigquery"` 的聚合事实，台账只需要它；接模型路径等于把 F52 的爆炸半径扩大一倍。
- ⛔ **不动 iOS**：数据源不产出 iOS 的 ANR，同一份 SQL 双端共用、iOS 自然跑出 0 行，
  ⛔ 不在 SQL 里按平台分叉，表下注解说明「iOS 无此概念」。
- ⛔ **不顺手解除 R2**：本 change 只让 ANR 绕开它（换判据），FATAL 侧的 `LIMIT 20` 一字未动
  （今天唯一 issue 数 12 < 20，未咬合）。
