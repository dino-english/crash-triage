## 1. 崩溃率独立展示（展示层换算，不改 SQL）

- [x] 1.1 在 `crash-daily.sh` 新增崩溃率百分比换算：`crash_events/sessions*100`，awk `printf '%.2f'` 两位小数，保留原始分数；分母为 0/不可得沿用「无法计算」
- [x] 1.2 确认 `IOS_RATE`/`AND_RATE`（分数）与新增 `IOS_RATE_PCT`/`AND_RATE_PCT`（百分比）并存，供卡片结构化渲染使用
- [x] 1.3 在卡片崩溃块每端列内把崩溃率从括号附注提为独立一行（崩溃计数一行 + 崩溃率一行）

## 2. 结构化卡片 JSON 组装

- [x] 2.1 在 `crash-daily.sh` 用 jq 组装完整 interactive 卡片 `content` JSON：顶层 `header`（标题 `📊 MM-DD 崩溃 & 性能`，模板色「有告警 red / 无告警 blue」）+ 崩溃块 `column_set`(bisect) + 性能块 `column_set`(bisect) + 放量块单栏段落 + 底部 `note`（口径 + 三表截止时间戳）
- [x] 2.2 三大块各配彩色小标题（markdown `<font color>`），崩溃块两栏各含「N 类 N 次」+ 独立崩溃率行，性能块两栏各含启动 P50/P95、最差慢帧页、冻结率、接口错误率，放量块两端各一行最新版 + 会话数
- [x] 2.3 卡片末尾留「详情」占位符（`__DETAIL_URL__`），供 agent 回填文档链接
- [x] 2.4 写入 `state/publish/card.json`，manifest.json 新增 `card_file` 字段指向它
- [x] 2.5 保留 `message.md`（纯 markdown 回退/调试视图）不删

## 3. cron 投递 prompt 更新

- [x] 3.1 更新 cron L1（`4b0c7362063b`）投递步骤：读 `card.json` → 替换 `__DETAIL_URL__` 为真实文档 URL → 原样作为 `im_v1_message_create` 的 `data.content` 发送
- [x] 3.2 在 prompt 中写明回退规则：`card.json` 缺失或为空时，回退读 `message.md` 走旧单 markdown 路径
- [x] 3.3 保留硬约束「卡片内容逐字使用脚本产出，禁止改写」

## 4. 同步运行副本与校验

- [x] 4.1 同步 `bin/crash-daily.sh`（运行副本）与 `scripts/crash-report/crash-daily.sh`（git 源副本）的改动，确保一致
- [x] 4.2 `CRASH_REPORT_DRY_RUN=1` 跑脚本，`jq empty` 校验 `card.json` 合法 + 打印字节数确认 <30KB
- [x] 4.3 人工核对 DRY RUN 输出：三块分区、双端分栏、崩溃率独立行、指标数值与旧卡片完全一致（崩溃数/崩溃率分子分母/启动/慢帧/冻结/错误率/放量会话）

## 5. 实跑投递与验收

- [x] 5.1 实跑投递到私聊（`ou_xxx`）验证卡片渲染，再投到群 `oc_655033f1f85fa04f9eac25d56f056fc9` — 2026-08-20 私聊实投完成（L1 run `20260820-111100` EXIT=0），卡片渲染由 Sir 目视确认。**投群未做**：本轮所有投递刻意限定私聊，避免验证期噪音进正式群；稳态由 Hermes cron 每日 07:00 自动投群
- [x] 5.2 用户确认群卡片效果与数值 → 记录验收结论 — 2026-08-20 Sir 在私聊确认卡片效果与数值。验收结论：卡片配色、版本分列、对比列箭头方向均符合预期；期间据 Sir 反馈修掉「进度文字过长」等排版问题

> 注：5.1/5.2 为需要用户在场的投递/验收步骤——需用户提供私聊 `ou_xxx`（当前 env 仅存群 `oc_...`），且卡片渲染效果需人工肉眼确认。代码实现与 DRY RUN 校验（1-4）已全部完成，投递步骤待用户参与后执行。
