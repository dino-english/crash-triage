## Context

日报链路现状（`bin/crash-daily.sh` 与 `scripts/crash-report/crash-daily.sh` 逐字节一致，共 847 行）：

- **卡片**：`CARD_JSON`（L695-717）用 `jq -n` 组装 v1 结构——`config.wide_screen_mode:true` + `header` + 顶层 `elements`，崩溃/性能两段各用 `column_set`（`flex_mode:"bisect"`）左右分栏，内填 `crash_col_md`/`perf_col_md`（L648/L662）拼出的 markdown；底部 `note` 组件收口径注释；末尾 `markdown` 详情链接。当前 `state/publish/card.json` 4143 字节，无 table 组件。
- **指标**：崩溃（次数/率/受影响安装）、性能（启动 P50/P95、慢帧最差页、冻结、接口错误率）、放量（最新版会话数），双端 iOS/Android；DoD/WoW 环比、阈值红绿灯、小样本提示、sparkline 已在 `crash-perf-daily-monitoring-enhancement` 落地，本次直接复用其取数结果与常量。
- **探明事实（explore-notes 第 1 节）**：CardKit v2 `table` 组件无「单元格级」样式属性，`text_color`/`background_style` 只作用于表头；单元格彩色文字只能走 `lark_md` 的 `<font color>` 语法（官方明确支持）；单元格「背景色」不可做；`options` 标签长文本会截断。
- **现状计数（grep 实测）**：`column_set` 3 处（1 注释 + L706/L710 两处组件）、`"note"` 1 处（L715）、`wide_screen_mode` 1 处（L701）、`"schema"` 0 处（需新增）、`tag:"table"` 0 处（需新增 2）。

## Goals / Non-Goals

**Goals:**

- 整卡迁 CardKit v2（`schema:"2.0"` + `body.elements` + `width_mode:"fill"`），`note`→`div`
- 崩溃表 + 性能表两张原生 table（行=指标，列=指标|iOS|Android），单元格红绿灯 + 紧凑环比 DoD/WoW
- 顶部摘要只渲染阈值命中行；底部口径弱化（div 小字浅色 + hr 分隔）
- `NET_ERR_RED` 0→1.0（Q1-a）；黄档采用脚本现值着色（Q2-a）；直接迁 v2（Q3-a）
- 双副本（`bin/` + `scripts/crash-report/`）改动逐字节一致

**Non-Goals:**

- 不改任何 SQL 查询、指标取数、告警判定、快照、`_dod_wow` 环比计算逻辑（红线）
- 不改放量段内容（仍为 markdown 单栏段落）、不改详情链接、不改 header 模板色规则
- 不改 `CARD` 扁平文本（L622-637，报告/调试用的 markdown 正文）——本次只动 `CARD_JSON` interactive 卡片
- 不做单元格背景色（官方无此能力）；不做 `config.style.color` 自定义 RGBA 深色配色
- 不新增/不删除指标，不调整崩溃率、慢帧等既有口径

## Decisions

### D1：整卡迁 v2（方案 A），table 是硬前提

- **决定**：采纳 explore 方案 A——顶部加 `schema:"2.0"`、`elements` 移入 `body.elements`、`wide_screen_mode` 删除改 `width_mode:"fill"`、`note`→`div`；两张 table 替换两处 `column_set`；header/`hr`/markdown 段落保留。
- **理由**：`table` 组件只存在于 v2 结构，迁 v2 是需求硬前提。v1 元素里仅 `note` 需改写，`header`/`hr`/`markdown`/`column_set` 在 v2 均保留；迁移面可控。
- **备选**：① 只加 table 不加 schema 2.0（explore 方案 B）——被否，v1 卡片 JSON 无 `table` 标签，解析失败；② 继续用 markdown 段落（方案 C）——被否，不满足 requester 点名的原生 table 诉求。

### D2：capability = 新能力 `crash-perf-daily-card-v2`

- **决定**：本 change 新增 capability `crash-perf-daily-card-v2`，不 MODIFY 未归档的 `crash-perf-daily-card`（`crash-perf-card-beautify` 内，不在 `openspec/specs/` 内）。
- **理由**：openspec 要求 MODIFIED 引用 `openspec/specs/<cap>` 的既有路径；未归档能力无此基准。沿用仓库既有约定（daily-monitoring-enhancement D8）避免跨 change 耦合。
- **备选**：MODIFY `crash-perf-daily-card`——被否，其未归档，validate 无既有 spec 可对齐，且归档时 merge 会失基准。

### D3：单元格红绿灯 = `lark_md` `<font color>`，黄档用 `orange`

- **决定**：平台列 `data_type:"lark_md"`，红/黄/正常分别 `<font color=red>` / `<font color=orange>` / 裸值（不包 font）。黄档选 `orange` 而非 `yellow`（浅色主题下 orange 对比度优于 yellow，深色主题两者都清晰）。整个核心指标单元格（当前值 + 环比变化量）包裹同一着色，由当前值阈值决定；环比变化方向（↑/↓）只靠箭头表达，不另行着色。
- **理由**：V1 结论「table 无单元格样式属性，彩色文字只能走 lark_md」。单条着色规则（阈值决定）最简、最不易误导；方向已由箭头承载，再按方向着色会与红绿灯语义打架。
- **备选**：① 单元格背景色——被否，官方无此能力；② 黄档用 `yellow`——被否，浅色主题对比度不足；③ 环比 delta 按方向单独着色（绿↓/红↑）——被否，与「红绿灯按阈值」单规则冲突，增加误读面。

### D4：表格行布局与核心指标环比内联

- **决定**：崩溃表 3 行（崩溃次数 / 崩溃率 / 受影响安装）、性能表 5 行（启动 P50 / 启动 P95 / 慢帧最差页 / 冻结率 / 接口错误率）。DoD/WoW 环比**内联**进核心指标单元格（崩溃率、P50/P95、慢帧、冻结、接口错误率），不单独成行；崩溃次数、受影响安装两行无红绿灯、无环比。
- **理由**：requester 需求「核心指标补 DoD/WoW 紧凑环比（数值 ↑/↓ 变化量）」，紧凑 = 内联而非拆行；红绿灯只作用于有阈值语义的核心指标。
- **备选**：环比 DoD/WoW 各拆独立行（explore §2 早期草案）——被否，「紧凑」诉求要求内联，且拆行会让「核心指标 + 环比」割裂、行数翻倍。

### D5：环比内联格式与「无基准隐藏」实现（展示层，不动 `_dod_wow`）

- **决定**：新增展示层助手（如 `cell_dod_wow()`），输入与 `_dod_wow` 相同（今日值/昨日值/D-7 值/单位/日期标注），输出紧凑格式：`当前值` + ` DoD ±变化量 ↑/↓` + ` WoW ±变化量 ↑/↓`，DoD/WoW 各自基准缺失时省略该段（不输出「无基准」）。变化量的符号、箭头、单位（pp/ms）复用 `_dod_wow` 的 awk 算术与约定，**不重算**。`_dod_wow` 与 `CARD` 扁平文本保持不变（报告/调试视图沿用「DoD X · WoW 无基准」旧格式）。
- **理由**：requirement「WoW 无基准时隐藏字段，不显示「无基准」」是表格展示层的裁剪，不是环比计算改变。新增 helper 而非改 `_dod_wow`，可避免连带改动 `CARD` 扁平文本与既有「无基准」语义（那属于报告正文，不在本次范围）。
- **备选**：直接改 `_dod_wow` 去掉「无基准」——被否，会连带改 `CARD` 扁平文本、扩大范围且可能影响报告可读性。

### D6：顶部摘要只渲染阈值命中行

- **决定**：摘要 markdown 由「全量 ALERTS 拼接」改为「仅渲染命中红/黄档的指标行」；无命中时显示「✅ 无异常」。命中黄档的指标行在摘要中可见（提示临近），但只有红档进入既有 `ALERTS`（🔴 告警）与 header 模板色切红。
- **理由**：requirement「顶部摘要只保留触发阈值指标」。黄档属「临近」，摘要里可见但不算告警（与既有「黄档仅注释待对齐、不告警」一致）。
- **备选**：摘要只显示红档、完全隐藏黄档——被否，「触发阈值」含红黄两档，黄档也应让收卡人看到趋势。

### D7：`NET_ERR_RED` 0→1.0（Q1-a，唯一数据层例外）

- **决定**：把脚本常量 `NET_ERR_RED` 从 `0` 改为 `1.0`，注释同步为「红 >1%（需求对齐）」。这是本 change 唯一触碰数据判定常量的地方，requester 已拍板（Q1-a）。
- **理由**：需求 8「接口错误率 >1% 红档」与现值 `0`（>0 即红）冲突；不改则单元格红档着色与告警行为均与需求不符。改这一处常量同时对齐「单元格着色」与「告警判定」两处（二者都读同一常量）。
- **备选**：另开 change 改常量——被否，requester 已拍板随本 change 一并落地。

### D8：黄档采用脚本现值着色（Q2-a）

- **决定**：黄档阈值直接采用脚本现有常量（崩溃率 0.5、慢帧 30、冻结 0.5、启动 P95 1500、接口错误率 0.5），着色即隐含确认；常量注释保留「待对齐」，后续团队对齐仅微调常量、不重走流程。
- **理由**：requester 拍板「按照你推荐的来」；着色与告警共用同一常量，避免两套阈值漂移。
- **备选**：本轮只做红/正常两态、不做黄档——被否，需求 3 明确要 🟡「临近」档。

### D9：深色风格 = 主题自适应（V5 结论）

- **决定**：不引入任何显式深色配置；header `template` 色、表头 `background_style:"grey"`、`text_color:"default"` 与 `<font color>` 枚举色均由客户端主题自适应。MUST NOT 写死浅色/深色专属 RGBA。
- **理由**：explore V5——CardKit 无 `theme` 开关，深色观感 = 跟随客户端主题；现卡本无显式深色配置，迁移后自动保持。
- **备选**：`config.style.color` 自定义 RGBA——被否，不需要，且引入维护面。

### D10：双副本同步 + 渲染实投验证

- **决定**：`bin/crash-daily.sh` ↔ `scripts/crash-report/crash-daily.sh` 改动逐字节一致（implement 验收用 `diff` 复测）。DRY RUN 只验 JSON 合法性（`jq empty`）+ 字节数 <30KB；`<font color>` 在表格单元格内的实际渲染须 implement 阶段先实投一张带色测试卡到私聊验证（R1 风险），确认着色与布局后再切正式。
- **理由**：双副本是既有约束；表格单元格 `<font color>` 官方只文档层支持、无表格示例，必须实投验证渲染（DRY RUN 验不了渲染）。
- **备选**：仅凭 DRY RUN `jq empty` 放行——被否，验不了渲染。

## Risks / Trade-offs

- **[v2 严格校验：残留任一 v1 字段整卡报错]** → D1 全量清理（`wide_screen_mode`/顶层 `elements`/`note`），implement 用官方错误码表做验收清单（230099/200861）。
- **[表格单元格 `<font color>` 渲染未实投验证]** → D10：implement 第一步先实投带色测试卡到私聊，确认着色与布局后再切正式。
- **[客户端 <7.20 降级显示]** → Q3-a 已拍板接受（低版本仅显示标题 + 升级提示，不影响 ≥7.20 成员）。
- **[`page_size` 默认 5 分页]** → D4 显式 `page_size:10`；性能表 5 行、崩溃表 3 行均 <10，无分页。
- **[黄档阈值「待对齐」隐含确认]** → D8：着色即采用现值，注释保留「待对齐」，后续对齐仅微调常量。
- **[`NET_ERR_RED` 0→1.0 改变告警行为]** → D7：requester 已拍板；iOS 0.6% 红→黄、Android 2.2% 仍红，属预期对齐。
- **[双副本漂移]** → D10：`diff` 复测；脚本顶部注释标明「双副本，改动须同步」。

## Migration Plan

1. 重构 `CARD_JSON` 组装段（现 L695-717）为 v2 结构；改写 `crash_col_md`/`perf_col_md` 为「表格单元格值」产出；新增 `cell_dod_wow()` 紧凑环比 helper；摘要改为阈值命中行；底部 `note`→`div`；`NET_ERR_RED` 0→1.0。同步双副本。
2. `CRASH_REPORT_DRY_RUN=1` 跑脚本：`card.json` 合法（`jq empty`）且 <30KB、含 2 张 table、`schema:"2.0"`、无 `column_set`/`note`/`wide_screen_mode` 残留、`bash -n` 通过、双副本 `diff` 一致。
3. 实投一张带红绿灯 table 的测试卡到私聊，验证 `<font color>` 单元格着色与整体布局。
4. 实跑投递到日报群 `oc_655033f1f85fa04f9eac25d56f056fc9`，用户确认效果后进入 review(代码)/validate。
5. **衔接对账（归档顺序约束）**：本 change 与未归档 `crash-perf-card-beautify`（capability `crash-perf-daily-card`）是「v1 卡片结构 → v2 卡片结构」替代关系。归档顺序约束：`crash-perf-card-beautify` 须先于本 change 归档；若顺序相反，本 change 归档时其 `crash-perf-daily-card-v2` spec 的 Purpose 须注明「v2 取代 v1 的 `column_set` 分栏结构」做一致性对账。

**回滚**：双副本改动经 git 未提交状态可 revert；无新增数据文件，回退即恢复 v1 卡片（`column_set` 分栏结构），不影响既有日报投递与数据管道。

## Open Questions

无。Q1/Q2/Q3 已由 requester 拍板（explore-notes OPEN QUESTIONS 节）；阈值红档、黄档现值、v2 迁移放行条件均已定，不改变 spec、方案或任务拆分。唯一剩余未知是「表格单元格 `<font color>` 实投渲染效果」，属 implement 阶段验收项（R1 风险），非待答决策。
