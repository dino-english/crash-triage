## Why

报告现在只有「受影响**安装**数」。读者问「影响了多少人」时，安装数是个近似——而 iOS 侧其实有真实的用户标识。

实测（近 7 天）`user.id` 非空率：

| | 事件 | 有 user.id |
|---|---|---|
| **iOS** | 1097 | **1060（96.6%）** |
| **Android** | 221 | **0（0%）** |

CLAUDE.md 里「用户率做不了」的结论是对的，但它说的是 `installation_uuid`（crashlytics）与 `instance_id`（sessions）JOIN 匹配 0 行——**`user.id` 这个字段从未被查过**。

## What Changes

- `crash-rate.sql` 增一列 `affected_users = COUNT(DISTINCT NULLIF(user.id, ''))`（同 `is_fatal=TRUE` + 同窗口 + 同版本过滤，与既有 `affected_installs` 可比）。
- 汇总段「影响多少人」增一列，位于「受影响安装」之后。
- Android 渲染 `— 不上报`。

## Non-goals

- ⛔ **不做用户崩溃率**。`firebase_sessions` 全字段实测无任何用户标识——用户分母在本项目**不存在**，不是暂时没做。
- ⛔ **不在 SQL 里按平台分叉**。同一份 SQL 双端共用，Android 自然跑出 0，判定放渲染层。
- ⛔ 不进台账（台账列已 9 列且跨端单表）。

## Capabilities

- `crash-perf-impact-summary`（修改）：新增「受影响用户仅单端可得且不可与安装数相减」要求。
