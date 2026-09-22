## Why

**报告把已关闭的 issue 排在最前面，而且一个字都没说它是关着的。**

2026-09-22 实测（`crashlytics_get_report` 取控制台同源数据，与 BigQuery 同窗逐条对）：

| 段 | Firebase topIssues | BigQuery 同窗 | 差集 |
| --- | --- | --- | --- |
| Android FATAL | 4 条 / 16 次 | **12 条 / 51 次** | 8 条 = 7 CLOSED + 1 MUTED |
| Android ANR | 20 条 / 43 次（`pageSize` 截断） | 35 条 / 59 次 | — |
| Android 非致命 | 2 条 / 80 次 | 2 条 / 80 次 | 0 |
| iOS FATAL | 1 条 / 1 次 | 1 条 / 1 次 | 0 |
| iOS 非致命 | 6 条 / 484 次 | 6 条 / 483 次 | 1（API 自然日窗恒大 0~2） |

⇒ **数值没有错**：可比的 5 条 FATAL 逐条 events/users/sessions 全等。差集 100% 由
Firebase 侧「默认只显示 OPEN」解释——逐个调 `crashlytics_get_issue` 复核，出现在
topIssues 的恰好就是那 4 条 OPEN，一条不差。

**但差集里有今天事件量最大的两条**：`fb6588bb`（11 次 / 8 台，1.7.1 + 1.7.0，最近 09-20）
与 `227fc097`（10 次 / 4 台，1.7.1，最近 09-18），**都已 CLOSED，却都还在现网版本上崩**。
它们排在日报明细表最前面，控制台默认视图里没有，而报告不标状态。两种读法都错：

- 拿 id 去控制台核 → 搜不到 → 判定报告错了（而报告是对的）；
- 不核 → 当成新问题排查 → 实际是「关掉了但还在崩」。

后者恰恰是最该看见的信号，但它**需要被标出来才读得出来**。

## 现行 spec 与现网代码已经矛盾

`crash-source-bigquery-migration` 写着「issue 开关状态不可得，且必须登记为不可得」，
理由是「唯一能给出开关状态的通路是 MCP `topIssues`，而它只返回 OPEN」。

⛔ **该前提已过期**：2026-09-11 的 R4 修复引入 `bin/fetch-issue-states.py`，
逐个调 `crashlytics_get_issue` 取 state（纯确定性、不经模型、带退避重试），
与 `topIssues` 不是同一个通路，**不受「关闭即消失」影响**。2026-09-22 实测
12 个 id 全部取到，且取回了 `topIssues` 结构上给不出的第三态 **MUTED**。

而 `render-ledger.sh:115` 从那天起就在渲染「✅已关闭」——**现网代码已经违反
这两条 spec 了**，只是没人回头改 spec。本 change 把 spec 对齐到已验证的事实。

## What Changes

- **MODIFIED** `crash-source-bigquery-migration`：「开关状态不可得」→「经确定性逐个查询**可得**」，
  并把「不得重新引入只返回 OPEN 的采集通路」这条**原样保留**（它仍然成立，且正是本次不走 topIssues 的理由）。
- **MODIFIED** `crash-perf-ledger-ownership`：图例不得把「消失」与「关闭」并列——**原意保留**，
  改为「两者必须分列」，并补上 MUTED 第三态。
- **ADDED** `crash-perf-issue-lifecycle`：日报 issue 明细表 MUST 把**生命周期**（新增/回归/长期）
  与 **Crashlytics 开关状态**分列呈现，且缺失态不得与 OPEN 合并。
- 代码：`fetch-issue-states.py` 增 `--extra-ids` / `--emit-map`；`crash-daily.sh` 明细表两处渲染点
  加「开关」列、原「状态」列改名「生命周期」；`render-ledger.sh` 认 MUTED。

## Non-goals

- ⛔ **不改任何数字**：事件数、崩溃率、受影响安装、crash-free 一律不动，本 change 只加标注列。
- ⛔ **不给非致命表加开关列**：NON_FATAL issue 不进事实层（`crash-issues-all.sql` 是
  `is_fatal = TRUE`），全列取不到，加了就是一列「？未取到」。
- ⛔ **不把 ANR 纳入台账**（今天按受影响安装排第一的是个 ANR：`4d05f9e7` 20 次 / 16 台）——
  那是独立的口径变更，不搭本 change 的车。
- ⛔ **不回溯订正台账时间线历史行**（R4 余留那条同理：时间线读作「当时的判定」）。
