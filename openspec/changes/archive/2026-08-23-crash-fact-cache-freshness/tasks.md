## 1. 基线取证（改之前先留证据）

- [x] 1.1 快照当前 `$STATE/issues/` 全部 18 个文件到 `$STATE/backup/fact-cache-before-<日期>/`，并记录每条的 `events_count_last_seen` / `latest_event` / `last_synced` / `source` 一览表
- [x] 1.2 实测确认窗口语义：同一个 issue 用 `{{DAYS}}=7` 与 `{{DAYS}}=30` 各跑一次 `bin/sql/crash-issues-all.sql`，记录两次的 `events` 值。**不同即坐实非单调**（design 的前提，虽已由 SQL 文本确证，留一份实测记录便于将来复查）
- [x] 1.3 全部 7 条 bq 记录的存档计数与当前 7d 窗口计数**逐条比对，尚无衰减**（最早事件在 08-17，**08-24 起开始出窗**）——定时炸弹未爆，趁现在修最便宜。原文：挑一条 2026-08-20 写入的 bq 记录，用当前窗口重跑一次查询，比较本次 `events` 与文件里的 `events_count_last_seen` —— 若已低于，说明定时炸弹开始显形，在 `findings.md` 记录首次观测到的日期

## 2. BigQuery 路径（确定性 shell）

- [x] 2.1 `bin/fetch-snapshot-bq.sh` 的 while 循环拆为两段（design D1）：先算抓取判定 `new|append|skip`，再无条件执行观测字段更新。**两段顺序执行，不再共用一个 if/else**
- [x] 2.2 `latest_event` 改为取 `max(已存, 本次观测)`（design D2）。⚠️ **必须与 2.1 同一步完成**——只做无条件覆盖而不加 max，会把「冻结」换成更糟的「倒退」
- [x] 2.3 新增 `window_days` 字段，值取本次查询实际使用的窗口天数（design D3）；新建与更新两条路径都要写
- [x] 2.4 更新计数器与日志措辞（design D4）：区分「抓取 新建 N · 增量 N · 跳过 N」与「记录 更新 N」，消除「每条都写了却报『命中跳过』」的歧义
- [x] 2.5 `bash bin/check-scripts.sh` 通过（含多字节变量 lint —— 该文件第 134 行的注释记着这里踩过两次）

## 3. 模型路径（prompt）

- [x] 3.1 `bin/fetch-snapshot.sh` 第 ③ 段的策略描述：拆开「抓取判定」与「记录更新」，措辞与 2.1 的 shell 实现对齐；明确写出「线上计数小于本地 → 不抓取，但仍更新观测字段」
- [x] 3.2 `latest_event` 取 max 的要求写进 prompt（模型不会自己想到窗口滑动会让 MAX 变小）
- [x] 3.3 `window_days` 写进 prompt 的结构定义
- [x] 3.4 ⚠️ **该段在文件里有两份**（light / full，约 80-95 行与 124-137 行）。**不要分别改两份**——按 design D5 提取为单一 shell 变量 `FACT_CACHE_POLICY`，两处 heredoc 插值引用，让重复物理消失。两种模式确有差异的措辞留在各自 heredoc 里
- [x] 3.5 `bash bin/check-scripts.sh` 通过（`${FACT_CACHE_POLICY}` 在 heredoc 里紧邻中文时会踩多字节变量名那条坑——这正是该 lint 存在的理由）

## 4. 验证

- [x] 4.1 `CRASH_REPORT_SKIP_ANALYSIS=1 CRASH_REPORT_NO_DELIVER=1 bash bin/crash-weekly.sh` 跑一轮（跳过分析层避免额度影响，bq 数据层照跑）
- [x] 4.2 抽查 `$STATE/issues/*.json`：**全部本轮观测到的 issue** 的 `last_synced` 都应为本轮时刻——包括那些计数未变或下降的。这是本 change 的核心验收点
- [x] 4.3 抽查 `latest_event`：与 1.1 的基线逐条比对，**不得有任何一条变早**
- [x] 4.4 抽查 `window_days` 已写入且与本轮实际窗口一致
- [x] 4.5 **产物断言**（design D6：prompt 类代码唯一可靠的测试形式）：写一段校验，对本轮观测到的每个 issue 断言 `last_synced` = 本轮时刻、`latest_event` 未倒退、`window_days` 已写入。**断言对象是落盘产物，不是 prompt 文本**——两份 prompt 都改对了模型仍可能没照做
- [x] 4.6 ✅ **已验证**（2026-08-23）：MacBook 上跑 `fetch-snapshot.sh <out> full`（真调 `claude -p` + firebase MCP，产出 report.md 14KB、snapshot.json 6 个 issue），随后 `FACT_CACHE_BASELINE=<跑批前 issues 快照> bin/test/assert-fact-cache.sh` → 「✅ 事实层产物断言通过（6 个 issue）」。⚠️ 首次调用偶发失败（退出码 1、stdout/stderr 全空），同命令重跑即成功——分析层缺重试与诊断输出，另记。
- [x] 4.7 抓取收益保住 ✅ 实测「抓取: 新建 0 / 增量 0 / 跳过 14」——记录全部更新的同时，一次抓取都没多发——抓取判定的收益必须保住（design Goals）。核对 4.6 那轮的日志抓取计数与改动前同口径的一轮

## 5. 联动与收尾

- [x] 5.1 已在 `crash-perf-functional-core` 的 tasks.md 中改写 task 3.5——缺陷已修，用例不再需要「钉住旧行为 + 标注已知缺陷」。原文：同步用例期望值：该 change 的 task 3.5 用例钉住的是本 change 修掉的旧行为，并标注了「已知缺陷，修复见后续 change」。本 change 落地后必须改写该用例期望值并删掉那句标注 —— 列为显式任务，不靠记性（design 风险表）
- [x] 5.2 `CLAUDE.md` 的「数据口径」一节增一条：事实层计数是**窗口内取值、非单调**，判定不得假设单调；观测字段每轮无条件更新
- [x] 5.3 `findings.md` 已记录 4 项发现 + 1 项未完成（4.6 模型路径未验证）。原文：若 findings.md 有条目（1.3 的显形日期、4.6 的模型路径未验证），归档前逐条与人确认
