## Context

**当前状态（2026-08-14）**：`scripts/crash-report/` 已实现并跑通两条链路，产出发到飞书群「Dino 崩溃 & 性能日/周报」（`oc_655033f1f85fa04f9eac25d56f056fc9`）。实现完整（`INSTALL.md` 344 行装机清单 + 两个主脚本 + 快照抓取 + SQL 片段 + launchd plist），但从未沉淀成 openspec change，`ios-nonfatal-reporting` 里的「崩溃日报（change 待建）」引用悬空至今。

**数据源现状**：

| 数据 | 现状 | 备注 |
|---|---|---|
| 性能（trace / 慢帧 / 网络） | ✅ BigQuery `firebase_performance` 已就绪 | 双端表均已到位 |
| 会话 / 版本放量（分母） | ✅ BigQuery `firebase_sessions` 已就绪 | 修复验证的分母 |
| 崩溃 | ⚠️ 临时走 Firebase MCP `topIssues` | 只返回 OPEN issue；待 `firebase_crashlytics` 出表换事件级 |
| 崩溃率 | ❌ 缺（`firebase_crashlytics` 未出表） | 分子缺失；SQL 待补 |

**运行宿主**：Mac mini（launchd 定时任务）。依赖 `gcloud`/`bq`、`firebase-tools`、`jq`；L2 额外依赖 `claude`。飞书投递由 Hermes agent 经 lark-mcp 完成。

**相关 change**：`ios-nonfatal-reporting`（NON_FATAL 通路，日报需为其展示维度）、`analytics`（产品埋点，与本文不同通道）。

**利益相关方**：iOS 开发、@魏博源（崩溃性能负责人）、Android 侧（issue ID 提交约定对齐）。

## Goals / Non-Goals

**Goals:**
- 把已存在的日/周报流水线正式登记为 openspec 能力，使需求、口径、约束、缺口可被检索与审计
- 固化两条链路的硬约束（只读、自动档不产根因、台账真相源、确定性变化检测、无变化不发），防止后续改动退化
- 收编已知缺口为可跟踪的 tasks，让「崩溃率 SQL」「L2 超时保护」「Android 约定对齐」有据可依

**Non-Goals:**
- **不改任何脚本行为**——本 change 是登记/文档化，脚本已跑通，不动实现
- 不新增数据源、不新增告警维度、不改定时时间
- 不把 L2 升级为「自动产根因」——硬约束保持
- 不覆盖 `nonfatal-reporting`（NON_FATAL 通路）与 `analytics`（产品埋点）的契约

## Decisions

### D1. 两条链路分工：L1 日报纯 shell，L2 周报用模型

**选择**：L1 每日数据日报完全不用模型（纯 `bq` + `jq` + shell）；L2 每周变化播报用模型（`claude -p`）但只用于取数与 git 反查。

**理由**：日报是固定模板的确定性查询，模型只会增加延迟与不确定性；周报的 triage 需要语义分析（读 issue 标题、判严重度、反查修复），模型不可省。两条链路按「是否需要语义」划界。

**代价**：L2 有模型成本与挂死风险（见 R5）；L1 模板改动需改脚本。

### D2. 只读 clone，绝不写业务仓库

**选择**：`repos/` 下维护只读 clone（dino-english-ios / dino-english-android），`git fetch` + `reset --hard` 同步；`git reset --hard` 只对 `repos/` 下的 clone 执行。

**理由**：自动链路一旦有写权限，误操作会污染工作仓库。台账更新由开发者在修复提交时顺手完成，自动链路只读 + 镜像。

**代价**：台账镜像最多滞后一天（挂在 L1 每天同步）。

### D3. L2 自动档不产根因与修复方案（硬约束）

**选择**：自动档只报「变了什么」，根因分析留给人工 `firebase-crash-triage`。

**理由**：2026-08-06 实例——自动生成的修复方案看似合理实则错误，且被下一轮 `git log --grep` 误判为「已修复」，错误自我强化。因果推断不可自动化。

**代价**：周报只给变化清单，落地动作仍需人介入。

### D4. 崩溃数据源过渡：MCP → BigQuery 事件级

**选择**：现阶段崩溃走 MCP `topIssues`，`firebase_crashlytics` 出表后改事件级统计。

**理由**：`topIssues` 只返回 OPEN issue——被误关的 issue（曾发生 `3fd09886` 误关事故）会从统计里消失并显示「0 崩溃」，看起来健康实际在崩。事件级统计（BigQuery）不受 issue 开关状态影响。

**代价**：过渡期日报有口径限制，必须显式标注（见 spec）。

### D5. 台账真相源 = 仓库文件，飞书是只读镜像

**选择**：`reports/crash-triage/LEDGER.md` 为真相源，L1 每日 overwrite 同步到飞书，镜像顶部带「请勿在此编辑」。

**理由**：台账需要 git 历史、code review、跨端共享；飞书文档无版本控制。让仓库为源，飞书只为「不看仓库的人也能读」。

### D6. 定时时间：L1 07:00，L2 周一 05:30

**选择**：L1 每天 07:00，L2 每周一 05:30（本地时区 Asia/Kuala_Lumpur），间隔 90 分钟。

**理由**（2026-08-07 实测）：① 避开打包高峰（近 8 个工作日 86 次构建中 01:00–07:00 为 0 次）；② 09:00 上班前报告已在群聊顶端；③ L2 完整 triage 实测 12 分钟以上，原定 06:30 与 07:00 的 L1 重叠会撞 lark-cli 429，故 L2 提前到 05:30 留 90 分钟余量。

### D7. 变化检测用 jq 确定性计算，不经模型

**选择**：L2 的新增/暴涨/消失/已修待验由 jq 对比 last-snapshot 与新快照确定性算出；模型只负责抓数据 + git 反查。

**理由**：变化检测是机械判定（事件量翻倍、issue 出现/消失），模型做反而引入不确定性；确定性计算可复现、可测。

**代价**：判据（如「暴涨 = 2 倍且 ≥5 次」）需硬编码，调整需改脚本。

### D8. 无变化不发

**选择**：L2 周报在变化数为 0 时静默跳过发送。

**理由**：周报是「变化播报」，无变化的一周发空卡片是噪音，会让群里的人逐渐忽略它。

### D9. bot 身份发消息，不走 OAuth

**选择**：飞书发消息与建文档都走 **bot 身份**，bot token 由 appId + appSecret 自动换取。

**理由**：不走 OAuth、无 7 天过期问题；user 授权只用于 CLI 配置初始化（2026-08-06 实测 user 为 `needs_refresh` 时 bot 仍 `ok=true`）。

**代价**：bot scope 不足需在开放平台后台申请，不是机器侧能解决的。

## Risks / Trade-offs

**R1. 崩溃率长期算不出（`firebase_crashlytics` 未出表）**
→ 日报只能报绝对数量，无法区分「没人用」与「没崩溃」。缓解：版本放量表（`firebase_sessions`）已就绪，提供分母视角；崩溃表出表后补 SQL。

**R2. MCP `topIssues` 只返回 OPEN，误关即消失**
→ 已有纪律：`--allowedTools` 禁止 server 前缀通配，逐个列只读工具；迁移到 BigQuery 事件级后此问题自动消失。

**R3. BigQuery 每日批量同步滞后约一天**
→ 卡片打印真实数据截止时间戳，不假设「截至昨天」；若需准实时需开 streaming export（Blaze 计划）。

**R4. 机器休眠错过触发**
→ launchd 的 `StartCalendarInterval` 在休眠错过时会唤醒补跑（与 cron 不同），报告不丢但可能延迟到唤醒时刻。

**R5. L2 无整体超时，agent 卡死会挂起**
→ 已给 `TRIAGE_TIMEOUT=1800`（30 分钟）包裹 triage 阶段；但需确认 `run_with_timeout` 是否覆盖全部 agent 调用。挂死会导致下周又起一个。待办：引入 `gtimeout` 整体兜底。

**R6. lark-cli 限流 429 导致文档静默不更新**
→ 发布函数带 exponential backoff + jitter 重试（最多 4 次）；探活带 3 次重试。

**R7. Android 无法自动判定修复状态**
→ 显示为 `—` 而非「未修」；打通前提是推动 Android 采用「提交信息带 issue ID」约定（待办）。

## Migration Plan

本 change 是**登记已实现的系统**，无迁移步骤：

1. **已实现**：`scripts/crash-report/` 完整跑通（见 Context）
2. **本 change**：登记契约（proposal + design + spec）+ 收编缺口（tasks）
3. **待办**（见 tasks 待办组）：部署 Mac mini、崩溃表出表后换数据源、L2 超时保护、Android 约定对齐
4. **归档**：本 change 归档后 spec 落入 `openspec/specs/crash-perf-daily-weekly-report/spec.md`

**回滚**：本 change 无代码改动，回滚 = 删除本 change 目录即可，脚本与台账不受影响。

## Open Questions

- `firebase_crashlytics` BigQuery 表的出表时间（2026-08-06 11:09 开通导出，当时已超 48 小时窗口大半未出表；需在控制台查导出配置）
- 崩溃率 SQL 的最终口径（分母 `firebase_sessions` 已就绪，分子待 `firebase_crashlytics`）
- L2 是否需要引入 `gtimeout` 整体超时保护（当前 `run_with_timeout` 是否已覆盖全部 agent 调用待确认）
- Android 是否采用「提交信息带 issue ID」约定（打通自动修复状态判定的前提，需跨端推动）

**已关闭**：
- ~~崩溃数据走 MCP 还是 BigQuery~~ → 过渡方案：MCP 先用，BigQuery 出表后换事件级（D4，2026-08-14）
- ~~定时时间~~ → L1 07:00 / L2 周一 05:30，间隔 90 分钟（D6，2026-08-07）
