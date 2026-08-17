# Explore Notes — crash-perf-execution-audit-log（事件溯源执行日志 sidecar：崩溃续跑 + 可审计）

> 本文件由 explorer 需求结晶产出，供 propose 阶段（架构师）作为唯一需求依据。结论均有代码依据（`文件:行`），未决事项集中在文末 OPEN QUESTIONS。
> 现状基准：`bin/crash-daily.sh`（954 行，运行副本）+ `bin/crash-weekly.sh`（197 行）+ `bin/fetch-snapshot.sh`（99 行）+ `bin/lib.sh`（35 行）+ `bin/sql/*.sql` + `state/` 全部运行时产物 + `~/.hermes/cron/jobs.json`（L1/L2 实际调度与投递 agent prompt）。
> 核心理念对照：DeepSeek Harness (dsh) 把一次 agent 运行建模为 append-only 类型化事件流（seq/时间/JSON payload），LLM 消息历史只是事件流的派生投影；崩溃恢复不 truncate，而是合成 end{interrupted} 标记、从断点续跑。本文把该思想映射到 shell 管线——**不是引入 dsh，是加一个轻量事件日志 sidecar**。

---

## 0. 现状全貌（读代码所得，非推测）

### 0.1 调度与投递（实际运行时）

- **真正在跑的调度器是 Hermes cron**（`~/.hermes/cron/jobs.json`），不是 launchd：
  - L1 日报 job `4b0c7362063b`：cron `0 7 * * *`，prompt = 跑 `crash-daily.sh` → 读 `state/publish/manifest.json` → `docx_builtin_import` 建 3 份文档（日报/台账镜像/索引页）→ `im_v1_message_create` 发 structured card（回填 `__DETAIL_URL__`/`__INDEX_URL__`/`__LEDGER_URL__` 占位符）。
  - L2 周报 job `1190a07e345c`：cron `30 5 * * 1`，prompt = 跑 `crash-weekly.sh` → 读 manifest → `send=false` 则停 → 建周报文档 → 发消息 → 追加 `state/weekly-index.jsonl` 归档行。
  - wrapper：`~/.hermes/scripts/crash-daily-wrapper.sh`（成功静默，失败输出错误+退出码）。
- `bin/*.plist`（launchd）**未装载**（`launchctl list | grep dino` 为空）——是早期部署遗留，脚本与文档仍引用，但实际不参与调度。见 INSTALL.md §7（描述 launchd 流程）与 §5 配置项。

### 0.2 L1 crash-daily.sh 步骤映射（线性脚本，无断点概念）

| # | 步骤（echo 标记即自然断点） | 代码位置 | 输入 | 输出 | 失败处理 |
|---|---|---|---|---|---|
| 0 | 初始化 | `bin/crash-daily.sh:32-65` | env | `logs/daily-$TS.log`（tee）、`TS`/`DAY` | `fail()` 写 `state/health-daily.json {ok:false}` 后 exit 1（`:68`） |
| 1 | 探活 | `:70-73` | bq | — | `bq query 'SELECT 1'` 失败即 fail |
| 2 | 查询性能数据 | `:132-135` | `perf-traces/screens/network.sql` × iOS/Android 表 | `PERF` markdown | 缺表跳过该平台（`table_exists` `:87-97` 有界重试 3 次） |
| 3 | 提取卡片指标 | `:138-268` | 同上 | `$TMP/start-*.csv` 等 | `extract()` 空表返回空 |
| 4 | 版本放量 | `:270-317` | `sessions-by-version.sql` × REALTIME/批量表 | `ADOPTION`、`IOS_TOP_*` | 表缺失回退批量表并置 `SESS_*_FALLBACK=1`（`:277-284`） |
| 5 | 崩溃统计 | `:326-399` | `crash-issues.sql`/`crash-rate.sql` × crashlytics REALTIME | `$TMP/crash-*.json`、`$TMP/rate-*.json`、`IOS_*`/`AND_*` | 查询失败写 `[]`（`:355-359`），0 行判「数据未同步」 |
| 6 | 天级单日值 | `:401-450` | `daily-*.sql` × 各表 + 偏移 | `*_1D` 变量 | 缺失 → 空串 |
| 7 | DoD/WoW 基准 | `:452-496` | `state/metrics-history.jsonl` | `*_DODWOW` | 无基准 → 「无基准」 |
| 8 | MCP 对照 | `:517-535` | `fetch-snapshot.sh light`（claude + MCP） | `state/crash-daily-$TS/snapshot.json` | **超时/失败只降级不失败**（`run_with_timeout` `lib.sh:9-35`，600s） |
| 9 | 组装报告 | `:537-588` | 全部上述 | `reports/$DAY-daily.md` | — |
| 10 | 卡片/结构化 JSON | `:590-795` | 指标变量 | `CARD`、`CARD_JSON`（schema 2.0） | DRY_RUN 在 `:797-809` exit |
| 11 | 索引页重建 | `:811-867` | `state/weekly-index.jsonl` + 崩溃 JSON | `state/index-render.md` | — |
| 12 | 产出投递清单 | `:869-907` | 报告/卡片/索引/台账 | `state/publish/manifest.json` | **`rm -rf "$PUBLISH_DIR"` 后重建（`:871`）** |
| 13 | 持久化 | `:909-948` | `*_1D` 变量 + MCP 快照 | `metrics-history.jsonl`（append+tail-7）、`daily-snapshot.json`（覆盖） | 历史写失败仅 echo 警告（`:937`） |
| 14 | 收尾 | `:950-954` | — | `health-daily.json {ok:true}` | **`rm -rf "$TMP"`（`:951`）删掉全部中间查询结果** |

L2 crash-weekly.sh：探活（`:50`）→ 同步仓库（`:55-65`）→ 抓快照 full 模式（`:67-83`，1800s 超时降级）→ 变化检测 jq（`:85-117`）→ 组装（`:121-150`）→ manifest（`:155-190`）→ **收尾 `cp "$SNAP_NEW" "$SNAP_LAST"`（`:193`）+ health.json（`:194`）**。

### 0.3 现有状态文件清单（state/）

| 文件 | 语义 | 写模式 |
|---|---|---|
| `health-daily.json` / `health.json` | 最近一次运行健康 | **覆盖**（last-writer-wins） |
| `daily-snapshot.json` | 今日快照（明日箭头/新增判定基准） | **覆盖** |
| `metrics-history.jsonl` | 天级单日值 7 日滚动 | append + `tail -7`，**无同日去重** |
| `weekly-index.jsonl` | 周报归档（L2 agent 追加） | append |
| `publish/`（manifest/card/message/docs） | 投递清单 | **每次 `rm -rf` 重建** |
| `crash-daily-$TS/snapshot.json` | MCP 对照快照 | 每 run 一目录，30d 清理 |
| `index-render.md`、`last-snapshot.json`（L2） | 索引渲染 / L2 基线 | 覆盖 / 覆盖 |

### 0.4 已实测证据：今天（2026-08-17）的重复运行暴露了全部缺口

- 07:00 L1 跑了一次（`logs/daily-20260817-070043.log`），**08:44 又手动/重跑了一次**（`daily-20260817-084451.log`；cron job 的 `fire_claim.at=08:42:47` 佐证）。
- `state/metrics-history.jsonl` 实测**同一日 2026-08-17 出现两行**（07:00 行 ios crash 2/sessions 394/perf_day 08-16；08:44 行 ios crash 0/sessions 378/perf_day 08-15）——两次运行数值不同，历史**没有同日去重**。
- 而 `hist_val()`（`crash-daily.sh:454`）取 `select(.day == $d) | head -1` → **明天 DoD 基准用的是 07:00 那行**；但 `daily-snapshot.json` 是 last-writer-wins → 快照用 08:44 的数值。**同一日内基准口径不一致，且无人能察觉**。
- 系统**无法回答**「08:44 这次重跑有没有把 3 份文档+卡片再投一遍」——没有任何「已投递」标记。`docx_builtin_import` 每次新建文档（INSTALL.md §0.2），重跑 = 重复投递，这是审计日志要消灭的核心场景。

---

## 1. 问题 1：事件日志放哪、什么格式（JSONL / SQLite / state/ 下？）

### 候选

| 方案 | 存储形态 | 优点 | 缺点 |
|---|---|---|---|
| **A. 每 run 一个 JSONL 文件** | `state/audit/YYYYMMDD-HHMMSS.events.jsonl`（events 每行一个 JSON） | append 安全（`>>`）；jq 原生（管线已重度依赖 jq）；**续跑判断 trivial（`[ -f ]`）**；run 间天然隔离；清理=按目录 mtime | 跨 run 查询要 `jq -s ./*.jsonl`（可用，`metrics-history` 已这么用） |
| B. 单一全局 JSONL | `state/audit/events.jsonl` | 追加最简单；跨 run 查询零聚合 | 多写者（L1/L2/手动重跑）交错风险；续跑判断要 tail 解析 |
| C. SQLite | `state/audit.db` | 可查询、可事务 | 引入 sqlite3 依赖（lib.sh 注释明言不依赖非标准工具）；对 sidecar 过重 |
| D. 复用现有 state 文件 | 扩 `health-daily.json` + `metrics-history.jsonl` | 零新文件 | 健康文件是覆盖语义、历史文件是指标语义，混入执行审计污染各自职责 |

**建议：A（每 run 一个 JSONL 事件文件）+ 稳定指针**。即：
- `state/audit/<run_id>.events.jsonl`：本 run 全部事件（append-only）；
- `state/audit/latest.json`：指向最近 run（或扩 `health-daily.json` 加 `run_id` 字段，二选一，propose 定）；
- 若跨 run 检索成为硬需求，再加 `state/audit/index.jsonl`（每 run 一行摘要，含 DAY/run_id/ok/步数）。

**dsh 对照**：事件即真相（append-only），`latest.json`/report 等派生投影可随时从事件流重建。事件字段最小集：`{seq, ts, run_id, attempt, type, step, payload}`，type 见问题 2。

## 2. 问题 2：断点粒度——一次 run 记哪些事件

### 候选

| 粒度 | 事件数/run（L1） | 覆盖 | 成本 |
|---|---|---|---|
| 仅步骤级 | ~10（对应 0.2 表 14 步合并成 8-9 个 echo 断点） | 续跑锚点、进度 | 最低（在 echo 处加 1 行） |
| **步骤级 + 查询级（推荐）** | ~25（步骤 + 每次 bq 调用） | **每个数字可溯源** | 低——`q()`/`qc()`/`q1d()`/`table_exists()` 是 4 个汇聚点，插桩 4 个函数即覆盖 ~95% bq 活动 |
| 子步骤全量 | 50+ | 理论上最细 | 噪音大，收益边际 |

**关键发现：bq 调用全部经过 4 个函数**——`q()`（`crash-daily.sh:77-80`）、`qc()`（`:335-336`）、`q1d()`（`:197-198`）、`table_exists()`（`:87-97`）。在这 4 个函数里各加 1 行 append，就能让**每个卡片数字都回指到（sql 文件、表、窗口天数、行数、耗时、重试次数）**。

**建议事件类型（基础集，propose 可增删）**：
- `run.start`（run_id/DAY/attempt/脚本版本）
- `step.start` / `step.end`（step 名、rc、耗时）
- `query`（sql 文件、表、DAYS、行数、耗时、rc）——从 4 个汇聚点发
- `table_select`（版本放量选表决策：REALTIME vs 批量回退，`crash-daily.sh:277-284` 的 SESS_*_FALLBACK 决策要落事件，否则「为什么放量用了停更批量表」不可查）
- `fetch`（MCP 对照成功/降级/超时，`crash-daily.sh:527-535`）
- `report`（REPORT 路径、字节数）
- `publish`（manifest.json 路径、含哪些投递项）
- `delivery.*`（**agent 侧**：`delivery.doc_created {label,url}`、`delivery.card_sent`、`delivery.index_appended`）
- `run.end`（`{ok:true}` 或 `{ok:false, error}`——即 dsh 的 `end{interrupted}` 合成标记，脚本 `fail()` 处补发）

## 3. 问题 3：崩溃续跑语义——每步怎么判「已完成可跳过」（幂等键）

**先拆两类步骤，语义完全不同**：

### a) 数据步骤（bq 查询 / MCP 抓取）——建议**续跑时重跑，不跳过**
- 日报是「拉到最新」型任务：数据源在推进（性能批量表滞后 ~2 天、sessions REALTIME 实时）。今天 07:00 与 08:44 两次运行数值不同就是证据——**skip-if-done 会产出过期报告**。
- 重跑成本低（单查询 <1 分钟）。审计日志对数据步骤的职责是**记录**（哪个输入、哪个窗口、几个结果行），不是 gating。

### b) 投递步骤（docx_builtin_import / im_v1_message_create）——必须幂等键 gating
- 现状：**无任何「已建/已投递」标记**。`state/publish/` 每 run `rm -rf` 重建（`:871`）；`docx_builtin_import` 每次新建文档（INSTALL.md §0.2）。脚本成功但 agent 中途崩（文档建了、卡片没发）、或同日重跑（今天 08:44 实例）→ **重复文档 + 重复卡片，系统无法自知**。
- **幂等键 = 按 DAY 的投递台账**：`state/delivery/<DAY>.json`（或 audit 流里的 `delivery.completed` 事件，二选一，见 OPEN QUESTIONS Q5）。
  - agent 建文档前查台账：`{DAY, daily_url, ledger_url, index_url, card_sent}` 已存在且完整 → 复用 URL、跳过创建；只建了部分 → 补剩余，**不重建已有**；
  - 崩溃窗口最小化：**每个 lark-mcp 调用返回后立刻写台账**（建完日报文档 → 立刻记 daily_url；再建台账镜像…），即 dsh 的「副作用前/后各 append 一条事件」思想——最坏情况是单次调用宽度的孤儿，而孤儿不可回收（飞书端无法枚举自己建的文档），只能靠台账把「已建」与「未建」的边界压缩到一个调用内。
- 卡片同理：`im_v1_message_create` 无幂等参数，`card_sent:true` 即闸门。

**续跑整体语义（推荐给 propose 的基线）**：脚本崩溃 → `run.end{ok:false, error}` 落审计 → 重跑 = 新 run_id（attempt+1），**数据步骤全量重跑**（新鲜度优先），**投递步骤查台账跳过已完成项**。不做 dsh 式的「从断点跳过已完成数据步骤」——那是 Tier 2，见问题 6。

## 4. 问题 4：与 cron/launchd 重跑、已有重试逻辑怎么共存

- **调度共存**：实际调度是 Hermes cron（jobs.json），launchd plist 未装载。审计日志落在 `state/` 下（`.gitignore` 已忽略），对调度器透明；唯一约束 = **append 安全**（`>>` 原子追加单行）+ **不得位于 `state/publish/` 内**（它每 run `rm -rf`，`:871`）。
- **现有重试逻辑不动，只加可见性**：
  - `table_exists()` 的有界重试（`:87-97`，3 次、2s/4s 退避）保持原样；审计日志为**每次 attempt** 记一条 `query{type:table_exists, attempt:N, rc, verdict}`——「这次是重试 2 次后成功还是确证不存在」从此可查；
  - `fetch-snapshot.sh` 超时降级（`:527-535`、weekly `:74-82`）从「echo 一行警告」升级为结构化 `fetch{degraded:true, reason}` 事件——事故复盘时不用再人肉 grep 日志。
- **L2 的收尾顺序缺陷**：`manifest.json` 在 `crash-weekly.sh:188` 写出，`cp SNAP_NEW SNAP_LAST`（基线提升）在 `:193`——**中间崩溃 → 基线未提升 → 下周一重 diff 把旧 issue 全部报成新增**（2026-08-07 已实踩，见 crash-perf-report-pipeline skill「pitfalls」）。审计日志至少要把「baseline_promoted」记为事件；是否顺手把顺序改为「先提升基线再写 manifest」属于行为修复，见 OPEN QUESTIONS Q4。
- **metrics-history.jsonl 同日去重**：append+tail-7 无去重（`:933-937`）已实测产生同日两行 + `hist_val` head-1 基准漂移（0.4 节）。审计日志本身不修这个，但**同 run 识别（run_id）是修它的前提**——建议 propose 一并把 `metrics-history.jsonl` 的写入改为按 `day` 键 upsert（保留最后一行），与审计日志同 PR。

## 5. 问题 5：可审计性——日报每个数字能否回溯源

### 现状（读代码核实）

| 卡片数字 | 当前可溯源到的层级 | 缺口 |
|---|---|---|
| 崩溃 N 类/E 次（IOS_N/EV） | `crash-issues.sql` + `CRASH_IOS_TBL` + 7 天窗（`:369-371`、`:328-331`） | 查询**结果**随 `rm -rf "$TMP"`（`:951`）消失 |
| 崩溃率（率/百分比） | `crash-rate.sql` 分子/分母（`:376-396`） | 同上 |
| 天级单日值/DoD/WoW | `daily-*.sql` + `perf_day_offset`（`:411-450`）+ 历史文件 | 历史文件有同日重复行（0.4） |
| 放量（版本/会话/设备） | `sessions-by-version.sql` + 表选择决策（`:306-317`、`:277-284`） | **REALTIME/批量回退决策不留痕** |
| 数据截止时间戳 | `table_max` 三表分别取（`:321-324`、`:398`） | 只进了 report 头部，不进结构化状态 |
| MCP 对照 | `state/crash-daily-$TS/snapshot.json` | 保留 30d ✓，但无 run 关联 |

### 目标（最小可行）

1. **查询级事件**（问题 2 的 4 汇聚点插桩）：每个数字 → `(run_id, step, sql 文件, 表, 窗口天数, 行数)`；结合 report 头部的三表截止时间戳（已计算，`DATA_UNTIL`/`ADOPTION_UNTIL`/`CRASH_UNTIL`），「哪个数字、哪个输入、哪个数据时点」全链路可答。
2. **`$TMP` 结果保留**：`:951` 的 `rm -rf "$TMP"` 改为按 mtime 清理（与 `:953` 的 crash-daily-* 目录 30d 一致）——中间 CSV/JSON 是**最直接的审计物证**（每个数字的原始行就在那）。
3. **报告头带 run_id**：`reports/$DAY-daily.md` 首部加 `> 本次运行：<run_id> · 审计：state/audit/<run_id>.events.jsonl`——飞书文档逐字引用报告（cron prompt 硬约束），等于文档自带审计指针。
4. `health-daily.json` 加 `run_id`（现在只有 last_run/ok/data_until，`:950`）。

**dsh 对照**：报表（report/card/文档）是事件流的派生投影；本方案把「投影」与「事件流」的指针关系显式化，压缩后原始事件仍可审（审计文件按 run 隔离，天然支持「shadow replace」式压缩而不丢原始）。

## 6. 问题 6：最小可行范围——先落哪些事件、哪些场景，成本/收益

| Tier | 内容 | 成本 | 收益 |
|---|---|---|---|
| **T0 可审计（建议本次必做）** | 4 汇聚点插桩 + 步骤事件 → `state/audit/<run_id>.events.jsonl`；`run_id` 进 health/report；`$TMP` 改 30d 保留；同日重复 run 检测事件 | ~30 行脚本改动（crash-daily.sh + crash-weekly.sh + fetch-snapshot 可后置）；零行为变化 | 每个数字可溯源；重复运行可见；2026-08-07 类事故可复盘 |
| **T1 投递幂等（建议本次必做）** | `state/delivery/<DAY>.json` 台账 + L1/L2 cron prompt 增加「查台账 → 建文档 → 立刻记台账」步骤；`metrics-history.jsonl` 按 day upsert | 脚本 ~15 行 + jobs.json 两段 prompt 改写 | **消灭重复投递/孤儿文档**——本 change 最痛的痛点（今天 08:44 实例） |
| T2 全事件溯源续跑 | 断点跳过数据步骤、压缩（compaction）、跨 run 检索 | 大 | 管线单次 10 分钟内，重跑成本可忽略，收益边际——**建议明确出界** |

**推荐**：本 change 落地 **T0 + T1**，T2 出界（propose 若超时问题重现再议）。T1 的投递台账是「崩溃续跑」真正兑现价值的点：脚本 10 分钟重跑不是问题，**重复建 3 份文档 + 重复发卡片才是问题**。

## 7. 风险与未知

- **agent 写文件的可信度**：投递台账由 cron agent（LLM）写。它已有写 `weekly-index.jsonl` 的先例（L2 prompt 第 6 步），但 LLM 写文件可能漏写/写错 → 台账读取方（下次投递）必须**容错**（台账损坏当「未投递」处理会重复建文档；当「已投递」处理会漏投——默认取「未投递」+ 人工可见的 audit 记录，见 OPEN QUESTIONS Q1/Q5）。
- **docx 孤儿不可回收**：`docx_builtin_import` 只建不更、飞书端无法枚举本 bot 建的文档 → 只要「建文档后、写台账前」崩溃，就产生一份孤儿文档。台账把窗口压到单个调用宽度，但无法归零；同日重投策略（Q1）决定孤儿概率上限。
- **多写者竞争**：L1/L2 都写 `state/audit/`（分 run 文件则无竞争）；若脚本与 agent 共用同一 events.jsonl，需 `>>` + 单行 JSON 纪律（每行一条完整 JSON，绝不跨行），或分文件（`script-*.jsonl` / `delivery-*.jsonl`）。推荐**分文件**，锁和并发都免了。
- **历史基准漂移**：若只修投递不修 `metrics-history.jsonl` 去重，08-17 类「同 run 两行」继续发生，DoD 基准口径继续漂移——建议 T1 顺带修（upsert by day），否则审计日志与基准逻辑不自洽。
- **launchd 遗留**：`bin/*.plist` 仍被 INSTALL.md 描述为调度方式，实际未装载。本 change 不动它，但 audit 设计不应假设单调度器（两份 plist 若被误装载会双跑——审计日志恰好能暴露）。

---

## OPEN QUESTIONS（需人/架构师拍板后进入 propose）

**Q1 · 同日二次运行的投递策略**（决定 T1 台账语义，影响 L1/L2 投递行为；今天 08:44 就是实例）
同一 DAY 内第二次运行（手动重跑 / 崩溃后重跑）时，投递步骤：a) **完全禁止重投**（台账 `delivery.completed` 存在即跳过全部投递，只更新 report/索引渲染）；b) 允许重投但每次记录（现状+审计可见）；c) 仅当上次投递未完成（`card_sent=false`）才补投，已完成则跳过。推荐 a 或 c——b 等于保留重复文档问题只加日志。

**Q2 · 数据步骤续跑语义**
脚本崩溃后重跑，数据步骤（bq 查询）是「**全量重跑**（新鲜度优先，推荐，日报任务性质决定）」还是「skip-if-done 从断点续」（省时，但会用旧数据）？若未来管线变重（如 weekly full triage 12min+），是否值得为它单独做断点跳过？

**Q3 · 审计日志保留期**
`state/audit/` 保留：a) 60d（对齐 logs）；b) 30d（对齐 crash-daily-*）；c) 90d+ 或永久（量级 ~25 事件/run × 2 run/天 ≈ 50 行/天，10KB 级，成本可忽略）。推荐 c（审计价值 > 磁盘成本），但这是运营策略，需拍板。

**Q4 · 是否顺带修 L2 基线提升顺序**（行为修复，超出纯审计范围）
`crash-weekly.sh:188`（写 manifest）→ `:193`（提升基线）之间崩溃会让下周把旧 issue 全报成新增（2026-08-07 实踩）。本 change 是否顺带改为「先 `cp` 基线再写 manifest」（即 manifest 永远对应已提升基线的 run）？还是只加 `baseline_promoted` 审计事件、行为不动？

**Q5 · 投递台账的写者与形态**
投递台账 `state/delivery/<DAY>.json` 由 cron agent（LLM）在每次 lark-mcp 调用后写。a) 独立文件（脚本不碰，agent 专用）；b) 并入统一审计流（`state/audit/delivery-*.jsonl`，与脚本事件分文件避免锁）；c) 两者都要（台账是「当前状态」、审计流是「历史」）。推荐 b（一个目录两种前缀即可）；另外**台账损坏时默认「未投递」还是「已投递」**也需拍板（推荐默认「未投递」+ 人工看审计流确认，避免静默漏投）。

**Q6 · MVP 边界确认**
本 change 是否按推荐只做 **T0（可审计）+ T1（投递幂等）**，T2（断点跳过/压缩/跨 run 检索）明确出界？若要求本次就做断点跳过（Q2 选 skip-if-done），范围将显著扩大，需一起拍板。

---

## DECISIONS（requester 已拍板 2026-08-17，propose 以此为准）

| Q | 决定 | 说明 |
|---|---|---|
| Q1 同日二次运行投递策略 | **c（仅上次未完成才补投，已完成跳过）** | `card_sent=false` 才补投；已完成项复用 URL 跳过 |
| Q2 数据步骤续跑语义 | **全量重跑**（新鲜度优先） | 不做 skip-if-done，日报是"拉最新"型任务 |
| Q3 审计日志保留期 | **60d+**（至少 60 天） | 对齐 logs 保留期起步，可延长 |
| Q4 L2 基线提升顺序 | **顺带修** | 改为先提升基线（`cp SNAP_NEW SNAP_LAST`）再写 manifest，根治 2026-08-07 类事故 |
| Q5 投递台账写者与形态 | **b：并入审计流但分文件**（`state/audit/delivery-*.jsonl`）；台账损坏默认**"未投递"** | 脚本事件与投递事件分文件避免锁；默认未投递 + 人工看审计流确认，避免静默漏投 |
| Q6 MVP 边界 | **T0（可审计）+ T1（投递幂等）**，T2 出界 | 见问题 6 的 Tier 表 |
