## Why

**iOS 的崩溃数据一直在被读反。**

实测（2026-08-24，近 7 天，主力版本口径）：

| 平台 | 非致命事件 | 其中后台 | 前台 |
|---|---|---|---|
| **iOS** | 995 | **981（98.6%）** | 14 |
| Android | 95 | 2 | 93 |

报告现在把这 995 条平铺成一个数。读者看到「iOS 非致命 995 次、Android 95 次」，合理结论是「iOS 问题比 Android 多一个数量级」——**而实际情况相反**：iOS 那 981 次发生在后台，用户完全无感；真正在用户面前崩的只有 14 次，比 Android 的 93 次少得多。

这不是数字错误，是**缺少一个维度导致的系统性误读**，与「iOS 崩溃 0 而同窗口 1020 条非致命」是同一类问题。

同时实测发现 iOS 60 天只有 **5 次致命崩溃 / 4 个 issue**（同期非致命 1424 次）——iOS 的严重度信息几乎全在非致命里，而非致命不拆前后台就是不可读的。

## What Changes

- `crash-error-types.sql` 增三类事件各自的 `_fg` / `_bg` / `_unknown` 三列。
- ⚠️ 该文件 WHERE 由 `('ANR','NON_FATAL')` 放宽为含 `FATAL`——既有四列全是 `COUNTIF(error_type=…)`，放宽扫描范围**不改变其取值**（已实测逐字节一致）。
- L1 取数管线接通九个字段，落进 `m-<key>.json` 的 `errtype`。
- 卡片与文档增一行摘要，仅在「样本 ≥ 20 且后台占比 ≥ 80%」时出现。

## Non-goals

- ⛔ **不动 `crash-rate.sql`**。FATAL 的前后台也从 `crash-error-types.sql` 取，正是为了不碰崩溃率与 crash-free 的口径。
- ⛔ **不给前后台的率**。sessions 表无 `process_state` 字段（本轮 schema 实测），前后台的会话分母不存在。⚠️ 更不得借 perf 表的屏幕 trace 样本数当分母——那是另一套采样总体，与 `installation_uuid`/`instance_id` JOIN 是同一类错误。
- ⛔ **前后台不参与红黄绿判定**。后台占比高不是告警，只是解释。
- ⛔ 不新建 SQL 文件，不改窗口天数。

## Capabilities

- `crash-perf-daily-weekly-report`（修改）：新增「三类事件必须可区分前后台」要求。
