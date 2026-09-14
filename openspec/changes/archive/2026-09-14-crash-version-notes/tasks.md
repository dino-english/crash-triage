## 1. 注记源

- [x] 1.1 新增 `notes/version-notes.tsv`：`平台 <TAB> 版本 <TAB> 一句话`，`#` 开头为注释
- [x] 1.2 文件头写明与 `local.env` 的边界（D1）：这是**内容**不是机器配置，故进版本控制不进 `$STATE`
- [ ] 1.3 首条注记：iOS 修复 safeDecode 埋点误报导致非致命降约 90%。**卡在发版**——对外版本号未定，写不了；仓库里的 `notes/version-notes.tsv` 目前只有注释与被注释掉的示例，生产跑批走的是「无命中」路径（已由 4.3 验过）

## 2. 读取与命中

- [x] 2.1 解析函数定义在**调用点之前**（顶层「先用后定」会被 check-scripts 第 7 项拦下）
- [x] 2.2 命中当前报告的版本集；⚠️ L1 用最新 2 版、L2 用主力版本，两者不同是设计如此（D3）
- [x] 2.3 ⛔ 文件不存在 / 无命中静默跳过；`grep` 无匹配返回 1，`set -e` 下必须 `|| true`
- [x] 2.4 上限 3 条，超出截断并标注实际条数

## 3. 渲染

- [x] 3.1 卡片摘要区独立 markdown 元素（D2），⛔ 不进表格、不碰 `build_card_table` / `md_table`
- [x] 3.2 markdown 与文档 XML 同位置输出
- [x] 3.3 ⛔ 全角括号 / `·` 先条件赋值再拼接，禁 `${var:+（...）}`

## 4. 验收

- [x] 4.1 `bash bin/check-scripts.sh` 十项通过
- [x] 4.2 `CRASH_REPORT_NO_DELIVER=1` 跑 L1，验注记出现在卡片 JSON 与 md
- [x] 4.3 负向：注记文件删掉后照常产出（⚠️ 双向测试，只验有注记的情形等于没验兜底）
- [x] 4.4 ⚠️ 单发 `card-preview.json` 到开发机 `ou_` 私聊验版面——摘要区变长会不会挤掉表格
- [x] 4.5 L2 同样跑一次；⚠️ L2 的 DRY_RUN 会提升基线，测试前先备份 `last-snapshot.json`

## 5. 实测记录（2026-09-08）

- **函数下沉到 `bin/lib/card.sh`**：一度只写在 `crash-daily.sh` 里，`crash-weekly.sh` 是独立进程完全看不见——
  ⚠️ 正是本仓库硬约束「**函数不跨进程**」那条。若不是复核「跑 L2 能验证什么」，会以
  「L2 跑通、退出码 0、卡片无注记」结案，而那验的是一个不存在的功能。
- **版本集由调用方传入**（L1 传 `$IOS_COLS/$AND_COLS`，L2 传 `$IOS_TOP2_VERS/$AND_TOP2_VERS`）：
  参数化不只为复用，是让「用哪个版本集」的决定留在调用点、看得见。实测同一份注记文件下，
  日报命中 1.7.0、周报命中 1.5.4，D3 的行为已由产物证实。
- **check-scripts 抓到我自己踩的全角字节**：注释里写 `$AND_COLS）` 被第 N 项拦下，改 `${AND_COLS}` 后过。
  该检查对注释同样生效，是对的。
- **单发验版面**：周报卡 `om_x100b66c90eb718a4ee89719cf2ab662`、日报卡（两条注记堆叠 + 宽表）
  `om_x100b66c911a8c0a0eeb000a5791ebef`，版面确认可接受，40 字上限暂不调整。
  ⚠️ 首次发报 `99992361 open_id cross app`——lark-cli 默认 profile 与 `crash-triage` profile 是不同 app，
  必须带 `--profile crash-triage`。
