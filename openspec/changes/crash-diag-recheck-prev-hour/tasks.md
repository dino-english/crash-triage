## 1. 实现

- [x] 1.1 `diag-hourly.sh`：复判上一小时（判定、命中记录、补报卡、跨 UTC 日重取、基线并集）；分布与投递抽成 `attach_breakdown` / `deliver_card`（不走 `$( )`，F72）
- [x] 1.2 `core/diag.sh`：`diag_plan` 的 last 只前移、first 取较早者；`diag_card` 第 6 个参数 `recheck`

## 2. 测试

- [x] 2.1 `core-diag.sh`：复判顺序（重跑时 first / last 不后退）、复判卡标题 / 表头 / 脚注；还原旧 plan 逻辑断言变红
- [x] 2.2 `fn-diag-hourly.sh`：⑨ 复判补报（标题、分布查的是被复判的小时、sent / hits / health、去重）；⑩ 跨 UTC 日（前一日重取、基线并集、PostHog 一条查询）；四个变异（去掉补报 / 去掉并集 / 去掉跨日重取 / plan 顺序颠倒）各自变红
- [x] 2.3 用生产 STATE 只读副本在本机回放 2026-11-26 21:00（2026-11-27）：复判 20 点激增 3 个（lottie 19 / auth/logout 14 / membership/current 10，与 GA4 原表独立核对一致）——lottie 当晚已报、去重；auth/logout 21 点也激增，进 21 点卡并写「从 20:00 起持续」；membership/current 发复判补报卡。两张卡实发维护者私聊，读回发现复判卡配置行写「本小时」→ 改「该小时」并补断言
- [x] 2.4 `check-scripts.sh` 十项全绿

- [x] 2.5 crash-reviewer 审查（2026-11-27）的修复：#1 先发本小时卡、复判一侧失败不连累（⑨a / ⑨b）；#2 复判去重按被复判小时结束时刻（⑨d）；#3 回放旧小时不改状态（core 断言）；#4 汇总说明写进 deploy-prod；#5 费用说法统一；#6 跳过投递时日志只列实际写了的卡片文件；#7 补 ⑨a–⑨d。六个变异各自变红
- [x] 2.6 修复后用新拉的生产状态副本再回放 11-26 21:00：结果同 2.3，投递顺序为先本小时、后复判；新版复判卡换幂等键实发私聊（同键时飞书去重返回旧消息，不会真发），`raw_card_content` 读回逐项与本地 last-card-recheck.json 一致（标题、表头「该小时」、10 台 · 4 账号 / 0.7 / 10×、分布、配置行、脚注）

## 3. 文档与上线

- [x] 3.1 docs/CLAUDE-部署与运维.md、docs/CLAUDE-架构与数据口径.md、crash-report-debug / morning-verify skill 同步
- [ ] 3.2 提交、推送（问维护者）；日报机 `update.sh`（问维护者）
