## Why

修复状态只比较「修复提交时间」与「最近一次事件时间」，**不看事件发生在哪个包上**——于是修复还没发版、或已发版但旧包用户仍在崩，都被报成「修了仍在」（修复无效），处置方向整个说反。

2026-10-06 在生产 fixmap 上实测（19 条映射）：

| 现判定 | 实际 | 条目 |
| --- | --- | --- |
| 修了仍在 | 修复**还没发版**，崩溃全在不可能含修复的旧包上 | Android `8bc4b97e`（修复 10-05 只在 `dev/feature/1.8.2`，崩溃在 09-30 首现的 182010） |
| 修了仍在 | 修复**已随新版发出、新包上 0 次**，只有没升级的旧包在崩 | Android `8b297547` `a34175e5` `ce481263` `d85cbe82` `fb6588bb` |
| 已修待验 | 修复**还没发版** | iOS `09ee5ad3`（10-05 修复只在 `dev-1.9.0`） |

这不是新需求，是**欠账**：

- 现行 spec `crash-perf-daily-weekly-report` 的「已修未发版」场景早已写明「含修复的版本尚未上线」且「iOS 与 Android 使用同一口径」，但 `crash-daily.sh:1416` 实际统计的是**所有** `fix_commit != null`——任何找到修复提交的 issue 都被报成「代码已修但未发版」。
- 原始设计（归档 `2026-08-20-crash-perf-daily-weekly-report` spec:131-132）规划了「代码已修·未发版 / 已发版·观察中」，v1 注明「需版本-事件对照，尚未实现，留人工」。
- 这个人工判断一直在做：2026-09-23 复核 `9c984b20`「修复仅进 v1.8.0，事件全在 1.7.0/1.7.1 → 存量，修复未触达正式用户」（归档 `crash-ledger-disposition-store` proposal:12）。每轮都得从头钻取一遍。

## What Changes

- 修复状态从两态（已修待验 / 修了仍在）扩为四态，判定**以事件所在的包是否含修复**为准，不再只比时间：

  | 状态 | 判据 |
  | --- | --- |
  | **修了仍在** | 修复提交之后，**含修复的包**上仍有事件 |
  | **已发版待验** | 含修复的包已上线，且其上 0 事件 |
  | **已发版待验（旧包仍崩 N 次）** | 同上，但不含修复的旧包仍有 N 次事件——备注，不另成一态 |
  | **已修未发版** | 修复提交之后尚无含修复的包上线 |

  「状态未知」（两个来源都没有证据）保留，语义不变。

- 「已发版」与「含修复的包」**按端用不同判据**（两端可得的信号不同，见 design）：
  - **iOS**：修复提交之后**首次出现**、且开启性能采集（上架包特征）的 build。发版 tag 不可用——iOS 缺 v1.8.1 / v1.8.2，且修复提交多不在任何 tag 祖先链上（实测 4/4）。
  - **Android**：修复提交进了 `origin/main` 或任一 `V*` 发版 tag；含修复的包 = 版本号 ≥ 最早包含它的 tag。⛔ 不用设备数门槛区分内部包与上架包（用户决定，2026-10-06）。
- 事件按 build 计数改走 **crashlytics 批量表 ∪ REALTIME**：REALTIME 只留 30 天（实测 09-06 起），只查它会漏掉早于 30 天的修复之后的事件（实测漏 2 条）。
- **L1 告警「代码已修但未发版」改用同一判定**，只计真正「已修未发版」的 issue，使实现符合现行 spec。
- 图例、卡片 `_fix_rows`、台账现状表、变更时间线的状态文案同步扩为四态。

## Capabilities

### New Capabilities

（无）

### Modified Capabilities

- `crash-perf-fix-status-reconcile`: 「对账只更新机器可判定的列」由两态改为四态，新增「含修复的包」的按端判据与「已发版」判据；「两态不得被写死成一态」扩为四态。
- `crash-perf-daily-weekly-report`: 「已修未发版」告警场景补明判定来源（与台账同一判定），消除实现与 spec 的漂移。

## Impact

**代码**

- `bin/scan-fix-commits.sh`：mapped 条目补 `commit_epoch`；Android 补 `release_ref`（最早包含该提交的 `V*` tag，或 `main`，或 null）与 `fixed_in_version`。仍是纯 git、只读。头注释 schema 补齐（现漏写「状态未知」）。
- **新增** `bin/fix-release-status.sh` + `bin/sql/fix-release-builds.sql`：按 fixmap 查事件所在 build、build 首现时间、iOS 性能采集设备数，输出改判后的 fixmap。判定逻辑放在 `bin/lib/` 的纯函数里（jq），SQL 只取数不判定。
- `bin/crash-weekly.sh`：反扫后调用新子脚本；`_chg_rows` / `_fix_rows` 的状态→图标映射从「其余一律修了仍在」改为逐态显式映射（⚠️ 现 else 分支会把新状态全吞成「修了仍在」）。
- `bin/crash-daily.sh`：反扫后调用新子脚本；`FIXED_PENDING` 由「已修待验」改为「已修未发版」；反扫前 fetch 业务仓库（见 design D5）；索引页图例与新状态对齐。
- `bin/render-ledger.sh`：处置状态列与时间线原文透传，无需改判定，只需确认新文案不破坏表格。
- `bin/deliver.sh`：台账指纹按列名定位，状态文案变化会触发一次 `block_replace`——符合预期，无需改。
- `bin/md2docx.py`：`❔` 无上色规则（既存），本 change 不新增 emoji，沿用 🛠️ / 📦 / ⚠️。

**夹具**：`fn-fix-status.sh`、`fn-fixed-pending.sh`、`fn-l1-fixed-pending.sh`、`fn-issue-state-filter.sh`、`fn-ledger-closed.sh` 都逐字断言了两态字面量，须随改；新增判定纯函数的夹具。

**跨进程**：新子脚本走「argv 进、文件 + 退出码出」；失败时保留时间规则的状态并**显式标注**「发版判定不可得」，不得静默回落。

**查询成本**：每轮每端 2 条查询（事件 × build、build 首现），扫 crashlytics 批量表 + REALTIME 与 sessions 两张表。

## Non-goals

- ⛔ **不用设备数 / 会话数门槛判「已发版」**（用户决定）。Android 内部 CI 包与上架包没有字段可分，本轮以 main / tag 为准。
- ⛔ **不要求 iOS 补打 tag**。iOS 用 build 首现 + 性能采集开关，不依赖团队打 tag 的纪律。
- ⛔ **不改反扫的提交识别规则**（`[crash:…]` / `Crashlytics…: <32位>` 两种形式、扫整条 message）。本 change 只改「找到提交之后怎么判状态」。
- ⛔ **不纳入 NON_FATAL**（承接 `crash-perf-fix-status-reconcile`「对账范围」既有结论）。
- ⛔ **不改人工结论的优先级**：人工结论与机器状态并存、可区分来源，机器状态不覆盖人工结论。
