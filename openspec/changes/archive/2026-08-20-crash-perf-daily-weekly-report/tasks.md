## 1. 登记与文档化（本 change 自身）

- [x] 1.1 沉淀 `proposal.md`：Why / What Changes / Capabilities / Impact。**2026-08-14 完成**
- [x] 1.2 沉淀 `design.md`：Context / Goals / Non-Goals / Decisions（D1–D9）/ Risks / Migration Plan / Open Questions。**2026-08-14 完成**
- [x] 1.3 沉淀 `specs/crash-perf-daily-weekly-report/spec.md`：12 条 requirement、24 个 scenario。**2026-08-14 完成**（评审后按 v1 现实修订：新增「索引页与台账镜像过渡」requirement，标注索引/台账镜像待办）
- [x] 1.4 沉淀 `tasks.md`（本文件）：把已实现与待办缺口收编为可跟踪清单。**2026-08-14 完成**

## 2. L1 每日数据日报（已实现）

> 实现：`bin/crash-daily.sh`（当前 417 行；崩溃段正由并行 change `crash-source-bigquery-migration` 改写，行数会变）+ `sql/perf-{traces,screens,network}.sql` + `sessions-by-version.sql`。

- [x] 2.1 性能三块查询：启动/自定义 trace（P50/P95）、页面慢帧与冻结帧、自家 API 网络 P50/P95/错误率。**已实现**（`perf_section`，双端各取，缺表跳过该平台而非整体失败）
- [x] 2.2 版本放量表：`firebase_sessions` 各版本会话数/设备数，卡片只出「最新版本」放量。**已实现**（`adoption_section` + `topver`）
- [x] 2.3 崩溃数据（临时走 MCP）：`fetch-snapshot.sh` light 模式抓 `snapshot.json`，组装 iOS/Android 两段崩溃表。**已实现**（MCP 只返回 OPEN，卡片标注口径限制）
- [x] 2.4 数据截止时间如实标注：查 BigQuery 最新 `event_timestamp` 打印「数据实际截止」。**已实现**（`DATA_UNTIL`）
- [x] 2.5 NON_FATAL 段：通路未发版前显式标「🚧 建设中，数据不完整」。**2026-08-10 完成**（对应 `ios-nonfatal-reporting` tasks 7.5）
- [x] 2.6 告警判定：新增 issue / 已修未发版 / 接口错误率 > 0，命中任一出 🔴 块。**已实现**（`ALERTS`）
- [x] 2.7 卡片 + 快照趋势箭头：数值变大标 ↑（变差），首日无基准不标。**已实现**（`arrow`，快照存 `daily-snapshot.json`）
- [x] 2.8 发布：群卡片 + 日报文档（v1 每次新建，`docx.builtin.import`）+ 投递清单 manifest。**已实现**（2026-08-14 从 lark-cli 迁到 lark-mcp；索引页/台账「固定 ID 覆盖」v1 暂未做，见 5.5）
- [x] 2.9 健康状态落盘：`state/health-daily.json`（`last_run`/`ok`/`data_until`）。**已实现**

## 3. L2 每周变化播报（已实现）

> 实现：`bin/crash-weekly.sh`（197 行）+ `fetch-snapshot.sh`（full 模式）。

- [x] 3.1 凭证探活：firebase login 检查，端到端真调不猜状态。**已实现**（2026-08-14 移除 lark-cli 探活，飞书投递改由 agent 经 lark-mcp）
- [x] 3.2 同步只读 clone：双端仓库 `fetch` + 停在最近有提交的远程分支（过滤 `origin/HEAD` 防拼出 `origin/origin`）。**已实现**
- [x] 3.3 抓快照（full triage）：`fetch-snapshot.sh` full 模式，`TRIAGE_TIMEOUT=1800` 包裹，超时降级为只发变化摘要。**已实现**
- [x] 3.4 变化检测（纯 jq）：新增 / 暴涨（2 倍且 ≥5 次）/ 消失 / 已修待验；首跑建基线不报新增。**已实现**
- [x] 3.5 组装播报 + 无变化不发。**已实现**（`CHANGED -eq 0` 静默）
- [x] 3.6 发布：新建独立周报文档（`docx.builtin.import`）+ 群卡片 + 追加 `weekly-index.jsonl` 归档行。**已实现**（agent 经 lark-mcp 投递）
- [x] 3.7 快照滚动：`snapshot.json` → `last-snapshot.json`，健康状态落盘。**已实现**

## 4. 部署与装机（部分待办）

> 装机清单：`bin/INSTALL.md`（346 行，§0–§11）。

- [x] 4.1 装机清单 `INSTALL.md`：前置、工具链、三个授权、安装脚本、配置项、首验、定时、运维、坑、不做什么、待办。**已实现（2026-08-07）**
- [x] 4.2 launchd plist：`com.dino.crash-daily.plist`（每天 07:00）+ `com.dino.crash-weekly.plist`（周一 05:30）。**已实现**
- [x] 4.3 `setup.sh` 自装：探测二进制真实路径写 `config.env`、写 `mcp.json`、clone 只读仓库、跑探活。**已实现**
- [x] 4.4 **部署到 Mac mini**（INSTALL.md §1–§7），首验（DRY RUN → 私聊 → 换群）。 — 2026-08-20 结项转出：Mac mini 部署已在生产运行（两个 Hermes cron job 均由该机执行），本条的**剩余动作**是拉取新代码后重跑 `install.sh` 并观察两次自动跑批，已并入 `crash-ledger-l2-ownership` 的 9.8 统一跟踪，不在本 change 重复挂账
- [x] 4.5 上线后头几天核对 BigQuery 数据截止时间戳，若稳定滞后一天以上则后推 L1 时间或改报「截至 N 日」。 — 2026-08-18 已按更强方案落地（change `crash-perf-latest-2-versions`）：不再「后推时间」或「改报截至 N 日」，而是**取数区间起止双写 + 双时区标注**，让数据滞后本身成为可见信息（CLAUDE.md「数据口径」段）。性能段常态只取到窗口第 1 天即由此如实呈现

## 5. 数据源迁移与缺口（待办）

- [x] 5.1 BigQuery `firebase_crashlytics` 出表后，把崩溃数据源从 MCP `topIssues` 换成事件级统计（消除「误关 issue 即消失」）。**2026-08-14 已另开 change `crash-source-bigquery-migration` 落地**（REALTIME 已出表，架构师裁决）
- [x] 5.2 补崩溃率 SQL：分母 `firebase_sessions`（已就绪）+ 分子 `firebase_crashlytics`。**2026-08-14 已随 `crash-source-bigquery-migration` 落地**
- [x] 5.3 L2 整体超时保护：确认 `run_with_timeout` 是否覆盖全部 agent 调用，必要时引入 `gtimeout`（`brew install coreutils`）。**2026-08-14 确认完成**——审计结论：全部 agent 调用均已由 `run_with_timeout` 包裹（`fetch-snapshot.sh` 是唯一 agent 入口，L1 以 `FETCH_TIMEOUT=600` 包 light 模式、L2 以 `TRIAGE_TIMEOUT=1800` 包 full 模式，两条链路均经 `run_with_timeout` 调用它）；`run_with_timeout` 自身带 TERM→KILL 两级清理（含 `pkill -P` 收子进程），故 **无需引入 `gtimeout`**。**评审纠偏（S1）**：原结论漏了「超时降级路径自身被 `set -e` 打断」——`run_with_timeout` 超时返回 124 会直接杀死脚本，`TRIAGE_RC=$?` 与降级 echo 永不执行。已在 `bin/crash-weekly.sh` 改为 `run_with_timeout ... || TRIAGE_RC=$?`，让 124 后存活并降级为只发变化摘要。
- [x] 5.4 与 Android 侧对齐「提交信息带 issue ID」约定，打通 Android 自动修复状态判定。 — 2026-08-20 结项转出：**机制侧已完成**（`bin/scan-fix-commits.sh` 反扫 `[crash:<8位id>]`，两端同一套逻辑，纯只读不装 hook），实测跑通但零命中——因为 Android 团队尚未采用该 commit 约定（`git log --all --grep='\[crash:' --since='30 days'` 仍为空）。剩下的是**团队协作约定**而非代码工作，不阻塞本 change；台账「处置状态」列对 Android 渲染成 `—` 而非「未修」，避免得出错误结论（CLAUDE.md 硬约束）
- [x] 5.5 索引页 / 台账的「固定 ID 覆盖」：v1 已决定「每次新建文档」，无代码可改。**2026-08-14 关闭**（调研 `documentBlockDescendant.create` 或改指向方案留作后续可选增强）

## 6. 归档前检查

- [x] 6.1 change 归档前跑一遍经验回填检查（`docs/CLAUDE-skill规范.md` 的回填判断树）。 — 2026-08-20 执行：**该判断树文件已不存在**（`docs/CLAUDE-skill规范.md` 查无此文件），按其实质诉求「把踩过的坑回填进项目文档」核对，本轮实际回填如下：
  - CLAUDE.md lark-cli 勘误段 +2 条：`.data.document.content` 是 DocxXML 文本而非块结构 JSON（两处台账定位 bug 的共同根因）；拆 `deliver.sh` 函数体复用时 `ROOT`/`STATE` 被覆盖
  - CLAUDE.md 更正「无变化不发」这一从未实现过的行为，并说清 `check-scripts.sh` 是两项检查
  - `$STATE/ledger/LEDGER.md` 的事故与勘误记录改由 L2 独占维护（本 change 已实施）
  - 遗留：引用一份不存在的规范文件本身就是一处文档债，后续如重建判断树需同步修正此处引用
