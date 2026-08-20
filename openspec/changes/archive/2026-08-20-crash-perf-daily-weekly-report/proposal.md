## Why

崩溃与性能数据散落在 Firebase 控制台与 Crashlytics issue 列表里，无人值守时只能靠人肉查：上线后有没有新崩溃、哪个版本在恶化、启动耗时有没有变慢、接口错误率有没有抬头，都靠「想起来去翻」。

`scripts/crash-report/` 里已经实现了一套完整的无人值守流水线——**L1 每日数据日报** + **L2 每周变化播报**——产出发到飞书群「Dino 崩溃 & 性能日/周报」（`oc_655033f1f85fa04f9eac25d56f056fc9`），但它**从未沉淀成 openspec change**：`ios-nonfatal-reporting` 里「崩溃日报（change 待建）」的引用一直悬空，需求、口径、约束、已知缺口全部只存在于脚本注释与 `INSTALL.md` 里，不可被 openspec 的归档/审计机制检索。

本 change 把这套已存在的系统**正式登记为 openspec 能力**：把两条链路的契约（数据源、口径、产出、硬约束）、已知坑与待办缺口收编成可检索的 requirement + tasks，让后续对日报/周报的任何改动（换数据源、加维度、改时间、加告警）都走标准的 change 流程。

## What Changes

- **新建能力 `crash-perf-daily-weekly-report`**：登记崩溃 & 性能日/周报两条链路的完整契约
  - **L1 每日数据日报**（`crash-daily.sh`）：每天 07:00，BigQuery 性能 + Crashlytics 崩溃 → 飞书群卡片 + 日报文档（v1 每次新建，`docx_builtin_import`）
  - **L2 每周变化播报**（`crash-weekly.sh`）：每周一 05:30，Firebase MCP 快照 + git 反查 → 新建独立周报文档 + 群卡片 + 索引页追加归档行
  - **过渡态待办**：重建索引页、同步台账镜像（固定 ID 覆盖）v1 暂未实现，照「崩溃数据源过渡」写进 spec
- **固化硬约束**：两条链路都不写业务仓库；L2 自动档不产出根因与修复方案；台账真相源是仓库文件（飞书是只读镜像）；变化检测用 jq 确定性完成不经模型；无变化不发（避免播报噪音化）
- **收编已知缺口**：崩溃率 SQL（等 `firebase_crashlytics` 出表）、L2 整体超时保护、Android issue ID 提交约定对齐、部署到 Mac mini

## Capabilities

### New Capabilities

- `crash-perf-daily-weekly-report`: 崩溃 & 性能日/周报自动化流水线——两条链路的定时、数据源、口径、产出、硬约束、告警判定与已知缺口

### Modified Capabilities

<!-- 无。本 change 为纯登记/文档化，不新增或修改现有能力的行为契约。
     与 `analytics`（产品埋点，进 Firebase Analytics / 看板）与 `nonfatal-reporting`（非致命上报通路，进 Crashlytics issue）是不同通道、不同消费端。 -->

## Impact

**代码**：无新增——`bin/` 已实现（`crash-daily.sh` / `crash-weekly.sh` / `fetch-snapshot.sh` / `setup.sh` / `lib.sh` / `sql/*.sql` / 两个 launchd plist，`scripts/crash-report/` 为 git 管理源副本）；本 change 只登记契约与收编待办。apply 阶段仅对 `fetch-snapshot.sh` 做了一处反引号转义修正（防 heredoc 内 markdown 代码段被 shell 吞掉）与接口错误率告警的变量修复，不改脚本行为。

**文档**：
- 新增 `openspec/changes/crash-perf-daily-weekly-report/`（本 change）
- 归档后 spec 落入 `openspec/specs/crash-perf-daily-weekly-report/spec.md`
- 台账 `reports/LEDGER.md` 已登记「崩溃 & 性能日/周报」现状

**运行环境**（Mac mini，定时任务宿主）：依赖 `gcloud`/`bq`、`firebase-tools`、`jq`；L2 额外依赖 `claude`（`AGENT_CMD` 可换 cursor / codex）。飞书投递由 Hermes agent 经 lark-mcp（`im_v1_message_create` + `docx_builtin_import`）完成，不再用 `lark-cli`。

**运营**：
- 团队每天早上上班前在飞书群看到前一天崩溃/性能摘要，每周一看到变化播报
- 台账 `reports/LEDGER.md` 每日同步镜像到飞书（v1 落地后），不看仓库的人也能读
