# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## 这是什么

Dino（iOS + Android）崩溃 & 性能日报/周报流水线的**部署运行时仓库**。没有应用代码、没有构建系统、没有测试框架——全部是 bash + `bq` + `jq` + Hermes cron，产出投递到飞书群 `oc_655033f1f85fa04f9eac25d56f056fc9`。

两条独立链路（详见 [bin/INSTALL.md](bin/INSTALL.md) §0）：

| | L1 日报 `crash-daily.sh` | L2 周报 `crash-weekly.sh` |
|---|---|---|
| 定时 | 每天 07:00（Hermes cron） | 每周一 05:30（Hermes cron） |
| 数据源 | BigQuery（crashlytics / sessions / performance） | BigQuery（`fetch-snapshot-bq.sh`）+ git 反查 |
| 用不用模型 | 否（`fetch-snapshot.sh` light 对照除外） | **数据层否**；仅分析层（`report.md` 根因/方案）用模型，失败只降级 |
| 职责 | **高频数据呈现**，不做分析、不碰结论 | **分析与结论沉淀** |
| 产出 | 群卡片 + 日报 + 索引页（**不含台账**，change `crash-ledger-l2-ownership`） | 周报文档 + 群卡片 + 索引页归档 + **台账同步** |
| 性能 | 日维度当期值 | 周维度趋势 + WoW（不出根因） |
| 版本口径 | **只统计最新 2 个版本**（按版本号），按版本分列 + 版本间对比 | **主力版本**（近 7 天会话量 top2） |

**两条链路都只读业务仓库，不 commit / 不 push / 不改业务代码。**

## 代码与状态分离

| | 路径 | 说明 |
|---|---|---|
| 代码 `ROOT` | 本仓库 clone 目录 | 脚本按自身位置解析（`bin/` 的上级），**不写死绝对路径**——clone 到哪都能跑 |
| 运行数据 `STATE` | `${XDG_STATE_HOME:-~/.local/state}/crash-triage` | logs / 快照 / 历史 / 每日报告 / `path.env` / `local.env` / 生成好的 plist |

```bash
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export CRASH_REPORT_ROOT="${CRASH_REPORT_ROOT:-$(dirname "$SELF_DIR")}"
STATE="${CRASH_REPORT_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/crash-triage}"
```

分开的理由不是洁癖：`git clean -xfd` / 重新 clone 会连同被忽略的文件一起抹掉，而 `last-snapshot.json` 丢了会把下周所有 issue 报成新增（2026-08-07 那类事故）。

**归档 `report-index.jsonl` 也在 `$STATE`**（2026-08-20 从仓库移出）。它存不可再生的飞书文档 URL，但「入 git」这个持久化手段在这里不成立——追加它的是无人值守的生产机，**那台机器推不了 git**（无凭证），条目只会躺在工作区：`git clean` 就全没、脏工作区卡住 `pull --ff-only`、两台机器必然分叉（三样都实测踩到）。仓库里那份留作历史存档，运行时不再写入。

`REPOS_ROOT` 同样自动探测：优先运行根的**同级目录**（业务仓库通常和本仓库并排 clone，只读 fetch），没有才用 `$ROOT/repos` 隔离 clone。

## 调度：Hermes cron（launchd 为备选）

**实际调度器是 Hermes cron**（`~/.hermes/cron/jobs.json`），两个 job 都是 `no_agent=true` + `script`：

| job | 调度 | 包装脚本 |
|---|---|---|
| `crash-daily` | `0 7 * * *` | `~/.hermes/scripts/crash-daily.sh` |
| `crash-weekly` | `30 5 * * 1` | `~/.hermes/scripts/crash-weekly.sh` |

包装脚本由 `bin/install.sh` 生成（写死 `ROOT` / `STATE` / `CHAT_ID` / `LARK_PROFILE` 后 exec 主脚本），**勿手改**——改配置重跑 `install.sh` / `update.sh`。`stdout` 重定向到 `/dev/null`：`--no-agent` 会把 stdout 原样投递，而卡片由脚本自己用 lark-cli 发。

**launchd plist 保留作弹性方案**（`bin/*.plist`，当前未装载）。必须是绝对路径，仓库里存的是带 `__ROOT__` / `__STATE__` 占位符的模板，由 `setup.sh` 按本机实际路径生成到 `$STATE/`——不手改、也不把带本机路径的脏文件写回仓库。

⚠️ **只能有一个调度器在跑**：launchd 与 Hermes cron 同时触发会双跑。卡片有幂等键不会重复，但**并发写 `docs.json` / 归档 JSONL 会互相覆盖**（脚本假设单写者）。装 plist 前先 `hermes cron pause`。

## 常用命令

```bash
# DRY RUN（投递目标由 local.env 定，不用传 CHAT_ID；ROOT 自动探测）
CRASH_REPORT_DRY_RUN=1 bash bin/crash-daily.sh
CRASH_REPORT_DRY_RUN=1 bash bin/crash-weekly.sh

# ⚠️ DRY_RUN 在打完卡片预览后就 exit 0，**跑不到 build_index / manifest**。
#    要验索引页或投递清单，用 NO_DELIVER（走完整链路，只是不投）：
CRASH_REPORT_NO_DELIVER=1 bash bin/crash-daily.sh

# ⚠️ 整跑要 5 分钟以上。别给它设短超时——进程被信号杀掉会触发 ERR trap，
#    把「被杀」当成故障告警发出去（2026-08-20 因 2 分钟超时误报进群）。

# 单条 SQL 手工验证（脚本用 sed 替换占位符再喂 bq）
sed -e "s|{{TABLE}}|dino-english-497507.firebase_performance.com_prime_dino_english_IOS|g" \
    -e "s|{{DAYS}}|3|g" -e 's|{{VERSIONS}}|"1.5.4"|g' \
    bin/sql/perf-screens.sql | bq query --use_legacy_sql=false --format=csv

# 装机 / 换机后重探工具路径（换过 node/brew 位置后必须重跑，否则 cron job 起不来）
bash bin/setup.sh

# 一键装机（探路径 + 授权自检 + 生成 wrapper + 注册 cron）／更新（拉代码 + 重探 + 自检）
bash bin/install.sh
bash bin/update.sh

# 改脚本后的唯一自动检查，写完立刻跑
bash bin/check-scripts.sh

# 事实层缓存的产物断言（prompt 类代码唯一可靠的测试形式）
FACT_CACHE_BASELINE=<跑批前的 issues 快照目录> bash bin/test/assert-fact-cache.sh

# 运维
hermes cron list                                # 两个 job 的调度 / 上次状态
hermes cron edit 92d0ff92e222 --schedule '0 7 * * *'   # 改时间（job id 见 list）
hermes cron pause <job_id>                      # 停掉
STATE="${XDG_STATE_HOME:-$HOME/.local/state}/crash-triage"
cat "$STATE/health-daily.json"                  # L1；L2 是 health.json
ls -t "$STATE/logs" | head                      # 日志保留 60 天
sqlite3 ~/.hermes/cron/executions.db \
  "SELECT job_id,status,claimed_at,finished_at FROM executions ORDER BY claimed_at DESC LIMIT 5;"
```

> ⚠️ `hermes cron run <id>` 手工触发**总是打印 `Ran now: failed`**，与实际成败无关——Hermes 后台派发路径只设 `executed=True` 却漏设 `execution_success`（`tools/cronjob_tools.py:1347` vs `hermes_cli/cron.py:476`）。**以 `executions.db` 的 status 和脚本日志为准**，别追这个假故障（2026-08-18 踩过）。

没有单元测试。验收链：`check-scripts.sh` → DRY RUN → 抽查 2–3 个数值与 Firebase 控制台对得上（[bin/INSTALL.md](bin/INSTALL.md) §6）。

⛔ `check-scripts.sh` 是**六项**检查（2026-08-23 起，change `crash-perf-functional-core`）：

1. `bash -n` 语法
2. **`$VAR` 紧邻多字节字符** —— 反复踩的那个坑（`"${miss:+（$miss）}"` 在 `set -u` 下报
   `miss?: unbound variable`，bash 把全角括号的字节并进了变量名）
3. `md2docx.py` 语法
4. **依赖方向 lint** —— `bin/lib/core/` 出现 `bq` / `lark-cli` / `$STATE` / `$ROOT` 即失败
5. **重复定义检测** —— 同名函数出现在两个及以上文件即失败（豁免清单以数据形式集中在脚本内）
6. **纯函数断言** —— `bin/test/run.sh`，39 条

外加可选的 ShellCheck（未安装则跳过，不影响退出码——生产机不该为开发期工具多一项装机步骤）。

⚠️ **必须递归扫描 `bin/**/*.sh`**。早先只扫 `bin/*.sh`，于是 `bin/lib/` 与 `bin/test/` 下的新代码
**完全不受任何检查**——实测第一个放进 `bin/test/` 的脚本就带着 `$SCRIPT（` 通过了自检、运行时才炸；
改递归后立刻抓出 6 处。

### 分层与依赖方向（2026-08-23，change `crash-perf-functional-core`）

采用 **Functional Core / Imperative Shell**，取 Clean Architecture 的依赖规则、不取 Ports & Adapters
（bash 无类型系统兜底，接口反转只有成本没有强制力）。

```
bin/lib/core/{format,verdict,version}.sh   纯函数：格式化 / 阈值判定 / 版本挑选
bin/lib/common.sh                          外壳层共享：step / alert_once / err_stack / on_err / fail
bin/lib.sh                                 编排辅助：run_with_timeout / cleanup_old_runs
bin/crash-{daily,weekly}.sh                编排（imperative shell）
```

- **核心层不依赖任何全局**，加载顺序任意，可在 `env -i` 空环境中直接调用——这是「可测」的操作性定义。
  依赖当前时刻的函数改为接收基准时刻作参数（`win_compact` / `win_full` / `stale_days` 首参是 epoch）。
- **核心层缺失时直接失败不退化**：`lib.sh` / `common.sh` 有回落分支，但阈值判定与格式化只有这一份实现，
  退化版本会**静默产出错误数字**，比直接失败危险得多。
- **依赖规则靠 grep lint 强制**（检查项 4）。bash 没有编译器，这是它在这门语言里唯一能落地的形式。
- ⛔ **渲染层拆分与表名参数化是刻意的 Non-goal**，不是遗漏：三种渲染共享 `cell()` / `delta_of()` 的判定，
  拆分需要逐段对照，与「零行为变更」的验收目标冲突；表名硬编码 16 处则属于投机抽象（12 个月内不接第三个 app）。

### 跨进程边界：8 个子脚本，一种形状

编排层（`crash-daily.sh` / `crash-weekly.sh`）与这 8 个脚本之间是**进程边界**，不是函数调用：

| 脚本 | 进 | 出 |
|---|---|---|
| `alert.sh` | argv | 飞书卡片 + 退出码 |
| `scan-fix-commits.sh` | argv（STATE / 两个仓库 / 天数） | `fixmap.json` + 退出码 |
| `fetch-snapshot-bq.sh` | `export` 环境变量 | `snapshot.json` / `issues/*.json` + 退出码 |
| `fetch-snapshot.sh` | argv + `export`（尤其 `REPOS_ROOT`） | `snapshot.json` / `report.md` / `issues/*.json` + 退出码 |
| `render-ledger.sh` | argv | 台账 markdown（stdout，`\x1e` 分段） |
| `split-fix-list.py` | stdin | stdout |
| `md2docx.py` | argv | DocxXML（stdout） |
| `deliver.sh` | argv（manifest 路径） | 飞书产物 + `docs.json` / 归档 JSONL |

**统一形状：`export` 环境变量 + argv 进，文件 + 退出码出。** 三条推论都踩过：

- ⚠️ **函数不跨进程**。核心层要在**每个**子脚本里各自 `.` 一次——`fetch-snapshot-bq.sh` 与
  `deliver.sh` 各有自己的加载行，不能指望编排层 export 函数（2026-08-23 加 `cache.sh` 时的约束）。
- ⚠️ **普通赋值不跨进程，必须 `export`**。`REPOS_ROOT` 漏 export 那次，子进程退回自己的默认值
  `$ROOT/repos`（不存在），周报整跑失败、日报被误判成「超时」。
- ⚠️ **退出码是唯一的失败信号**，所以「成功」的判据必须两端一致：`fetch-snapshot.sh` 曾出现
  退出码 1 但 `snapshot.json` 已写、`report.md` 没写，而下游判的是 `[ -s report.md ]`——
  判据不一致正是静默降级的温床（2026-08-23 已改成两端都要求产物齐全）。

产物清单集中登记在 [bin/test/artifacts.sh](bin/test/artifacts.sh)（三层：中间产物 / 投递产物 / 基准文件）。

⛔ **一处已知未修的重复**：`fetch-snapshot.sh` 的 `FACT_CACHE_POLICY` 用**自然语言在 prompt 里**
复述了 `fetch-snapshot-bq.sh` 的同一套事实层缓存策略。这是跨语言、跨执行模型的重复——
`check-scripts.sh` 的重复定义检测只扫 bash 函数，抓不到；模型那份也无法断言。
唯一的检查手段是对产物断言（`bin/test/assert-fact-cache.sh`）。统一它要改运行时行为，留作后续 change。

**等价性验收**（`bin/test/`）：三层产物 diff —— 中间产物（取数层）/ 投递产物（渲染层）/ 基准文件（状态写入）。
`baseline.sh` 走**快照回滚协议**：不还原则 L2 的基线提升会让第二次跑批看到零变化、`issues/` 缓存会从冷变热走不同分支。
⚠️ 活数据上 diff 永远不为空（滚动窗口锚在跑批时刻，实测 6 分钟内 sessions 就变），故用
`CRASH_REPORT_BQ_CACHE=<目录>` 按 SQL 哈希冻结数据——**生产禁用**。
⚠️ 该缓存只包住 `bqq`（L1 的助手），`crash-weekly.sh` 有 9 处直连 `bq query` 绕过它，
故 L2 目前只能做「数字盲比对」验结构。

## 架构要点

### 富文本：颜色必须走 DocxXML

飞书 **markdown 导入不支持颜色和高亮框**，要配色只能用 DocxXML（`docs +create` / `docs +update` 的默认格式）。

| 产物 | 渲染方式 |
|---|---|
| 日报 | `crash-daily.sh` 直接生成 XML（`build_report_xml`），复用卡片那套 `cell()` / `delta_of()` 的阈值判定，只把 `<font color=X>` 转成 `<span text-color="X">` |
| 台账 | `bin/render-ledger.sh` 生成 markdown → `bin/md2docx.py` 通用转换（结构照搬 + 状态词按语义上色 + 引用块转高亮框 + 表格斑马纹），由 L2 的 `sync_ledger()` 定点写入 |
| 索引 / 周报 | `bin/md2docx.py` 同款转换（2026-08-18 起四份产物配色统一） |

配色常量集中在 `crash-daily.sh` 顶部：`XC_HEAD`（表头蓝底）/ `XC_ZEBRA`（偶数行灰底）/ `XC_HILITE`（最新版列黄底）。

写 XML 时两条铁律：**结构标签不能转义、字段值必须转义**（把整行喂给转义函数会让 `<tr><td>` 变成字面文本，飞书渲染出一张空表）；**`<span>` 不能嵌套**（正则上色时要跳过已有标签内的文本）。

### 生成与投递分离，两段都无 LLM

`crash-daily.sh` / `crash-weekly.sh` 只算数据、产出 `$STATE/publish/manifest.json` + `card.json` + 待导入的 markdown；`bin/deliver.sh` 读 manifest，用 `lark-cli` 走完投递。脚本末尾串行调用 deliver，**投递失败不改变生成脚本的退出码**——数据已落盘，重跑 `deliver.sh` 补投即可。`CRASH_REPORT_NO_DELIVER=1` 只生成不投递。

L1 投递链路（顺序不能换）：导入日报 → 回填索引页的 `__DAILY_URL__` → 导入索引页 → 回填卡片的 `__DETAIL_URL__` / `__INDEX_URL__` → 发卡片。占位符必须在导入前填好：`drive +import` 只能新建不能覆盖。**台账不在 L1 链路里**（change `crash-ledger-l2-ownership`），索引页的台账入口是固定 URL 直链。

L2 的台账同步是 `deliver.sh` 里独立的 `sync_ledger()`，不走上面这条主链：按标题定位现状表 → `block_replace` 定点替换 → 时间线 `append` 追加。**全程不得 `overwrite`**，定位失败必须报错中止（退化成 overwrite 会连时间线历史一起重写）。首次同步目标文档还没有「Issue 现状表」标题时走 bootstrap：`append` 本地台账全文，旧内容原样保留在其上方，由人工核实后另行清理。

- **幂等靠 `--idempotency-key`**（值 = `run_id`），台账同步不需要它（`block_replace` 本身幂等）。这条链路以前交给 LLM agent 做，代价是「文档建了卡片没发」的重复投递且系统不自知——2026-08-18 换成确定性脚本。
- **陈旧 manifest 闸门**：`deliver.sh` 校验 `day` 必须等于今天。脚本失败时不会重写 manifest，照投就会把昨天的卡片当今天发。
- **同一位置的导入必须串行**，并发会撞 `232140101`/`232140100`/`233523001`。
- **文档组织**：`deliver.sh` 自动建 `Dino 崩溃 & 性能日/周报` 父目录 + `L1 日报` / `L2 周报` 子目录（按名字查、查不到才建，token 缓存在 `$STATE/folders.json`）。日报周报收进各自目录，索引与台账放父目录根部。
- **覆盖优先于新建**：建过的文档记在 `$STATE/docs.json`，下次直接 `docs +update --command overwrite`。索引 / 台账永久固定 URL；日报周报每天（每周）一份新的，但**同日重跑覆盖当天那份**（键 `daily-<日期>`）。优先级 `环境变量 DOC_*_ID > docs.json 自动记忆 > 新建`。**台账是例外**：固定 URL 但绝不 `overwrite`，走 `sync_ledger()` 的 block_replace + append。
- **清理挂在投递收尾**，不能挂在「新建」路径上——稳态下每天都是覆盖，新建路径根本不执行。
- **归档统一**：日报与周报都写 `$STATE/report-index.jsonl`，索引页据此渲染两张归档表。归档在**卡片发送成功之后**追加——归档的语义是「已投递」不是「已生成」。
- **自测模式不写正式产物**（2026-08-20 起）：`deliver.sh` 按 `CHAT_ID` 前缀判定，投群（`oc_`）才是正式投递；投私聊（`ou_`）时**跳过归档、索引页覆盖与台账同步**。起因是查实两台机器的 `docs.json` 指向**同一份**索引页与台账（`UPQNdbz…` / `Ttpwdhg…`），开发机跑一次就会覆盖群里那份索引页、并把测试结论写进正式台账。日报/周报文档本身照常建——它们按 `docs.json` 的日期键各机器各一份、互不干扰，而看到真实渲染效果正是自测的目的。今日条目次日才出现在归档表，当天的入口在页面顶部。

### L2 数据层与分析层分离（2026-08-20 起，design D12）

L2 拆两层，**数据不依赖模型**：

| 层 | 手段 | 额度挂了 |
|---|---|---|
| **数据** | `fetch-snapshot-bq.sh`（BigQuery 事件级）→ `snapshot.json` → 变化检测（jq）/ 反扫（git）/ 台账渲染（bash）/ 同步（lark-cli）/ 卡片 | **照跑** |
| **分析** | `fetch-snapshot.sh full`（`claude -p`）→ `report.md` 根因与方案 | 跳过，周报少一章 |

起因是两次实测事故：2026-08-19 18:21 与 08-20 09:30 的 Anthropic 429 让 `crash-weekly.sh` 在 `[ -s "$SNAP_NEW" ] || fail` 处整跑退出，**群里什么都收不到**——而那些数字本就躺在 BigQuery 里。

- **数据层用 `crash-issues-all.sql`，不是 L1 的 `crash-issues.sql`**：差别是**刻意不加版本过滤**。台账按 issue 跨版本追踪生命周期，加过滤会让「上一版修好、这版没复发」的 issue 从现状表凭空消失、时间线断档。L1 那份保持原样，零改动。
- **反扫提前到取数之前**：`scan-fix-commits.sh` 纯 git、不依赖快照，跑完直接把 `fix_commit` 填进 `snapshot.json`。
- **两端皆空 = 取数失败，必须非零退出**：把「bq 挂了」渲染成「本周零崩溃」是最坏的错误报告。
- **缺分析必须在卡片上看得见**：周报与卡片口径行都标「⚠️ 本周无深度分析 — <原因>；数据与台账不受影响」。缺分析与无异常是两件事，读混了比缺失本身更糟。
- **`CRASH_REPORT_SKIP_ANALYSIS=1`** 跳过分析层，用于验证降级路径（不必真等额度耗尽）。
- **缓存判定在 shell 不在 prompt**：文件存在性 + `events_count_last_seen` 比较，`CRASH_REPORT_FORCE_REFETCH=1` 强制重写。bq 路径写的文件标 `source:"bigquery"` 存聚合事实，与模型路径的完整事件数组互不覆盖。

### 版本口径（2026-08-18 起，change `crash-perf-latest-2-versions`）

日报**三段全部按版本过滤**，只统计最新 2 个版本，每个数字按版本分列，**不输出跨版本合计**。

- **版本清单唯一源 = `firebase_sessions` 活表**，按版本号 `sort -V` 取最新 N 个（不是会话量排序）。
- ⛔ **不设会话数门槛**（2026-08-22 起，`MIN_SESSIONS` 由 5 中和为 1，常量本身仍在 `crash-daily.sh:108`；`resolve_versions()` 还在替换 `{{MIN_SESSIONS}}`，但 `latest-versions.sql` 里已无该占位符，是一次空转替换。别与维度表的 `DIM_MIN_SESSIONS=200` 混淆，那个还在用）：门槛会把**刚开始放量或已被叫停的新版**
  静默剔除。实测 Android 1.5.4 停止上报后（1d 会话 1 个），「最新 2 版」自动滑到 1.5.3/1.5.1，
  **卡片上一个字都没说 1.5.4 存在过**——而放量被叫停正是最该看见的事。
  小样本改由 `SAMPLE_SESSION_MIN` 在单元格打「⚠️」**标出来而不是藏起来**。
  ⚠️ 残余风险（刻意接受）：版本号更高的内测/灰度包哪怕只有 1 个会话也会成为「最新版」占据报告——
  一个内测包出现在线上数据里本身就是要看见的事。各表「最新版本」并不一致（性能批量表滞后 ~2 天、crashlytics 新版常为空），各段各自解析必然错位。
- **主力版本补列**：会话量 top2 有版本不在最新 N 版内时追加「主力」列，列上限 4。两集合重合时（当前常态）卡片形态与不开此特性一致。
- **SQL 占位符 `{{VERSIONS}}` 只替换值**，`IN (...)` 谓词与字段路径写在各 SQL 文件里——perf 系是顶层 `app_display_version`，crashlytics/sessions 系是嵌套 `application.display_version`，**两套路径不可共用模板**。
- **周报走另一套版本口径**（会话量 top2 = 盘子里的大头），与日报互补，卡片/文档都显式标注不可混比。
- **`sessions-by-version.sql` 刻意不加版本过滤**（放量明细要回答「还剩多少旧版本」），版本解析请用 `latest-versions.sql`。

### 数据口径（改数字前必读）

- **三张表同步节奏不同，窗口也不同**：性能 `PERF_DAYS=3`（批量表滞后 ~2 天）、放量 `DAYS=1`（sessions REALTIME）、崩溃 `CRASH_DAYS=7`（对齐 MCP 默认 7 天窗）。
- **取数区间起止双写**（2026-08-18 起）：卡片与文档都标注每段的 `起 → 止`，双时区（`+08` 与 UTC）。
  - **起点 = 本次跑批时刻 − N 天**，因为所有滚动窗口 SQL 都是 `WHERE event_timestamp >= TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL {{DAYS}} DAY)`——下界锚在跑批时刻而非数据最新时刻，故由 shell 直接算出，**不额外查 BigQuery**。
  - **终点 = 各表 `MAX(event_timestamp)`**（L1 复用已有的 `table_max()`；L2 原本没有时间戳，新增 2 次查询）。
  - 两者之差 = 数据滞后，**缺口本身就是要看见的信息**（性能段常态显示只取到窗口第 1 天，这是正常的批量表滞后，不是故障）。
  - 措辞一律用「窗口起点」而非「数据自」：它是查询下界，不保证那一刻真有数据。
  - 版式：卡片用 `win_compact()`（一行双时区），文档用 `win_full()`（每个时刻都写两个时区）。**不假设「截至昨天」**。
- **崩溃率 = 事件数 / 会话数**。分母为 0 显示「无法计算」，不能显示 0。
- **Crash-free 会话率 = 1 − 崩溃会话数 / 会话数**（2026-08-22 起，与崩溃率并存互补：前者答「多少会话是干净的」，后者答「崩溃有多频繁」）。
  - 只计致命崩溃（ANR 与非致命各有自己的行）；同一会话崩多次只计一次。
  - **分子分母不做 JOIN**：实测 crashlytics 的 `firebase_session_id` 只有 **83.9%** 能在 sessions 表找到对应会话，
    JOIN 会让那 16% 的崩溃会话从分子里消失、**高估** crash-free——高估是最坏方向。不 JOIN 则失真变成**低估**，
    故本值是**下界估计**，真实值不低于所示数字（报告上必须标注）。
  - ⛔ **用户率做不了**：`crashlytics.installation_uuid`（64 字符十六进制）与 `sessions.instance_id`（22 字符 base64url）
    是两个 ID 体系，实测 JOIN 匹配 **0 行**。而 **Firebase 控制台首屏给的正是用户率**——
    两者数值不同（用户率通常更低），**报告必须标注不可直接对照**，否则读者必然拿会话率去对照控制台得出错误结论。
  - ⚠️ **阈值方向与其余指标相反**（越大越好）。`traffic_light()` 是「大于红线 → red」，直接套用会把 100% 判成红档
    且**不报错**，只会安静地把最健康的版本标红。实现上是**用坏方向值判定、好方向值展示**：
    判定传「崩溃会话率」与 `100 − 阈值`，展示 crash-free。
  - ⚠️ 分母为 0 时显示「无法计算（该版本窗口内无会话）」，**绝不能显示 100%**——零崩溃除以零会话不是「完全干净」。
  - **不进摘要行**：事件数 ≥ 崩溃会话数，故崩溃会话率恒 ≤ 事件率，**crash-free 红档必然已被崩溃率红档覆盖**，
    再报一行只是重复告警。
- ⛔ **`error_type` 有三类，不要用 `is_fatal` 代替**：`is_fatal = TRUE` 等价于 `error_type = 'FATAL'`；
  **ANR 与 NON_FATAL 的 `is_fatal` 都是 FALSE**，崩溃系 SQL 沿用致命过滤会让这两类**整体不可见**（2026-08-22 前一直如此）。
  实测近 14 天：Android FATAL 105 / ANR 93 / NON_FATAL 131；iOS FATAL 4 / **无 ANR 行** / NON_FATAL 1020。
  - **ANR 仅 Android**：iOS 系统层无此概念，数据源不产出该 `error_type`。iOS 的 ANR 位置必须渲染成
    「— 无此概念（见冻结率）」，**不能留空、不能填 0**——前者被读成「数据没取到」，后者被读成「iOS 没有卡死问题」。
  - **ANR 率 = ANR 事件 / 会话数**，与崩溃率同分母、内部可比。⚠️ **与 Google Play 的「用户感知 ANR 率」
    （日活用户分母）口径不同，不可直接对照商店门槛**——报告上必须标注，否则读者必然拿数字去对照 0.47% 得出错误结论。
  - **NON_FATAL 双端不可比**：由客户端主动上报（`recordError` / `recordException`），覆盖多少取决于埋了多少收口点。
  - ⚠️ **NON_FATAL 必须取 `issue_subtitle`**：iOS 的 title 恒为 Crashlytics SDK 包装帧
    （`FIRCLSNonFatalError.m …`），top issue 三条标题一模一样、零区分度；信息全在 subtitle。
    Android 两者互补（title=位置、subtitle=异常类型），故两列都出。
  - 崩溃次数 / 崩溃率 / 受影响安装三项**保持 FATAL 口径不变**（`metrics-history.jsonl` 按此积累 90 天，混入会让趋势断裂）。
- **两套口径不可混比**：滚动窗口展示值（`perf-*.sql` / `crash-rate.sql`）与天级单日值（`*-1d.sql`，字段带 `_1d`，供 DoD/WoW）显式分离存储在 `$STATE/metrics-history.jsonl`。
- 崩溃主源已从 MCP `topIssues`（只含 OPEN issue）迁到 BigQuery 事件级（含已关闭 issue）。`fetch-snapshot.sh` light 模式的 MCP 抓取现在只用于：首验期数值对照、索引页「跟踪中的 issue」、`fix_commit` 反查。见 change `crash-source-bigquery-migration`。
- **事实层缓存的计数是「窗口内取值」，不是单调量**（2026-08-22 修，change `crash-fact-cache-freshness`）：
  `crash-issues-all.sql` 的 events 是滚动窗口内的 `COUNT(*)`，老事件出窗即下降。
  - **抓取判定与记录更新必须拆开**：计数下降只意味着没有新事件 → 跳过抓取是对的；
    但观测字段（计数 / `latest_event` / `last_synced` / `window_days`）**每轮无条件刷新**。
    旧实现把两者挤在一个 if/else 里，导致 `latest_event` 冻结（台账「最近一次发生」停在历史峰值那天）、
    `last_synced` 冻结（正在被修好的 issue 看起来像「数据停更」，好消息读成故障）。
  - **`latest_event` 取 `max(已存, 本次)`**：窗口内的 `MAX(event_timestamp)` **同样非单调**——
    最新那条出窗后剩余事件的 MAX 会更早。只做无条件覆盖会把「冻结」换成更糟的「倒退」。
  - ⛔ **更新时不碰 `.source`**：该字段区分「只有聚合事实」（bigquery）与「有完整事件数组」（模型路径），
    由创建者写死；改写会把模型路径记录的来源标签抹掉（实测踩过，7 条被覆盖后从备份还原）。
  - **落盘后必须校验是合法 JSON**（2026-08-23 补，提交 `1a04aa2`）：这些文件由模型用 Write 工具
    **直接写盘**，shell 侧没有写入点可校验。实测 2026-08-21 07:06 那批 20 个文件有 **12 个非法**
    （breadcrumbs 数组后多一个 `]`）。事实层「一次抓永久留、不参与清理」，坏文件**不会自愈**：
    此后每轮的每个下游都在 `jq: parse error` 上静默降级——反扫整个失败、台账「处置状态」列停更，
    而退出码是 0、卡片上一个字都没提。现在 `fetch-snapshot.sh` 在 `claude -p` 返回后扫一遍，
    非法文件隔离到 `$STATE/backup/corrupt-issues-<TS>/`（隔离不删除：它是模型行为的物证；
    隔离后下轮判定为「文件不存在」自动重抓）。`bin/test/assert-fact-cache.sh` 的断言链最前面
    也加了合法性检查——**合法性必须先于语义**，否则解析失败时 jq 返回空串、断言静默全过。
  - **prompt 侧策略是单一变量 `FACT_CACHE_POLICY`**，两处 heredoc 插值引用——
    **消除重复而不是检测重复**。prompt 没有语法检查、改漏一份不报错；
    而 prompt 的唯一可靠检查是**对产物的断言**：`bash bin/test/assert-fact-cache.sh`。
- **Android `fix_commit` 恒为 null**——Android 未采用「提交信息带 Crashlytics issue ID」约定，必须渲染成 `—` 而不是「未修」（后者得出错误结论）。

### 缺数三态（顺序不可颠倒）

1. `table_exists()` 为假 → `表未同步`
2. 表存在但 `table_max()`（**不带版本过滤**）为空 → `⚠️ 数据未同步`
3. 表有数据但该版本 0 行 → `— 该版本无数据`

第 2 步必须用不带版本过滤的探测，否则新版尚未产生数据会天天误报成数据源故障。**崩溃段例外**：有会话就有分母，`0 类 0 次` 是「这版没崩过」的结论本身，走 `crash_state()` 不进第 3 态。

### 表缺失 / 数据未同步的处理约定

`table_exists()` 只把 bq 明确返回的 `not found` 当作「不存在」，429/5xx/超时有界重试 3 次后**按「存在」处理**，让后续查询自行失败并触发「数据未同步」告警——不能误回退到已停更的批量表。注意 `bq show` 要 `project:dataset.table`（冒号），查询里是全点号；且 `Not found` 写在 stdout 不是 stderr。

sessions 优先 REALTIME 活表，缺失才回退批量表并在卡片上显式标注（批量表 2026-08-11 起停更）。

### 阈值与告警

红/黄/绿阈值集中在 `crash-daily.sh` 顶部常量（`CRASH_RATE_RED` 等）；判定统一走 `traffic_light()`，红档进 `red_line()` → `ALERTS` → 卡片 header 变红，黄档只进摘要不告警。空值 / 「无法计算」不判定，避免误告警。

**告警判定版本**：默认最新版；**最新版会话数低于 `SAMPLE_SESSION_MIN`(30) 时回退为该端会话量最大的版本**
（2026-08-22 起，change `crash-alert-sample-fallback`）。上一版与主力补充列平时只着色不告警（既定事实拦不了发版）。

- **为什么加回退**：固定判定最新版的前提是「最新版代表线上」。新版刚放量时这个前提不成立，
  于是**同一条规则同时制造漏报与误报**——实测同一次跑批：Android 1.5.4（1 个会话）的
  `崩溃率 8.33%(3/36)` 触发红档误报，而 6600 个会话的 1.5.3 真实超标的 `ANR 0.71%` 却沉默。
- **回退只影响告警与摘要行的判定对象，不改表格呈现**——各版本列一列不少。
- ⛔ **回退必须在摘要行说明**：换了判定对象却不说，比漏报更难排查（数字对得上、版本对不上）。
  读者看到的是「最新版是 1.5.4，为什么在报 1.5.3」，必须当场解释。
- ⚠️ **判据是 `adopt.sessions`，即 `DAYS=1` 的会话数，不是崩溃段那个 7 天窗口**——
  赋值链：`DAYS=1`(:96) → `resolve_versions()`(:504) → `AND_VER_CSV`(:511) → `collect_window` 第 8 参 → `vsess`(:608) → `adopt.sessions`(:629) → `alert_ver()`(:784)。
  两个窗口会给出相反结论：实测 2026-08-23，Android 1.5.4 的 **7 天**会话 46（≥30 → 不回退，判定它自己、ANR 0.00% 绿档），
  而 **1 天**会话只有 10（<30 → 回退到 1.5.3、ANR 0.693% 红档）。**看错窗口就会把「会不会告警」判反。**
- 判据统一用**会话数**，作用于全部 6 项告警指标。性能指标的真实样本量是 trace/screen 样本数而非会话数，
  但两者同向，且性能指标已有自身的「样本不足 → 空值 → 不告警」保护。
- `SAMPLE_SESSION_MIN` 已改为可配（`CRASH_REPORT_SAMPLE_SESSION_MIN`）——调低它即可验证稳态等价性。

`ANR_RATE_RED=0.47` / `ANR_RATE_YELLOW=0.24`：⚠️ **0.47 参考 Google Play 的 Bad Behaviour 门槛，但口径不同**
（Play 用日活用户分母的「用户感知 ANR 率」，我们用 ANR 事件 / 会话数）。取此值只因没有更好的锚且宁可偏严，
**不是对齐后的数值**。

⛔ **不要说「首次纳入统计必然红档」**——会不会红取决于**判定对象是谁**，而那由上面那条 1 天窗口的
小样本回退决定。2026-08-23 实测：

| 版本 | 本口径 事件/会话 | ≈Play 口径 受影响安装/设备 |
|---|---|---|
| 1.5.4（最新，判定对象） | **0.000%** 🟢 0/46 | 0.000% 🟢 0/30 |
| 1.5.3 | 0.693% 🔴 49/7068 | **0.884%** 🔴 36/4071 |
| 1.5.1 | 1.011% 🔴 10/989 | 1.125% 🔴 7/622 |

最新版 ANR 为 0，只因它 1 天会话 10 个 < 30 才回退到 1.5.3 而报红；放量涨过 30 就不红了。

但**红是真的，不是分母选错造成的假象**：换成更接近 Play 的「受影响安装 / 设备数」口径，1.5.3 从
0.693% 涨到 **0.884%**——设备数远小于会话数，而受影响安装与事件数接近。所以
**调阈值或换分母都不能让它合理地不红**。
⚠️ 该近似有硬伤：`installation_uuid` 与 `instance_id` 是两套 ID 体系（实测 JOIN 匹配 0 行），
跨 ID 空间相除只能看数量级；Play 的真实口径还更窄（只算「用户感知」ANR、28 天 DAU 分母）。

唯一合理的「不红」做法是**首轮只着色不告警**（表格照常红字，`ALERTS` 里不加 ANR），人工确认一轮
后再启用——理由是运营（避免无人值守时被当成流水线故障排查），不是数据。等价做法是**挑有人在场的
时段上线**，二选一即可。

### 摘要行（卡片顶部的 🔴 / 🟡 行）

摘要行由 `red_line()` / `yellow_line()` 生成，**必须标版本、且区分「没超阈值」与「没算出来」**：

- **有值的端**渲染成 `iOS 1.5.4 425ms`——不标版本会被读成两端同口径，而两端最新版常常不是同一个版本号（Android 线上没有 1.5.2，序列是 `1.5.3 → 1.5.1`）。
- **无值的端**降级成末尾括注 `（iOS 1.5.4 无数据）`，不占主位。表格里的缺数三态（样本不足 / 该版本无数据 / 表未同步）压进摘要行只剩一个「—」，看起来像故障。
- **没有数据不告警**：两端都无值时整行不输出。旧实现会打出 `🔴 指标 iOS — · Android —`——零数据却在报警。
- **单端指标走 `red_line_one()` / `yellow_line_one()`**：ANR 只有 Android 有，走双端的 `red_line()` 会渲染出
  「（iOS 1.5.4 无数据）」——而「无数据」的语义是「该取到却没取到」，与「这类事件不存在」是两回事，
  混用会误导。**不给 iOS 补任何占位值，连括注都不要**。

典型形态（2026-08-18 实测，新版 1.5.4 刚放量、性能表仅 199 行样本不足）：

```
🔴 慢帧最差页 Android 1.5.3 94.6%（iOS 1.5.4 无数据）
🔴 启动 P95 iOS 1.5.4 425ms · Android 1.5.3 4363ms
```

⛔ 全角括号与 `·` 分隔符一律先条件赋值再拼接，不要写成 `${var:+（...）}`（见上方 `check-scripts.sh` 第二项）。

### 卡片的能力边界

CardKit v2 的 `table` 组件字段只有 `rows` / `page_size` / `row_height` / `row_max_height` / `freeze_first_column` / `header_style` / `margin`。**`header_style` 只作用于表头**（`background_style` 仅 `grey|none`），**行级与单元格级都没有背景色**。单元格是 `lark_md`，只有 `<font color=>`（文字色），没有底色语法。

所以**斑马纹是文档独有能力**（DocxXML 的 `<td background-color>`），卡片对齐不了；卡片能与文档一致的只有文字颜色（同一套 `traffic_light()` 判定）。

### 报告结构：汇总 / 版本对照 / 明细

日报文档四章：**一、汇总**（2026-08-22 起，原「一、结论」升级）/ 二、版本对照 / 三、明细 / 四、环比与口径。

汇总段**只回答三个问题**，多一个都不加——它的价值来自能被一眼读完，加满会退化成数据倾倒：

1. **影响多少人** —— 受影响安装数 + **集中度**（事件 / 受影响安装）。9 次崩溃影响 1 台设备（集中度 9.0）
   与 14 次影响 7 台（2.0）严重度完全不同，而只看事件数两者长得一样。
2. **集中在哪** —— **三张表**（机型 / 系统版本 / 归因），列 = 平台|版本|取值|事件|影响安装|集中度[|崩溃率]。
   - **用表不用项目符号**：内容本来就是表格数据，列对齐才能横向比较（实测 Android 14 的 2.89%
     vs 16 的 0.66%，散在项目符号里看不出来）；且文档其余段都是带斑马纹的彩色表，
     裸 `<p>` 段落在视觉上不统一。XML 侧复用 `xml_csv_table`。
   - 平台与版本各占一列，重复行不碍事——**表格里不需要「两版一致就合并」那套压缩**，
     那是项目符号形态为了少写小标题才需要的。
   - ⚠️ **只有系统版本维度给率**：实测系统版本桶大（2657 / 1221 / 715 会话）率可靠；
     **机型桶太小**（最大 75 会话），门槛设 50 只剩 1 行、设 100 一行不剩——机型只给绝对数，
     且必须标注「未除以装机量，不代表该机型更易崩」。
   - 加分母确实会反转结论：Android 16 事件数最多（16 次）但率只有 **0.60%**（2657 会话），
     而 Android 14 是 **3.22%**（715 会话）。只看绝对数会把最健康的版本当成头号问题。
3. **什么时候** —— 峰值时段 + 聚集提示，**两者必须分开**。峰值是常态分布的描述（作息高峰），
   聚集才是异常信号（一次发版 / 配置推送 / 后端异常）；合并会让常态被读成事故。
   - 聚集判定用「最密集绝对小时桶 vs 均匀期望」的粗糙比较，**不做统计检验**——
     样本量在两百上下，任何显著性检验都会给出不可靠结论。

⛔ **汇总段不给根因**：维度聚合只显示相关性，与性能段「不出根因」是同一条硬约束。
**汇总段不进卡片**（已拍板），卡片经详情链接指向文档。

**issue 明细按受影响安装数排序，不按事件数**——排在第一位的会被当成最该修的，排序口径直接改变读者行为。

### 归因 / 生命周期 / 两个 crash-free（2026-08-22，change `crash-actionable-signals`）

- **归因**（`blame_frame.owner` + `.library`）：`DEVELOPER`/`THIRD_PARTY`/`SYSTEM` → 自家 / 三方 / 系统。
  ⛔ **owner 标识的是崩溃栈中被判定为责任帧的那一帧属于谁，不是「谁触发了这次崩溃」**。
  实测最有信息量的一行是 `SYSTEM · com.prime.dino.english · 30 事件 / 18 人`——**归因方是系统、
  库却是自家包名**，那是系统帧被自家代码调用。**owner 与 library 必须一起给**，
  任一列单独看都会得出错误结论；且不得表述为「非自家问题」。
- **issue 生命周期**（`🆕新增` / `🔁回归` / `长期`）：基准是 `daily-snapshot.json` 的
  `issue_seen: {"<id>": "<末次出现日期>"}`，保留 90 天，**数据源是 BigQuery issue id**。
  - ⚠️ 旧的 `ios_ids`/`android_ids` 来自 MCP 且**长期为空数组**——L1 的新增判定原本是死的，本次一并修复。
  - ⚠️ **「上一轮」取基准里的最大日期，不是「昨天」**：跑批漏跑一天时，按「昨天」判定会把所有 issue 误判成回归。
  - ⛔ **首轮只建基线不标新增**（无 `issue_seen` 键时）——首轮刷一屏「新增」与该词要传达的信息相反。
- **卡片两个 crash-free 并列**：`94.29%(1.5.4) · 99.29%（全版本）`。前者答「新版发得怎么样」，
  后者答「整体健不健康」，也才是与 Firebase 控制台数量级可对照的那个。
  ⚠️ 新版刚放量时最新版比率基于个位数会话，**没有统计意义**——只给它会让读者把小样本值当作整体健康。
- ⛔ **灰度关联做不了**：实测近 30 天 201 个崩溃事件中 `remote_config_feature_rollouts`
  **一条都没有**（字段存在但恒空）。要用它得先确认客户端是否在用 Remote Config rollouts 并正确上报。
  ——**不要基于「字段存在」推断可用，先查有没有值。**

### 卡片：单表、列 = 平台 × 版本（2026-08-22 定稿）

卡片是**一张** CardKit v2 表：**列 = 指标 | iOS 最新 | iOS 上版 | Android 最新 | Android 上版**，
行 = 6 项简报指标。手机端实测通过。

- **为什么不是「列 = 平台、版本挤在格内」**：那种排法**只显示最新版的值**，主力版本要从 delta 反推。
  而新版刚放量时最新版样本极小（实测 Android 1.5.4 只有 1 个会话），于是卡片上唯一可见的数字
  全是没有统计意义的那个——`Android 1.5.3: 49 次 ANR 0.71%` 这种真正要看的数字**完全不出现**。
  **版面选择直接决定了哪些数字存在。**
- **为什么不是「每端一张表」**：那让行数天然翻倍（N 个指标 = 2N 行），加上 ANR / 非致命 / crash-free
  后合计 26 行，群里要滑很久。
- **表头只放「平台 版本」**：表头是整张表最吃宽度的地方，挂上 `(1229/888)` 会被 CardKit 截断成
  `(1236/...`（实测）。放量规模与全版本 crash-free 放到表下的 markdown 行。
- **对比不占列**：四个版本并排，变化横向读得出来。`delta_cell` 的「箭头跟数值方向、颜色跟好坏」
  规则只在文档的版本对照表里用。
- ⚠️ **列名不能叫 `ios` / `android`**：CardKit v2 把它们当成**元素的平台变体键**
  （`ios`/`android`/`pc`/`harmony`），会把数据行解析成平台变体对象并报
  `table rows name is invalid; invalid name:harmony`。用 `c1`…`c4`。
  **这个错 `jq empty` 与结构检查都发现不了，只有真发一张才炸。**
- ⚠️ **卡片单元格必须用短文案**（`CELL_BREVITY=1`）：性能停更时
  「⚠️ 数据未同步（截至 2026-08-18 06:59 UTC）」会在 8 个格子里各重复一遍，把列宽整个撑爆——
  实测桌面端就截断成「⚠️ 数据未同步（截至...」，信息量归零。而**截止时刻在卡片顶部的摘要行里
  已经说过了**。卡片用「⚠️ 停更」，文档保留完整文案。

⚠️ **`ROW_DEFS` 必须拆成 `ROW_DEFS_CARD`（6 行）与 `ROW_DEFS_DOC`（13 行）**，
**显式指定的只有 3 处**，另有 3 处走兼容别名 `ROW_DEFS="$ROW_DEFS_DOC"`（:1066）——
拆常量前按这张表核对（2026-08-23 实测行号）：

| 行 | 函数 | 用的变量 |
|---|---|---|
| 1103 | `build_card_table()` | `ROW_DEFS_CARD` |
| 1306 | `md_table()` | `ROW_DEFS_CARD` |
| 1281 | `md_table_doc()` | `ROW_DEFS_DOC` |
| 1206 | `build_table()` | `$ROW_DEFS`（别名 → DOC） |
| 1400 | `verdict_line()` | `$ROW_DEFS`（别名 → DOC，结论行要评估全部指标） |
| 1576 | `xml_table()` | `$ROW_DEFS`（别名 → DOC） |

⚠️ 别名那 3 处**不会因为改 `ROW_DEFS_DOC` 的名字而报错**，只会静默拿到空集合。
`crash-daily.sh:1270` 的注释写着「三个调用点」，指的是显式那 3 处，别当成全部。
**这里踩过**：第一次实施漏了 markdown 文档那条路径，文档的「二、版本对照」段被卡片形态覆盖成 6 行。
**卡片敢砍到 6 行的前提正是文档保持完备**——拆共享常量前先 `grep -n` 数清调用点。

同版本 DoD/WoW 只进日报文档，不进卡片。**汇总段也不进卡片**，经详情链接指向文档。

### 运行数据布局（`$STATE/`，均不入库）

```
$STATE/                          # ${XDG_STATE_HOME:-~/.local/state}/crash-triage
├── issues/<32位id>.json         事实层：崩溃事件详情，一次抓永久留，不参与清理
├── ledger/LEDGER.md             台账本地源（L2 产出，同步飞书）
│   └── snapshots/               历史专项快照 md（从仓库移入）
├── runs/<日期>/{L1,L2}/<时刻>/  跑批产物（物证），保留 30 天，附 latest 软链
├── reports/<日期>-{daily,weekly}.md  报告 markdown 本地副本，保留 90 天
├── backup/                      台账等不可再生内容的**手工**备份，无写入者也不自动清理
├── logs/                        保留 60 天，**整目录按 mtime 清**（含 bq-stderr-<TS>.log）
├── publish/                     每次运行 rm -rf 重建的投递目录
├── path.env                     setup.sh 探测生成（只有 PATH），install.sh / update.sh 每次覆写
├── local.env                    机器本地配置（CRASH_REPORT_CHAT_ID），**人手写，脚本永不覆写**
└── *.json                       基准文件，**保持顶层不动**（见下表）
```

三条约定（都是踩过的坑）：

- **顶层只放基准文件**，跑批中间产物一律落 `runs/<日期>/L1/<时刻>/`。`index-render.md` 的路径要交给 `deliver.sh`，而 `publish/` 下次跑批即被 `rm -rf`，放 `runs/` 补投时才找得到。基准文件不进子目录是因为丢失后果严重（`docs.json` 丢 → 新建整套重复飞书文档；`last-snapshot.json` 丢 → 全部 issue 报成新增），保持原位 = 零迁移风险。
- **清理不能按文件名前缀分网**：L1 只删 `daily-*.log`、L2 只删 `weekly-*.log`，`bq-stderr-*.log` 从两张网中间漏过去永不清理。现按 `find "$STATE/logs" -type f -mtime +60` 整目录清。同理 L2 那条 `snapshot-*.json` 遗留清理必须带 `-maxdepth 1`，否则递归进 `runs/` 与 `backup/`。
- ⚠️ **`path.env` 是新名**（旧 `config.env`——它是探测结果缓存不是配置，叫 config 会诱导人把真配置写进去然后被覆写）。读取端的 `config.env` 回落分支**已于 2026-08-21 全部移除**（提交 `93bbb72`），现在只剩 `setup.sh:48` 的 `rm -f "$STATE/config.env"` 清理旧文件。

| 文件 | 作用 |
|---|---|
| `daily-snapshot.json` | issue 生命周期判定基准 + 当日版本集回溯。核心键是 `issue_seen: {"<32位id>": "<末次出现日期>"}`，**数据源是 BigQuery issue id**，随 `HISTORY_KEEP`(90 天) 滚动清理（末次出现早于保留期起点即丢弃）。⚠️ 同文件里的 `ios_ids` / `android_ids` 来自 MCP 且**长期为空数组**，是迁移前的遗留字段，生命周期判定已不读它们。⚠️ 判「上一轮」取 `issue_seen` 里的**最大日期**而非「昨天」——漏跑一天时按「昨天」会把所有 issue 误判成回归。基准为空时**只建基线不标新增**。 |
| `metrics-history.jsonl` | 天级单日值滚动 **90 天**（`HISTORY_KEEP`，**按版本存储**）；无 `versions` 键的旧口径行读取时自动丢弃并提示 |
| `perf-history.jsonl` | L2 性能周维度趋势，滚动 **12 周**（`PERF_HISTORY_KEEP`，约一季度）；WoW 对比的基准 |
| `docs.json` | 文档台账：决定覆盖还是新建。带日期后缀的键保留 90 天（`DOC_KEEP_DAYS`），`index` / `ledger` 无日期后缀、永不清理 |
| `folders.json` | 目录 token 缓存，按 profile 隔离 |
| `report-index.jsonl` | 历次日报/周报的飞书文档 URL，索引页据此渲染归档表；**不可再生**（飞书端无法枚举本 bot 文档），2026-08-20 从仓库移入 |
| `last-snapshot.json` | L2 变化检测基准；**首跑无基准时只建基线不报新增**（否则刷一屏「新增」）。⚠️ **提升在 `NO_DELIVER` 闸门之前**（`crash-weekly.sh:624`），所以「跑两次对比产物」这个验收方法在 L2 上不成立——第二次会看到零变化。测试前先备份它 |
| `health-daily.json` / `health.json` | L1 / L2 的健康状态 |

旧口径周报归档 `ledger/weekly-index.jsonl` 由 `build_index()` 读时与 `report-index.jsonl` 合并，避免历史断链。

**归档的异地备份靠人工**，不在关键路径上——想留一份进 git 就手工拷回仓库提交：

```bash
scp dino911@dino911s-mac-mini:.local/state/crash-triage/report-index.jsonl reports/
```

生产机推不了 git，所以不能指望它自己备份；这条命令在有凭证的机器上跑。

## 部署实例：飞书侧固定资源

租户 / 应用 ID、文件夹 token、固定文档 URL、scope 现状、不要删的历史文档、`docs.json` /
`folders.json` 的键格式——**这些是这套部署独有的查阅型事实，不是代码**，已移到
[bin/INSTALL.md §12](bin/INSTALL.md)。运行时它们缓存在 `$STATE/docs.json` 与
`$STATE/folders.json`（机器本地、不入库），INSTALL.md 那份是缓存丢失 / 换机器时的兜底。

改代码时只需记住三条：

- ⚠️ **open_id 按 app 隔离**，跨 app 用报 `99992361`。群 ID（`oc_`）是租户级的，不受影响。
- ⚠️ **两台机器的 `docs.json` 指向同一份索引页与台账**，所以开发机跑一次就会覆盖群里那份。
  `deliver.sh` 据此设了自测闸门：投 `ou_` 时跳过归档 / 索引页 / 台账同步。
- **投递目标由机器决定，不由命令决定。** 每台机器在 `$STATE/local.env` 写自己的
  `CRASH_REPORT_CHAT_ID`（开发机 `ou_` 私聊，**只有生产机填 `oc_` 群**）。该文件人手写、
  脚本永不覆写；加载点在三个入口**解析 `CHAT_ID` 之前**，普通赋值会盖掉命令行传入的同名
  环境变量——所以 `CRASH_REPORT_CHAT_ID=oc_… bash bin/crash-daily.sh` 在开发机上仍只发私聊。
  `deliver.sh` 另用它压过 manifest 里的 `chat_id`（不一致时打印一行），挡住拿别处的 manifest
  在本机补投。样例见 [bin/local.env.example](bin/local.env.example)。起因是 2026-08-20 一次测试
  命令行直接写了正式群 ID。

## 硬约束（都是踩过的坑）

- **`--allowedTools` 禁止前缀通配**：写 `"mcp__firebase"` 会放行写操作 `crashlytics_update_issue`，2026-08-06 已因此误关线上 issue（事故记录见 `$STATE/ledger/LEDGER.md`）。必须逐个列只读工具。
- **跨仓库 git 反查必须带 `--add-dir`**，否则被权限边界拦下、静默产出未验证的 `null`。prompt 里已要求「不得让 null 冒充查过没有」。
- **L2 的根因与方案边界**：`full` 模式的 `report.md` 确实会出根因与方案（七章 226 行，含风险分级与钻取确认）。边界是：
  - **崩溃段**：可出根因与方案，但**必须标注未经复核**，且必须区分「✅钻取确认」与「⚠️聚合推断」。
  - **性能段**：**不出根因与方案**（硬约束）——性能是连续指标，无堆栈可钻取，推断无从证伪；只给趋势、可定位对象与下一步取证方向。
  - **台账**：只收结论，深度分析留在周报并以链接引用。自动生成的错误结论会被下一轮反扫误判为「已修复」而自我强化——这是该约束的原始理由，对**写入台账的结论**依然成立。
  - 要人工深度定位跑 `firebase-crash-triage` skill。
- **`claude -p` 必须 `< /dev/null`**，`--mcp-config` 显式传（`.mcp.json` 按 cwd 加载）。
- **`repos/` 只 fetch 不 checkout / reset**：`REPOS_ROOT` 自动探测时会指向同级的**工作仓库**（不是隔离 clone），绝不能破坏未提交状态。
- **`REPOS_ROOT` 必须 export**：`fetch-snapshot.sh` 是子进程且有自己的默认值 `$ROOT/repos`，不 export 就会 `cd` 到不存在的路径——周报整跑失败、日报 MCP 对照段被误判成「超时」。
- **`unset PYTHONPATH`**（两个入口脚本开头都有）：Hermes 向子进程注入 `PYTHONPATH=~/.hermes/hermes-agent:<其 py3.12 site-packages>`，而 gcloud/bq 用自己的 Python 3.14 启动，被塞进 3.12 的包树后 `apitools` 等 ABI 不匹配，**导入即崩**。报错文案是「gcloud installation corruption / 请重装 SDK」，**极具误导性**——2026-08-13 曾据此误诊为「bq 不可用 / gcloud 未认证」，实际认证一直正常。
  - 生产路径（cron）因脚本开头的 `unset` 免疫；**从 Hermes 会话里手工调 `bq`/`gcloud` 排查时会中招**。
  - 兜底：`~/.local/bin/{bq,gcloud,gsutil}` 是 wrapper，内容为 `exec env -u PYTHONPATH /opt/homebrew/bin/$T "$@"`。删掉即回滚。
- **超时用 `lib.sh` 的 `run_with_timeout`**，不依赖 coreutils `timeout`；`set -e` 下要 `|| RC=$?` 捕获 124 才能走降级路径。
- **L2 平稳周照常投递**：卡片、周报文档、台账同步一个不少。`send=false` 只由 DRY RUN 产生，与本周有无变化无关（代码从没判断过 `WEEK_STATE`）。周报正文有卡片装不下的性能趋势与版本明细，而「本周无异常」本身就是要让人看见的结论。

## 规格与台账

- **OpenSpec 驱动**（`openspec/`，schema `spec-driven`，CLI 已装）。进行中的 change 在 `openspec/changes/<name>/`（proposal / design / tasks / specs delta），归档在 `changes/archive/`，已归档能力落在 `openspec/specs/`。工作流走 `.hermes/skills/openspec-{explore,propose,apply-change,archive-change}`——propose 阶段**只写规划产物不写代码**。
- 动手改脚本前先看对应 change 的 `design.md`/`tasks.md`：多数当前行为（阈值、卡片表格结构、staleness 兜底、审计日志）都有对应 change 记录了理由与取舍。
- ✅ **台账口径（change `crash-ledger-l2-ownership`，2026-08-19 完成）**。起因是三份台账并存分叉、L1 每天镜像的是孤儿副本。
  - **口径**：台账由 **L2 独占产出**，本地源 `$STATE/ledger/LEDGER.md`，同步到飞书文档 `TtpwdhgKroMH1DxJumojTflrppz`。**L1 不再读写台账**（`crash-daily.sh` 已无 `LEDGER_SRC` / `DOC_LEDGER_ID`，索引页台账入口改固定 URL 直链）。
  - **结构**（对齐 Android 那份的四段式）：项目常量 / 崩溃收口点登记 / **Issue 现状表**（单表双端，含「平台」列）/ **变更时间线**（挂周报链接）。
  - **同步方式**：`deliver.sh` 的 `sync_ledger()`——现状表走 `docs +update --command block_replace` 定点替换，时间线走 `--command append` 追加，**任何阶段都不用 `overwrite`**（会丢时间线历史）。定位不到标题块且无本地全文可 bootstrap 时**报错中止，不退化为 overwrite**。
  - **block ID 不可跨轮缓存**（2026-08-19 spike 实测）：每次 `block_replace` 都会让被替换的块拿到新 ID，旧 ID 立即失效；但 `append` 不扰动其他块的 ID。所以每轮同步前必须按标题重查当次 ID，**不要存进 `docs.json`**。
  - **初始内容**：Issue 现状表从零建立，不迁移历史结论（旧台账留在两个业务仓库供查阅）；「项目常量」与「收口点登记」两段例外迁移——它们是项目事实而非处置结论。
  - **修复状态由代码提交驱动**：commit message 约定 `[crash:<8位id>]`，`bin/scan-fix-commits.sh` 反扫两个业务仓库 `git log --all --grep='\[crash:' --since='14 days'` 自动更新「处置状态」列。纯只读、不 checkout / reset、**不在业务仓库装任何 hook**——反扫幂等可补漏，hook 漏一次就永久没记录，且要在团队共用仓库里配飞书凭证。8 位短 id 撞到多个 issue 时不自动更新，标为待人工确认。
  - **性能不进台账**：性能是连续指标、无追踪 ID，只在 L2 周报做趋势与页面定位，且不出根因。

### lark-cli 实测勘误（2026-08-19 spike，2026-08-20 补三条）

- **`--profile crash-triage` 不存在**：`lark-cli profile list` 只列出 appId `cli_aaf7b44ddeb8de14`，`crash-triage` 是未生效的历史 alias。用 `--profile cli_aaf7b44ddeb8de14`，或不传（它是唯一激活的 profile）。
- **`docs +fetch` 取正文的 jq 路径是 `.data.document.content`**，不是 `.content`（后者恒为 `null`）。
- ⛔ **`.data.document.content` 的值是 DocxXML 文本，不是块结构 JSON**（2026-08-20 实测，一次踩三处）。所有 scope（`outline` / `section` / `keyword`）都一样。想拿 block id 必须**解析 XML 标签**，在 JSON 里 `jq` 找 `type=="table"` / 遍历 `.. | objects` 永远落空：
  - 标题：`grep -oE '<h[1-6] id="[^"]*">标题文本<'`
  - 表格：`grep -oE '<table id="[^"]*"'`
  - `sync_ledger()` 的标题与表格定位都因此失效过：标题那处取「第一个带 id 的对象」还会**命中正文里提到同名文字的引用块**（台账开头那段说明就写着「Issue 现状表」），导致误判「标题不存在」而退回 bootstrap，把四段结构重复 append 了两遍。同名标题有多个时取**最后一个**（旧结构在上、本流水线建的新结构在下）。
- **`--content @绝对路径` 被拒**（"must be a relative path within the current directory"）：改用 stdin（`cat f | lark-cli ... --content -`）或先 `cd` 到文件目录用 `@./file`。
- **拆 `deliver.sh` 函数体复用时会覆盖同名变量**：`head -n <case 行> deliver.sh > /tmp/f.sh && . /tmp/f.sh` 这招能单独调 `sync_ledger()` / `publish_doc()`，但它顶部的 `ROOT=` / `STATE=` 会覆盖调用方的赋值（2026-08-20 实测 `$ROOT` 被清空，`md2docx.py` 路径变成 `//bin/...`）。source 之后再赋值，或直接写绝对路径。
