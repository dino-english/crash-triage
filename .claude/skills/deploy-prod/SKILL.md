---
name: deploy-prod
description: 部署到生产机 Mac mini——合入 main、ssh 执行 update.sh、核验清单，含两个已证实的假故障。
---

# 生产部署（Mac mini）

1. 本地：工作区干净 → `git checkout main && git merge --ff-only <branch> && git push origin main`
   （合完切回工作分支；若分叉先查 `git log main ^branch` 弄清哪个提交落错了支）。
2. 远端：`ssh dino911@dino911s-mac-mini`，clone 在 `/Users/dino911/gitWorkspace/crash-triage`，
   **远端名是 `github` 不是 `origin`**。执行 `bash bin/update.sh` 并**读完整输出**——
   自检的 ❌ 行就靠这里兜底（2026-08-23 实例：本地漏看的 lint 违规在这里拉响）。
3. 核验清单：
   - `git rev-parse --short HEAD` = 预期 sha；`/bin/bash bin/check-scripts.sh` 全绿
   - `stat path.env`：mtime 未被本次动过（setup.sh 缺工具时先退出不写盘）
   - 工具可达：`. ~/.local/state/crash-triage/path.env; export PATH` 后逐个 `command -v node claude npx bq lark-cli jq`
   - cron 在位：同上 PATH 后 `hermes cron list`（**别 head 截断**，crash 两个 job 在列表后面）

## 首次启用 L0 / 技术诊断（change `crash-tech-diagnostics`，⛔ 每一步先问维护者）

在上面第 2 步 `update.sh` 之后做。下面每条都是对外或花钱的动作，逐条征得同意再执行：

1. **一次性回填日聚合**（维护者 2026-11-26 批准 35 天）。先跑 `bash bin/diag-backfill.sh 35 --dry-run`，把打印出来的字节数报给维护者，同意后去掉 `--dry-run` 再跑。
   - ⛔ 不跑这一步的话，L2 冷启动要补 35 张表，会超出它 60 GB 的计费上限，周报这一节就会显示「取数失败」。
2. **写投递目标**：在 `$STATE/local.env` 里写 `export CRASH_REPORT_DIAG_ALERT_CHAT_ID="oc_706585b425aa175d888509b372deaebe"`——首周发「Dino AI 客服测试」群（维护者 2026-11-26 定；群里唯一的真人是维护者，日报机发卡的「Dino AI Data Assistant」在群里）。✅ 2026-11-26 已写，原文件备份为 `local.env.bak-20261126`。
   - 以后要改发私聊，得用维护者在日报机应用下的 open_id。⚠️ open_id 按应用隔离，开发机上的那个不能直接用；做法是日报机上 `HERMES_HOME=~/.hermes lark-cli im +chat-members-list --chat-id <群> --as bot`，在 users 列表里找本人。
3. **生成包装脚本**：⛔ **不要整体跑 `install.sh`**。生产机现有的 crash-daily / crash-weekly 包装没有 `export HERMES_HOME`，模板里有，整体跑会把它补进去，日报 / 周报发卡的应用身份可能跟着变（2026-11-26 上线时发现，未核实前不动）。
   - 正确做法：先 `cp -Rp ~/.hermes/scripts ~/.hermes/scripts.bak-<日期>`，再用 python 从 `bin/install.sh` 截出 `w="$HERMES_SCRIPTS/diag-hourly.sh"` 到 `ok "wrapper $w"` 之间那一段，设好 `ROOT` / `STATE` / `PROFILE` / `HERMES_SCRIPTS` 后执行。
   - 执行完 `cmp` 两份旧包装，必须未变。✅ 2026-11-26 按这个做法装好。
4. **注册 cron**：`hermes cron create '5 * * * *' --name diag-hourly --no-agent --script diag-hourly.sh`，然后把 job id 补进 docs/CLAUDE-部署与运维.md 的调度表。✅ 2026-11-26 已注册，job id `01c4ed7d509e`。注册前先 `env -i HOME=$HOME /bin/bash ~/.hermes/scripts/diag-hourly.sh` 手动跑一次首跑，有问题当场就能看到。
5. **首跑核验**：看 `cat $STATE/health-diag.json`。首跑会自动回填 L0 前 7 天（约 20 GB，按 design 走，不另批）。
6. **观察项**：2026-12-04 汇总 `diag/hits.jsonl` 与 `diag/evals.jsonl`，再从 `INFORMATION_SCHEMA.JOBS_BY_USER` 取实际费用，一起报维护者。

## 假故障（别追）

- 非交互 ssh 里 `setup.sh 失败 / 缺工具`：ssh 无 brew PATH 的假象，按上面核验 path.env 即可。
- `update.sh` 报「无 hermes cron 任务」：同因。
- ⚠️ 不要在 mini 上手工跑 crash-daily/weekly 验证——它的 local.env 指向**正式群**。
