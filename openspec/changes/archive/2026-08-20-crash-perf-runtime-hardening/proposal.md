## Why

流水线本身的数字是确定性的（bq + jq），但**运行链路里塞进了三类不确定性**，每一类都已经实际咬过人：

1. **路径硬编码**：`CRASH_REPORT_ROOT` 默认写死 `$HOME/crash-triage`，plist 里写死 `/Users/USER/crash-triage`，注释与文档写死 `~/gitWorkspace`（这个目录在本机根本不存在）。换机器、换用户名、换工作区都要手改多处。
2. **双副本分叉**：`bin/`（运行时）与 `scripts/crash-report/`（源副本）是同一套脚本的两份拷贝，靠人记得双改。2026-08-14 评审发现 `fetch-snapshot.sh` 反引号转义只改了一侧；2026-08-18 接手时 `crash-daily.sh` 两侧仍有差异。
3. **LLM 投递**：建文档 → 拿 URL → 回填占位符 → 发卡片全是确定性 API 调用，却交给 Hermes cron agent 执行。代价写在 `crash-perf-execution-audit-log` 的 proposal 里：「脚本成功但 agent 中途崩（文档建了、卡片没发）会留下重复文档+重复卡片而系统完全不自知」，为此又要设计一整套投递幂等台账 + `card_sent` 闸门去兜。

同时状态与代码混在一起：运行数据落在仓库目录并靠 `.gitignore` 遮住，而 `git clean -xfd` / 重新 clone 会把它们连根抹掉——其中 `last-snapshot.json` 丢失会让下周把所有 issue 报成新增（2026-08-07 那类事故）。

## What Changes

**路径自解析（零硬编码）**

- 运行根 = 本脚本所在 `bin/` 的上级目录（`BASH_SOURCE` 解析），仓库 clone 到哪都能跑；`CRASH_REPORT_ROOT` 显式设置仍优先。
- `REPOS_ROOT` 自动探测：优先运行根的**同级目录**（业务仓库通常并排 clone，只读 fetch），没有才用 `$ROOT/repos` 隔离 clone——旧安装因未设此值重复 clone 了 175M。
- launchd plist 改为带 `__ROOT__` / `__STATE__` 占位符的模板，由 `setup.sh` 按本机实际路径生成到状态目录，不再往仓库写带本机路径的脏文件。

**代码与状态分离**

- 代码根（仓库，git 管）：`bin/` · `sql/` · `reports/LEDGER.md`。
- 状态根 `CRASH_REPORT_STATE_DIR`（默认 `${XDG_STATE_HOME:-~/.local/state}/crash-triage`）：`logs/` · 生成的日报周报 · 快照 · 历史 · `publish/` · `audit/` · `config.env` · 生成好的 plist。
- **例外**：`reports/weekly-index.jsonl` 反向移入仓库并纳入 git——它存的是历次周报飞书文档的 URL，飞书端无法枚举本 bot 的文档，丢了就永久断链。其余状态均可再生。
- `.gitignore` 随之简化：仓库里不再产生运行时文件。

**删除双副本**

- `scripts/crash-report/` 整体删除（19 个文件）。`bin/` 本身全部纳入 git，副本不承载独有内容；其存在前提（源在 git、运行在别处、`setup.sh` 负责搬运）已随「运行根即仓库」消失。
- `setup.sh` 的自装 cp 逻辑一并删除。

**投递去 agent 化**

- 新增 `bin/deliver.sh`：读 manifest，用 `lark-cli` 完成导入文档 → 回填占位符 → 发交互卡片。生成脚本末尾串行调用，**投递失败不改变生成脚本退出码**（数据已落盘，重跑即补投）。
- **幂等靠 `lark-cli --idempotency-key`**（值 = `run_id`），不需要投递台账——`crash-perf-execution-audit-log` 的 T1（投递幂等台账 / `card_sent` 闸门 / 同日补投策略）因此可以整体取消。
- **陈旧 manifest 闸门**：manifest 新增 `day` / `run_id`；`day` 不等于今天则拒绝投递并报错。脚本失败时不会重写 manifest，照投就会把昨天的卡片当今天发。
- 同一位置的导入必须串行（并发撞 `232140101`/`232140100`/`233523001`），`deliver.sh` 天然串行。

**文档组织与归档统一**

- 云文档按目录收纳：`Dino 崩溃 & 性能日/周报` 父目录 + `L1 日报` / `L2 周报` 子目录，按名字幂等查找（查不到才建，token 缓存在状态目录）。
- 索引与台账镜像改为**原地覆盖**（`docs +update --command overwrite`，设了 `DOC_INDEX_ID` / `DOC_LEDGER_ID` 时生效），URL 固定；日报周报仍每次新建（快照性质）。此前「只能新建不能覆盖」是 MCP 工具 `docx_builtin_import` 的限制，换 lark-cli 后不再成立。
- 日报与周报**统一归档在一份 `reports/report-index.jsonl`**（进 git），索引页据此渲染两张归档表。此前只有周报有归档，日报文档次日即成孤儿（一年约 730 份）。

## Capabilities

### New Capabilities

- `crash-perf-runtime-layout`: 路径自解析与代码/状态分离的运行时布局契约
- `crash-perf-deterministic-delivery`: 投递链路的确定性与幂等契约

## Impact

**代码**：`bin/crash-daily.sh` · `bin/crash-weekly.sh` · `bin/setup.sh` 路径段重写；两个 plist 改占位符模板；新增 `bin/deliver.sh`；删除 `scripts/crash-report/`（19 文件）；`.gitignore` 重写。

**契约取消**：`crash-perf-execution-audit-log` 的 T1「投递幂等台账」不再需要（幂等已由 lark-cli 原生提供），该 change 归档时应删除对应条目。

**运维**：`~/crash-triage`（08-13 的旧独立安装，431M）已删除。Mac mini 若靠默认值而非显式 `CRASH_REPORT_ROOT` 运行，部署时需确认运行根变化。

**兼容**：旧的 `reports/weekly-index.jsonl` 在索引渲染时仍会被读入合并，历史周报不断链。
