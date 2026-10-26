## 0. 拍板

- [x] 0.1 开 change 修「必修混入窗口外 issue」（用户 2026-10-26）

## 1. 实现

- [x] 1.1 `priorities_validate` 第 3 参 = 数据层快照 id；P0/P1 不在其中 → P2，why「本周窗口内无事件 · 原判 Px」，输出 `demoted`
- [x] 1.2 `crash-weekly.sh`：传数据层 id；来源注记写降级条数；标题回落到分析层快照

## 2. 测试

- [x] 2.1 `core-tier.sh` 夹具：窗口外 P1 → P2 且不计 dropped；窗内不变；旧代码红
- [x] 2.2 `check-scripts.sh` 十项全绿

## 3. 验证（⛔ 部署前）

- [x] 3.1 用 10-26 生产 L2 产物（`priorities.json` + 两份快照）离线重放分档：3 条 PAG 进 👀、必修 4 条、3 条 PAG 不再 @ 人
- [x] 3.2 整跑 L2 NO_DELIVER + 实发私聊读回（隔离 STATE 副本，模型换桩造「窗口外 P1」）

## 4. 文档

- [x] 4.1 失效模式登记新增一条（自然日窗 vs 滚动窗混入必修）

## 实施记录（2026-10-26）

- 2.1 `core-tier.sh` 新增 2 条：新代码 127/127；`git stash` 旧 `tier.sh` 后这 2 条红
- 2.2 `check-scripts.sh` 全部通过；shellcheck 计数改前改后相同（存量 75 处不变）；`fn-fetch-events-mcp.sh` 缺依赖跳过（存量）
- 3.2 开发机 STATE 复制到 scratchpad 隔离跑（不碰开发机 STATE 与共享文档），`AGENT_CMD` 桩以数据层快照造分析层产物，
  另加 `29d4790c` 只进分析层快照并排 P1；BigQuery 真查。rc=0；日志「🚨 1（来源 model · 1 条本周窗口内无事件，降为观察）· 👀 1」；
  卡片与文档首屏均只剩窗内 P0、窗外条目进 👀 且标题回落、无 👤；实发私聊 `om_x100b62dfe64d18a0…` 读回一致
  （发前把 `<at>` 换成纯文本，免得私聊卡 @ 到开发机配置的负责人）
- 3.1 生产 10-26 产物实证机制：`29d4790c` `4ade82c7` `ed3883b1` `85c581ed` 数据层快照 0 条、分析层快照各 1 条。
  重放：旧代码复现线上 7 条必修；新代码 demoted=3、必修 `22b2b310` `3fc8c6cb` `b307f98b` `62f88f39`。
  生产 /tmp 影子跑（/bin/bash 3.2 + jq-1.7.1-apple，set -euo pipefail）rc=0、结果一致，临时文件已删
