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

### 数据口径 → docs/CLAUDE-架构与数据口径.md

37 条口径规则**已全部下沉**到那份文档（2026-09-04，为压回 8,000 常驻预算；下沉前
逐条核过覆盖，三条只在这里有过的已原文搬入）。改数字、改查询、改渲染前必须读它——
走 `.claude/skills/crash-metric-change/`，它第 1 步就是强制读「数据口径 / 版本口径 /
阈值与告警」三节。

只留一条在这里，因为它咬的是**不改指标的人**：

- ⛔ **bq 的 CSV 一律走 `csv2tsv`（bin/lib/csv.sh），禁 `awk -F,` / `cut -d,`**——Apple 机型标识符自带逗号（`iPad7,11`），裸切会把 1 个事件渲染成 11 且无告警


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
