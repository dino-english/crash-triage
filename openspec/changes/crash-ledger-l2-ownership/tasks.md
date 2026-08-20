## 1. 前置验证（spike，未通过不得进入后续任务组）

- [x] 1.1 备份飞书台账文档 `TtpwdhgKroMH1DxJumojTflrppz` 当前内容到 `$STATE/backup/ledger-<日期>.xml`（`docs +fetch --as bot`），确认文件非空且可解析
- [x] 1.2 用 `docs +fetch --doc <token> --detail with-ids` 取得文档 block ID 列表，记录表格块的 ID
- [x] 1.3 对该表格块执行一次 `docs +update --command block_replace`，确认表格被替换且文档其余部分不变
- [x] 1.4 在文档末尾 `--command append` 追加一段内容，再次 `--detail with-ids` 取 ID，**验证表格块 ID 是否仍然一致**
- [x] 1.5 若 1.4 中 ID 变化 → 记录结论，改用锚点方案（`str_replace` 配 `<!-- LEDGER:TABLE:BEGIN -->` / `<!-- LEDGER:TABLE:END -->`），并更新 design.md D3 的选型结论
- [x] 1.6 实测 `crashlytics_list_events` 单个 issue 取全部事件详情的耗时与返回字段，确认含堆栈帧 / 设备 / 系统 / `memory.free` / `processState` / `current_screen` / breadcrumb / variant
- [x] 1.7 把 1.1–1.6 的结论写入 design.md（覆盖「未验证前提」段），未通过项标明替代方案

## 2. STATE 布局与仓库清理

- [x] 2.1 一次性清理旧布局残渣：保留**最近 1 组 L1**（同一时刻的 `crash-daily-<TS>` + `metrics-<TS>` 各一）与**最近 1 组 L2**（`weekly-<TS>` 一个）作为新旧布局对照样本，其余 `metrics-*` / `crash-daily-*` / `weekly-*` 全部删除。删前 `ls | wc -l` 记录基线，删后核对基准文件（`docs.json` / `folders.json` / `last-snapshot.json` / `daily-snapshot.json` / `metrics-history.jsonl` / `health-*.json`）仍在顶层原位未动
- [x] 2.2 删除 `$STATE` 下 26 个空目录与散落调试文件（`keychain-probe.log` / `index-render.md`）
- [x] 2.3 建立新目录骨架：`$STATE/{issues,ledger,runs,backup}`，确认 `docs.json` / `folders.json` / `last-snapshot.json` / `metrics-history.jsonl` / `health-*.json` **仍在顶层原位未动**
- [x] 2.4 `crash-daily.sh`：`TMP` / `CRASH_DIR` 改为 `$STATE/runs/<日期>/L1/<时刻>/`，跑批收尾创建 `latest` 软链
- [x] 2.5 `crash-weekly.sh`：`OUT_DIR` 改为 `$STATE/runs/<日期>/L2/<时刻>/`，同样建 `latest` 软链
- [x] 2.6 清理逻辑改为按 `$STATE/runs/<日期>/` 整目录清理（30 天），并确认 `issues/` 与 `ledger/` 不在清理范围内
- [x] 2.7 跑批收尾对空目录执行 `rmdir`（失败忽略），避免再产生空目录残渣
- [x] 2.8 仓库清理：`reports/LEDGER.md` / `reports/weekly-index.jsonl` / 两份专项快照 md 移入 `$STATE/ledger/`（`git rm --cached` + 物理移动），`.gitignore` 补规则
- [x] 2.9 确认 `reports/report-index.jsonl` 仍在 git 中且内容完整（历次飞书 URL 一条不少）
- [x] 2.10 `bash bin/check-scripts.sh` 全绿

## 3. L1 移除台账职责（BREAKING）

- [x] 3.1 `crash-daily.sh`：删除 `LEDGER_SRC` / `DOC_LEDGER_ID` 变量与台账 XML 渲染段
- [x] 3.2 `crash-daily.sh`：索引页模板移除 `__LEDGER_URL__` 占位符，台账行改为固定 URL 直链
- [x] 3.3 `crash-daily.sh`：索引页新增导航说明段（父目录 → `L1 日报` / `L2 周报` 子目录 → 按日期查找）
- [x] 3.4 `deliver.sh`：删除台账镜像导入步骤与 `__LEDGER_URL__` 回填逻辑
- [x] 3.5 `bash bin/check-scripts.sh` 全绿
- [x] 3.6 L1 DRY RUN：确认产物中无台账文件、无 `__LEDGER_URL__` 残留占位符、card.json 仍合法
- [x] 3.7 记录 L1 跑批耗时，与改造前基线对比（不应显著增加）

## 4. 事实层缓存

- [x] 4.1 `fetch-snapshot.sh`：新增事实层写入 —— 抓到的事件详情按 issue 落盘 `$STATE/issues/<32位id>.json`，含 1.6 确认的全部字段
- [x] 4.2 `fetch-snapshot.sh`：新增命中判定 —— 比较本地已存事件数与线上 `events` 计数，相等则跳过抓取
- [x] 4.3 `fetch-snapshot.sh`：新增增量合并 —— 线上计数更大时只抓增量并追加，既有事件记录不改写
- [x] 4.4 `fetch-snapshot.sh`：新增 `CRASH_REPORT_FORCE_REFETCH=1` 强制重抓开关
- [x] 4.5 `fetch-snapshot.sh`：抓取失败时以已有本地事实继续，产出中标明哪些 issue 事实不完整；区分「已查证为空」与「未查」
- [x] 4.6 首轮全量抓取实测：记录耗时，确认未触及 `TRIAGE_TIMEOUT`（1800s）—— 实测 12 个 issue 全量抓取 13m04s，远低于 1800s
- [x] 4.7 二次跑批实测：确认命中本地、跳过重抓，耗时显著下降 —— 实测命中 11 个/部分命中 1 个/未命中 0 个，耗时从 13m04s 降至 3m46s
- [x] 4.8 `bash bin/check-scripts.sh` 全绿

## 5. 修复状态反扫

- [x] 5.1 新增反扫函数：`git log --all --grep='\[crash:' --since='14 days'` 扫两个业务仓库，只读、不改工作区 —— `bin/scan-fix-commits.sh`
- [x] 5.2 解析 `[crash:<8位十六进制>]`，映射到当前 issue 集合的完整 32 位标识
- [x] 5.3 歧义处理：某 8 位短标识匹配到多于一个 issue 时不自动更新，在产出中标明待人工确认 —— 实测通过（伪造重复 short id 验证）
- [x] 5.4 业务仓库不可读时跳过该平台并显式标明，另一平台照常 —— 实测通过（`platform_unavailable` 数组）
- [x] 5.5 幂等性验证：连续两轮跑批扫到同一提交，台账中只记录一次 —— 脚本本身纯函数幂等（同输入同输出，`mapped` 以 issue id 为 key 天然去重）；落台账走 6.4 的 block_replace 定点覆盖，不追加
- [x] 5.6 状态判定：有修复提交且线上无新事件 → 「已修待验」；有修复提交但线上仍有新事件 → 「修了仍在」 —— 实测通过（比较事实层 `events[].eventTime` 最大值与提交时间）
- [ ] 5.7 确认反扫只改「处置状态」与提交标识两列，不覆盖结论性备注（延后到 6.2 台账渲染实现时一并验收，见该任务）

## 6. 台账产出与同步

- [x] 6.1 从两份业务仓库台账提取「项目常量」与「收口点登记」，双端并列，写入 `$STATE/ledger/LEDGER.md` 骨架（D11）
- [x] 6.2 实现 Issue 现状表渲染：单表双端，列为 `平台 / Issue ID / 标题 / 类型 / 首次纳入 / 处置状态 / 本次状态 / 事件量趋势 / 备注` —— `bin/render-ledger.sh`，实测通过（保留 first_seen/note，反扫只改处置状态与提交标识两列，5.7 一并验收）
- [x] 6.3 实现变更时间线渲染：每条含日期、变更摘要、周报文档链接 —— 同上脚本，实测新增/消失/暴涨/反扫状态变更均正确生成，平稳周不追加
- [x] 6.4 `crash-weekly.sh`：跑批末尾新增台账渲染与本地写入
- [x] 6.5 `deliver.sh`：新增台账同步 —— **决策更新（Sir 2026-08-19 批注见 comment）：首次建立四段结构改用 `append`，overwrite 全程不用**，`sync_ledger()` 已按此实现（block_replace 现状表 + append 时间线）
- [x] 6.6 定位失效时报错中止，**不退化为 overwrite**（规格硬要求）—— `sync_ledger()` 定位失败两处均 `return 1` 中止，无 overwrite 兜底路径
- [x] 6.7 台账同步失败不改变 L2 退出码，失败原因落日志，可单独重跑 —— `deliver.sh` weekly 分支只打印警告不 `fail`
- [x] 6.8 周报投递失败时不追加时间线条目（避免挂空链接）—— 同步位置在 `send_card` + `archive_append` 之后，且 `__REPORT_URL__` 只在 `URL_REPORT` 非空时回填
- [x] 6.9 `bash bin/check-scripts.sh` 全绿

## 7. L2 性能段

- [x] 7.1 `crash-weekly.sh`：复用 `perf-screens.sql` / `perf-network.sql` / `perf-traces.sql`，按周窗口取数
- [x] 7.2 周报新增性能段：双端分列，含启动耗时 / 慢帧最差页 / 冻结率 / 接口错误率
- [x] 7.3 性能段标注取数区间起止（双时区）与版本口径，显式声明与日报口径不可混比
- [x] 7.4 周环比呈现：有上周基准则标变化（箭头跟数值、颜色跟好坏），无基准则显式标明而非显示零变化 —— `$STATE/perf-history.jsonl` 按 (平台,版本) 存 P95，WoW 对比
- [x] 7.5 性能数据源不可用时性能段标明缺数原因，崩溃段不受影响 —— `PERF_OK` 独立于 `ADOPT_OK`/崩溃段判定
- [x] 7.6 确认性能内容**不写入台账**——`render-ledger.sh` 只读 snapshot.json（崩溃）与 fixmap.json，不涉及 PERF_ROWS/perf-history.jsonl
- [x] 7.7 确认性能段不产出根因与修复方案，只给趋势、对象与下一步取证方向——perf_md() 只渲染表格数值，无分析文本；报告文档三处显式声明「不出根因」
- [ ] 7.8 记录 L2 跑批新增耗时与 BigQuery 扫描量（待 8.3 完整 DRY RUN 时一并测量）

## 8. 端到端验收

- [x] 8.1 `bash bin/check-scripts.sh` 全绿
- [x] 8.2 L1 DRY RUN：exit 0，card.json 合法，无台账产物（2026-08-19 实测）
- [x] 8.3 L2 DRY RUN：exit 0，周报含崩溃段与性能段，台账本地源结构正确（158s）
- [x] 8.4 L2 真实投递到私聊 `ou_edd20a8dbfcc5e3ee279a225aec044d0`：周报文档 + 卡片 + 台账同步全部成功 — **延后到 10.8 与新增改动一起验**（Sir 2026-08-20 指示：不投递，修完统一测）
- [x] 8.5 人工抽查飞书台账：四段结构完整、现状表双端单表、时间线条目挂周报链接 — **延后到 10.9**（依赖 8.4）
- [x] 8.6 **二次跑批验证**：再跑一次 L2，确认现状表被更新而时间线历史条目完整保留（run2 正确将 run1 的 🆕新增 更新为 🔁遗留，first_seen 保持 2026-08-19）
- [x] 8.7 抽查 2–3 个数值与 Firebase 控制台对得上
- [x] 8.8 确认两个业务仓库工作区干净、无新增提交（只读约束未被破坏）

## 9. 文档与收尾

- [x] 9.1 `CLAUDE.md`：改写台账口径段 —— 删除「`reports/LEDGER.md` 是人工真相源」（已被证伪），改为台账由 L2 产出、本地源在 `$STATE/ledger/`
- [x] 9.2 `CLAUDE.md`：更新 L1/L2 职责表（L1 移除台账、L2 新增台账与性能段）
- [x] 9.3 `CLAUDE.md`：更新 `$STATE` 文件表，新增 `issues/` / `ledger/` / `runs/` 说明
- [x] 9.4 `CLAUDE.md`：新增 commit message 约定 `[crash:<8位id>]` 与反扫机制说明
- [x] 9.5 `CLAUDE.md`：按实测修正「L2 自动档不出根因」的适用范围（崩溃段实际会出根因与方案且标注未经复核；性能段不出）
- [x] 9.6 `bin/INSTALL.md`：更新目录结构与验收链
- [x] 9.7 提交（分两笔：代码改造 / 文档与清理），不 push 直到 Sir 确认 — `f8f338a` + `0dc1d25`，Sir 已 push
- [ ] 9.8 Mac mini 同步：`git fetch && merge --ff-only` → 重跑 `install.sh` → 确认 wrapper 正确 → 观察次日 07:00 与下周一 05:30 两次自动跑批

## 10. L2 数据层与分析层分离（2026-08-20 追加，design D12）

起因：2026-08-19 18:21 与 08-20 09:30 两次 Anthropic 429，L2 因 `snapshot.json` 拿不到而整跑 `fail`，群里什么都收不到。数据是确定性聚合，不该和分析同生共死。

- [x] 10.1 新增 `bin/sql/crash-issues-all.sql`：全版本口径 issue 聚合（刻意不加版本过滤，理由见 D12），含 `users` 列
- [x] 10.2 新增 `bin/fetch-snapshot-bq.sh`：纯 bq 产出 `snapshot.json`，结构与模型路径一致；两端皆空则非零退出
- [x] 10.3 事实层缓存判定移进 shell（文件存在性 + `events_count_last_seen` 比较），`CRASH_REPORT_FORCE_REFETCH=1` 强制重写；缓存文件标 `source:"bigquery"`，不覆盖模型路径的事件明细
- [x] 10.4 `crash-weekly.sh`：数据段改调 `fetch-snapshot-bq.sh`；反扫提前到取数之前，结果直接填 `fix_commit`
- [x] 10.5 `crash-weekly.sh`：分析段降级为可选，超时 / 非零退出（含 429）/ 未产出 `report.md` 均只降级；新增 `CRASH_REPORT_SKIP_ANALYSIS=1` 用于验证
- [x] 10.6 周报与卡片标注分析层状态：无分析时给出原因并声明数据与台账不受影响；同步修正「MCP topIssues / OPEN FATAL」旧口径文案
- [x] 10.7 自测：`check-scripts.sh` 全绿；`CRASH_REPORT_SKIP_ANALYSIS=1` 全链 DRY RUN exit 0，台账现状表 20 行、时间线增量与周报均产出；缓存三态（首跑 18 新增 / 二跑 18 命中 / FORCE 18 重写）实测符合预期
- [ ] 10.8 L2 真实投递到私聊 `ou_edd20a8dbfcc5e3ee279a225aec044d0`：周报文档 + 卡片 + 台账同步全部成功（合并原 8.4；首次同步走 `append` bootstrap）
- [ ] 10.9 人工抽查飞书台账：四段结构完整、现状表双端单表、时间线条目挂周报链接（合并原 8.5）
- [ ] 10.10 二次真实投递：确认现状表被 `block_replace` 更新而时间线历史完整保留（D2 核心验收点在飞书端的闭环，本地层面已由 8.6 验过）
- [ ] 10.11 额度恢复后跑一次**带分析**的 L2，确认分析层正常产出且标注切换为「✅ 本周含深度分析」
