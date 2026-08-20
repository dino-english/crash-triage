## Why

台账（LEDGER）当前的归属与实现存在三处结构性错位，且已在生产中产生可观测后果：

1. **台账真相源分叉**：`ab6748b`（2026-08-14）把 iOS 仓库的台账复制进 crash-triage 并将 `LEDGER_SRC` 指向副本，但未删除业务仓库原件。iOS 团队仍在更新原件（`b8522526`，08-17），三份台账已分叉（crash-triage 153 行 / iOS 98 行 / Android 70 行），L1 每天镜像的是**过期副本**，且标题写着「— iOS」——Android 那份 23 KB 的深度结论从未进入飞书。
2. **数据与分析职责错配**：L1 有性能数据但无分析能力；L2 有分析能力（实测 `report.md` 226 行、含风险分级与钻取确认）但完全不含性能。台账由 L1（纯数据链路）同步，而结论由 L2（分析链路）产出——写的人和搬的人不是同一条链路。
3. **事实层反复重抓**：`snapshot.json` 只存 6 个字段（`id/title/events/users/fix_commit/fix_branches`），而 L2 分析实际依赖堆栈帧、设备型号、系统版本、`memory.free`、`processState`、`current_screen`、breadcrumb、variant ID。模型每周调 `crashlytics_list_events` 读完即弃，下周对同一 issue 重抓同样的历史事件——崩溃事件是**不可变历史事实**，重抓无收益。

附带问题：`$STATE` 顶层已有 107 个条目（39 个 `metrics-*` + 37 个 `crash-daily-*` + 15 个 `weekly-*`，其中 26 个是失败跑批留下的空目录），按时间戳平铺，排查需先找时间戳；仓库内混放了可再生产出物（`LEDGER.md`、专项快照 md），违反「仓库只控代码」原则。

## What Changes

- **BREAKING** L1 不再生成、投递、镜像台账：移除 `crash-daily.sh` 的 `build_ledger_xml` 段与 `LEDGER_SRC` 变量，`deliver.sh` 不再导入台账镜像、不再回填 `__LEDGER_URL__`。
- 台账所有权移交 L2：新增台账渲染与同步能力，本地源 `$STATE/ledger/LEDGER.md`，同步到既有飞书文档 `TtpwdhgKroMH1DxJumojTflrppz`（复用）。首次建立四段结构走 `append` 追加，既有内容原样保留、由人工确认后另行清理，**任何阶段都不使用 `overwrite`**。
- 台账结构对齐 Android 仓库那份的四段式：项目常量 / 收口点登记 / **Issue 现状表**（单份双端，含「平台」列）/ **变更时间线**。现状表由 L2 用 `docs +update --command block_replace` 定点更新；时间线用 `--command append` 追加，绝不 `overwrite`。
- 台账初始内容**从零生成**：不合并 iOS（98 行）与 Android（70 行）两份业务仓库台账。旧台账留在各自业务仓库供随时查阅，新台账只跟当前线上 issue 走——首次运行时以本轮 `topIssues` 结果建立现状表基线，历史结论不迁移。
- 新增修复状态反扫：跑批时以 `git log --all --grep='\[crash:'` 扫两个业务仓库，解析 `[crash:<8位id>]` 约定，自动更新台账「处置状态」列并记录 commit hash。**不在业务仓库安装任何 hook**。
- 新增事实层缓存：首次抓取某 issue 时把完整事件详情落盘 `$STATE/issues/<32位id>.json`，永久保留；后续跑批先查本地，仅对新增事件增量抓取；`CRASH_REPORT_FORCE_REFETCH=1` 可强制重抓。
- L2 周报新增性能段：复用 L1 现成的 `perf-*.sql`，产出周维度趋势与 WoW。**性能不进台账**——性能是连续指标无追踪 ID，只在周报做趋势与页面定位，不出根因。
- `$STATE` 布局整理：跑批产物收进 `runs/<日期>/{L1,L2}/<时刻>/`（30 天清理，附 `latest` 软链）；基准文件（`docs.json` / `folders.json` / `last-snapshot.json` / `metrics-history.jsonl` / `health-*.json`）**保持在 `$STATE` 顶层不动**，零迁移风险。现有 91 个跑批残渣目录直接删除。
- 仓库清理：`reports/` 只保留 `report-index.jsonl`（存历次飞书文档 URL，飞书端无法枚举 bot 文档，删了永久断链，不可再生）；`LEDGER.md`、`weekly-index.jsonl`、两份专项快照 md 移入 `$STATE`。
- 索引页移除台账那一行的旧语义，改为标明结构与导航方式（父目录 → `L1 日报` / `L2 周报` 子目录 → 按日期查找），台账单独一行指向固定 URL。

## Capabilities

### New Capabilities
- `crash-perf-ledger-ownership`: 台账的产出方（L2）、渲染结构（四段式 + 双端单表）、飞书同步方式（`block_replace` 表格 + `append` 时间线）、以及 L1 移除台账职责后的边界。
- `crash-perf-issue-fact-cache`: 崩溃事件事实层的落盘结构、命中判定、增量抓取与强制重抓语义。
- `crash-perf-fix-status-reconcile`: `[crash:<8位id>]` commit message 约定、跑批期反扫窗口与幂等性、台账「处置状态」列的更新规则与不可覆盖边界。
- `crash-perf-weekly-performance`: L2 周报性能段的取数口径、周维度趋势与 WoW 呈现、以及「不出根因」的硬边界。
- `crash-perf-state-layout`: `$STATE` 目录分层（`runs/` 按日期分组 + 顶层基准文件不动）、清理策略、以及仓库内产出物的保留判据。

### Modified Capabilities
- `crash-perf-daily-weekly-report`: L1 产出物集合移除台账镜像；L2 产出物集合新增台账同步与性能段；新增 L1/L2 职责边界。同时废止三条前提已被证伪的既有需求 —— 「台账真相源是仓库文件」（三份台账已分叉，该前提在生产中从未成立）、「修复状态判定口径」（iOS 靠 32 位 ID 反查的前提不成立，移交 `crash-perf-fix-status-reconcile`）、「索引页与台账镜像过渡」（过渡态两端均已了结）。并按实测重划「L2 自动档不产出根因」的适用范围：崩溃段可出但须标注未复核，性能段不出。
- `crash-perf-deterministic-delivery`: 投递链路移除「导入台账镜像 → 回填 `__LEDGER_URL__`」两步，台账同步排在周报卡片发送之后；新增台账定点更新（非新建、非整份覆盖）契约。

## Impact

**代码**
- `bin/crash-daily.sh`（1378 行，26 处 `$STATE` 引用）：移除台账段，跑批产物路径改为 `runs/<日期>/L1/<时刻>/`
- `bin/crash-weekly.sh`（421 行，13 处 `$STATE` 引用）：新增台账渲染与同步、性能段、修复状态反扫
- `bin/deliver.sh`（7 处 `$STATE` 引用）：移除台账镜像导入，新增台账定点更新
- `bin/fetch-snapshot.sh`：事实层落盘与命中判定
- 新增 `bin/sql/` 复用（性能段不新增 SQL 文件）
- `bin/check-scripts.sh`：无需改动（语法自检与多字节校验继续适用）

**文档**
- `CLAUDE.md`：台账口径段（「`reports/LEDGER.md` 是人工真相源」的表述已被证伪，需改写）、L1/L2 职责表、`$STATE` 文件表、硬约束中「L2 自动档不出根因」的适用范围需按实测重新界定
- `bin/INSTALL.md`：目录结构与验收链

**外部依赖**
- 飞书文档 `TtpwdhgKroMH1DxJumojTflrppz`（台账，复用；新结构以 `append` 建立，不覆盖既有内容）
- 飞书文档 `UPQNdbzGio2l3bxOleRjK1nOpHd`（索引页，移除台账旧语义行）
- 两个业务仓库：只读 `git log`，**不安装 hook、不 commit、不 push**（既有只读约束不变）
- `lark-cli` 的 `docs +update --command block_replace / append`（能力已实测存在）

**未验证前提（需在实施期先验，不得假设）**
- `block_replace` 在台账文档结构变动后能否稳定定位表格块；退路是 `str_replace` 配锚点标记

**生产影响**
- 改动在 MacBook 本地进行，测试投递到私聊 `ou_edd20a8dbfcc5e3ee279a225aec044d0`
- Mac mini 保持现状运行现有代码（`crash-daily` 07:00 / `crash-weekly` 周一 05:30），验收通过后才同步
- MacBook 侧两个 cron job 保持 paused，避免双跑
