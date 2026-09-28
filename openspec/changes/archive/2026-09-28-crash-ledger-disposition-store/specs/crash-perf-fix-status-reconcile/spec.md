## ADDED Requirements

### Requirement: 对账范围须对每张现状表有确定答案

修复状态反扫的适用范围 MUST 对台账中每一张现状表显式给出答案，MUST NOT 留白。本轮确定：Issue 现状表纳入对账；NON_FATAL 现状表 **不纳入**。

不纳入的理由 MUST 记录在案，且 MUST NOT 被理解为「NON_FATAL 无需跟踪修复状态」——其修复状态由人工结论承载。

#### Scenario: 反扫命中某 NON_FATAL issue 的标识

- **WHEN** 某提交 message 携带的标识对应一个 NON_FATAL issue
- **THEN** 不改写该 issue 在 NON_FATAL 现状表中的任何列
- **AND** MUST NOT 覆盖其人工结论

#### Scenario: 人工结论与反扫结果并存

- **WHEN** 某 issue 同时存在人工结论与可识别的修复提交
- **THEN** 人工结论 MUST 保持不变
- **AND** 机器可判定字段与人工结论 MUST 在呈现上可区分来源

### Requirement: 不遵守标识约定的修复提交须可被识别为对账盲区

对账依赖提交 message 中的约定标识。未携带标识的修复提交 MUST NOT 被当作「该 issue 未修复」的证据。

理由：2026-09-23 实测 `847a280c`（修复 `359fadbc`，已验证线上生效）的 message 既无 `[crash:<8位id>]` 也无 32 位标识，按 `git log --grep` 完全查不到；而 `21ef358b` 携带 32 位标识可被识别。若把「查不到」读成「未修复」，会得出与线上事实相反的结论。

#### Scenario: 修复提交未携带标识

- **WHEN** 某 issue 的实际修复提交未携带约定标识
- **THEN** 其修复状态停留在上一轮，标注为「对账未覆盖」
- **AND** MUST NOT 标注为「未修复」

#### Scenario: 人工已确认修复但对账无记录

- **WHEN** 人工结论已判定某 issue 修复生效，而对账未识别到修复提交
- **THEN** 以人工结论为准呈现
- **AND** MUST NOT 因对账无记录而推翻人工结论
