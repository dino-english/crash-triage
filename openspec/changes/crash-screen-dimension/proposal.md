## Why

**「崩在哪个页面」这个维度一直躺在数据里没人用。**

`custom_keys.current_screen` 实测覆盖率：Android 200/221 = 90.5%，iOS 1096/1097 = 99.9%。

实测分布（近 7 天，主力版本）：

| Android（FATAL+ANR） | 事件/安装 | | iOS（NON_FATAL） | 事件/安装 · 集中度 |
|---|---|---|---|---|
| MainActivity | 32 / 27 | | DinoChatViewController | 230 / 46 · 5.0 |
| **SplashActivity** | **19 / 13** | | DCWebViewController | 141 / 27 · 5.2 |
| (未知) | 10 / 10 | | ClassViewController | 103 / 24 · 4.3 |
| CommonWebActivity | 9 / 9 | | WelcomeGiftPopupViewController | 60 / 21 · 2.9 |

**`SplashActivity` 19 次崩溃——启动页崩溃意味着用户根本进不去**，严重度远高于同样次数的深层页面崩溃。现在的报告里看不到这条信息。

对比现有的机型维度：实测 per-issue 的机型集中度只有 19%–33%（唯一机型数 ≈ 影响安装数，等于一设备一机型），而**页面集中度 58%–100%**。同一份数据里，页面是信号、机型是噪音。

## What Changes

- 新增 `bin/sql/crash-dimensions-nodenom.sql`：无分母维度分布，列 = `dim / events / users / concentration`。
- L1 汇总段「集中在哪」增第四张表「页面」，与既有三张同列同序（少一列崩溃率）。
- L2 影响面分布段同构增页面块。
- ⚠️ iOS 侧用 `NON_FATAL` 口径取数，Android 用 `FATAL,ANR`——`{{ERROR_TYPES}}` 由调用方给。

## Non-goals

- ⛔ **不给页面崩溃率**。`firebase_sessions` 无 screen 字段（本轮 schema 实测），页面级会话分母不存在。⛔ 更不得借 `perf-screens.sql` 的屏幕 trace 样本数当分母——那是另一套采样总体。
- ⛔ **不出根因**。维度聚合只显示相关性，与性能段同一条硬约束。
- ⛔ 不改现有三张维度表的口径与列序。
- ⛔ 不做 per-issue 的页面下钻（那是 TOP3 下钻的范围，另开 change）。

## Capabilities

- `crash-perf-impact-summary`（修改）：新增「页面维度」与「无分母维度只给绝对数」两条要求。
