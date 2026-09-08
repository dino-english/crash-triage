## MODIFIED Requirements

### Requirement: NON_FATAL 维度展示

日报 SHALL 展示 NON_FATAL（非致命异常）维度：双端各自的事件量与 TOP issue，按版本分列。

NON_FATAL MUST 独立成段，MUST NOT 并入崩溃次数、崩溃率或受影响安装——后三项保持致命口径，其历史序列与台账均按该口径积累。

报告 MUST NOT 以静态文案断言任一端的上报状态。上报通路是否已发版、线上是否有数据，MUST 由当轮实测数据决定：有数据即呈现数据，无数据走既有的缺数三态判定。通路覆盖范围的已知限制 MAY 作为附注呈现，但 MUST NOT 取代实测数字。

#### Scenario: iOS 通路建设中

- **WHEN** 某端的 NON_FATAL 上报通路已知未完整覆盖（收口点未铺满）
- **THEN** 日报在该端的 NON_FATAL 数字旁标注「通路覆盖不完整，数量级不代表真实异常量」
- **AND** MUST NOT 把较小的数字读成该端更稳
- **AND** 该标注 MUST 描述通路覆盖范围，MUST NOT 断言线上是否有数据——后者由实测决定

#### Scenario: 通路发版后

- **WHEN** 某端的 NON_FATAL 上报通路已发版且线上有数据
- **THEN** 呈现该端的 NON_FATAL 事件量与 TOP issue
- **AND** 移除一切「建设中 / 零上报」的断言

#### Scenario: 某端窗口内无 NON_FATAL 事件

- **WHEN** 某端有会话数据但窗口内无 NON_FATAL 事件
- **THEN** 呈现为零值
- **AND** MUST NOT 把零值单独读成「该端更稳」

#### Scenario: 双端数字并列

- **WHEN** 双端 NON_FATAL 数字并列呈现
- **THEN** MUST 标注两端的上报通路差异（收口点覆盖范围不同会使数量级不可比）
- **AND** MUST NOT 让读者据此直接比较两端稳定性
