## 1. 实施

- [x] 1.1 `crash-weekly.sh` 的卡片调用由 `sec "iOS" ios 0` 改为 `1`（段一在卡片里是 markdown 块）
- [x] 1.2 ⛔ 表格路径不动：主力版本表与日报明细的卡片侧保持无链接
- [x] 1.3 群消息 `message.md` 也用带链接版：核实它只是 DRY RUN 预览 + 归档产物，`deliver.sh` 并不消费；
      三个消费点内容一致后，`CHANGES_MD_DOC` 已合并回 `CHANGES_MD`（⚠️ 三消费点的注释保留，F37 教训未失效）

## 2. 验收

- [x] 2.1 ⚠️ **必须实发一张卡片**到开发机 `ou_` 私聊：确认段一 id 可点、列宽无变化
- [x] 2.2 确认表格单元格仍无链接
- [x] 2.3 `bash bin/check-scripts.sh` 九项通过
- [x] 2.4 夹具：`fn-issue-identity.sh` 的「卡片版无链接」断言需按新口径改写

## 3. 文档

- [x] 3.1 `docs/CLAUDE-架构与数据口径.md` 订正「链接只进文档不进聊天侧」那句
- [x] 3.2 `docs/CLAUDE-失效模式登记.md` 增一条：卡片能力必须实发验证，且「裸 URL」与「markdown 链接」不是一回事
- [x] 3.3 归档本 change

## 实施记录（2026-09-01）

- **实发实测**（⛔ 这是本 change 唯一可接受的证据形式，已写进 spec）：
  markdown 块里的 `[2a800b33](url)` **可点、列宽无变化**；表格单元格 `lark_md` **不渲染链接**。
- 原禁令的理由「卡片单元格宽度有限，链接会挤占并触发截断」**把裸 URL 与 markdown 链接混为一谈**——
  后者只显示锚文本，与纯文本一样宽。⛔ 已归档的 `crash-report-issue-identity` 不改写，本 change 即其勘误。
- ⚠️ 实施过程中前台跑整跑被 120s 超时杀掉（CLAUDE.md 明写「整跑要 5 分钟以上，别设短超时」）。
  核实后果：未发告警、无残留进程，`weekly-metrics.jsonl` 与 `LEDGER.md` 写了一半，已从备份还原。
