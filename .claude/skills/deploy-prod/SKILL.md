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

## 假故障（别追）

- 非交互 ssh 里 `setup.sh 失败 / 缺工具`：ssh 无 brew PATH 的假象，按上面核验 path.env 即可。
- `update.sh` 报「无 hermes cron 任务」：同因。
- ⚠️ 不要在 mini 上手工跑 crash-daily/weekly 验证——它的 local.env 指向**正式群**。
