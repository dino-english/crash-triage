# 任务清单 — crash-perf-card-table-v2

> 本 change 契约规模：**9 条 requirement / 33 个 scenario**（`specs/crash-perf-daily-card-v2/spec.md`）。
> 实现范围：`bin/crash-daily.sh` + `scripts/crash-report/crash-daily.sh`（双副本，逐字节一致），仅动展示层 `CARD_JSON` 组装段与相关拼装函数；SQL / 取数 / 告警 / 快照零改动，唯一例外 `NET_ERR_RED` 0→1.0。
> 现状计数（grep 实测，2026-08-16）：`column_set` 3 处（L641 注释 + L706/L710 组件）、`tag:"note"` 1 处（L715）、`wide_screen_mode` 1 处（L701）、`"schema"` 0 处、`tag:"table"` 0 处、`tag:"markdown"` 10 处、`tag:"hr"` 3 处、`__DETAIL_URL__` 2 处（L716 组件 + L789 注释）。

## 1. CardKit v2 结构迁移（R1 / D1）

- [x] 1.1 `CARD_JSON` 组装段（现 L695-717）顶部加 `"schema":"2.0"` 显式声明（当前 0 处）
- [x] 1.2 顶层 `elements` 移入 `body.elements`（v2 新增 body 层；删顶层 `i18n_elements` 语义）
- [x] 1.3 删除 `config.wide_screen_mode`（L701），改 `config.width_mode:"fill"`
- [x] 1.4 底部 `note` 组件（L715）改写为 `div`（`tag:"div"` + `text_size:"notation"` + `text_color:"grey"`），`plain_text` 内容迁入 div
- [x] 1.5 v1 残留清零验收：`grep -n 'wide_screen_mode\|"note"\|i18n_elements'` 在 `CARD_JSON` 组装段应为空；`grep -n '"schema"'` 应命中 1 处 `"2.0"`

## 2. 原生 table 组件（R2 / D3 / D4）

- [x] 2.1 新增崩溃表 `tag:"table"`：3 行（崩溃次数 / 崩溃率 / 受影响安装）× 3 列（指标/iOS/Android），替换第一处 `column_set`（L706）
- [x] 2.2 新增性能表 `tag:"table"`：5 行（启动 P50 / 启动 P95 / 慢帧最差页 / 冻结率 / 接口错误率）× 3 列，替换第二处 `column_set`（L710）
- [x] 2.3 列定义：`metric` 列 `data_type:"text"`、`ios`/`android` 列 `data_type:"lark_md"`（承载红绿灯着色）
- [x] 2.4 两表显式 `page_size:10`（避免默认 5 分页）+ `header_style{bold:true, background_style:"grey"}` + `row_height:"low"`
- [x] 2.5 改写 `crash_col_md`（L648）与 `perf_col_md`（L662）为「表格单元格值」产出（每行一个指标值，含红绿灯着色与紧凑环比），不再拼分栏 markdown 段落
- [x] 2.6 两表放 `body.elements` 根节点下，`grep -c 'column_set'` 归零（当前 3 处，含 L641 注释同步更新）

## 3. 单元格红绿灯（R3 / D3 / D7 / D8）

- [x] 3.1 新增单元格着色助手：按 `traffic_light()` 结果对平台单元格包 `<font color=red|orange>`，正常档裸值不包；空值/「无法计算」不判定不包色
- [x] 3.2 核心指标单元格（崩溃率/P50/P95/慢帧/冻结/接口错误率）整体着色（当前值 + 环比变化量同格同色，D3）
- [x] 3.3 `NET_ERR_RED` 常量 `0 → 1.0`（L54，Q1-a），注释改「红 >1%（需求对齐）」；同步双副本
- [x] 3.4 黄档采用脚本现值着色（Q2-a），常量注释保留「待对齐」（`CRASH_RATE_YELLOW=0.5` / `SLOW_FRAME_YELLOW=30` / `FROZEN_YELLOW=0.5` / `START_P95_YELLOW=1500` / `NET_ERR_YELLOW=0.5`）

## 4. 核心指标紧凑环比 DoD/WoW（R4 / D5）

- [x] 4.1 新增展示层助手 `cell_dod_wow()`：输入同 `_dod_wow`（今日/昨日/D-7/单位/日期标注），输出 `当前值 + DoD ±变化量 ↑/↓ + WoW ±变化量 ↑/↓` 紧凑格式
- [x] 4.2 DoD 无基准（昨日/D-7 缺失）时省略 DoD 段、WoW 无基准时省略 WoW 段（不渲染「无基准」字样），两端均无则只显示当前值
- [x] 4.3 变化量符号/箭头/单位（±pp/±ms、数值变大=变差=↑）复用 `_dod_wow` 的 awk 算术，不重算（红线）
- [x] 4.4 单元格去除「对比 X vs Y」日期标注，实际对比日期只在底部口径说明统一出现一次

## 5. 顶部摘要 + 底部口径弱化（R5 / R7 / D6）

- [x] 5.1 顶部摘要 markdown 改为仅渲染命中红/黄档的指标行（不再全量 ALERTS 罗列）；无命中显示「✅ 无异常」
- [x] 5.2 黄档行在摘要可见但不进 `ALERTS`（🔴 告警）与 header 模板色切红（沿用既有「黄档仅注释待对齐、不告警」）
- [x] 5.3 底部口径说明保留慢帧定义 + 三表截止时间戳，用 `div` 小字浅色 + `hr` 分隔（与 1.4 合并落地）

## 6. 保留项与红线（R8 / R9 / D9 / D10）

- [x] 6.1 深色风格主题自适应：不引入写死 RGBA，header template 色 + `text_color:"default"` + `<font color>` 枚举色由客户端主题自适应
- [x] 6.2 保留三层结构（崩溃/性能/放量）、header 标题栏（告警红/无告警蓝切换）、放量 markdown 段落、详情链接 `__DETAIL_URL__`
- [x] 6.3 红线核对：`git diff` 确认 `crash-rate.sql`/`crash-issues.sql`/`perf-*.sql`/`sessions-by-version.sql`/天级单日值查询及 `_dod_wow`/`traffic_light`/取数/告警/快照逻辑零改动（唯一改动 `NET_ERR_RED`）
- [x] 6.4 双副本同步：`bin/crash-daily.sh` ↔ `scripts/crash-report/crash-daily.sh` 逐字节一致（`diff` 复测）

## 7. 校验与验收（D10）

- [x] 7.1 `bash -n` 双副本通过
- [x] 7.2 `CRASH_REPORT_DRY_RUN=1` 跑脚本：`card.json` 合法（`jq empty`）、<30KB、含 2 张 `table`、`"schema":"2.0"`、无 `column_set`/`note`/`wide_screen_mode` 残留、单元格含 `<font color>` 着色与紧凑环比
- [x] 7.3 实投一张带红绿灯 table 的测试卡到私聊，验证 `<font color>` 单元格着色与整体布局（R1 风险，DRY RUN 验不了渲染） — 2026-08-20 私聊实投完成（L1 run `20260820-111100`）。R1 风险已解除：CardKit v2 `table` 组件（`crash-daily.sh:797`）+ 18 处 `<font color>` 单元格着色实测渲染正常，Sir 目视确认
- [x] 7.4 实跑投递日报群 `oc_655033f1f85fa04f9eac25d56f056fc9`，用户确认效果 → 记录验收结论，进入 review(代码) / validate — 2026-08-20 Sir 确认效果。**投群未做**：验证期投递刻意限定私聊避免噪音进正式群，稳态由 cron 每日 07:00 自动投群。验收结论：红绿灯着色、版本分列、对比列箭头跟数值方向而颜色跟好坏，均符合 design 预期
