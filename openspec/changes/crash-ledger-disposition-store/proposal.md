## Why

**iOS 侧几乎没有崩溃处置跟踪能力**，因为它的主口径是 NON_FATAL，而 NON_FATAL 没有任何承载人工结论的地方。

iOS 主力版本常年 FATAL = 0——`crash-weekly.sh:668-675` 实测记录 iOS 1.5.3 有 **958 条 NON_FATAL、0 条 FATAL**，`crash-daily.sh:2471` 也标明口径按端不同（**Android = FATAL + ANR，iOS = NON_FATAL**）。后果直接反映在台账上：Issue 现状表（带「首次纳入 / 处置状态 / 备注」三列人工结论的那张）里 **iOS 只有 1 条**，其余全是 Android；iOS 的实际内容几乎全在 NON_FATAL 现状表里，**而那张表由 `nf_rows()` 纯机器渲染，一列人工结论都没有**。

2026-09-23 的人工复核把这个缺口摆到了台面上。四条带 `SIGNAL_REGRESSED` 的 iOS NON_FATAL issue：

| issue | 事件（近 7 天） | 复核结论 |
| --- | --- | --- |
| `359fadbc` SafeDecodeFallback | 64 | 修复 `847a280c`(09-08) 进 v1.7.0+，53 次全在修复前的 1.6.0.28，**含修复正式包 0 次 → 已验证生效** |
| `9c984b20` avfaudio 引擎启动失败 | 225 | 修复 `21ef358b`(09-14) 仅进 v1.8.0，事件全在 1.7.0/1.7.1 → **存量，修复未触达正式用户，无法验证** |
| `c2b2ecfe` AzureTTSEngine -4002 | 33 | 同上 |
| `c3184f91` avfaudio IO cycle | 41 | 1.8.0 上 10 次**全部来自 `dino-english-ios-adhoc` 内测包**，且走 `AzureTTSAudioPlayer` 后台播放路径而非所修的 DinoChat 离场路径 → **部分修复，另一路径仍在** |

⚠️ **四条里三条的「回归」是假警报**：`SIGNAL_REGRESSED` 不区分版本，issue 关闭后收到**任何**事件（含修复前老版本的存量）就会重开。这四条结论都无处安放，下一轮复核只能把同样的钻取从头做一遍，并很可能再次把存量误读成回归。

**为什么「给表加两列」解决不了**：人工结论今天唯一的存储就是表格本身——`crash-weekly.sh:419-424` 用 awk 从上一版台账抽出表格，`render-ledger.sh:54-71` 再从中解析 `id → {first_seen, disposition, note}` 合并回去。而 NON_FATAL 表是「按受影响安装取头部」的滚动榜单，**行一掉榜结论就没了**，回榜时是白纸。同一个脆弱点也压在 FATAL 表上：`prev_table` 抽取一旦失败（锚点失效、文件损坏），**全表结论静默归零且无告警**。

## What Changes

- **新增**处置结论的独立存储 `$STATE/ledger/dispositions.json`，键为 `issue_id`，与 `error_type`、平台、以及呈现所在的表**全部解耦**。人工独占写入，跑批只读不覆盖。
- **台账** NON_FATAL 现状表新增 `处置状态` 与 `备注` 两列，渲染期按 `issue_id` join 该存储；无结论的行留空，不影响既有机器列。
- **周报正文** 的 iOS NON_FATAL 段（TOP N 下钻）一并呈现结论——iOS 段本就走 NON_FATAL，读者不必为看一句「这条是假警报」去翻台账。
- ⛔ **日报不呈现结论**：`crash-perf-daily-weekly-report` 的「L1 与 L2 的职责边界」明确 **L1 MUST 只负责高频数据呈现，MUST NOT 产出分析、结论或台账**。本 change 不动该边界。
- 结论**不随掉榜丢失**：issue 掉出头部后存储条目原样保留，回榜自动重新呈现。
- 存储格式一次设计到位，**FATAL / ANR 表的迁移不在本轮**（见 Non-goals），但格式必须能直接承接，不留二次迁移。
- ⛔ **不合表**：NON_FATAL 与 Issue 现状表继续分列，量级判据已由 `crash-ledger-anr-tracking/design.md:6-7` 论证（iOS 非致命 14 天 1020 条，混排淹没十几条 FATAL），本 change 承接该前提。

## Capabilities

### New Capabilities

- `crash-perf-disposition-store`: issue 处置结论的持久化——结论以 `issue_id` 为键独立存储，其生命周期与「该 issue 本轮是否被呈现」彻底解耦；定义写入权属（人工独占）、读取时机（渲染期 join）、跨 `error_type` 的统一键空间，以及存储不可得时的降级行为。

### Modified Capabilities

- `crash-perf-ledger-ownership`: 台账结构定义补入 NON_FATAL 现状表（现行 spec 只写四段，实现已有第五段，属既存漂移）；现状表的人工结论来源从「解析上一版表格」改为「渲染期 join 独立存储」；NON_FATAL 现状表列定义新增两列人工结论。
- `crash-perf-daily-weekly-report`: 周报 NON_FATAL 段在呈现数据之外一并呈现处置结论；同时明确该要求**不延伸到 L1 日报**，使 L1/L2 职责边界对「结论呈现」有确定答案。
- `crash-perf-fix-status-reconcile`: 明确 NON_FATAL **不纳入** fixmap 反扫并给出理由，使该 spec 对两张表都有确定答案而非留白。

## Impact

**代码**

- `bin/render-ledger.sh`：`nf_rows()` 增 join 与两列；⚠️ 新增入参（结论存储路径），须与调用点同步
- `bin/crash-weekly.sh`：传入结论存储路径；周报 iOS NON_FATAL 下钻段增结论呈现。⚠️ 跨进程边界必须 `export`，漏了不报错（`REPOS_ROOT` 踩过）
- `bin/deliver.sh`：NON_FATAL 块 `block_replace` 列数变化，须确认飞书表格列宽——**列宽只能实发验证**
- `bin/check-scripts.sh`：十项检查须递归覆盖新增路径
- ⛔ `bin/crash-daily.sh` **不改**

**状态**

- 新增 `$STATE/ledger/dispositions.json`。⚠️ 它是**人工资产**、不是可重算的派生数据：`git clean -xfd` 与换机都会丢，须与 `last-snapshot.json` 同级纳入备份

**文档**

- 台账飞书文档 NON_FATAL 表标题下的静态说明需加两列解释（部署日人工动作，与 anr-tracking 的 2.4 / 4.5 同类）

**依赖与冲突**

- ⚠️ `crash-ledger-anr-tracking`（17/22，in-progress）正在改 `build_rows()` 与 Issue 现状表。本 change **只碰 `nf_rows()`**，不动 `build_rows()`，以避开在途冲突；FATAL/ANR 迁移到新存储须在其归档后另起。

## Non-goals

- ⛔ **本轮不迁移 FATAL / ANR 表的结论来源**，它们继续走 `prev_table` 解析。理由是避开 `crash-ledger-anr-tracking` 的在途范围，**不是**认为现状可接受——该脆弱点已在 Why 中记录，迁移另起 change。
- ⛔ **日报不呈现处置结论**（L1 职责边界，见 What Changes）。
- ⛔ **不把 NON_FATAL 并入 Issue 现状表**（量级）。
- ⛔ **不改 NON_FATAL 的入选判据**（继续按受影响安装取头部）。本 change 解的是「掉榜丢结论」，不是「谁该进榜」——换判据是 ANR 那条路，对千条级的 NON_FATAL 不成立。
- ⛔ **不把 NON_FATAL 纳入变化检测**（新增/回归/消失/暴涨）与卡片变化行。
- ⛔ **不建结论的历史版本 / 审计链**。结论是当前判断，被覆盖即失效；溯源看 `$STATE/ledger/snapshots/` 的专项报告。
