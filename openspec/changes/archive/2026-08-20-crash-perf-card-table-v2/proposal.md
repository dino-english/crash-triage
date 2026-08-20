## Why

日报卡片现在用 CardKit v1 的 `column_set` 分栏把 iOS / Android 指标左右堆成两坨 markdown——数字混排、没有行列对齐，崩溃率、慢帧、接口错误率谁红谁绿要逐行读字才看得清。飞书 CardKit v2 原生 `table` 组件支持「行 = 指标、列 = iOS/Android」的表格布局与单元格级彩色文字（lark_md `<font color>`），把日报从「一坨字」升级成「一眼看红绿的表格」。explore 已验证：`table` 只在 v2 结构存在，迁 v2 是需求硬前提；v1 元素里仅 `note` 需改写，迁移面可控。

## What Changes

- **整卡迁 CardKit v2**（R1）：顶部声明 `schema:"2.0"`、元素移入 `body.elements`、`config.wide_screen_mode` 删除改用 `width_mode:"fill"`；废弃的 `note` 组件改写为 `div`（`text_size:"notation"` + 灰字），恰好满足「口径说明字号调小、颜色变浅」。
- **崩溃表 + 性能表各一张原生 table**（R2）：行 = 指标，列 = 指标 | iOS | Android；指标列 `data_type:"text"`、平台列 `data_type:"lark_md"`（承载红绿灯着色）；`page_size` 显式设 10（避免默认 5 分页）。两张 table 放在 `body.elements` 根（table 不可嵌 column_set 内），`column_set` 分栏不再承载崩溃/性能内容。
- **单元格红绿灯分级**（R3）：`lark_md` 单元格对数值包 `<font color=red|orange|green>`，红档=超阈值、黄档=临近、正常=裸值不标；阈值初版崩溃率>1%、慢帧>50%、接口错误率>1%（另冻结>1%、启动 P95>2000ms，沿用脚本常量）。
- **核心指标紧凑环比 DoD/WoW**（R4）：`数值 ↑/↓ 变化量`，WoW 无基准时隐藏该字段（不再显示「WoW 无基准」）；环比日期说明不在表格内重复，底部统一写一次。
- **顶部摘要只显示触发阈值指标**（R5）：摘要 markdown 只渲染命中红/黄档的指标行，无异常时显示「✅ 无异常」占位。
- **崩溃率旁保留受影响安装数**（R6）：表内「受影响安装」行与崩溃率并列展示；小样本（<30 会话）追加「⚠️ 样本量小」。
- **底部口径说明弱化**（R7）：保留慢帧口径说明，改 `div` 小字浅色 + 分隔线区隔。
- **保留项**（R8）：深色风格（主题自适应，不写死 RGBA）、三层结构（崩溃/性能/放量）、三表截止时间戳、详情跳转链接。
- **接口错误率红档阈值对齐**（唯一数据层例外，Q1-a 已拍板）：`NET_ERR_RED` 常量 `0 → 1.0`，与需求「接口错误率 >1% 红档」一致；**红线：其余 SQL / 数据计算 / 口径一律不动**。

## Capabilities

### New Capabilities

- `crash-perf-daily-card-v2`: 日报群卡片的 CardKit v2 展示结构契约——`schema:"2.0"` 原生 table（崩溃表 + 性能表，行=指标、列=iOS/Android）、单元格红绿灯、核心指标紧凑环比 DoD/WoW、顶部异常摘要、底部弱化口径说明；数据计算口径不变

### Modified Capabilities

<!-- 无。本 change 是 v1 卡片结构（crash-perf-card-beautify 的 crash-perf-daily-card，尚未归档、不在 openspec/specs/ 内）
     的 v2 重构，无法对未归档 capability 写 MODIFIED delta（openspec 要求 MODIFIED 引用 openspec/specs/<cap> 的既有路径）。
     故以新 capability crash-perf-daily-card-v2 承接，归档顺序约束与衔接见 Impact 与 design.md Migration Plan。 -->

## Impact

**代码**：

- `bin/crash-daily.sh` + `scripts/crash-report/crash-daily.sh`（双副本，逐字节一致）：`CARD_JSON` 组装段（现 L695-717，含 `column_set` 2 处、`note` 1 处、`wide_screen_mode` 1 处）重构为 v2 结构；`crash_col_md`（L648）与 `perf_col_md`（L662）两个分栏 markdown 拼装函数改写为「表格单元格值」产出；顶部摘要改为仅渲染阈值命中行；底部 `note`→`div`。**仅动展示层，SQL / 取数 / 告警判定 / 快照逻辑不动**。
- `NET_ERR_RED` 常量 `0 → 1.0`（L54，Q1-a，唯一数据层例外）。

**数据源 / SQL**：零改动。`crash-rate.sql`、`crash-issues.sql`、`perf-*.sql`、`sessions-by-version.sql`、天级单日值查询全部不动。

**契约**：新增 `openspec/specs/crash-perf-daily-card-v2/spec.md`（归档后）。不改 `crash-perf-daily-weekly-report` 既有 requirement。

**衔接 / 归档顺序**：本 change 与未归档 `crash-perf-card-beautify`（capability `crash-perf-daily-card`）是「v1 卡片结构 → v2 卡片结构」的替代关系。归档顺序约束：`crash-perf-card-beautify` 须先于本 change 归档；若顺序相反，本 change 归档时其 spec 需在 Purpose 里注明「v2 取代 v1 的 column_set 分栏结构」做一致性对账（见 design.md Migration Plan）。

**风险**：v2 严格校验（任一 v1 残留字段整卡报 230099/200861）；客户端 ≥7.20 门槛（低版本仅显示标题 + 升级提示，Q3-a 已拍板接受）；表格单元格 `<font color>` 渲染需实投验证（DRY RUN 只验 JSON 合法性）。
