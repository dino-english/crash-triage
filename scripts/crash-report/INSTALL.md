# 崩溃 & 性能日/周报 — Mac mini 安装清单

面向在 Mac mini 上执行安装的人或 agent。**按顺序做，每步都有验收命令，验收不过不要往下走。**

---

## 0. 这套东西是什么

两条独立链路，都跑在这台机器上，产出发到飞书群「Dino 崩溃 & 性能日/周报」（`oc_655033f1f85fa04f9eac25d56f056fc9`）：

| | L1 每日数据日报 | L2 每周变化播报 |
|---|---|---|
| 定时 | 每天 07:00 | 每周一 06:30 |
| 数据源 | BigQuery（crashlytics / sessions / performance） | Firebase MCP（topIssues 等） |
| 用不用模型 | **否**，纯 `bq` + `jq` + shell | 是，仅用于取数与 git 反查 |
| 碰不碰仓库 | 只读 clone（git 反查修复状态） | 只读 clone |
| 产出 | 群卡片 + **刷新索引页** + **同步台账镜像** | 新建报告文档 + 群卡片 + 索引页追加一行 |

**两条都不写业务仓库、不 commit、不 push。**

### L1 顺带承担的文档同步

L1 每天都跑，所以文档同步挂在它身上（最多 1 天延迟），不单独做同步脚本：

1. **重建索引页**（`DOC_INDEX_ID`，overwrite）——跟踪表数据每天变
2. **同步台账镜像**（`DOC_LEDGER_ID`，overwrite）——把仓库 `reports/crash-triage/LEDGER.md` 推上去，让不看仓库的人也能读

> 台账的**真相源始终是仓库文件**，在线版是只读镜像。镜像顶部带「请勿在此编辑」警告。人在修复提交时更新仓库台账，次日 L1 自动同步上线。

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

脚本源在 iOS 仓库 `scripts/crash-report/`。两种取法：

```bash
# 方式 A：已有仓库 clone（推荐）
cd /path/to/dino-english-ios && git pull
export CRASH_REPORT_ROOT="$HOME/crash-triage"
bash scripts/crash-report/setup.sh

# 方式 B：只 scp 脚本目录过来
scp -r <你的机器>:/path/to/dino-english-ios/scripts/crash-report ~/
export CRASH_REPORT_ROOT="$HOME/crash-triage"
bash ~/crash-report/setup.sh
```

`setup.sh` 会把同目录的 `*.sh` 自装到 `$CRASH_REPORT_ROOT/bin/`。**源（仓库）与运行副本（`$ROOT/bin`）分离**：仓库版本随 git 管理，脚本有更新时重跑 `setup.sh` 即覆盖运行副本。

`setup.sh` 会做：

1. **探测二进制真实路径写入 `bin/config.env`** —— 不硬编码 PATH。launchd 只给最小 env，各机器 node/brew 路径不同，硬编码必挂
2. 写 `bin/mcp.json`（Firebase MCP 配置，**不含任何密钥**，复用本机 firebase login 凭证）
3. clone 两个只读仓库到 `repos/`（已存在则只 fetch）
4. 跑一遍探活

**验收**：`setup.sh` 末尾打印「安装完成」且两个 ✅ 全绿。

---

## 5. 配置项

全部通过环境变量传入，写在 launchd plist 的 `EnvironmentVariables` 里。

| 变量 | 必填 | 说明 |
|---|---|---|
| `CRASH_REPORT_ROOT` | 是 | 根目录，建议 `$HOME/crash-triage` |
| `CRASH_REPORT_CHAT_ID` | 是 | 目标群 `oc_655033f1f85fa04f9eac25d56f056fc9`；**首次部署建议先填自己的 `ou_xxx` 私聊验证几轮再换群** |
| `CRASH_REPORT_DRY_RUN` | 否 | `1` = 只打印不发送。首次务必用它跑 |
| `AGENT_CMD` | 否 | L2 用的 agent 命令，默认 `claude`；可换 cursor / codex |
| `DOC_INDEX_ID` | 是（L1） | 索引页文档 ID，L1 每天 overwrite 重建 |
| `DOC_LEDGER_ID` | 是（L1） | 台账镜像文档 ID，L1 每天从仓库 `LEDGER.md` 同步 |

**当前文档 ID**（2026-08-07 建立）：

```
DOC_INDEX_ID=V1I3di1YQo29v6xNZoGjbZCDppe    # Dino 崩溃跟踪 · 索引
DOC_LEDGER_ID=FvmTdArLyoOydQxdAo8jRNSUpAg   # 崩溃专项台账 LEDGER · iOS
```

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
export CRASH_REPORT_ROOT="$HOME/crash-triage"
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

## 7. 装定时

### 7.1 时间配置

| | 任务 | 默认时间 | plist |
|---|---|---|---|
| **L1** | 每日数据日报 | **每天 07:00** | `com.dino.crash-daily.plist` |
| **L2** | 每周变化播报 | **每周一 05:30** | `com.dino.crash-weekly.plist` |

时间写在 plist 的 `StartCalendarInterval` 里，**改时间只改这一段**：

```xml
<!-- L1：每天 07:00 -->
<key>StartCalendarInterval</key>
<dict>
    <key>Hour</key><integer>7</integer>
    <key>Minute</key><integer>0</integer>
</dict>

<!-- L2：每周一 05:30。Weekday 1=周一，0 或 7=周日 -->
<key>StartCalendarInterval</key>
<dict>
    <key>Weekday</key><integer>1</integer>
    <key>Hour</key><integer>5</integer>
    <key>Minute</key><integer>30</integer>
</dict>
```

时间是**本机时区**（Asia/Kuala_Lumpur），不是 UTC——跟 cron 一致，不用换算。

### 7.2 为什么选这两个时间

- **避开打包高峰**：这台机器近 8 个工作日 86 次构建的分布统计中，**01:00–07:00 为 0 次**（高峰在 18:00，14 次）。定在这个窗口不与打包抢资源
- **赶在上班前出结果**：大家 09:00 左右到，07:00 跑完的报告正好在群聊顶端
- **L2 比 L1 早 90 分钟**：完整 triage 实测跑 **12 分钟以上**（2026-08-07 实测，且中途断连失败过一次）。原定 06:30 与 07:00 的 L1 会重叠，两者都调 lark-cli 会加剧限流——已撞过 429。留 90 分钟余量

### 7.3 安装

```bash
# plist 里的 USER 占位符要替换成实际用户名
sed -i '' "s|/Users/USER|$HOME|g" "$CRASH_REPORT_ROOT/bin/"*.plist 2>/dev/null || \
  sed -i '' "s|/Users/USER|$HOME|g" scripts/crash-report/*.plist

cp scripts/crash-report/*.plist ~/Library/LaunchAgents/
launchctl load ~/Library/LaunchAgents/com.dino.crash-weekly.plist
launchctl load ~/Library/LaunchAgents/com.dino.crash-daily.plist
```

**验收**：

```bash
launchctl list | grep com.dino.crash
# 期望两行，第二列（上次退出码）为 0；从未跑过时为 0 或 -
```

**改完时间要重新加载**（改 plist 不会自动生效）：

```bash
launchctl unload ~/Library/LaunchAgents/com.dino.crash-daily.plist
launchctl load   ~/Library/LaunchAgents/com.dino.crash-daily.plist
```

### 7.4 ⚠️ 关于 BigQuery 数据延迟（影响 L1 时间选择）

Crashlytics 导出 BigQuery 是**每日批量同步**，官方未承诺具体时点。07:00 本地 = 前一天 23:00 UTC，**不保证昨天的数据一定已经同步完**。

因此 L1 脚本会在卡片里打印**实际查到的最新事件时间**，而不是假设「数据截至昨天」。上线后头几天核对这个时间戳：

- 若稳定滞后一天以上 → 把 L1 往后推（如 10:00），或改为报「截至 N 日」
- 若需要准实时 → 需在 Firebase 控制台额外开 streaming export（要 Blaze 计划）

**不要**在没核对过时间戳前就相信卡片上的日期。

### 7.5 机器休眠的影响

`StartCalendarInterval` 在机器休眠错过触发时，**唤醒后会补跑一次**（launchd 行为，与 cron 不同——cron 会直接跳过）。所以这台机器如果会休眠，日报不会因此断档，但可能延迟到唤醒时刻才发。

若需要严格准点，在系统设置里关闭休眠，或用 `caffeinate` 保持唤醒。

---

## 8. 日常运维

**日志**：`$CRASH_REPORT_ROOT/logs/`，保留 60 天自动清理。

**健康状态**：

```bash
cat "$CRASH_REPORT_ROOT/state/health.json"
# {"last_run":"...","ok":true,"changes":N}   ok=false 时含 error 字段
```

**排查「报告没出现」**：

1. `launchctl list | grep com.dino.crash` 看退出码
2. 看 `logs/` 最新一份日志
3. 最常见原因按概率排序：① PATH 问题（换过 node/brew 位置后没重跑 `setup.sh`）② gcloud/firebase 凭证失效 ③ BigQuery 当日数据未同步

**停止**：

```bash
launchctl unload ~/Library/LaunchAgents/com.dino.crash-daily.plist
```

---

## 9. 已知约束与坑（都是实测踩过的）

| 坑 | 说明 |
|---|---|
| **launchd 最小 env** | 不继承登录 shell 的 PATH。`config.env` 由 `setup.sh` 探测生成，**换过 node/brew 路径后必须重跑 `setup.sh`** |
| **`claude -p` 需 `< /dev/null`** | 否则等 stdin 3 秒并打警告 |
| **`.mcp.json` 按 cwd 加载** | `claude -p` 必须从含该文件的目录执行，或显式传 `--mcp-config` |
| **`--allowedTools` 禁用前缀通配** | 写 `"mcp__firebase"` 会放行写操作 `update_issue`，已因此误关过线上 issue。必须逐个列只读工具 |
| **跨仓库读取需 `--add-dir`** | 否则 git 反查被权限边界拦下，**静默产出未验证的 null** |
| **`git reset --hard` 只对 `repos/` 下的 clone** | 绝不能把 `repos/` 指向任何人的工作仓库 |
| **BigQuery 是每日批量同步** | 日报看到的是「截至昨天」，不是实时。卡片上须写清楚 |
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

- **Android 无法自动判定修复状态**：Android 未采用「提交信息带 Crashlytics issue ID」的约定（2026-08-07 核实：全仓 0 处 32 位 hex 引用），`fix_commit` 恒为 null。自动表格显示 `—`，其修复情况以每周 triage 报告的**语义分析**为准。若要打通，需推动 Android 侧采用同样的提交约定（iOS 侧由 `crash-prevention` skill 定为硬规则）。
- **L2 完整 triage 无整体超时**：实测跑 12 分钟以上，且曾因长连接中断失败一次（重试后成功）。目前无 `timeout` 包裹，agent 卡死会一直挂着。若上线后出现挂起，需引入 `gtimeout`（`brew install coreutils`）。
- **BigQuery 每日批量同步**：日报数据实际滞后约一天。卡片会打印真实的数据截止时间戳，**不要假设「截至昨天」**。

### 待做

- [ ] 部署到 Mac mini（本文档 §1–§7）
- [ ] BigQuery 崩溃表就绪后，把崩溃数据源从 MCP 换成事件级统计，并补崩溃率
- [ ] 为 L2 加整体超时保护
- [ ] 与 Android 侧对齐「提交带 issue ID」约定（打通自动修复状态判定的前提）
