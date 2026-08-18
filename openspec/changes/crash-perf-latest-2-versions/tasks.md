## 1. SQL 层：版本过滤

- [x] 1.1 新增 `bin/sql/latest-versions.sql`（`{{TABLE}}`=sessions 表 / `{{DAYS}}` / `{{MIN_SESSIONS}}`，返回 version + sessions + devices，不排序不 LIMIT，排序交给 shell `sort -V`）
- [x] 1.2 `crash-issues.sql` / `daily-crash-1d.sql` 加 `AND application.display_version IN ({{VERSIONS}})`
- [x] 1.3 `crash-rate.sql` 三个子查询各加谓词（分子 crashlytics、分母 sessions、affected_installs），确保分子分母同版本集
- [x] 1.4 `daily-sessions-1d.sql` 加谓词
- [x] 1.5 `daily-perf-1d.sql` 五个子查询各加 `AND app_display_version IN ({{VERSIONS}})`
- [x] 1.6 `perf-traces.sql` / `perf-screens.sql` / `perf-network.sql` 各加谓词
- [x] 1.7 `sessions-by-version.sql` 保持全版本（放量明细需看全貌），加注释说明为何不过滤
- [x] 1.8 `bin/sql/README.md` 占位符表新增 `{{VERSIONS}}` / `{{MIN_SESSIONS}}`，并记两套字段路径

## 2. crash-daily.sh：版本解析与逐版本取数

- [x] 2.1 新增常量 `VERSION_COUNT`（默认 2）/ `MIN_SESSIONS`（默认 5），可经 `CRASH_REPORT_VERSION_COUNT` / `CRASH_REPORT_MIN_SESSIONS` 覆盖
- [x] 2.2 新增 `resolve_versions()`：查 `latest-versions.sql` → `sort -V` → 取最新 N 个（新→旧）；解析失败/无版本时整段降级为「版本解析失败」并跳过版本过滤段（不静默出全版本数）
- [x] 2.3 取数助手加版本参数：`q()` / `q1d()` / `qc()` 的 sed 增加 `{{VERSIONS}}` 替换
- [x] 2.4 新增 `version_rows()`（该版本在窗口内是否有行）与三态判定 `data_state()`（表未同步 / 数据未同步 / 该版本无数据 / 正常，判定序见 design D6）
- [x] 2.5 崩溃指标逐版本提取（issue 数 / 事件数 / 受影响安装 / 崩溃率 / 最新时间戳）
- [x] 2.6 性能指标逐版本提取（启动 P50/P95、慢帧最差页、冻结率、接口错误率）
- [x] 2.7 放量逐版本提取（会话数 / 设备数）
- [x] 2.9 主力版本补列：解析会话量 top2，与最新 N 版取并集（按版本号新→旧、上限 4），列头标注「最新」/「主力」；补充列只取窗口值，不进 1d/历史/sparkline（design D11）
- [x] 2.8 `perf_day_offset()` / `table_max()` 的内联 SQL 补版本过滤（版本级截止时间戳），全表探测保留一份不带过滤的用于第 2 态判定

## 3. crash-daily.sh：呈现重构

- [x] 3.1 卡片改双表（iOS 表 / Android 表），列 = `指标 | <版本列 2–4 个> | 对比`，9 行（崩溃 3 + 性能 5 + 会话数 1）；版本列由 2.9 的并集决定，对比列恒为「最新版 vs 上一版」
- [x] 3.2 新增 `delta_cell()`：版本间差值 + ↑/↓ + 红绿着色，任一端缺数据出 `—`
- [x] 3.3 阈值红绿灯与小样本提示判定对象改为最新版（design D8）
- [x] 3.4 卡片头部摘要保留红/黄档告警，标题追加版本号（`📊 08-18 崩溃 & 性能 · 1.5.4 vs 1.5.3`）
- [x] 3.5 卡片底部口径行重写：三表截止时间戳 + 版本集 + 「本报告仅统计最新 2 个版本」显式声明
- [x] 3.6 日报文档改四段式（结论 / 双版本对照 / 明细 / 口径），DoD/WoW 移入文档
- [x] 3.7 索引页「今日概览」与「跟踪中的 issue」补版本上下文；MCP 对照段显式标注「全版本口径，与卡片不可比」

## 4. 环比基准与历史

- [x] 4.1 `metrics-history.jsonl` 写入改按版本存储（`{day, versions, ios:{"<ver>":{…}}, android:{…}}`）并按 `day` upsert
- [x] 4.2 读取侧丢弃无 `versions` 键的旧格式行并打印提示（design D9）
- [x] 4.3 DoD/WoW / sparkline 取数改为「同版本同指标」，版本首次出现时显示「无基准」
- [x] 4.4 `daily-snapshot.json` 增加 `versions` 字段，箭头基准按版本比对

## 5. crash-weekly.sh：主力版本视角与呈现

- [x] 5.1 新增 bq 放量段：会话量 top2 版本的会话/设备/崩溃事件数（与日报「版本号最新 2 个」互补，卡片显式标注两者差异）
- [x] 5.2 周报卡片重构（变化摘要 + 主力版本放量两段）
- [x] 5.3 周报文档补版本上下文段
- [x] 5.4 `cp SNAP_NEW SNAP_LAST` 与写 manifest 顺序对调（先提升基线再写 manifest，承 `crash-perf-execution-audit-log` 已登记项）

## 6. 台账与文档

- [x] 6.1 `reports/LEDGER.md` 重排：活跃 issue 精简表（5 列）+ 详情条目 + `<details>` 折叠历史归档（只重排不改结论）
- [x] 6.2 `bin/INSTALL.md` 配置项表新增两个环境变量，§9 坑表补「版本解析源为 sessions，最新版在性能段常态无数据」

## 7. 同步与验收

- [x] 7.1 `bin/` 改动同步到 `scripts/crash-report/`，`diff -rq bin scripts/crash-report` 仅剩 README.md / mcp.json 两处 Only in
- [x] 7.2 DRY RUN 实跑（真连 BigQuery）：卡片 JSON `jq empty` 通过、双表列头为实际版本号、对比列方向正确（2026-08-18 实跑通过）
- [ ] 7.3 抽查 2–3 个版本级数值与 Firebase 控制台一致（**需人工**：已用 bq 直查数据源交叉验证，控制台侧未核）
- [ ] 7.4 观察 1–2 周后复评阈值（样本变小后波动加剧，design D8）
