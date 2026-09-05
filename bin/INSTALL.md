# 崩溃 & 性能日/周报 — Mac mini 安装清单

面向在 Mac mini 上执行安装的人或 agent。**按顺序做，每步都有验收命令，验收不过不要往下走。**

---

## 0. 这套东西是什么

两条独立链路，都跑在这台机器上，产出发到飞书群「Dino 崩溃 & 性能日/周报」（`oc_655033f1f85fa04f9eac25d56f056fc9`）：

| | L1 每日数据日报 | L2 每周变化播报 |
|---|---|---|
| 定时 | 每天 07:00 | 每周一 06:30 |
| 数据源 | BigQuery（crashlytics / sessions / performance） | Firebase MCP（topIssues 等） |
| 用不用模型 | **否**，纯 `bq` + `jq` + `lark-cli` | 是，仅用于取数与 git 反查 |
| 碰不碰仓库 | 只读 clone（git 反查修复状态） | 只读 clone |
| 产出 | 群卡片 + 日报 + 索引页（**不含台账**，change `crash-ledger-l2-ownership`） | 周报文档 + 群卡片 + 索引页归档 + **台账同步**（新增性能段、WoW 环比） |
| 投递 | `bin/deliver.sh`（`lark-cli`，确定性、幂等） | 同左 |
| 版本口径 | **只统计最新 2 个版本**（按版本号），按版本分列 + 版本间对比 | **主力版本**（近 7 天会话量 top2，复用日报 SQL 换窗口） |

**两条都不写业务仓库、不 commit、不 push。**

### L1 顺带承担的文档同步

L1 每天都跑，所以文档同步挂在它身上（最多 1 天延迟），不单独做同步脚本：

1. **重建索引页**（`DOC_INDEX_ID`，overwrite）——跟踪表数据每天变

> ⚠️ **现状（2026-08-19）**：lark 块 API 不支持表格、`docx_builtin_import` 只能新建不能覆盖，所以「固定 ID 覆盖」改为**每次新建 + 回填**：L1 每天产 2 份文档（日报 + 索引页），索引页两入口（日报/周报最新）的 URL 由 agent 建完文档后回填占位符（`__DAILY_URL__` / `__INDEX_URL__`），卡片末尾带 `📄 详情` + `🗂 崩溃跟踪索引` 两个链接。因此各文档 URL 天天变，稳定入口靠每天卡片里的「索引」链接。

> 台账由 **L2 独占产出**（change `crash-ledger-l2-ownership`）。本地源在 `$STATE/ledger/LEDGER.md`，同步到飞书文档 `TtpwdhgKroMH1DxJumojTflrppz`。L1 不再读写台账——索引页的「台账」入口是固定 URL，不是动态生成的文档。

---

## 1. 前置：这台机器上必须已有

```bash
# 验收：全部有输出才继续
command -v brew node npm git
sw_vers -productVersion          # macOS 版本
```

缺 node 用 `brew install node`。**不要用 nvm 装**——launchd 最小环境读不到 nvm 的 shell 初始化，会导致定时任务起不来（本机实测踩过：node 在 `/usr/local/bin` 而非 homebrew 路径，脚本硬编码 PATH 时直接挂）。

---

## 2. 安装工具链

```bash
brew install --cask google-cloud-sdk    # 提供 gcloud + bq
brew install jq                          # 若 /usr/bin/jq 已存在可跳过
npm install -g @larksuiteoapi/lark-cli   # 包名以实际发布名为准
npm install -g @anthropic-ai/claude-code # L2 需要；L1 不需要
```

**验收**：

```bash
gcloud --version && bq version && jq --version && lark-cli --version && claude --version
```

---

## 3. 三个授权（**必须人在这台机器上操作，agent 的 shell 无 TTY 做不了**）

### 3.1 Google Cloud（L1 查 BigQuery 用）

```bash
gcloud auth login                                  # 弹浏览器，选有 dino-english-497507 权限的账号
gcloud config set project dino-english-497507
```

无桌面环境时用 `gcloud auth login --no-launch-browser`（需手工贴回验证码）。

**验收**：

```bash
bq ls dino-english-497507:firebase_crashlytics     # 能列出表即通过
```

### 3.2 Firebase CLI（L2 的 MCP 复用它的登录凭证）

```bash
npx -y firebase-tools@latest login
```

**验收**：

```bash
npx -y firebase-tools@latest login:list            # 输出含 @ 的邮箱即通过
```

### 3.3 lark-cli（发消息 / 建文档）

```bash
lark-cli auth login --domain im
```

会输出 verification_url，在浏览器完成授权。

**验收**：

```bash
lark-cli im +chat-list --as bot --page-size 1 | jq '.ok'    # true 即通过
```

> **注**：发消息与建文档都走 **bot 身份**，bot token 由 appId + appSecret 自动换取，**不走 OAuth、无过期问题**。上面的 user 授权只用于 CLI 自身配置初始化。若 bot 报 scope 不足，需在开放平台后台申请，不是这台机器能解决的。

---

## 4. 安装脚本

**代码就地跑在仓库里，不复制到别处**；可变的运行数据单独放一处：

| | 路径 | 谁管 |
|---|---|---|
| 代码 `ROOT` | 本仓库 clone 目录（脚本按自身位置解析，无需配置） | git |
| 运行数据 `STATE` | `${XDG_STATE_HOME:-~/.local/state}/crash-triage` | 本机，不入库 |

分开的理由：`git clean -xfd` 或重新 clone 会连同被忽略的文件一起抹掉，而 `last-snapshot.json` 丢了会把下周所有 issue 报成新增（2026-08-07 那类事故）。

```bash
git clone <本仓库> ~/crash-triage-repo   # 目录名随意，脚本不依赖
cd ~/crash-triage-repo
bash bin/setup.sh                        # 两个路径都不用设，setup 自己解析
```

`setup.sh` 会做：

1. **探测二进制真实路径写入 `$STATE/path.env`**（2026-08-20 前叫 `config.env`，`setup.sh` 会自动清掉旧文件） —— 不硬编码 PATH。cron / launchd 都只给最小 env，各机器 node/brew 路径不同，硬编码必挂
2. 写 `bin/mcp.json`（Firebase MCP 配置，**不含任何密钥**，复用本机 firebase login 凭证）
3. 业务仓库：**运行根的同级目录**里有就直接用（只读 fetch），没有才 clone 到 `$ROOT/repos`
4. 按本机实际路径生成 launchd plist 到 `$STATE/`（备选调度方案，见 §7.6；主调度是 Hermes cron）
5. 跑一遍探活

**验收**：`setup.sh` 末尾打印「安装完成」且两个 ✅ 全绿。

---

## 5. 配置项

全部通过环境变量传入，写在 `~/.hermes/scripts/crash-{daily,weekly}.sh` 包装脚本里（由 `install.sh` 生成）；用 launchd 时则写在 plist 的 `EnvironmentVariables` 里。

| 变量 | 必填 | 说明 |
|---|---|---|
| `CRASH_REPORT_ROOT` | 否 | 代码根。**默认 = 本仓库 clone 目录**（脚本按自身位置解析，不写死路径） |
| `CRASH_REPORT_STATE_DIR` | 否 | 运行数据目录。默认 `${XDG_STATE_HOME:-~/.local/state}/crash-triage` |
| `CRASH_REPORT_CHAT_ID` | 是 | 目标群 `oc_655033f1f85fa04f9eac25d56f056fc9`；**首次部署建议先填自己的 `ou_xxx` 私聊验证几轮再换群** |
| `CRASH_REPORT_DRY_RUN` | 否 | `1` = 只打印不发送。首次务必用它跑 |
| `AGENT_CMD` | 否 | L2 用的 agent 命令，默认 `claude`；可换 cursor / codex |
| `CRASH_REPORT_VERSION_COUNT` | 否 | 日报统计的**最新版本个数**，默认 `2` |
| `CRASH_REPORT_MIN_SESSIONS` | 否 | 版本候选门槛（低于此会话数的版本不进清单），默认 `5` |
| `CRASH_REPORT_MAX_VERSION_COLS` | 否 | 卡片版本列上限（最新 N 版 ∪ 主力 2 版），默认 `4` |
| `DOC_INDEX_ID` | 否 | 索引页文档 **URL**（或 token）。设了就每天原地覆盖、URL 固定；不设则每天新建一份 |
| `CRASH_REPORT_DOC_URL_BASE` | 否 | 索引页传裸 token 时用它拼回 URL；直接传完整 URL 则不需要 |
| `CRASH_REPORT_FOLDER` | 否 | 云文档父文件夹名，默认 `Dino 崩溃 & 性能日/周报` |
| `CRASH_REPORT_FOLDER_DAILY` / `_WEEKLY` | 否 | 子文件夹名，默认 `L1 日报` / `L2 周报` |

**文档组织**（`deliver.sh` 自动建目录，按名字幂等复用）：

```
Dino 崩溃 & 性能日/周报          ← 父文件夹
  ├─ L1 日报/                    ← 日报文档（每天新建一份，全部收在这里）
  ├─ L2 周报/                    ← 周报文档（每周新建一份）
  ├─ Dino 崩溃跟踪 · 索引         ← 设了 DOC_INDEX_ID 则原地覆盖，URL 固定
  └─ 崩溃专项台账 LEDGER（镜像）  ← 设了 DOC_LEDGER_ID 则原地覆盖，URL 固定
```

日报与周报**统一归档在索引页**（`reports/report-index.jsonl` → 索引页的「报告归档」两张表）。
首次运行时索引与台账是新建的，把它们的 URL 填进 `DOC_INDEX_ID` / `DOC_LEDGER_ID` 即可钉成固定文档
（`deliver.sh` 新建时会把 URL 打印出来）。

**项目常量已硬编码在脚本里，无需配置**：

```
Firebase project   dino-english-497507
iOS App ID         1:465344775452:ios:610bc2f8ea0750fff466d9
Android App ID     1:465344775452:android:2c546b57b0176325f466d9
BigQuery 数据集     firebase_crashlytics / firebase_sessions / firebase_performance
BigQuery 表名       com_prime_dino_english_IOS / _ANDROID
```

---

## 6. 首次验证（**不要跳过**）

```bash
# CRASH_REPORT_ROOT 不用设：默认就是本仓库 clone 目录（state/ logs/ 已在 .gitignore 里）
export CRASH_REPORT_CHAT_ID="<你自己的 ou_xxx>"     # 先发私聊
export CRASH_REPORT_DRY_RUN=1

bash "$CRASH_REPORT_ROOT/bin/crash-weekly.sh"        # L2
bash "$CRASH_REPORT_ROOT/bin/crash-daily.sh"         # L1（BigQuery 表就绪后才有）
```

**逐项核对**：

- [ ] 凭证探活全过
- [ ] 仓库同步打印出的分支是当前活跃开发分支（不是 `main`、不是某个老 feature 分支）
- [ ] 数值跟 Firebase 控制台对得上（**抽查 2-3 项，别只看格式**）
- [ ] DRY RUN 输出的卡片文案没有乱码、没有空字段

核对通过后去掉 `DRY_RUN` 再跑一次，确认私聊收到。**最后**才把 `CHAT_ID` 换成群。

---

## 7. 装定时（Hermes cron）

### 7.1 时间配置

| | 任务 | 默认时间 | cron 表达式 | job 名 |
|---|---|---|---|---|
| **L1** | 每日数据日报 | **每天 07:00** | `0 7 * * *` | `crash-daily` |
| **L2** | 每周变化播报 | **每周一 05:30** | `30 5 * * 1` | `crash-weekly` |

时间是**本机时区**（Asia/Kuala_Lumpur），不是 UTC。改时间：

```bash
hermes cron list                                        # 拿 job id
hermes cron edit <job_id> --schedule '0 10 * * *'       # 改完立即生效，无需重载
```

### 7.2 为什么选这两个时间

- **避开打包高峰**：这台机器近 8 个工作日 86 次构建的分布统计中，**01:00–07:00 为 0 次**（高峰在 18:00，14 次）。定在这个窗口不与打包抢资源
- **赶在上班前出结果**：大家 09:00 左右到，07:00 跑完的报告正好在群聊顶端
- **L2 比 L1 早 90 分钟**：完整 triage 实测跑 **12 分钟以上**（2026-08-07 实测，且中途断连失败过一次）。原定 06:30 与 07:00 的 L1 会重叠，两者都调 lark-cli 会加剧限流——已撞过 429。留 90 分钟余量

### 7.3 安装

`bin/install.sh` 的第 6 步已自动生成 wrapper 并提示注册命令。手工注册：

```bash
hermes cron create '0 7 * * *'  --name crash-daily  --no-agent --script crash-daily.sh
hermes cron create '30 5 * * 1' --name crash-weekly --no-agent --script crash-weekly.sh
```

`--script` 是相对 `~/.hermes/scripts/` 的路径，wrapper 由 `install.sh` 生成（写死 `ROOT` / `STATE` / `CHAT_ID` / `LARK_PROFILE`）。`--no-agent` 表示不起 LLM，脚本 stdout 直接投递——所以 wrapper 把 stdout 重定向到 `/dev/null`（卡片由脚本自己用 lark-cli 发）。

**验收**：

```bash
hermes cron list | grep -A3 crash
# 期望两个 job，enabled=True，next_run_at 是下一个预定时刻
```

**确认真的跑得起来**（推荐在首次部署时做一次）：把调度临时改到几分钟后，等 ticker 自行触发，再改回来——这是唯一能验证「调度器 → wrapper → 主脚本 → 投递」整条链路的方式。

```bash
hermes cron edit <job_id> --schedule '55 16 * * *'      # 改到 5 分钟后
sleep 300 && sqlite3 ~/.hermes/cron/executions.db \
  "SELECT status,claimed_at,finished_at,error FROM executions ORDER BY claimed_at DESC LIMIT 1;"
hermes cron edit <job_id> --schedule '0 7 * * *'        # 还原
```

> ⚠️ **不要用 `hermes cron run <id>` 判断成败**：它**总是打印 `Ran now: failed`**，与实际结果无关（Hermes 后台派发路径漏设 `execution_success`，见 `tools/cronjob_tools.py:1347` vs `hermes_cli/cron.py:476`）。以 `executions.db` 的 status 与 `$STATE/logs/` 的脚本日志为准。

**停止**：`hermes cron pause <job_id>`

### 7.4 ⚠️ 关于 BigQuery 数据延迟（影响 L1 时间选择）

Crashlytics 导出 BigQuery 是**每日批量同步**，官方未承诺具体时点。07:00 本地 = 前一天 23:00 UTC，**不保证昨天的数据一定已经同步完**。

因此 L1/L2 的卡片与文档都打印**每段的取数区间**（`起 → 止`，双时区）：起点是本次跑批时刻减去窗口天数（SQL 的 `TIMESTAMP_SUB(CURRENT_TIMESTAMP(), …)` 下界），终点是该表实际查到的最新事件时间。**两者之差就是数据滞后**，一眼可见。

上线后头几天核对这个区间：

- 性能段常态只覆盖窗口第 1 天（批量表滞后 ~2 天）——**正常，不是故障**
- 放量段终点应几乎等于跑批时刻（sessions REALTIME 活表）；若明显落后，查 sessions 表是否回退到批量表
- 若崩溃段稳定滞后一天以上 → 把 L1 往后推（如 10:00）
- 若需要准实时 → 需在 Firebase 控制台额外开 streaming export（要 Blaze 计划）

### 7.5 机器休眠的影响

**Hermes cron 错过的触发不会补跑**（与 launchd 的 `StartCalendarInterval` 不同——后者唤醒后会补跑一次）。若 Mac 在 07:00 处于休眠，**当天日报就不会出**。

若需要严格准点：在系统设置里关闭休眠，或用 `caffeinate` 保持唤醒；也可改用 `bin/*.plist`（launchd 备选方案，见 §7.6）。

### 7.6 备选：launchd（当前未装载）

`bin/com.dino.crash-{daily,weekly}.plist` 是带 `__ROOT__` / `__STATE__` 占位符的模板，`setup.sh` 会按本机实际路径生成到 `$STATE/`。保留它的理由：launchd 不依赖 Hermes 进程，是 gateway 挂掉时的兜底，且有休眠补跑能力。

```bash
STATE="${XDG_STATE_HOME:-$HOME/.local/state}/crash-triage"
cp "$STATE"/com.dino.crash-*.plist ~/Library/LaunchAgents/
launchctl load ~/Library/LaunchAgents/com.dino.crash-daily.plist
launchctl list | grep com.dino.crash    # 第二列 = 上次退出码
```

> ⛔ **切换前必须先停掉另一个调度器**（`hermes cron pause`）。两者同时跑会双跑：卡片有幂等键不会重复，但**并发写 `docs.json` / 归档 JSONL 会互相覆盖**（脚本假设单写者）。

---

## 8. 日常运维

**日志**：`$STATE/logs/`（默认 `~/.local/state/crash-triage/logs/`），保留 60 天自动清理。

**健康状态**：

```bash
cat "${XDG_STATE_HOME:-$HOME/.local/state}/crash-triage/health.json"      # L2
cat "${XDG_STATE_HOME:-$HOME/.local/state}/crash-triage/health-daily.json" # L1
# {"last_run":"...","ok":true,"changes":N}   ok=false 时含 error 字段
```

**排查「报告没出现」**：

1. `hermes cron list` 看两个 job 的 enabled / next_run_at；`sqlite3 ~/.hermes/cron/executions.db "SELECT job_id,status,claimed_at,error FROM executions ORDER BY claimed_at DESC LIMIT 5;"` 看实际执行结果
2. 看 `logs/` 最新一份日志
3. 最常见原因按概率排序：① PATH 问题（换过 node/brew 位置后没重跑 `setup.sh`）② gcloud/firebase 凭证失效 ③ BigQuery 当日数据未同步

**停止**：

```bash
hermes cron pause <job_id>          # job id 从 hermes cron list 拿
```

---

## 8.5 搬到 Hermes / 其它 Agent 运行时执行

脚本本身不挑运行环境，但**凭证与状态全部挂在 `$HOME` 上**，换一个执行主体就会踩下面这些。按「不做会怎样」排序：

| # | 事项 | 不做的后果 |
|---|---|---|
| 1 | **`lark-cli` 主密钥落地**：先在交互式终端跑一次 `lark-cli config keychain-downgrade` | appSecret 存在 macOS Keychain（`{"source":"keychain"}`），无 TTY / 无解锁登录钥匙串的守护进程读不到，**所有 lark-cli 调用直接失败** |
| 2 | **显式设 `CRASH_REPORT_STATE_DIR`** | Hermes 若以不同 `$HOME` 运行，`docs.json` / `folders.json` 读不到 → 判定为「没建过」→ **每次运行都新建一套目录和文档**，云空间迅速变垃圾场 |
| 3 | **显式设 `REPOS_ROOT`** | 同级探测依赖仓库位置，探不到会回落 `$ROOT/repos` 并 clone 一份 175M 的副本 |
| 4 | **绑定应用用 `lark-cli config bind --source hermes --app-id cli_xxx`**，不是 `config init` | Agent 上下文（`HERMES_HOME` / `OPENCLAW_HOME` 已设）下 `config init` 会**直接拒绝**，提示改用 bind |
| 5 | **`unset PYTHONPATH`**（脚本已内置） | Hermes 会注入自己的 `PYTHONPATH`，`bq` 的 `from utils import bq_error` 误抓 hermes-agent 的 `utils.py` 而崩（2026-08-14 实测） |
| 6 | **`AGENT_CMD` 指向可用的 agent CLI** | `fetch-snapshot.sh` 默认调 `claude -p`；Hermes 环境里未必有，或指向坏的安装 → 周报根因段与日报 MCP 对照段静默降级 |
| 7 | **确认只有一个调度器在跑** | launchd 与 Hermes cron 同时触发会双跑：卡片有幂等键不会重复，但**并发写 `docs.json` / 归档 JSONL 会互相覆盖**（脚本假设单写者） |

| 8 | **确认 `HOME` 传给了子进程** | `lark-cli` 靠 `$HOME` 找 `~/.lark-cli` 与钥匙串。用 `env -i` 之类的干净环境起进程会让它读不到凭证——**连故障告警都发不出去**（实测） |
| 9 | **`node` 必须在 PATH 上** | `lark-cli` 是 node 脚本不是独立二进制，缺 node 直接 `env: node: No such file or directory`。告警的最小依赖是 `node + lark-cli + jq` |

**故障告警（`bin/alert.sh`）不依赖 agent**：纯 shell + `jq` + `lark-cli`，`claude` 不在 PATH 上也能发。这是刻意的——agent 挂掉恰恰是最该收到告警的场景。它的 PATH 兜底会自动补 `~/.npm-global/bin` / `/opt/homebrew/bin` / `/usr/local/bin`，因为「PATH 配错」本身就是最常见的故障原因，告警器不能和被监控对象共享故障源。

其余仍依赖 `$HOME` 的东西，换主体前逐个确认可达：`~/.lark-cli`（应用与 token）、`~/.config/gcloud`（bq 的 ADC）、`~/.config/configstore`（firebase-tools 登录态）、`~/.npm-global`（`lark-cli` / `claude` 可执行文件）。

### 把 `AGENT_CMD` 换成 hermes：结论是「暂缓」（2026-08-18 实测）

接口大体对得上：`claude -p` ↔ `hermes -z`（one-shot，只输出最终文本）、`--add-dir` ↔ `--in DIR`、MCP 已全局配好 `firebase` + `lark`。

**卡在工具白名单上**。当前调用靠 `--allowedTools` 逐个列出只读工具，这是 2026-08-06 误关线上 issue 后立的硬规则。hermes 侧：

```
$ hermes -z "..." -t firebase:crashlytics_get_report
hermes -z: ignoring unknown --toolsets entries: firebase:crashlytics_get_report
hermes -z: --toolsets did not contain any valid toolsets.
```

`-t` 只认内置 toolset 名（`web` / `terminal` / `file` / `memory` 等），**不支持 `server:tool` 粒度**；而 `hermes mcp list` 显示 firebase 是 **all tools enabled**，含写操作 `crashlytics_update_issue`。切过去就丢掉了调用级白名单。

三个选项：

| 方案 | 代价 |
|---|---|
| **A. 保持 `claude -p`**（当前） | 无。`--allowedTools` 每次调用生效，粒度最细 |
| **B. `hermes tools disable firebase:crashlytics_update_issue`** | 全局配置，影响所有 hermes 用法；且是「默认允许、逐个禁止」，将来新增写工具会漏 |
| **C. 单独配只读 firebase MCP server** | `firebase-tools --only crashlytics` 只到分组级，仍含 `update_issue`，不成立 |

**当前采用 A。** 切换前置条件：hermes 支持调用级工具白名单，或确认 B 的黑名单足够覆盖。

**授权类操作必须提前在交互式终端做完**：设备流登录、`gcloud auth login`、`firebase login` 都要浏览器和 TTY，Agent 运行时里做不了。

## 9. 已知约束与坑（都是实测踩过的）

| 坑 | 说明 |
|---|---|
| **cron / launchd 最小 env** | 都不继承登录 shell 的 PATH。`path.env` 由 `setup.sh` 探测生成，**换过 node/brew 路径后必须重跑 `setup.sh`**；投递目标另放人手写的 `local.env`，`setup.sh` 永不覆写它 |
| **`PYTHONPATH` 会毒死 gcloud/bq** | Hermes 注入的 `PYTHONPATH` 指向其 py3.12 site-packages，而 gcloud 用 3.14 启动 → `apitools` ABI 不匹配、导入即崩，报错却写「gcloud installation corruption，请重装」。**两个入口脚本开头都有 `unset PYTHONPATH`**，生产路径免疫；手工排查时用 `~/.local/bin/{bq,gcloud,gsutil}` wrapper（内含 `env -u PYTHONPATH`） |
| **`hermes cron run` 的成败提示不可信** | 后台派发路径漏设 `execution_success`，**永远打印 `Ran now: failed`**。以 `executions.db` 的 status + 脚本日志为准 |
| **`claude -p` 需 `< /dev/null`** | 否则等 stdin 3 秒并打警告 |
| **`.mcp.json` 按 cwd 加载** | `claude -p` 必须从含该文件的目录执行，或显式传 `--mcp-config` |
| **`--allowedTools` 禁用前缀通配** | 写 `"mcp__firebase"` 会放行写操作 `update_issue`，已因此误关过线上 issue。必须逐个列只读工具 |
| **跨仓库读取需 `--add-dir`** | 否则 git 反查被权限边界拦下，**静默产出未验证的 null** |
| **`git reset --hard` 只对 `repos/` 下的 clone** | 绝不能把 `repos/` 指向任何人的工作仓库 |
| **BigQuery 是每日批量同步** | 数据滞后，不是实时。卡片与文档都标注每段的取数区间（`起 → 止`，双时区），**滞后一眼可见**——不要假设「截至昨天」 |
| **版本清单只从 sessions 解析** | crashlytics / performance 的「最新版本」各不相同（性能批量表滞后 ~2 天、crashlytics 新版常为空）。各段各自解析必然错位，故统一以 `firebase_sessions` 活表为唯一源 |
| **最新版在性能段常态无数据** | 性能表滞后，新版列显示「该版本无数据」是**正常状态**，不是故障。判定序：表不存在 → 表整体无数据（数据未同步）→ 该版本无数据 |
| **崩溃段没有「该版本无数据」态** | 有会话就有分母，`0 类 0 次` 是「这版没崩过」的结论本身。把它渲染成缺数会让最该被看见的好消息消失 |
| **投递不要交给 LLM** | 建文档→拿 URL→回填占位符→发卡片全是确定性调用，交给 agent 会出现「文档建了卡片没发」的重复投递且系统不自知。`deliver.sh` 用 `lark-cli --idempotency-key` 根治（2026-08-18 改） |
| **陈旧 manifest 会投出昨天的卡片** | 脚本失败时不会重写 manifest。`deliver.sh` 校验 `day` 必须等于今天，否则拒投并报错 |
| **同一位置的导入必须串行** | 并发导入到同一文件夹会撞 `232140101`/`232140100`/`233523001`。`deliver.sh` 天然串行，勿改成并行 |
| **`bq show` 要冒号格式** | `project:dataset.table`，而查询里用的是 `project.dataset.table`。传全点号给 `bq show` 会**永远返回「表不存在」**，导致整块数据被静默跳过 |
| **`drive +delete` 输出前有非 JSON 行** | 输出首行是 `Deleting docx ...`，直接管道进 `jq` 会 parse error——**看起来失败其实已删成功**。用 `--json` 或 `tail -n +2` 再解析，否则会误判并重复操作 |
| **`docs +update --content @文件` 只认相对路径** | 绝对路径被拒（`--file must be a relative path within the current directory`）。脚本里一律用 `--content -` 走 stdin |
| **发布类命令别吞 stderr** | `2>/dev/null` 会把 lark-cli 的错误详情丢光，只剩一句「失败」。排查时无从下手——保留原始返回写进日志 |

---

## 10. 这套东西不做什么

- **不自动建任务、不自动 @人、不自动提交** —— 报告产出即终点，后续由人决定
- **不写业务仓库** —— `repos/` 是只读 clone，台账更新由开发者在修复提交时顺手完成
- **L2 自动档不出根因与修复方案** —— 硬约束。自动生成的方案可能看似合理实则错误，且会被下一轮 `git log --grep` 误判为「已修复」，错误自我强化。因果推断只在人工跑时做

---

## 11. 待办与已知缺口（截至 2026-08-07）

### 等外部条件

| 项 | 影响 | 备注 |
|---|---|---|
| BigQuery `firebase_crashlytics` 未出表 | 崩溃统计暂走 Firebase MCP 的 `topIssues`，**只统计 OPEN issue**——被误关的 issue 即使仍在崩也不显示 | 2026-08-06 11:09 开通，已超 48 小时窗口大半；若明日仍无，需查控制台导出配置 |
| BigQuery `firebase_sessions` 未出表 | **崩溃率算不出**（缺分母），日报只能报绝对数量 | 同上 |
| Android 性能表未同步 | 卡片性能项只有 iOS，已标注「（仅 iOS）」 | SDK 已确认接入（`app/build.gradle.kts` 有 plugin + implementation） |

### 已知限制（非缺陷，不会自行消失）

- **Android 的 `—` 不等于「未修」**：⛔ 旧结论「Android 未采用该约定、`fix_commit` 恒 null」**已于 2026-09-01 订正**——那次核查（2026-08-07）只认 `[crash:<8位id>]` 一种写法，而实际在用的是 `Crashlytics: <32位id>`（Android 写在 subject、iOS 写在 body）。2026-09-05 在生产机业务仓复核：Android 近 90 天 **4 条**（`85c581ed` / `a34175e5` / `ce481263` / `fa48b2eb`），iOS 1 条。<br>现状是 **iOS 有硬规则**（`crash-prevention` skill），null ⇒ 判「🔴 未修」可信；**Android 采用但非强制**，null 只渲染为 `—`，意为「提交信息里没找到」——不等于未修。若要让 Android 也能判「未修」，需把该约定在 Android 侧定为硬规则。
- **L2 完整 triage 无整体超时**：实测跑 12 分钟以上，且曾因长连接中断失败一次（重试后成功）。目前无 `timeout` 包裹，agent 卡死会一直挂着。若上线后出现挂起，需引入 `gtimeout`（`brew install coreutils`）。
- **BigQuery 每日批量同步**：日报数据实际滞后约一天。卡片会打印真实的数据截止时间戳，**不要假设「截至昨天」**。

### 待做

- [ ] 部署到 Mac mini（本文档 §1–§7）
- [ ] BigQuery 崩溃表就绪后，把崩溃数据源从 MCP 换成事件级统计，并补崩溃率
- [ ] 为 L2 加整体超时保护
- [ ] 与 Android 侧对齐「提交带 issue ID」约定（打通自动修复状态判定的前提）

---

## 12. 飞书侧固定资源（部署实例）

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
| 崩溃专项台账 LEDGER | `https://qjphu5vphyf4.jp.larksuite.com/docx/TtpwdhgKroMH1DxJumojTflrppz` |

日报 / 周报**不在此表**：每天（每周）一份新文档收进对应目录，**同日重跑覆盖当天那份**（键 `daily-YYYY-MM-DD` / `weekly-YYYY-MM-DD` 记在 `docs.json`）。历史通过索引页的「报告归档」表与 `reports/report-index.jsonl` 追踪。

### 投递目标

| 场景 | ID |
|---|---|
| 正式群 | `oc_655033f1f85fa04f9eac25d56f056fc9`（Dino 崩溃 & 性能日/周报） |
| 私聊验证 | `ou_edd20a8dbfcc5e3ee279a225aec044d0` |

`deliver.sh` 按前缀分流：`ou_` 走 `--user-id`，其余走 `--chat-id`。每台机器在 `$STATE/local.env`
里写自己的 `CRASH_REPORT_CHAT_ID`：开发机（MacBook）填私聊，**只有生产机（Mac mini）填正式群**。
机制说明见 CLAUDE.md「部署实例」。

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
