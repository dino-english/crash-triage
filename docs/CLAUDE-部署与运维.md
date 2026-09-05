# 部署与运维

> 拆分自 CLAUDE.md（crash-triage@2377dad，change `agent-config-governance` 第 8 组），逐节原样迁入。

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

| job | job id | 调度 | 包装脚本 |
|---|---|---|---|
| `crash-daily` | `72f0850e6688` | `30 8 * * *` | `~/.hermes/scripts/crash-daily.sh` |
| `crash-weekly` | `6d834f1f6da5` | `30 5 * * 1` | `~/.hermes/scripts/crash-weekly.sh` |

**改调度**：`hermes cron edit <job id> --schedule "<cron 表达式>"`（改完 `hermes cron list` 核对 `Next run`）。
⚠️ 非交互 ssh 里必须先 `. ~/.local/state/crash-triage/path.env; export PATH`，否则 `hermes` 不在 PATH，
`update.sh` 会报「无 hermes cron 任务」——那是假故障，不是真的没注册。

⚠️ **L1 由 `0 7 * * *` 改为 `30 8 * * *`**（2026-08-27，change `crash-data-completeness` 第 4 组）。
回退：`hermes cron edit 72f0850e6688 --schedule "0 7 * * *"`。
理由：perf 分区约 23:54 UTC 落地，而 07:00(+08) = 23:00 UTC **系统性地早 54 分钟**，白白多背一天滞后。
⛔ **这个改动必须在新代码之后**，顺序反了会出假信号：旧代码用 `MAX(DATE(event_timestamp))` 取「最新可用单日」，
23:00 UTC 跑时残日还没落地、侥幸取中完整日；挪到 00:30 UTC 残日已落地，就会拿 7 小时切片去比完整天
（实测 iOS 1.5.4：残日 29 样本 P95 548ms vs 完整日 192 样本 1044ms，渲染成「−496ms ↓」的假改善，F33）。

包装脚本由 `bin/install.sh` 生成（写死 `ROOT` / `STATE` / `CHAT_ID` / `LARK_PROFILE` 后 exec 主脚本），**勿手改**——改配置重跑 `install.sh` / `update.sh`。`stdout` 重定向到 `/dev/null`：`--no-agent` 会把 stdout 原样投递，而卡片由脚本自己用 lark-cli 发。

**launchd plist 保留作弹性方案**（`bin/*.plist`，当前未装载）。必须是绝对路径，仓库里存的是带 `__ROOT__` / `__STATE__` 占位符的模板，由 `setup.sh` 按本机实际路径生成到 `$STATE/`——不手改、也不把带本机路径的脏文件写回仓库。

⚠️ **只能有一个调度器在跑**：launchd 与 Hermes cron 同时触发会双跑。卡片有幂等键不会重复，但**并发写 `docs.json` / 归档 JSONL 会互相覆盖**（脚本假设单写者）。装 plist 前先 `hermes cron pause`。

## 验收链与 check-scripts 十项

没有单元测试。验收链：`check-scripts.sh` → DRY RUN → 抽查 2–3 个数值与 Firebase 控制台对得上（[bin/INSTALL.md](bin/INSTALL.md) §6）。

⛔ `check-scripts.sh` 是**十项**检查（2026-08-23 起，change `crash-perf-functional-core`；
第 10 项 2026-09-05 加）。⚠️ **以脚本头部的清单为准**——本节曾长期列 7 条却写「九项」，
条目也与脚本不符（多了 `md2docx.py 语法`、少了第 6/7 项），2026-09-05 对齐：

1. `bash -n` 语法（递归扫 `bin/**/*.sh`）
2. **`$VAR` 紧邻多字节字符** —— 反复踩的那个坑（`"${miss:+（$miss）}"` 在 `set -u` 下报
   `miss?: unbound variable`，bash 把全角括号的字节并进了变量名）
3. **依赖方向 lint** —— 核心层不得出现取数 / 投递 / 模型 / 状态目录
4. **重复定义检测** —— 同名函数出现在两个及以上**生产**文件即失败（⛔ 不比对 `bin/test/`，
   夹具的桩本就不该收口；豁免清单以数据形式集中在脚本内）
5. **bq 直连收口 lint** —— `bq query` 出现在 `bin/lib/bq.sh` 之外即失败（豁免 `install.sh` 探活）。
   findings F5 的护栏：没有它时每个照着旧写法新增的取数函数都在扩大等价性缓存的缺口
6. **printf 格式串里的字面 %**（F22：只在运行时炸，`bash -n` 查不出）
7. **顶层「先用后定」**（F24 同源：常量/函数定义晚于使用，报错常被 EXIT trap 吞成 0）
8. **纯函数断言**（`bin/test/run.sh`）+ **函数级回归**（`fn-regression.sh`，生产 shell 设置下）
9. ShellCheck（可选）
10. **过期论断 lint** —— 已登记的、已被订正的结论不得复活。⚠️ 能力边界：只认**登记在册**的，
    认不出没登记的；它防的是「同一条已知错误结论再次复活」，不是「发现新的错误结论」。
    起因：「Android 未采用提交约定」这条 2026-09-01 已订正的结论在仓库里留了三份拷贝，
    09-05 修了两处漏了第三处，而漏掉那处最贵——L2 跑了扫描器、拿到 4 条 Android 命中后扔掉。

外加可选的 ShellCheck（未安装则跳过，不影响退出码——生产机不该为开发期工具多一项装机步骤）。

⚠️ **必须递归扫描 `bin/**/*.sh`**。早先只扫 `bin/*.sh`，于是 `bin/lib/` 与 `bin/test/` 下的新代码
**完全不受任何检查**——实测第一个放进 `bin/test/` 的脚本就带着 `$SCRIPT（` 通过了自检、运行时才炸；
改递归后立刻抓出 6 处。

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


## 链路对照（拆分前 CLAUDE.md「这是什么」全表）

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

## 常用命令（完整版，含 SQL 手工验证示例）

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

