## ADDED Requirements

### Requirement: ANR 必须有处置跟踪通路

进入台账的 ANR issue MUST 与 FATAL 一样具备首次纳入日期、处置状态与开关状态，
其处置状态 MUST 由同一套提交反扫与 issue 状态同步驱动。

理由：2026-09-22 实测 Android 按受影响安装排第一的是 ANR `4d05f9e7`
（20 事件 / 16 安装 / 跨三个版本 / 当天仍在发生），影响面是头号 FATAL 的两倍，
而台账当时一条 ANR 都没有——最该被跟进的问题反而是唯一没有跟进记录的。

#### Scenario: ANR 有对应的修复提交

- **WHEN** 某 ANR issue 被提交反扫命中
- **THEN** 其处置状态按与 FATAL 相同的规则更新
- **AND** 该状态变更进入变更时间线

#### Scenario: ANR 被关闭或静音

- **WHEN** 某 ANR issue 在 Crashlytics 侧为 CLOSED 或 MUTED
- **THEN** 处置状态按开关状态渲染，与 FATAL 同规则
- **AND** MUST NOT 渲染为「未处理」

### Requirement: ANR 入选台账的判据是影响面阈值，不是 top N

ANR 进入现状表的判据 MUST 是受影响安装数达到阈值，MUST NOT 使用固定条数的 top N 榜单。

理由：2026-09-22 实测 Android ANR 7 天共 34 条，其中 **32 条受影响安装数为 1**。
在完全并列的取值上取 top N，成员资格由 issue_id 的字典序决定——新条目出现即把旧条目
挤出榜单，台账随即报出「消失」与下一轮的「回归」，而这些变化**没有任何事实对应**。

未入选的条目数 MUST 被标注，MUST NOT 静默丢弃。

#### Scenario: 长尾条目大量并列

- **WHEN** 多个 ANR issue 的受影响安装数相同且低于阈值
- **THEN** 它们一并不入选，且其总数被标注
- **AND** MUST NOT 因排序位置而使其中一部分入选

#### Scenario: 某 ANR 的影响面越过阈值

- **WHEN** 某 ANR issue 的受影响安装数首次达到阈值
- **THEN** 它进入现状表，首次纳入日期为越过阈值之日
- **AND** 该语义与 FATAL 的「首次出现之日」不同，MUST 在表下注明

#### Scenario: 取数命中安全上界

- **WHEN** ANR 取数返回的行数等于上界
- **THEN** 未入选计数 MUST 标注为「至少」而非确切值
- **AND** MUST NOT 把被上界截断的结果当作全量
