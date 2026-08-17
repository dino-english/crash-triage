## Context

崩溃&性能日/周报管线由 shell 脚本（`bin/crash-daily.sh` 954 行 + `bin/crash-weekly.sh` 197 行）产出内容，投递由 Hermes cron agent（L1 `4b0c7362063b` / L2 `1190a07e345c`）经 lark-mcp 完成。现状无任何执行审计痕迹：`state/publish/` 每 run `rm -rf` 重建（`crash-daily.sh:871`）、`docx_builtin_import` 每次新建文档（INSTALL.md §0.2）、`state/metrics-history.jsonl` append+tail-7 无同日去重（`:933-937`）、L2 先写 manifest（`crash-weekly.sh:188`）后提升基线（`:193`）。2026-08-17 当天 07:00 与 08:44 两次运行已实测暴露全部缺口：同日两行基准漂移 + 无法回答「是否重复投递」。约束：脚本已重度依赖 jq；`lib.sh` 注释明言不依赖非标准工具（不引入 sqlite3）；`state/` 已 `.gitignore`；`state/publish/` 每 run 重建，审计产物不得放其中。动因见 proposal.md - Why。

## Goals / Non-Goals

**Goals:**

- 每次 run 产生一个 append-only 事件流，每个卡片数字可回指（run_id + step + sql + 表 + 窗口 + 行数）。
- 投递幂等：同一 DAY 内二次运行不重复建文档/发卡片，崩溃后可从台账续投未完成项。
- 数据步骤崩溃后全量重跑（新鲜度优先），审计只记录、不 gating。
- 顺带修复同日基准漂移（metrics-history 按 day upsert）与 L2 基线提升顺序（先 cp 后 manifest）。

**Non-Goals:**

- 不做断点跳过数据步骤（skip-if-done）、不做事件压缩（compaction）、不做跨 run 检索索引——T2，明确出界。
- 不引入 sqlite3 / dsh / 任何新非标准依赖；不改任何 SQL 或 bq 查询口径。
- 不回收孤儿文档（飞书端无法枚举本 bot 文档，无法归零，仅把窗口压到单次调用宽度）。
- 不动 launchd `bin/*.plist`（未装载的部署遗留）。

## Decisions

### D1. 存储形态：每 run 一个 JSONL + run_id 进 health（不设独立 latest.json）

选 explore-notes 候选 A（`state/audit/<run_id>.events.jsonl`），run_id = 脚本时间戳 `TS`（`YYYYMMDD-HHMMSS`，已在 `crash-daily.sh:32` / `crash-weekly.sh:30` 计算）。「最近 run」指针不复用独立 `latest.json`，而是让 `health-daily.json` / `health.json` 新增 `run_id` 字段——health 已是 last-writer-wins 的「最近一次运行」状态，天然就是指针，避免引入又一个需要维护一致性的文件。

- 备选：单一全局 `events.jsonl`（多写者交错风险）、SQLite（引入 sqlite3 依赖，过重）、复用 health/metrics（污染职责）——均否决，理由见 explore-notes §1。

### D2. 事件 schema 与类型

每行一条完整 JSON（`jq -c` 可解析），字段最小集 `{seq, ts, run_id, attempt, type, step, payload}`。类型集：

- `run.start` / `run.end`（end 含 `{ok, error?}`，fail() 处补发 ok:false）
- `step.start` / `step.end`（step 名、rc、耗时）
- `query`（sql 文件、表、DAYS、行数、耗时、rc、attempt）
- `table_select`（平台、选中表、`SESS_*_FALLBACK` 回退标记）
- `fetch`（success/degraded/timeout + reason）
- `report`（路径、字节数）
- `publish`（manifest 路径、投递项）
- `duplicate_run`（当日已有 run_id 列表）
- `baseline_promoted`（L2 基线提升）
- `delivery.doc_created` / `delivery.card_sent` / `delivery.index_appended`（agent 侧，写独立文件）

### D3. 脚本事件与投递事件分文件

脚本写 `<run_id>.events.jsonl`；cron agent 写 `state/audit/delivery-<DAY>.jsonl`（Q5=b 拍板：并入审计流但分文件）。分文件理由：脚本与 agent 是两个独立写者，共享单文件需要 `>>`+单行 JSON 纪律仍可能交错；分文件后各自 append，锁和并发都免了。二者靠 `run_id`（agent 从 health 读）与 `DAY` 关联。

### D4. 4 个 bq 汇聚点插桩，不改查询

`q()`（`:77`）、`table_exists()`（`:87`）、`q1d()`（`:197`）、`qc()`（`:335`）四个函数覆盖 ~95% bq 活动。在每个函数末尾 append 一条 `query` 事件（`table_exists` 追加 attempt/verdict）。改的是函数封装层，不改任何 `.sql` 文件内容、不改查询语义。`table_max()`（`:99`）与 `perf_day_offset()`（`:202`）也是直连 bq 的查询，一并纳入 `query` 事件（补充到汇聚点清单，保证「每个数字可溯源」无漏网）。

### D5. 同日重复 run 检测

run_id = `YYYYMMDD-HHMMSS`。同日检测 = 检查 `state/audit/` 下是否存在 `run_id` 前缀 `YYYYMMDD-` 的其它 `.events.jsonl`（本 run 之外）。存在即落 `duplicate_run` 事件（记录先前 run_id 列表），不中止本次运行。

### D6. 投递幂等与补投语义（Q1=c）

台账（`delivery-<DAY>.jsonl` 中的 `delivery.*` 事件）是投递的真值。agent 流程改为：**读台账 → 判断 → 建/发 → 立刻写台账**。

- 已存在 `card_sent=true` → 跳过全部投递，复用 URL 仅更新报告/索引渲染。
- 存在但不完整（缺 daily_url/ledger_url/index_url 任一，或 `card_sent` 缺失/false）→ 只补缺失项，不重建已有项。
- 台账损坏/无法解析 → 按「未投递」处理（允许重建），并在审计流落一条可见记录供人工核对。

### D7. metrics-history 按 day upsert

`metrics-history.jsonl` 写入从「append + `tail -7`」改为：读现有 → `jq` 按 `day` 键覆盖（`map(select(.day != $DAY)) + [新行]`）→ 原子写（`.tmp` + `mv`）。保持「最近 7 天」语义由「保留至多 7 个 day」实现（按 day 去重后可能仍超 7，取最新 7 个 day）。`hist_val()`（`:454` 的 `head -1`）无需改——upsert 后每个 day 恒唯一。

### D8. L2 基线提升顺序（Q4 顺带修）

`crash-weekly.sh` 把 `:188`（写 manifest）与 `:193`（`cp SNAP_NEW SNAP_LAST`）对调：先提升基线、落 `baseline_promoted` 事件，再写 manifest。首跑建立基线的分支（`:90-93` 写空 `SNAP_LAST`）不受影响。

### D9. 中间产物 30d 保留 + 审计日志 60d 保留

`crash-daily.sh:951` 的 `rm -rf "$TMP"` 删除，改为 `find "$TMP" -mtime +30 -delete`（与 `:953` 的 `crash-daily-*` 30d 对齐）；新增 `find "$ROOT/state/audit" -mtime +60 -delete`。审计日志 60d+（Q3 拍板）。

## Risks / Trade-offs

- **agent 写台账可信度**（LLM 漏写/写错）→ 读取方容错：默认「未投递」+ 审计流可见记录；台账只增不改（append-only），损坏时宁可重投不可漏投。
- **孤儿文档不可回收**（`docx_builtin_import` 只建不更、飞书端无法枚举）→ 每个 lark-mcp 调用返回后立刻写台账，窗口压到单次调用宽度；接受残余风险（Q5 已拍板）。
- **多写者竞争** → 分文件（D3），各自 append，无锁。
- **run_id 秒级碰撞**（同日两次运行在同一秒，`YYYYMMDD-HHMMSS` 撞号）→ 概率极低；若发生，后写覆盖前写的 `health.run_id` 但事件文件因 `>>` 会追加进同一文件——可接受，`seq` 字段仍保证行序唯一；如未来需要严格隔离可给 run_id 加进程后缀（T2 再议）。
- **metrics-history upsert 改动**触碰主链路持久化 → 原子写（`.tmp`+`mv`）保持，改动仅限「同 day 覆盖」，字段 schema 不变，`hist_val`/`spark_hist` 读取侧零改动。

## Migration Plan

1. 脚本改动（crash-daily.sh / crash-weekly.sh）与 jobs.json prompt 改动一次性合入（审计日志无副作用，对调度器透明）。
2. 部署后首次运行即开始产生 `state/audit/`，无冷启动问题（空目录即可 append）。
3. 回滚：审计日志与台账是纯增量 sidecar，删除相关代码即可回滚，不影响既有日报/周报产出；metrics-history 的 upsert 回滚 = 恢复 append 写法（同 run 两行风险回归，但不破坏现有数据）。
4. 归档顺序约束：本 change 的 metrics-history upsert 与 L2 基线顺序修复落在未归档的 `crash-perf-daily-weekly-report` 主链路上，故该 change 须先于本 change 归档；若顺序相反，本 change 归档时在 spec Purpose 注明一致性对账（见 proposal.md Impact）。

## Open Questions

- 暂无阻塞性未知。`state/audit/index.jsonl`（每 run 一行摘要，供跨 run 检索）是否纳入属于 T2，本次不做，届时再议。
- run_id 是否需要进程后缀以避免同秒碰撞属低频问题，T2 再议（见 D5/Risks）。
