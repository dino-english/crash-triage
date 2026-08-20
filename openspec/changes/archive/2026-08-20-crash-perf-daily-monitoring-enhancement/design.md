## Context

日报链路现状（`bin/crash-daily.sh` 与 `scripts/crash-report/crash-daily.sh` 逐字节一致）：

- **指标**：崩溃（issue 聚合 + 崩溃率）、性能（启动 P50/P95、慢帧最差页、冻结、接口错误率）、放量（最新版会话数），双端 iOS/Android。
- **快照**：`state/daily-snapshot.json` 只存 3 个**滚动窗口值**（`ios_events` / `android_events` / `start_p50` + issue id 数组），供 `arrow()` 算「窗口值环比」与「新增 issue」判定。
- **告警**：`ALERTS` 只拼三条硬编码——新增 issue、已修未发版、接口错误率 >0（`awk 'i>0||a>0'`）。
- **窗口口径**：崩溃 7 天、性能 3 天、放量 1 天，全部 `TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL N DAY)` 滚动窗。

核心矛盾（见 explore-notes 第 4 节）：**现状 `arrow()` 的对比基准是「近 N 天滚动窗口值」，不是「昨日单日值」**——窗口重叠会钝化变化，语义与 R1 的「环比昨日」不同。DoD/WoW/sparkline 必须建立在「天级单日值 + 7 日历史」之上，而不是沿用窗口口径。

## Goals / Non-Goals

**Goals:**

- 建立「天级单日值」的每日持久化与 7 日滚动历史，作为 DoD/WoW/sparkline 的统一基准
- 五指标两档环比（DoD 昨日 / WoW 上周同日），百分比用 pp、耗时用 ms
- 受影响安装数、统一阈值红绿灯、小样本提示、慢帧定义注释、7 日 sparkline
- 双副本（`bin/` 运行副本 + `scripts/crash-report/` git 源副本）改动一致

**Non-Goals:**

- 不改三大板块分层结构、截止时间戳标注、崩溃口径注释、详情跳转链接（保留项 R0）
- 不做 Crash-Free Users Rate（D1 已否决：无可靠总用户分母）
- 不改周报（L2）链路，只动 L1 日报
- 不修改 `crash-perf-daily-card` / `crash-perf-daily-weekly-report` 两个未归档 change 的既有 requirement（本 change 是新增能力，见 proposal Capabilities 注释）

## Decisions

### D1：7 日滚动历史 = `state/metrics-history.jsonl`

- **决定**：新增 `state/metrics-history.jsonl`，每次 L1 运行结束 **append 一行** JSON（含 `day` + 双端全指标单日值），超过 7 行截断保留最近 7 天。原子写 = 写临时文件 + `mv` 覆盖。现有 `daily-snapshot.json` 保留，扩展字段承载「今日全指标单日值」作为明日 DoD 基准。
- **理由**：DoD 只需昨日值、WoW 需 D-7 值、sparkline 需 7 日序列——三种读取都从同一份历史取，避免多处各存一套。jsonl 每行一天、追加语义天然适合「只增不减 + 截断」，且可 `tail`/`jq` 确定性处理。原子写防 L1 运行中途崩溃留下半行。
- **备选**：① 用单个 JSON 数组文件整体重写——被否，重写无原子性保障、越写越慢；② 继续只靠 `daily-snapshot.json` 只存昨日——被否，无法支撑 WoW 与 sparkline。

### D2：DoD/WoW 用「天级单日值」，与「窗口展示值」口径显式分离

- **决定**：DoD/WoW/sparkline 全部基于**日历日锚定的单日值**（查询 `event_timestamp ∈ [D-1, D)` 等整日区间），而不是现状 `CURRENT_TIMESTAMP - N 天` 的滚动窗。持久化字段名带口径标识（如 `crash_events_1d`、`sessions_1d`），与现有窗口值（如 `ios_events`）明确区分，代码注释同步写明「天级口径 ≠ 窗口口径，不可混比」。
- **理由**：滚动窗口重叠会钝化环比（今天 7 天窗含 6 天旧数据），只有整日锚定才与「环比昨日 / 同比上周同日」的语义一致。
- **备选**：直接从滚动窗推导昨日值——被否（重叠 + 非整日边界，explore 第 4 节已论证）。

### D3：受影响安装数并入 `crash-rate.sql` 第三子查询

- **决定**：在 `crash-rate.sql` 现有 `crash_events`（分子）与 `sessions`（分母）两个标量子查询旁，加第三个标量子查询 `COUNT(DISTINCT installation_uuid) WHERE is_fatal=TRUE AND 窗口内`，产出 `affected_installs`。
- **理由**：与分子同表（crashlytics）同窗口（`{{DAYS}}`），天然口径一致，避免独立 SQL 再维护一份窗口/表名替换逻辑。实现时新增「天级版」（D2）供 DoD/WoW/sparkline 取数。
- **备选**：独立 SQL 文件——被否，同表同窗口却拆两份，窗口或表名改动容易漏改。

### D4：sparkline 用 Unicode 方块字符，markdown 原生渲染

- **决定**：`▁▂▃▄▅▆▇█` 八个方块字符，把 7 日序列按 min-max 归一化后映射到 0–7 档，拼成一行字符串嵌在 markdown 里。仅崩溃率/接口错误率/启动 P95 三指标（R6 点名）。
- **理由**：无需图片、无需外部图表服务，飞书 markdown 与仓库 markdown 均原生渲染，且确定性（jq/awk 可拼）。三指标范围遵 explore 点名，慢帧/冻结/P50 不画。
- **备选**：① 用 `▏▎▍▌` 等更细字符——被否，方块档位更醒目、跨字体渲染更稳；② 图片 sparkline——被否，引入生成/存储/投递复杂度，违背「无图片」约束。

### D5：阈值集中在脚本顶部可配置常量

- **决定**：脚本顶部集中定义阈值常量，判定函数读常量，不再 `awk 'i>0'` 硬编码。接口错误率并入统一框架（红档沿用 >0，行为不倒退）。完整初值表（红=explore D3 拍板；黄/绿=explore 第 5 节建议值落地，全部显式标注「待对齐」）：

| 指标 | 🟢 绿（待对齐） | 🟡 黄（待对齐） | 🔴 红（D3 拍板） | 顶部常量 |
|---|---|---|---|---|
| 崩溃率 | < 0.5% | 0.5% – 1% | > 1% | `CRASH_RATE_RED=1.0`（黄绿另设常量，待对齐） |
| 接口错误率 | = 0% | (0, 0.5%] | > 0（首版沿用现行为） | `NET_ERR_RED=0` |
| 慢帧占比（最差页） | ≤ 30% | 30% – 50% | > 50% | `SLOW_FRAME_RED=50` |
| 冻结率 | < 0.5% | 0.5% – 1% | > 1% | `FROZEN_RED=1.0` |
| 启动 P95 | ≤ 1500ms | 1500 – 2000ms | > 2000ms | `START_P95_RED=2000` |
| 小样本会话数 | — | — | — | `SAMPLE_SESSION_MIN=30`（< 30 加提示） |

- **理由**：集中一处便于调参；黄绿未对齐的初值显式标注「待对齐」，避免被误当已确认口径。现状「接口错误率 >0 即 🔴」是散落的硬编码 if，纳入框架后消除特判分支。explore 第 5 节建议值已落地此处，实现者不再回翻 explore 或自行编值。
- **备选**：独立配置文件（如 `thresholds.env`）——被否，阈值是脚本逻辑的一部分，放顶部常量最易读、最不易漂移，且不引入新文件加载顺序问题。

### D6：DoD/WoW 单位约定（对齐 explore D2）

- **决定**：百分比类指标（崩溃率/接口错误率/慢帧占比/冻结率）用 `±X.Xpp ↑/↓`；启动 P50/P95 用 `±Xms` 绝对差。箭头沿用「数值变大 = 变差 = ↑」。WoW 是「是否真的变差」主判据，DoD 是「今天是否突发异常」辅助信号（写进注释口径，不改展示格式）。
- **理由**：explore D2 已拍板；百分比指标天然无量纲，耗时指标用户关心绝对毫秒而非百分比。

### D7：性能类指标 DoD 的滞后回退

- **决定**：性能批量表滞后约 2 天，07:00 运行时「昨日」性能数据常未到齐。perf 类指标（启动 P50/P95、慢帧、冻结）的 DoD 取「**最新可用单日值**与其前一单日值」对比，并在注释标注实际对比的日期；若历史里只有一个可用日，显示「无基准」。崩溃/放量（REALTIME）不受影响，严格按「昨日」对比。此条已编码进 spec R1「性能指标滞后回退」scenario，实现与验收均以 spec 为准。
- **理由**：不能硬算一个不存在的「昨日性能值」；回退到最新可用日至少给出趋势，且如实标注避免了「用 D-2 冒充 D-1」的误导。
- **备选**：perf 指标一律显示「无基准」直到数据追齐——被否，2 天滞后常态存在，等于永久失去 perf 环比。

### D8：双副本同步 + capability 结构

- **决定**：`bin/` 与 `scripts/crash-report/` 两个镜像副本（`.sh` 与 `sql/` 目录）的改动必须逐字节一致（implement 验收用 `diff` 复测）。本 change 只新增一个能力 `crash-perf-daily-monitoring`，不 MODIFY 未归档的 `crash-perf-daily-card` / `crash-perf-daily-weekly-report`（它们不在 `openspec/specs/` 内，MODIFIED delta 无基准；且本次对卡片/告警是「新增内容与新增判定」，属 ADDED 语义）。
- **理由**：双副本是既有约束（explore 风险 #6）。capability 结构见 proposal Capabilities 注释——避免对未归档 change 做跨 change 耦合，保证本 change 可独立归档。
- **备选**：对 `crash-perf-daily-card` 写 MODIFIED delta——被否，其尚未归档，`openspec validate` 无既有 spec 可对齐。

### D9：慢帧/冻结环比用平台聚合，最差页仅作今日展示

- **决定**：慢帧占比、冻结率的 DoD/WoW 采用**平台级聚合帧级占比**（iOS/Android 各自对所有页面汇总「慢帧数 ÷ 总帧数」）作对比，而非 `perf-screens.sql` 的「最差页」单页值。卡片上「最差页」今日展示（含页名、`ORDER BY slow_pct DESC` 取最差）保持不动，仅作现状快照，不参与环比；红绿灯阈值（R3）仍作用于今日最差页展示值。此条已编码进 spec R1「慢帧冻结环比用平台聚合」scenario。
- **理由**：最差页每天可能不同（`perf-screens.sql | head -1`），跨天对比不同页面语义失真；平台聚合口径稳定，且与受影响安装数等平台级指标对齐。最差页的帧级占比语义已由 R5 注释兜底，不因环比而改动。
- **备选**：① 同页面对比——被否，需逐页存历史，复杂度高且页面集本身在变动；② 照旧比最差页并仅标注「页面可变」——被否，仍无法消除跨页失真。

## Risks / Trade-offs

- **[性能表滞后导致 DoD 口径不齐]** → D7 回退 + 如实标注对比日期，不硬算。
- **[慢帧/冻结「最差页」跨天不可比]** → D9 平台聚合口径，最差页仅作今日展示。
- **[WoW/sparkline 冷启动前 7 天无基准]** → 显示「无基准」/ 按已有天数渲染，属预期，勿当故障（explore 风险 #5）。
- **[口径混用：天级 vs 窗口]** → D2 字段带口径标识 + 注释显式区分，code review 重点检查。
- **[历史文件写并发/原子性]** → L1 是唯一写者，冲突风险低；仍用临时文件 + mv 原子写（explore 风险 #4）。
- **[crashlytics REALTIME 仍在回填，DoD 首验期数值偏低]** → 沿用「回填中」注释，勿据 DoD 突降判断「崩溃变少」（explore 风险 #1）。
- **[sparkline 归一化极值失真]** → 7 日序列若某天为 0、某天为尖峰，归一化会放大波动；首版接受（迷你图本为「看趋势」而非「看绝对量」），若误读再引入固定分位档。

## Migration Plan

1. 实现并同步双副本：`crash-rate.sql` 加第三子查询 + 新增天级单日值查询 + 慢帧/冻结平台聚合查询；`crash-daily.sh` 加 DoD/WoW 计算、阈值红绿灯、小样本提示、sparkline、`metrics-history.jsonl` 读写。
2. `CRASH_REPORT_DRY_RUN=1` 跑脚本，核对：DoD/WoW 数值与手工验证一致、阈值告警命中、sparkline 档位合理、`card.json` 合法且 <30KB、双副本 `diff` 一致、`bash -n` 通过。
3. 冷启动：首次运行写入首行 history（无 DoD/WoW 基准，预期）；连续跑满 7 天确认 WoW 与 sparkline 出现完整基准。
4. 实跑投递到私聊验证卡片渲染，再投群；用户确认后归档。
5. **衔接对账（归档顺序约束）**：本 change 与未归档 `crash-perf-daily-weekly-report` 在「接口错误率告警」上契约重叠（本 change 把接口错误率纳入统一阈值框架，红档沿用 >0）。**归档顺序约束**：本 change 必须先于 `crash-perf-daily-weekly-report` 归档；若顺序相反，`crash-perf-daily-weekly-report` 归档时必须同步改写其「告警判定 → 接口错误率异常」scenario（其 spec:139-142），与本 change 的统一阈值框架对账（红档沿用 >0，行为不倒退）。

**回滚**：双副本改动经 git 未提交状态可 revert；`metrics-history.jsonl` 是新增文件，删除即回退到「无历史」状态（DoD/WoW/sparkline 显示无基准），不影响既有日报投递。

## Open Questions

无。阈值红档已拍板、黄绿建议值已落地并标注「待对齐」、受影响安装数口径与 DoD/WoW 单位已拍板、perf 滞后回退与慢帧/冻结平台聚合口径已定；均不改变 spec、方案或任务拆分。
