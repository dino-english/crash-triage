## ADDED Requirements

### Requirement: 生命周期与开关状态必须分列

issue 明细表 MUST 把**生命周期**（新增 / 回归 / 长期，由流水线自己的历史快照判定）
与 **Crashlytics 开关状态**（OPEN / CLOSED / MUTED，由 issue 查询取得）分列呈现。

两者正交：一个 CLOSED 的 issue 可以同时是「长期」，一个 OPEN 的 issue 可以是「新增」。
⛔ 列名 MUST NOT 使用会被误读为对方的措辞——原「状态」列 MUST 改名为「生命周期」。

同一张表的**每一个渲染点**都 MUST 同改：其中一处是 DRY RUN 预览，
即验收工具本身，只改另一处会让预览显示的东西与实际发出的不一致。

#### Scenario: issue 已关闭但窗口内仍在发生

- **WHEN** 某 issue 状态为 CLOSED，且在明细表中有事件行
- **THEN** 开关列 MUST 标注为已关闭
- **AND** 生命周期列 MUST 照常给出其新增 / 回归 / 长期判定
- **AND** 该行 MUST NOT 因已关闭而被剔除或降序

#### Scenario: 开关状态取不到

- **WHEN** 某 issue 的开关状态既不在缓存中、本轮也未查到
- **THEN** 开关列 MUST 渲染为可与三种已知状态区分的缺失态
- **AND** MUST NOT 留空

#### Scenario: 出现未知的状态取值

- **WHEN** 查询返回的状态不属于已知三态
- **THEN** MUST 原样透传该取值
- **AND** MUST NOT 归并到任一已知状态
