## 0. 拍板

- [x] 0.1 @ 范围只限 🚨（用户 2026-10-21「可以」）
- [x] 0.2 明显属于模块的 SDK 归该模块，兜底人按负责人表（用户 2026-10-21「可以」）
- [x] 0.3 Android 补埋点只在周报给建议（用户 2026-10-21）
- [x] 0.4 open_id 取自 crash-triage 机器人列群成员，表上人员全部在群（2026-10-21 核）

## 1. 内容文件

- [x] 1.1 `notes/owners.tsv`（design D1 取值原样落盘）
- [x] 1.2 `notes/module-rules.tsv`：按 design D2 起草；⚠️ 用 10-21 实测的 65 个 issue 逐条过一遍，灰色项（如 `media`、`pag`、`radio`）先不映射、落兜底

## 2. 取数

- [x] 2.1 `bin/sql/crash-issue-owner-signals.sql`：按 issue 取 blame_frame（owner / symbol / file / library）与 `current_screen` 众数；FATAL + ANR；走 `q_render` / `bqq`
- [x] 2.2 生产 dry-run 扫描量与耗时记入本文件：Android 8 个 issue × 30 天 145 KB、实跑 3s

## 3. 核心纯函数 `bin/lib/core/owner.sh`

- [x] 3.1 `owner_attach <条目> <fixmap.mapped> <信号> <规则原文> <负责人原文>` → 条目 + `owner_mod/owner_src/owner_id/owner_note`；`owner_coverage` 按台数算覆盖率（实现时合并为一个函数：归属与解析总是一起用）
- [x] 3.2 夹具 `bin/test/core-owner.sh`（13 条）+ `fn-owner-enrich.sh`（生产 shell 设置 4 条）：取 10-21 实测形态（`62f88f39` scope、`d3675e82` 自家帧、Azure Speech SDK、iOS 登录页、Android `MainActivity`、全不命中、负责人缺、兜底缺）；⛔ 双向——去掉任一优先级分支必须有用例变红
- [x] 3.3 `check-scripts.sh` 十项全绿

## 4. 渲染

- [x] 4.1 日报 🚨 条目追加 `👤 <at id=…></at> · 模块（依据）`；周报 🚨 必修同
- [x] 4.2 `alert.sh` 失败卡片 @ 两端 `monitor_maintainer`
- [x] 4.3 周报覆盖率一行 + Android < 50% 时的建议（design D5）
- [x] 4.4 文档首屏同步（卡片与文档两处渲染点都要改——F35）

## 5. 验证（⛔ 部署前全部完成）

- [x] 5.1 生产 /tmp 影子跑（STATE 副本、local.env 指无效 ID、NO_DELIVER），取 card.json
- [x] 5.2 **实发私聊**（只发卡片，不走 deliver.sh），确认：`<at>` 渲染成人名、⛔ 被 @ 的人是否真收到通知（先只 @ 用户本人验证，再换真实负责人前须用户同意）
- [x] 5.3 用 10-14 ~ 10-21 每天的生产 🚨 回放归属结果，逐条人工核对模块是否对；错 @ 一条即回 1.2 收紧规则
- [x] 5.4 L2 同样影子跑 + 实发验证（⚠️ L2 DRY_RUN 会提升基线，先备份四个文件 + LEDGER.md）

## 6. 上线后监控（不是验证）

- [ ] 6.1 首周每天抽查 @ 是否落对人，收集被 @ 者反馈

## 实施记录（2026-10-21）

- 3.2 双向：去掉 scope / own / lib / screen 任一分支各有用例变红（scope 4 红、其余 2 红）；去掉 owner_enrich 的 bq 失败兜底 → ERR trap 命中（②红）
- 5.3 回放 10-12 ~ 10-21 生产 🚨 的 10 个 issue：首轮 `4ade82c7` / `ed3883b1` 按页面判成 webview——**错**（PAG GC 线程崩溃，页面是巧合），
  收紧为「THIRD_PARTY 帧不用页面」后 10 条全部人工核对无误：voice 3（`85c581ed` fix(ai)、`62f88f39` fix(tts)、`b307f98b` 腾讯口语评测 SDK）·
  dinoclass 1（`fb54dcb7` fix(classsdk)）· 兜底 6（PAG ×3、LINE、PAG iOS、libperfetto）
- ⚠️ 回放用的本地 bqq 桩把 SQL 当命令行参数传，`--` 开头的注释被 bq 当成 flag——**桩的问题，不是 SQL 的**；正式 bqq 走临时文件，复跑正常
- 5.1 / 5.4（10-21 14:53，生产 /tmp，STATE 副本 + local.env 指无效 ID）：L1 NO_DELIVER rc=0，🚨 2 条均 voice（修复 scope），卡片 / 文档两处渲染一致；
  L2 DRY_RUN rc=0，模型必修 6 项归属与 5.3 回放一致；覆盖率「iOS 0/3 台 · Android 5/12 台」+ 补埋点建议
- 5.2 实发私聊（@ 全部替换成用户本人）：日报卡 `om_x100b62b27fa478a0…`、告警卡各一张，读回 `<at>` 均被识别为提及；⚠️ 是否真收到通知待用户确认
- 5.4 周报卡同样实发私聊（`om_x100b62b27720d0ac…`，@ 替换成用户本人）：读回 6 条 👤 均被识别为提及，覆盖率行完整
- 5.2 用户 2026-10-21 确认收到 @ 通知（测试卡 @ 全部替换为用户本人；上线后按 owners.tsv 真实 @）
- 4.3 补：覆盖率建议加样本门槛（某端 < 10 台只给分数，用户 2026-10-21）；格式化移入纯函数 `owner_coverage_line`，⑭–⑯ 三条，去掉门槛 ⑭ 红
