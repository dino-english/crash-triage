# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## 这是什么

Dino（iOS + Android）崩溃 & 性能日报/周报流水线的**部署运行时仓库**。没有应用代码、没有构建系统、没有测试框架——全部是 bash + `bq` + `jq` + Hermes cron，产出投递到飞书群 `oc_655033f1f85fa04f9eac25d56f056fc9`。

两条独立链路（详见 [bin/INSTALL.md](bin/INSTALL.md) §0）：

| | L1 日报 `crash-daily.sh` | L2 周报 `crash-weekly.sh` |
|---|---|---|
| 定时 | 每天 07:00（Hermes cron） | 每周一 05:30（Hermes cron） |
| 数据源 | BigQuery（crashlytics / sessions / performance） | Firebase MCP `topIssues` + git 反查 |
| 用不用模型 | 否（`fetch-snapshot.sh` light 对照除外） | 是，取数 + git 反查 + 分析 |
| 职责 | **高频数据呈现**，不做分析、不碰结论 | **分析与结论沉淀** |
| 产出 | 群卡片 + 日报 + 索引页（**不含台账**，change `crash-ledger-l2-ownership`） | 周报文档 + 群卡片 + 索引页归档 + **台账同步** |
| 性能 | 日维度当期值 | 周维度趋势 + WoW（不出根因） |
| 版本口径 | **只统计最新 2 个版本**（按版本号），按版本分列 + 版本间对比 | **主力版本**（近 7 天会话量 top2） |

**两条链路都只读业务仓库，不 commit / 不 push / 不改业务代码。**

## 代码与状态分离

| | 路径 | 说明 |
|---|---|---|
| 代码 `ROOT` | 本仓库 clone 目录 | 脚本按自身位置解析（`bin/` 的上级），**不写死绝对路径**——clone 到哪都能跑 |
| 运行数据 `STATE` | `${XDG_STATE_HOME:-~/.local/state}/crash-triage` | logs / 快照 / 历史 / 每日报告 / `config.env` / 生成好的 plist |

```bash
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export CRASH_REPORT_ROOT="${CRASH_REPORT_ROOT:-$(dirname "$SELF_DIR")}"
STATE="${CRASH_REPORT_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/crash-triage}"
```

分开的理由不是洁癖：`git clean -xfd` / 重新 clone 会连同被忽略的文件一起抹掉，而 `last-snapshot.json` 丢了会把下周所有 issue 报成新增（2026-08-07 那类事故）。

**例外：`reports/report-index.jsonl` 放在仓库里且纳入 git**——它存的是历次日报/周报飞书文档的 URL，飞书端无法枚举本 bot 的文档，删了就永久断链。其余状态都可再生。

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
# DRY RUN（不投递；L1 会把卡片 JSON 写到 state/publish/card.json 后 exit 0）
CRASH_REPORT_ROOT=$HOME/crash-triage CRASH_REPORT_CHAT_ID=<ou_xxx> \
  CRASH_REPORT_DRY_RUN=1 bash bin/crash-daily.sh
CRASH_REPORT_ROOT=$HOME/crash-triage CRASH_REPORT_CHAT_ID=<ou_xxx> \
  CRASH_REPORT_DRY_RUN=1 bash bin/crash-weekly.sh

# 单条 SQL 手工验证（脚本用 sed 替换占位符再喂 bq）
sed -e "s|{{TABLE}}|dino-english-497507.firebase_performance.com_prime_dino_english_IOS|g" \
    -e "s|{{DAYS}}|3|g" -e 's|{{VERSIONS}}|"1.5.4"|g' \
    bin/sql/perf-screens.sql | bq query --use_legacy_sql=false --format=csv

# 装机 / 换机后重探工具路径（换过 node/brew 位置后必须重跑，否则 cron job 起不来）
bash bin/setup.sh

# 一键装机（探路径 + 授权自检 + 生成 wrapper + 注册 cron）／更新（拉代码 + 重探 + 自检）
bash bin/install.sh
bash bin/update.sh

# 改脚本后的唯一自动检查（bash -n 语法自检，全绿才提交）
bash bin/check-scripts.sh

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

没有单元测试。改脚本后的验收链：`bash bin/check-scripts.sh`（语法自检，唯一的自动检查）→ DRY RUN → 抽查 2–3 个数值与 Firebase 控制台对得上（[bin/INSTALL.md](bin/INSTALL.md) §6）。

## 架构要点

### 富文本：颜色必须走 DocxXML

飞书 **markdown 导入不支持颜色和高亮框**，要配色只能用 DocxXML（`docs +create` / `docs +update` 的默认格式）。

| 产物 | 渲染方式 |
|---|---|
| 日报 | `crash-daily.sh` 直接生成 XML（`build_report_xml`），复用卡片那套 `cell()` / `delta_of()` 的阈值判定，只把 `<font color=X>` 转成 `<span text-color="X">` |
| 台账镜像 | `bin/md2docx.py` 通用转换（markdown 结构照搬 + 状态词按语义上色 + 引用块转高亮框 + 表格斑马纹） |
| 索引 / 周报 | `bin/md2docx.py` 同款转换（2026-08-18 起四份产物配色统一） |

配色常量集中在 `crash-daily.sh` 顶部：`XC_HEAD`（表头蓝底）/ `XC_ZEBRA`（偶数行灰底）/ `XC_HILITE`（最新版列黄底）。

写 XML 时两条铁律：**结构标签不能转义、字段值必须转义**（把整行喂给转义函数会让 `<tr><td>` 变成字面文本，飞书渲染出一张空表）；**`<span>` 不能嵌套**（正则上色时要跳过已有标签内的文本）。

### 生成与投递分离，两段都无 LLM

`crash-daily.sh` / `crash-weekly.sh` 只算数据、产出 `$STATE/publish/manifest.json` + `card.json` + 待导入的 markdown；`bin/deliver.sh` 读 manifest，用 `lark-cli` 走完投递。脚本末尾串行调用 deliver，**投递失败不改变生成脚本的退出码**——数据已落盘，重跑 `deliver.sh` 补投即可。`CRASH_REPORT_NO_DELIVER=1` 只生成不投递。

投递链路（顺序不能换）：导入日报 → 导入台账镜像 → 回填索引页的 `__DAILY_URL__` / `__LEDGER_URL__` → 导入索引页 → 回填卡片的 `__DETAIL_URL__` / `__INDEX_URL__` → 发卡片。占位符必须在导入前填好：`drive +import` 只能新建不能覆盖。

- **幂等靠 `--idempotency-key`**（值 = `run_id`），不需要投递台账。这条链路以前交给 LLM agent 做，代价是「文档建了卡片没发」的重复投递且系统不自知——2026-08-18 换成确定性脚本。
- **陈旧 manifest 闸门**：`deliver.sh` 校验 `day` 必须等于今天。脚本失败时不会重写 manifest，照投就会把昨天的卡片当今天发。
- **同一位置的导入必须串行**，并发会撞 `232140101`/`232140100`/`233523001`。
- **文档组织**：`deliver.sh` 自动建 `Dino 崩溃 & 性能日/周报` 父目录 + `L1 日报` / `L2 周报` 子目录（按名字查、查不到才建，token 缓存在 `$STATE/folders.json`）。日报周报收进各自目录，索引与台账放父目录根部。
- **覆盖优先于新建**：建过的文档记在 `$STATE/docs.json`，下次直接 `docs +update --command overwrite`。索引 / 台账永久固定 URL；日报周报每天（每周）一份新的，但**同日重跑覆盖当天那份**（键 `daily-<日期>`）。优先级 `环境变量 DOC_*_ID > docs.json 自动记忆 > 新建`。
- **清理挂在投递收尾**，不能挂在「新建」路径上——稳态下每天都是覆盖，新建路径根本不执行。
- **归档统一**：日报与周报都写 `reports/report-index.jsonl`（进 git），索引页据此渲染两张归档表。归档在**卡片发送成功之后**追加——归档的语义是「已投递」不是「已生成」。今日条目次日才出现在归档表，当天的入口在页面顶部。

### 版本口径（2026-08-18 起，change `crash-perf-latest-2-versions`）

日报**三段全部按版本过滤**，只统计最新 2 个版本，每个数字按版本分列，**不输出跨版本合计**。

- **版本清单唯一源 = `firebase_sessions` 活表**，按版本号 `sort -V` 取最新 N 个（不是会话量排序）。各表「最新版本」并不一致（性能批量表滞后 ~2 天、crashlytics 新版常为空），各段各自解析必然错位。
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
- **崩溃率 = 事件数 / 会话数**，不是 crash-free（需 session 级关联，未做）。分母为 0 显示「无法计算」，不能显示 0。
- **两套口径不可混比**：滚动窗口展示值（`perf-*.sql` / `crash-rate.sql`）与天级单日值（`*-1d.sql`，字段带 `_1d`，供 DoD/WoW）显式分离存储在 `$STATE/metrics-history.jsonl`。
- 崩溃主源已从 MCP `topIssues`（只含 OPEN issue）迁到 BigQuery 事件级（含已关闭 issue）。`fetch-snapshot.sh` light 模式的 MCP 抓取现在只用于：首验期数值对照、索引页「跟踪中的 issue」、`fix_commit` 反查。见 change `crash-source-bigquery-migration`。
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

**告警只由最新版触发**，上一版与主力补充列只着色不告警（既定事实拦不了发版）。小样本提示 `SAMPLE_SESSION_MIN` 判定对象是**版本级**会话数。

### 摘要行（卡片顶部的 🔴 / 🟡 行）

摘要行由 `red_line()` / `yellow_line()` 生成，**必须标版本、且区分「没超阈值」与「没算出来」**：

- **有值的端**渲染成 `iOS 1.5.4 425ms`——不标版本会被读成两端同口径，而两端最新版常常不是同一个版本号（Android 线上没有 1.5.2，序列是 `1.5.3 → 1.5.1`）。
- **无值的端**降级成末尾括注 `（iOS 1.5.4 无数据）`，不占主位。表格里的缺数三态（样本不足 / 该版本无数据 / 表未同步）压进摘要行只剩一个「—」，看起来像故障。
- **没有数据不告警**：两端都无值时整行不输出。旧实现会打出 `🔴 指标 iOS — · Android —`——零数据却在报警。

典型形态（2026-08-18 实测，新版 1.5.4 刚放量、性能表仅 199 行样本不足）：

```
🔴 慢帧最差页 Android 1.5.3 94.6%（iOS 1.5.4 无数据）
🔴 启动 P95 iOS 1.5.4 425ms · Android 1.5.3 4363ms
```

⛔ **多字节字符不能紧跟 `${var:+...}`**：`"${miss:+（$miss）}"` 在 `set -u` 下报 `miss?: unbound variable`——bash 把全角括号的后续字节并进了变量名。全角括号与 `·` 分隔符一律先条件赋值再拼接。

### 卡片的能力边界

CardKit v2 的 `table` 组件字段只有 `rows` / `page_size` / `row_height` / `row_max_height` / `freeze_first_column` / `header_style` / `margin`。**`header_style` 只作用于表头**（`background_style` 仅 `grey|none`），**行级与单元格级都没有背景色**。单元格是 `lark_md`，只有 `<font color=>`（文字色），没有底色语法。

所以**斑马纹是文档独有能力**（DocxXML 的 `<td background-color>`），卡片对齐不了；卡片能与文档一致的只有文字颜色（同一套 `traffic_light()` 判定）。

### 卡片与对比列

卡片是每端一张 CardKit v2 表（列 = 指标 | 版本列 2–4 个 | 对比），行标签带窗口天数（`崩溃率 7d` / `会话数 1d`）——不标窗口必被读成同一口径。对比列 = 最新版 − 上一版：**箭头跟数值方向，颜色跟好坏**（合并会让「会话数 -51 ↑」这类越大越好的指标自相矛盾）；会话数用 `neutral` 不着色。同版本 DoD/WoW 只进日报文档，不进卡片。

### 运行数据布局（`$STATE/`，均不入库）

> ⚠️ **以下是 change `crash-ledger-l2-ownership` 定稿的目标布局，实施中。** 当前代码仍按时间戳平铺（`metrics-<TS>/` / `crash-daily-<TS>/` / `weekly-<TS>/`）。

```
$STATE/                          # ${XDG_STATE_HOME:-~/.local/state}/crash-triage
├── issues/<32位id>.json         事实层：崩溃事件详情，一次抓永久留，不参与清理
├── ledger/LEDGER.md             台账本地源（L2 产出，同步飞书）
│   └── snapshots/               历史专项快照 md（从仓库移入）
├── runs/<日期>/{L1,L2}/<时刻>/  跑批产物，保留 30 天，附 latest 软链
├── backup/                      台账等不可再生内容的手工备份
├── logs/                        日志保留 60 天；bq stderr 落 bq-stderr-<TS>.log
├── publish/                     每次运行 rm -rf 重建的投递目录
└── *.json                       基准文件，**保持顶层不动**（见下表）
```

**为什么基准文件不进子目录**：它们是跨跑批的累积状态，丢失后果严重（`docs.json` 丢 → 新建整套重复飞书文档，2026-08-19 实际发生；`last-snapshot.json` 丢 → 全部 issue 报成新增，2026-08-07 事故）。保持原位 = 零迁移风险，46 处 `$STATE/xxx.json` 引用一处不改。

| 文件 | 作用 |
|---|---|
| `daily-snapshot.json` | 明日「新增 issue」判定基准（MCP ids）+ 当日版本集回溯 |
| `metrics-history.jsonl` | 天级单日值滚动 **90 天**（`HISTORY_KEEP`，**按版本存储**）；无 `versions` 键的旧口径行读取时自动丢弃并提示 |
| `docs.json` | 文档台账：决定覆盖还是新建。带日期后缀的键保留 90 天（`DOC_KEEP_DAYS`），`index` / `ledger` 无日期后缀、永不清理 |
| `folders.json` | 目录 token 缓存，按 profile 隔离 |
| `last-snapshot.json` | L2 变化检测基准；**首跑无基准时只建基线不报新增**（否则刷一屏「新增」） |
| `health-daily.json` / `health.json` | L1 / L2 的健康状态 |

**仓库内保留判据 = 可再生性。** `reports/report-index.jsonl` 是**唯一入库的运行产物**——它存历次日报/周报的飞书文档 URL，而飞书端无法枚举本 bot 的文档，删了就永久断链。其余（台账、专项快照、`weekly-index.jsonl`）都移入 `$STATE`。

## 部署实例：飞书侧固定资源

**这些是这套部署独有的事实，不是代码。** 运行时它们缓存在 `$STATE/docs.json` 与 `$STATE/folders.json`（机器本地、不入库），本表是缓存丢失 / 换机器 / 换会话时的兜底记录。`deliver.sh` 新建任何固定资源时会打印可直接粘贴的回填块。

### 租户与应用

| 项 | 值 |
|---|---|
| 租户域名 | `qjphu5vphyf4.jp.larksuite.com` |
| **主力应用** | 壹帏管家 `cli_aaf7b44ddeb8de14` · lark-cli profile `crash-triage` · 身份钉死 `--as bot` |
| 另两个应用 | `cli_aad59f453275de18`（Leong Chee Wei's Lark CLI，lark-cli 默认 profile）· `cli_aaf7d7fc6ef9de17`（Dino AI Data Assistant） |
| 你的 open_id | 壹帏管家下 `ou_edd20a8dbfcc5e3ee279a225aec044d0` · 旧 app 下 `ou_a14d438768dbc819773b94c84f82726a` |

⚠️ **open_id 按 app 隔离**，跨 app 用会报 `99992361 open_id cross app`。群 ID（`oc_`）是租户级的，不受影响。

### 文件夹（2026-08-18 建，均已授予你 full_access）

```
Dino 崩溃 & 性能日/周报   ExuPfsz3Rl1x7kdIQRojxeFVpue
  ├─ L1 日报              DRngfVukxlsGvodQSNhjco1BpKs
  └─ L2 周报              RSr3fsHDal7uu5dtqTjjPxdtpbb
```

### 固定文档（原地覆盖，URL 不变）

| 文档 | URL |
|---|---|
| Dino 崩溃跟踪 · 索引 | `https://qjphu5vphyf4.jp.larksuite.com/docx/UPQNdbzGio2l3bxOleRjK1nOpHd` |
| 崩溃专项台账 LEDGER（只读镜像） | `https://qjphu5vphyf4.jp.larksuite.com/docx/TtpwdhgKroMH1DxJumojTflrppz` |

日报 / 周报**不在此表**：每天（每周）一份新文档收进对应目录，**同日重跑覆盖当天那份**（键 `daily-YYYY-MM-DD` / `weekly-YYYY-MM-DD` 记在 `docs.json`）。历史通过索引页的「报告归档」表与 `reports/report-index.jsonl` 追踪。

### 投递目标

| 场景 | ID |
|---|---|
| 正式群 | `oc_655033f1f85fa04f9eac25d56f056fc9`（Dino 崩溃 & 性能日/周报） |
| 私聊验证 | `ou_edd20a8dbfcc5e3ee279a225aec044d0` |

`deliver.sh` 按前缀分流：`ou_` 走 `--user-id`，其余走 `--chat-id`。

### scope 现状（2026-08-18）

- **bot 身份**：三个 app 都已开通 `drive:drive`，建目录 / 建文档 / 发消息全通。
- **user 身份**（壹帏管家）：只批下来 `im:*` 与 `contact:user.basic_profile:readonly`，**没有 docs / drive / 权限管理**。
- 后果：**加协作者只能在飞书 UI 里点**（`drive +member-add` 需要 `docs:permission.member:create`，bot 身份则被 `1063002` 拒）。想走 CLI 需在后台给 user 身份补 scope 并**发布新版本**，然后重新 `lark-cli auth login --profile crash-triage`。

### ⛔ 不要删的历史文档（旧 app 云空间根目录）

| token | 标题 | 说明 |
|---|---|---|
| `V1I3di1YQo29v6xNZoGjbZCDppe` | Dino 崩溃跟踪 · 索引 | 2026-08-07 建，INSTALL.md 旧 `DOC_INDEX_ID` |
| `FvmTdArLyoOydQxdAo8jRNSUpAg` | 崩溃专项总台账（LEDGER）— iOS | 2026-08-07 建，旧 `DOC_LEDGER_ID` |
| `OjTmd3Vyuo8RPuxV76MjRYxzpCd` | 崩溃 & 性能日报 · 2026-08-07 | 历史产物 |
| `KSFUdzCKYocCYcx4l1yjrBiFpyd` | 崩溃周报 · 2026-08-07 | 历史产物 |
| `CkUpdh7KSo2oGuxOsmpjgL4up5G` · `Wb0Td39FXojn4wx2lqFjFJSdphb` | 【探测】权限检查 · （无标题） | 非本流水线产物 |

### 运行时状态文件

| 文件 | 内容 | 键 |
|---|---|---|
| `$STATE/docs.json` | 文档台账（决定覆盖还是新建） | `<profile>\|index` · `<profile>\|ledger` · `<profile>\|daily-<日期>` |
| `$STATE/folders.json` | 目录 token 缓存 | `<profile>\|<父token或root>/<目录名>` |

两者都按 profile 隔离：换 app 后复用旧 token 会得到「无权限」，比「找不到」更难排查。

## 硬约束（都是踩过的坑）

- **`--allowedTools` 禁止前缀通配**：写 `"mcp__firebase"` 会放行写操作 `crashlytics_update_issue`，2026-08-06 已因此误关线上 issue（见 `reports/LEDGER.md` 事故记录）。必须逐个列只读工具。
- **跨仓库 git 反查必须带 `--add-dir`**，否则被权限边界拦下、静默产出未验证的 `null`。prompt 里已要求「不得让 null 冒充查过没有」。
- **L2 的根因与方案边界**（2026-08-19 按实测修正）：原表述「L2 自动档不出根因与修复方案」与实际不符——`full` 模式的 `report.md` 实测会产出七章 226 行，含风险分级、钻取确认的根因、修复方案（且自述「未经人工复核，落地前须验证」），甚至会主动标注「为什么本轮不给根因」（栈未符号化时）。真正的边界是：
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
- 无变化时 L2 不发送（`send:false`），避免播报噪音化。

## 规格与台账

- **OpenSpec 驱动**（`openspec/`，schema `spec-driven`，CLI 已装）。进行中的 change 在 `openspec/changes/<name>/`（proposal / design / tasks / specs delta），归档在 `changes/archive/`，已归档能力落在 `openspec/specs/`。工作流走 `.hermes/skills/openspec-{explore,propose,apply-change,archive-change}`——propose 阶段**只写规划产物不写代码**。
- 动手改脚本前先看对应 change 的 `design.md`/`tasks.md`：多数当前行为（阈值、卡片表格结构、staleness 兜底、审计日志）都有对应 change 记录了理由与取舍。
- ⚠️ **台账口径已变（change `crash-ledger-l2-ownership`，实施中）**。旧表述「`reports/LEDGER.md` 是崩溃处置结论的人工真相源，飞书上是只读镜像（L1 每天同步）」**已被证伪**：2026-08-19 实测发现三份台账并存且分叉——`crash-triage/reports/LEDGER.md`（153 行，只含 iOS）、`dino-english-ios/reports/crash-triage/LEDGER.md`（98 行，iOS 团队仍在更新）、`dino-english-android/reports/crash-triage/LEDGER.md`（70 行，从未进过飞书）。根因是 `ab6748b`（08-14）复制 iOS 台账进本仓库却未删原件，本仓库那份成了孤儿副本，L1 每天镜像的是过期内容。
  - **新口径**：台账由 **L2 独占产出**，本地源 `$STATE/ledger/LEDGER.md`，同步到飞书文档 `TtpwdhgKroMH1DxJumojTflrppz`。**L1 不再读写台账**。
  - **结构**（对齐 Android 那份的四段式）：项目常量 / 崩溃收口点登记 / **Issue 现状表**（单表双端，含「平台」列）/ **变更时间线**（挂周报链接）。
  - **同步方式**：现状表走 `docs +update --command block_replace` 定点替换，时间线走 `--command append` 追加，**绝不 `overwrite`**（会丢时间线历史）。
  - **初始内容**：Issue 现状表从零建立，不迁移历史结论（旧台账留在两个业务仓库供查阅）；「项目常量」与「收口点登记」两段例外迁移——它们是项目事实而非处置结论。
  - **修复状态由代码提交驱动**：commit message 约定 `[crash:<8位id>]`，跑批时反扫两个业务仓库 `git log --all --grep='\[crash:' --since='14 days'` 自动更新「处置状态」列。**不在业务仓库装任何 hook**——反扫幂等可补漏，hook 漏一次就永久没记录，且要在团队共用仓库里配飞书凭证。
  - **性能不进台账**：性能是连续指标、无追踪 ID，只在 L2 周报做趋势与页面定位，且不出根因。
