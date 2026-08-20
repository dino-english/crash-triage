## Context

日报群卡片由两条链路协作产出（见 proposal.md - Why，不赘述）：

1. `crash-daily.sh` 提取指标、组装 `CARD`（目前是纯 markdown 文本）→ 写入 `state/publish/message.md` + `manifest.json`
2. cron L1（`4b0c7362063b`）的 agent 读 manifest，把 message.md 追加「详情」链接后，包成 `{"config":{"wide_screen_mode":true},"elements":[{"tag":"markdown","content":"<全文>"}]}` 发给 `im_v1_message_create`

当前 `CARD` 变量（脚本第 385-393 行）是一段拼好的 markdown：标题行 + 告警块 + 崩溃/启动/卡顿/冻结/接口/放量六行 + 口径 note。崩溃率已存在但以 `（率 2/1017）` 藏于崩溃行括号内。

飞书 interactive 卡片支持（lark-mcp 白名单内，不新增工具）：`header`（彩色标题栏，模板 blue/wathet/turquoise/green/yellow/orange/red/carmine/violet/purple/indigo/grey）、`column_set`（`flex_mode` 分栏，`bisect` 两栏均分 / `flow` 自动流式）、`hr` 分隔线、`note` 注释块、markdown 内 `<font color='red'>…</font>` 彩色文字。

## Goals / Non-Goals

**Goals:**
- 把卡片从「单 markdown 堆叠」升级为「彩色 header + 三块分区 + 双端分栏 + note」的结构化卡片
- 崩溃率提为独立醒目指标（口径不变，百分比纯展示换算）
- 卡片 JSON 由脚本确定性产出，agent 零改写投递

**Non-Goals:**
- 不改任何 SQL / 取数 / 聚合 / 告警 / 快照 / 箭头趋势逻辑
- 不改日报文档（`docs/daily.md`）内容——文档保持 markdown 全量，卡片只是群聊摘要
- 不做固定 ID 覆盖索引页/台账（既有待办，不属于本 change）
- 不改周报（L2）卡片——本 change 只动 L1 日报卡片

## Decisions

### D1：卡片 JSON 由脚本产出，agent 原样投递

- **决定**：`crash-daily.sh` 用 jq 组装完整 interactive 卡片 `content` JSON（header + column_set + hr + note + 末尾详情占位符），写入 `state/publish/card.json`；manifest 增加 `card_file` 字段。cron prompt 改为：读 `card.json` → 把占位符替换成真实文档 URL → 原样作为 `data.content` 发送。
- **理由**：现状让 agent 手写卡片 JSON，既违背「禁止改写脚本产出」的硬约束，又每次跑都有手写 JSON 出错的风险（skill 已记录「content 手写 JSON 易错」）。脚本用 jq 组装是确定性的、可单测的、字节可复现的。
- **备选**：① 让 agent 按 prompt 描述现拼 header/column_set——被否，违背「禁止改写」且易错；② 脚本继续出 markdown、仅给 agent 一份「如何结构化」的说明——被否，agent 每次可能拼得不一样。

### D2：卡片结构 = header + 三块 column_set/段落 + note

- **决定**：顶层 `header`（标题 `📊 MM-DD 崩溃 & 性能`，模板色按告警状态：有告警 red / 无告警 blue）；主体三块，每块一个彩色小标题（markdown `<font color>`）+ 内容：
  - **崩溃块**：`column_set`（bisect）两栏 iOS | Android，各含「N 类 N 次」+ 独立崩溃率行
  - **性能块**：`column_set`（bisect）两栏 iOS | Android，各含启动 P50/P95、最差慢帧页、冻结率、接口错误率
  - **放量块**：单栏段落（最新版 + 会话数，两端各一行）
  - 底部 `note`：口径说明 + 截止时间戳（三表分列）
- **理由**：崩溃/性能是「双端对比」最密集的两块，`column_set` 分栏收益最大；放量块行少、分栏浪费宽度，用单栏段落更紧凑。三块彩色小标题用 `<font color>` 实现（lark 卡片无「块级标题」元素，header 只能有一个顶层）。
- **备选**：三大块各自都用 column_set——被否，放量只有一行分栏意义小且更挤。

### D3：崩溃率独立行 + 百分比换算在展示层做

- **决定**：崩溃块每端列内，崩溃计数一行、崩溃率单独一行。百分比 = `crash_events/sessions*100`，用 awk `printf '%.2f'` 保留两位小数（`2/1017→0.20%`、`39/2500→1.56%`），同时保留原始分数。分母为 0 或不可得时沿用现有 `rate_str` 的「无法计算」。
- **理由**：口径（事件数/会话数）是既有 SQL `crash-rate.sql` 定的，spec 明确不改；百分比只是把已有分数换算成更易读的形式，不新增查询、不改 SQL。
- **备选**：改 SQL 做 session 级 crash-free 精确口径——被否，违反「数据计算方式不能变」且 `crash-rate.sql` 注释已明示该口径留待后续。

### D4：保留 markdown 视图作为回退与调试

- **决定**：脚本仍写 `state/publish/message.md`（纯 markdown 版本），新增 `card.json`（结构化版本）。若 `card.json` 缺失或为空，agent 回退用 message.md 走旧单 markdown 路径。
- **理由**：灰度回退能力——结构化卡片一旦在某端渲染异常，可一键切回旧形态而不丢当日数据。且 message.md 仍是人工排查时最好读的形态。
- **备选**：彻底删掉 message.md——被否，丢失回退与调试抓手。

## Risks / Trade-offs

- **[lark 卡片 JSON 手写易错]** → 用 jq 确定性组装消除手写；DRY RUN 时对 `card.json` 跑 `jq empty` 校验合法性。
- **[30KB content 上限]** → 当前纯文本卡片远小于上限（几百字节）；结构化后仍远低于上限，但需在 DRY RUN 里打印 `card.json` 字节数确认。若超限则砍放量块历史版本行（卡片本就只出最新版）。
- **[column_set 内 markdown 超宽挤压]** → 崩溃/性能块分栏内只用短行（指标名 + 数值），长文案（口径说明）放 note 块不放入分栏；`wide_screen_mode=true` 已开启。
- **[header 模板色语义漂移]** → 明确「有告警 red / 无告警 blue」单一规则，写进 cron prompt 与脚本注释，避免 agent 或后人改色。
- **[崩溃率百分比浮点精度]** → 用 awk `%.2f` 固定两位小数，与现有 `pct()` 的「整数去零、非整保一位」口径区分开（崩溃率天然是千分位量级，需两位小数）。

## Migration Plan

1. 改 `scripts/crash-report/crash-daily.sh` 与 `bin/crash-daily.sh`（两者是 git 源副本 + 运行副本，需同步）——`CARD` 逻辑新增 jq 组装 `card.json`，manifest 增 `card_file`
2. 更新 cron L1 prompt（`hermes cron update 4b0c7362063b`）：投递步骤改读 `card.json`
3. **DRY RUN 验证**：`CRASH_REPORT_DRY_RUN=1` 跑脚本，人工检查 `card.json` 结构合法 + 字节数 + 三块分区 + 崩溃率独立行 + 指标数值与旧卡一致
4. 实跑投递到私聊验证渲染（先 `ou_xxx` 私聊，再群）
5. 用户确认群卡片效果 → 才 `openspec archive`

**回滚**：脚本改动通过 git 未提交状态可 revert；若结构化卡片渲染异常，agent 侧可临时回退走 message.md 单 markdown 路径（D4 保留的兜底），不影响数据投递。

## Open Questions

无。崩溃率口径、卡片结构、告警色规则均已在上文定死，无会改变 spec 或任务拆分的遗留未知。
