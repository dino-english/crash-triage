## Why

日报群卡片现在是「单个 markdown 元素」——崩溃、性能、放量三大块挤在一大坨纯文本里，iOS/Android 数字混排，一眼看不清「哪端在恶化、崩溃率多少、新版放量够不够」。飞书 interactive 卡片原生支持彩色 `header`、`column_set` 分栏、`hr` 分隔线、`note` 注释块，全部已在 lark-mcp 白名单工具内，**不新增工具、不改数据计算**即可把卡片从「一坨字」升级成「三块彩色分区 + 双端分栏」的可扫读结构。

崩溃率（事件数/会话数）其实已在卡片上，但以 `（率 2/1017）` 分数形式藏在崩溃行括号里，几乎不可见。本次把它提为独立醒目指标，并给出百分比换算（纯展示换算，分子分母不变）。

## What Changes

- **日报群卡片从「单个 markdown 元素」升级为结构化 interactive 卡片**：
  - 顶部彩色 `header` 标题栏（模板色，如 blue/red 按告警状态切换）
  - 三大块（崩溃 / 性能 / 放量）各配彩色小标题 + `hr` 分隔线
  - 崩溃、性能两块用 `column_set` 左右分栏（iOS | Android 并排）
  - 口径/截止时间用 `note` 注释块收尾
- **崩溃率提为独立醒目指标**：从崩溃行括号里抽出，单独一行展示「崩溃率 iOS x.x% (2/1017) · Android x.x% (39/2500)」。**口径不变**（事件数/会话数，非 crash-free），百分比仅是展示层换算。
- **数据计算方式完全不变**：所有 BigQuery 查询、指标提取、告警判定、快照、箭头趋势逻辑一律不动，仅改卡片 `content` 的 JSON 结构与渲染。
- **cron 投递 prompt 同步更新**：卡片结构由脚本产出（确定性 JSON），agent 只负责原样投递，不手写、不改写卡片 JSON（消除手写 JSON 易错 + 违背「禁止改写」硬约束的风险）。

## Capabilities

### New Capabilities

- `crash-perf-daily-card`: 日报群卡片的展示结构契约——三大块彩色分区、双端分栏、崩溃率独立醒目指标、结构化 interactive 卡片（header/column_set/hr/note），且数据计算口径不变

### Modified Capabilities

<!-- 无。本次只新增卡片展示契约，不修改 crash-perf-daily-weekly-report（其 spec 尚未归档）等既有能力的行为需求。
     数据计算、告警、快照、台账等既有 requirement 均不变，仅新增「卡片如何展示」这一独立关注点。 -->

## Impact

**代码**：
- `scripts/crash-report/crash-daily.sh` + `bin/crash-daily.sh`：`CARD` 组装逻辑从「拼 markdown 文本」改为「用 jq 产出结构化卡片 JSON」（保留 markdown 作为回退/调试视图），崩溃率百分比换算在展示层新增
- cron L1 prompt（`~/.hermes/cron/jobs.json` 内 `4b0c7362063b`）：投递步骤从「拼单个 markdown 元素」改为「原样读取脚本产出的卡片 JSON 投递」

**数据源 / SQL**：零改动。`crash-rate.sql`、`crash-issues.sql`、`perf-*.sql`、`sessions-by-version.sql` 全部不动。

**契约**：新增 `openspec/specs/crash-perf-daily-card/spec.md`（归档后）。不改 `crash-perf-daily-weekly-report` 的既有 requirement。

**风险**：lark 卡片 `content` JSON 手写易错 + 30KB 上限；分栏 `column_set` 内 markdown 若超宽会挤压——需在 DRY RUN 里用真实数据验证渲染。由脚本用 jq 确定性产出 JSON 可消除手写错误，30KB 上限需在设计中确认当前卡片体量（当前纯文本卡片远小于上限）。
