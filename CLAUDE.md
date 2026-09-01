# CLAUDE.md

Dino（iOS + Android）崩溃 & 性能日报/周报流水线的**部署运行时仓库**——bash + `bq` + `jq` + Hermes cron，无应用代码、无构建、无测试框架，产出投递飞书群 `oc_655033f1f85fa04f9eac25d56f056fc9`。

两条独立链路（全表见 docs/CLAUDE-部署与运维.md，详规见 bin/INSTALL.md §0）：**L1 日报** `crash-daily.sh`（每天 07:00；高频数据呈现，不做分析；只统计最新 2 个版本）｜**L2 周报** `crash-weekly.sh`（周一 05:30；数据层零模型，分析层 `claude -p` 失败只降级；主力版本 = 近 7 天会话量 top2）。**两条链路都只读业务仓库，不 commit / 不 push / 不改业务代码。**

## 代码与状态分离

代码 `ROOT` = 本仓库 clone 目录（脚本自解析，不写死绝对路径）；运行数据 `STATE` = `${XDG_STATE_HOME:-~/.local/state}/crash-triage`。分离不是洁癖：`git clean -xfd` 连被忽略文件一起抹，`last-snapshot.json` 丢了会把所有 issue 报成新增。归档 `report-index.jsonl` 也在 `$STATE`（生产机推不了 git）。`REPOS_ROOT` 自动探测同级业务仓库。

## 常用命令

```bash
CRASH_REPORT_DRY_RUN=1 bash bin/crash-daily.sh      # 卡片预览后即 exit 0
CRASH_REPORT_NO_DELIVER=1 bash bin/crash-daily.sh   # 完整链路不投递（验索引页/manifest 用这个）
bash bin/setup.sh                # 装机/换机重探工具路径（换过 node/brew 位置必须重跑）
bash bin/install.sh              # 一键装机；更新用 bin/update.sh
bash bin/check-scripts.sh        # 改脚本后必跑（九项检查）
FACT_CACHE_BASELINE=<跑批前快照目录> bash bin/test/assert-fact-cache.sh
hermes cron list                 # 调度运维；改时间 edit / 停 pause
cat "$STATE/health-daily.json"   # L1 健康（L2 是 health.json）；日志在 $STATE/logs
```

没有单元测试。验收链：`check-scripts.sh` → DRY RUN → 抽查数值对 Firebase 控制台（INSTALL.md §6）。

## 硬约束（都是踩过的坑；完整解释见「按任务继续阅读」指向的 docs）

### 跑批与调试

- ⚠️ DRY_RUN 打完卡片预览就 exit 0，**跑不到 build_index / manifest**——验索引页用 NO_DELIVER
- ⚠️ **整跑要 5 分钟以上，别设短超时**——进程被信号杀掉会触发 ERR trap，把「被杀」当故障告警发进群
- ⚠️ `hermes cron run` 手工触发**总打印 `Ran now: failed`**，与成败无关——以 executions.db 与脚本日志为准
- ⚠️ 活数据上 diff 永远不为空——等价性验收用 `CRASH_REPORT_BQ_CACHE` 冻结数据，**生产禁用**
- ⚠️ L2 基线提升在 NO_DELIVER 闸门**之前**——「跑两次对比产物」在 L2 不成立，测试前先备份 `last-snapshot.json`
- ⛔ `check-scripts.sh` 是**九项**检查；⚠️ 必须**递归**扫 `bin/**/*.sh`（只扫顶层时 lib/test 完全不受检）
- ⛔ **顶层「先用后定」会被第 7 项拦下**——常量/函数定义晚于使用，报错常被 EXIT trap 吞成 0。⚠️ 函数级测试抽函数出来跑，**原理上看不见顺序**，只能靠静态检查
- ⚠️ **函数级测试必须跑在生产 shell 设置下**（`bin/test/harness.sh`）——夹具少了 `set -e` + ERR trap，「过程中踩了 ERR trap」这类问题测不出来（见 docs/CLAUDE-测试盲区.md）
- ⛔ 全角括号 / `·` 一律先条件赋值再拼接，**禁 `${var:+（...）}`**——bash 把全角字节并进变量名
- ⛔ prompt 与 bash 的重复（`FACT_CACHE_POLICY`）没有工具能检测，唯一检查是产物断言 `assert-fact-cache.sh`
- ⛔ 渲染层拆分与表名参数化是**刻意的 Non-goal**，不是遗漏
- ⛔ **跑批期间不得改 `bin/**`**——bash 按字节偏移边读边执行，改动会让运行中的进程从错位处继续读，报出与改动无关的错误（甚至不报错、执行拼接逻辑）。判据是「有没有进程在跑」不是「我改的是不是那个文件」
- ⛔ **终止跑批用 `kill -9`**：默认信号会被 ERR trap 捕获，发一张假故障告警卡
- ⛔ **失败必须非零退出**：四个脚本用完成哨兵（末尾 `RUN_COMPLETED=1`，trap 里没看到就 `exit 1`）。⚠️ bash 3.2 下 `set -u` 失败进 EXIT trap 时 `$?` **已经是 0**，保留 `$?` 的写法修不好；任何合法的提前 `exit 0` 都要先置位

### 跨进程边界（8 个子脚本：`export`+argv 进、文件+退出码出）

- ⚠️ **函数不跨进程**——核心层在每个子脚本里各自 source
- ⚠️ **普通赋值不跨进程，必须 `export`**（`REPOS_ROOT` 漏过：周报整跑失败、日报误判「超时」）
- ⚠️ **退出码是唯一失败信号**，「成功」判据必须两端一致——判据不一致是静默降级的温床

### 数据口径（改数字前必读 docs/CLAUDE-架构与数据口径.md，走 crash-metric-change skill）

- ⛔ `error_type` 三类（FATAL/ANR/NON_FATAL），**不要用 `is_fatal` 代替**——后两类会整体不可见
- ⚠️ NON_FATAL 必须取 `issue_subtitle`（iOS title 恒为 SDK 包装帧，零区分度）
- ⚠️ ANR 率与 Google Play「用户感知 ANR 率」**口径不同不可对照商店门槛**，报告必须标注；iOS 无 ANR 概念，渲染「— 无此概念」不留空不填 0
- ⚠️ `ANR_RATE_RED=0.47` 参考 Play 门槛但口径不同——宁严的锚，**不是对齐后的数值**
- ⛔ **用户率做不了**：`installation_uuid` 与 `instance_id` 两套 ID 体系，JOIN 匹配 0 行；⚠️「受影响安装/设备」近似只能看数量级
- ⚠️ crash-free **阈值方向相反**（越大越好）——用坏方向值判定、好方向值展示；不进摘要行
- ⚠️ 分母为 0 显示「无法计算」，**绝不能显示 100% 或 0**
- ⚠️ 新版刚放量时最新版比率**没有统计意义**——卡片两个 crash-free 并列（最新版 · 全版本）
- ⛔ **不设会话数门槛**（`MIN_SESSIONS` 已中和为 1）——门槛会静默剔除刚放量/被叫停的新版；⚠️ 残余风险刻意接受：1 个会话的内测包也会成为「最新版」
- ⛔ **性能段窗口只取完整日**（`LCD = DATE(DATA_UNTIL)−1`）——perf 表每天只灌到 06:59 UTC，**最后一个日历日恒为 7 小时残日**；DoD/WoW 两端都必须是完整日。⚠️ 07:00 跑时残日还没落地，`MAX(DATE(...))` 侥幸取中完整日，**单独把 cron 挪晚会激活这个 bug**（F33）
- ⛔ 完整性判据用「表里有 D+1 的事件 ⇒ D 已灌完」，**不查 `INFORMATION_SCHEMA.PARTITIONS`**——perf 表按摄取时间分区，partition_id 与事件日不是一回事
- **性能段分域选版**：性能段可多一列「性能兜底」（性能表里可得的最新版）；⛔ 崩溃/放量段口径不变，最新版照常出现；⛔ 判据只看有无性能数据，**不得掺会话量门槛**；⚠️ 回溯上限 4 个候选
- **缺数第 3 态细分**：「尚无数据（预计 X 到位）」vs「⚠️ 本轮未取到（上次有值 X）」。⛔ **判据必须显式判 `null`**，慢帧/冻结/错误率的 `0` 是合法值；⛔ **只给日期不给数值**——五个性能格子的口径与历史字段全都对不上；⚠️ 文案必须带日期
- ⚠️ 历史行带 `window_mode`（`legacy`/`complete_day`），**不回填不重算**；跨口径环比必须标注，切满 7 天自动消失
- ⚠️ 小样本由 `SAMPLE_SESSION_MIN` 打 ⚠️ **标出来而不是藏起来**
- ⚠️ **只有系统版本维度给率**——机型桶太小只给绝对数，且标注「未除以装机量」
- ⚠️ 缺数三态顺序不可颠倒：表未同步 → ⚠️ 数据未同步（探测**不带版本过滤**）→ 该版本无数据；崩溃段 0 次是结论、不进三态
- ⛔ `blame_frame.owner` 标识**责任帧归属**，不是「谁触发崩溃」——owner 与 library 必须一起给
- ⚠️ issue「上一轮」取 `issue_seen` **最大日期**不是「昨天」——漏跑一天会把全部 issue 误判回归
- ⚠️ 旧 `ios_ids`/`android_ids` 来自 MCP 且长期空数组——生命周期判定已不读
- ⚠️ **周报主力版本 = 窗口 top2 ∪ 当日 top1**（上限 3，逐行标入选理由）——累计量是滞后指标，发版周会选中正在退役的版本；⛔ 不掺会话量门槛；⚠️ 补入版本的会话/设备取窗口口径不混窗；⛔ 理由不进 `ADOPT_ROWS` 也不拼进版本列（会污染 WoW 匹配键）
- ⛔ **三份产物的 issue 条目一律带 8 位短 id，id 本身即控制台链接**——标题不是稳定标识（责任帧名 vs 人话名不可互推）。⚠️ 链接只进文档，聊天侧（群消息 / 卡片）用反引号纯短 id；⚠️ `CHANGES_MD` 有**三个**消费点，改前数清楚
- ⚠️ **周报段一的三态判定复用台账的 `issue-seen.json`**，⛔ 不新建第三份基准；⛔ 读取必须在基准提升之前（提升后判定恒为「长期」）
- ⚠️ **跨版本合计数必须给版本构成**（只在跨版本时出括注）；⚠️ `users` 跨版本不可相加，版本维度只给事件数
- ⛔ **issue 开关状态不可得**——导出 schema 只有 `issue_id`/`issue_title`/`issue_subtitle`；台账图例的「消失」⛔ 不等于已修复、更不等于已关闭
- ⛔ **首轮只建基线不标新增**
- ⛔ 更新事实层记录**不碰 `.source` 字段**（区分 bigquery 聚合与模型完整事件）
- ⛔ **灰度关联做不了**（`remote_config_feature_rollouts` 字段存在但恒空）——先查有没有值，别按「字段存在」推断可用
- ⛔ **汇总段不给根因**（与性能段「不出根因」同一条）；汇总段不进卡片；明细按受影响安装数排序
- ⛔ **bq 的 CSV 一律走 `csv2tsv`（bin/lib/csv.sh），禁 `awk -F,` / `cut -d,`**——Apple 机型标识符自带逗号（`iPad7,11`），裸切会把 1 个事件渲染成 11 且无告警
- ⛔ **SQL 占位符替换只走 `q_render`（bin/lib/query.sh）**，漏传当场失败并指名；⚠️ 共享层**不设窗口默认值**，漏传会静默用错窗口
- **前后台**取 `process_state`（双端同名同枚举）回落自埋 `app_foreground`；⚠️ 两端取值不同（Android `true/false`、iOS `1/0`），归一化表达式**全仓只此一处**（`SQL_FG_NORM`）。⛔ 只给绝对数——会话表无该字段，**前后台没有分母**
- **页面维度**取 `custom_keys.current_screen`，走无分母 SQL（`crash-dimensions-nodenom.sql`）。⛔ 永远不给率；⚠️ `(未知)` 照常成行不得丢弃；⚠️ 两份维度 SQL **列序不同**，渲染层不可共用列号
- ⚠️ **iOS 几乎没有 FATAL**（实测 60 天 5 事件 / 4 issue，同期非致命 1424）——iOS 侧维度与下钻**必须用 NON_FATAL 口径**，否则渲染出单行表，而「只有一行」与「iOS 很健康」在版面上一样
- **受影响用户数** `user.id` **仅 iOS 可得**（实测 iOS 96.6% / Android 0%）。Android 渲染「— 不上报」，⛔ 不是 0 也不是空；⛔ 与受影响安装**不可相加减**（实测前台子集 6 安装 / 7 用户）；⛔ 无用户率（会话表无用户标识）
- **复发率**由生命周期「🔁回归」态聚合，⛔ **给分数不给百分比**（基准仅十余项，百分比是伪精度）；基准未建立时说「本轮建立基准」，⛔ 不显示 0/0
- ⛔ **per-issue 的「top 机型」不是结论**——实测唯一机型数≈影响安装数（一设备一机型）。三分支：仅 1 台设备时明说判不了、真集中才点名、其余标「分散」

### 告警

- ⚠️ 小样本回退判据是 `adopt.sessions`（**1 天窗口**），不是崩溃段 7 天窗——看错窗口会把「会不会告警」判反
- ⛔ **回退必须在摘要行说明**——换了判定对象不说，比漏报更难排查
- ⛔ 不要说「首次纳入统计必然红档」——会不会红取决于判定对象是谁（由 1 天窗小样本回退决定）
- ⚠️ 缺分析必须在卡片可见（「⚠️ 本周无深度分析 — 原因」）——缺分析与无异常是两件事
- ⛔ **失败原因从日志读真实 API 错误码，不按退出码猜**（429 额度 / 529 过载 / 5xx / 4xx），识别不出时**明说识别不出**。⚠️ 写死「常见原因：额度耗尽」会把 529 说成额度问题，让人干等
- ⛔ **补救建议必须由产生原因的那个分支一并赋值**，不得在渲染处写死——否则会出现「原因：显式跳过」+「建议：等额度恢复」这种自相矛盾
- ⛔ **新增的检查/告警不得走触发 ERR trap 的路径**，且加完要**双向测试**（违规样本变红 + 全量代码不误报）。⚠️ `grep` 无匹配返回 1，放进 `set -e` 路径必须 `|| true`

### 卡片与文档

- ⚠️ 表格列名不能叫 `ios`/`android`（CardKit 平台变体键，**只有真发一张才炸**）——用 `c1`…`c4`
- ⚠️ 卡片单元格用短文案 `CELL_BREVITY=1`（如「⚠️ 停更」），完整文案留文档——长文案把列宽撑爆截断
- ⚠️ **卡片列宽只有真发一张才验得出**（DRY RUN 与 markdown 预览都验不出，盲区④）——单发 `$STATE/publish/card.json` 到开发机 `ou_` 私聊即可，不必重跑链路；⛔ 压缩时不得砍掉有记录的口径标注（样本量括注、两端窗口标注）
- ⚠️ 卡片表格的列集合有**两个定义点**（`build_card_table` 出 JSON、`md_table` 出预览与日报 md）——改一处会让**预览与实发不一致**（F35）
- ⚠️ `ROW_DEFS` 拆 CARD(6)/DOC(13)：显式 3 处 + 别名 3 处；⚠️ 改名时别名处**不报错只静默拿空集合**——拆共享常量前先 `grep -n` 数清调用点

### 投递、台账与部署

- ⚠️ **只能有一个调度器在跑**——launchd 与 Hermes cron 双跑会并发写坏 `docs.json`/归档
- ⚠️ open_id 按 app 隔离（跨 app 报 `99992361`）；群 `oc_` 是租户级
- ⚠️ **两台机器的 `docs.json` 指向同一份索引页与台账**——开发机投 `ou_` 时自动跳过归档/索引/台账同步
- ⚠️ `path.env` 是探测缓存不是配置（旧名 `config.env` 已废）；真配置写 `local.env`，人手写、脚本永不覆写
- 台账同步全程**不得 `overwrite`**；block ID 不可跨轮缓存——见 docs/CLAUDE-架构与数据口径.md「台账口径」

### 模型与环境

- **`--allowedTools` 禁止前缀通配，必须逐个列只读工具**——`mcp__firebase` 会放行写操作 `crashlytics_update_issue`，2026-08-06 误关过线上 issue
- **跨仓库 git 反查必须带 `--add-dir`**——否则被权限边界拦下、静默产出未验证的 null
- **L2 根因边界**：崩溃段可出但必须标「未经复核」并区分「✅钻取确认」与「⚠️聚合推断」；**性能段不出根因**；台账只收结论
- **`claude -p` 必须 `< /dev/null`**，`--mcp-config` 显式传
- **`repos/` 只 fetch 不 checkout / reset**（自动探测指向同级工作仓库）
- **`REPOS_ROOT` 必须 export**（子进程有自己的默认值）
- **`unset PYTHONPATH`**（两入口开头）——Hermes 注入的 3.12 包树让 bq/gcloud 导入即崩，报错文案误导为「重装 SDK」
- **超时用 `run_with_timeout`**，`set -e` 下 `|| RC=$?` 捕获 124 才走降级
- **L2 平稳周照常投递**——`send=false` 只由 DRY RUN 产生，与本周有无变化无关

### lark-cli（全文见 docs/CLAUDE-lark-cli勘误.md）

- profile 用 appId `cli_aaf7b44ddeb8de14`；`docs +fetch` 正文在 `.data.document.content`
- ⛔ 其值是 **DocxXML 文本不是块结构 JSON**——拿 block id 要解析 XML 标签，`jq` 找块永远落空
- `--content @绝对路径` 被拒（用 stdin）；source `deliver.sh` 片段会覆盖调用方 `ROOT`/`STATE`

## 规格与台账

OpenSpec 驱动（`openspec/`，schema `spec-driven`）。**动手改脚本前先看对应 change 的 design/tasks**——阈值、卡片结构、staleness 兜底都有记录的理由与取舍。台账由 **L2 独占产出**（change `crash-ledger-l2-ownership`），修复状态由反扫两个业务仓库的 commit message 驱动。⚠️ **两种形式都认**：`[crash:<8位id>]`（最初约定，实测两仓近 90 天各 0 条）与 `Crashlytics[ issue]: <32位id>`（**事实上正在用的**，Android 写在 subject、iOS 写在 body）。⛔ 「Android 无此约定故 `fix_commit` 恒 null」是**已订正的过期结论**——2026-09-01 改扫描器后反扫从 0 条变 6 条。⚠️ 仍要扫**整条 message 不是 subject**（两仓落点不同）。

## 按任务继续阅读

| 任务 | 读 |
| --- | --- |
| 改架构 / 数据口径 / 阈值 / 卡片 / 台账逻辑 | docs/CLAUDE-架构与数据口径.md |
| 改指标口径前的校验流程 | .claude/skills/crash-metric-change/ |
| 调试跑批、验产物（DRY_RUN / NO_DELIVER） | .claude/skills/crash-report-debug/ |
| 零行为重构的等价性验收 | .claude/skills/eqv-check/ |
| 脚本分层 / 消重 / 该不该拆 | docs/CLAUDE-分层与复用.md |
| 改动前扫一眼「哪些错会静默重犯」 | docs/CLAUDE-失效模式登记.md |
| 「我明明测过了为什么还炸」 | docs/CLAUDE-测试盲区.md |
| 部署、调度、装机换机、STATE 布局、check-scripts 九项 | docs/CLAUDE-部署与运维.md |
| 调 lark-cli / 排查同步失败 | docs/CLAUDE-lark-cli勘误.md |
| 部署生产机 / 跑批后核验 | .claude/skills/deploy-prod/ 与 morning-verify/ |
| 飞书固定资源（租户 / 文件夹 token / 固定 URL） | bin/INSTALL.md §12 |
| 设计/审计报告内容（模块 · 指标 · 维度 · 排版） | .claude/skills/crash-report-design/ 与 crash-report-analyst agent |
| 人工深度定位某个崩溃 | firebase-crash-triage skill |
