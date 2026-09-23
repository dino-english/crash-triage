## MODIFIED Requirements

### Requirement: 台账图例不得把「消失」与「关闭」并列为同一态

⚠️ 原意保留：⛔ 三件事仍然 MUST NOT 压进同一格。本次只把「已关闭不可呈现」
放宽为「必须与消失分列呈现」，并补上第三态 MUTED（2026-09-22 实测存在）。

台账图例 MUST 分别定义「消失」「已修复」「Crashlytics 开关状态」三者，
MUST NOT 将其中任意两者渲染为同一格。

「消失」的含义 MUST 明确为**滚动窗口内无事件**，并显式标注其不等于已修复。

处置状态列 MUST 区分 CLOSED 与 MUTED：两者的处置含义不同——前者是「认为已了结」，
后者是「知情并主动不处理」，压成一格会让被静音的问题反复被推给人跟进。

#### Scenario: issue 在窗口内无事件

- **WHEN** 某 issue 本轮窗口内无事件
- **THEN** 标注为消失，并注明其含义为窗口内无事件
- **AND** MUST NOT 表述为已修复或已关闭

#### Scenario: issue 已被静音

- **WHEN** 某 issue 的状态为 MUTED
- **THEN** MUST 渲染为与 CLOSED 不同的状态
- **AND** MUST NOT 渲染为「未处理」或「已修待验」

#### Scenario: 处置状态列依赖的约定未被遵守

- **WHEN** 修复提交未采用约定的 issue 标记格式
- **THEN** 处置状态列停留在上一轮取值
- **AND** 图例 MUST 注明该列依赖提交约定，未被遵守时不更新
- **AND** MUST NOT 将其渲染为「未修复」
