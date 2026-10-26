## MODIFIED Requirements

### Requirement: 周报分档由分析层优先级契约驱动

周报的 🚨 SHALL 取自分析层产物 `priorities.json` 中的 P0 / P1 条目（P2 归 👀）。该产物 MUST 经脚本校验：数组；`issue_id` 为 32 位小写十六进制且出现在本轮 `snapshot.json`；`priority` ∈ {P0, P1, P2}。

P0 / P1 条目的 `issue_id` MUST 同时出现在本轮**数据层**快照（与「本周变化」同一窗口）；只出现在分析层快照中的条目 MUST 降为 P2。

`priorities.json` MUST NOT 成为分析层的成功判据。

#### Scenario: 契约合规

- **WHEN** `priorities.json` 校验通过且非空
- **THEN** 🚨 段 MUST 按 P0 → P1 呈现，每条带一句动作
- **AND** MUST 标注「模型分析 · 未经人工复核」

#### Scenario: 契约失效

- **WHEN** `priorities.json` 缺失、非法，或校验后为空而快照非空
- **THEN** 🚨 MUST 回落为日报分档规则（周口径数据）
- **AND** MUST 在卡片与文档显式标注「分析层优先级不可用（原因）——以下为规则判定」

#### Scenario: 编造的 issue

- **WHEN** 某条目的 `issue_id` 不在本轮快照中
- **THEN** 该条 MUST 被剔除并记日志
- **AND** MUST NOT 呈现

#### Scenario: 本周窗口内无事件的 issue

- **WHEN** 某 P0 / P1 条目的 `issue_id` 只出现在分析层快照、不在数据层快照
- **THEN** 该条 MUST 降为 P2 进 👀，理由 MUST 写明「本周窗口内无事件」及原优先级
- **AND** MUST NOT 进 🚨、MUST NOT @ 负责人
- **AND** 来源注记 MUST 写明降级条数
- **AND** 理由：topIssues 按自然日取窗（≈8 天），比数据层滚动 7×24h 宽；2026-10-26 有 3 条末次事件早于窗口的 issue 被排进 P1 并 @ 人，同卡「本周变化」却标 ✅ 消失
