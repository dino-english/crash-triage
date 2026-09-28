## MODIFIED Requirements

### Requirement: Issue 现状表为双端单表

⚠️ 原条文（双端不拆表、靠「平台」列区分）**一字不改**，本次只追加一条同构的约束：
类型也不拆表，靠已有的「类型」列区分。

Issue 现状表是一张表，iOS 与 Android 的条目共存于其中，通过「平台」列区分。
MUST NOT 按平台拆成多张表或多份文档。

FATAL 与 ANR 的条目 MUST 共存于这张表中，通过「类型」列区分，MUST NOT 按类型拆表。

⛔ NON_FATAL 仍然单独成表，理由是**量级**而非类型：实测 iOS 14 天 1020 条，
混排会把十几条 FATAL 淹没，而台账最主要的用途正是「一眼看出有几个致命问题」。
ANR 过影响面阈值后是个位数，不构成淹没。

#### Scenario: 双端均有 issue

- **WHEN** 本轮取到 iOS 与 Android 的 issue
- **THEN** 两端条目出现在同一张表中
- **AND** 每行标明所属平台

#### Scenario: 单端无 issue

- **WHEN** 某一端本轮无 issue
- **THEN** 表中仅出现另一端的条目
- **AND** 不因此拆表或省略平台列

#### Scenario: 同表内同时存在 FATAL 与 ANR

- **WHEN** 本轮既有 FATAL 条目又有过阈值的 ANR 条目
- **THEN** 两类出现在同一张表中，各行「类型」列如实标明
- **AND** MUST NOT 因类型不同而拆表

#### Scenario: ANR 多到淹没 FATAL

- **WHEN** 过阈值的 ANR 条目数超过 FATAL 条目数
- **THEN** 拆表的前提条件成立，可另行开 change 处理
- **AND** 在那之前 MUST NOT 预先拆表
