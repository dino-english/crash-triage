## ADDED Requirements

### Requirement: 三类事件必须可区分前后台

报告 MUST 能区分崩溃事件发生在前台还是后台。当某端某类事件绝大多数发生在后台时，MUST 显式说明，MUST NOT 让读者按「事件总数」判断严重度。

理由：实测 iOS 非致命 995 次中 981 次（98.6%）发生在后台，用户无感；同窗口 Android 95 次中 93 次在前台。只看总数会得出「iOS 问题比 Android 多一个数量级」的相反结论。

#### Scenario: 某端某类事件以后台为主

- **WHEN** 某端某类事件的后台占比达到阈值且样本量足够
- **THEN** MUST 输出说明，含总数、后台数与占比
- **AND** 文案 MUST NOT 表述为「无需处理」——后台崩溃仍会中断上传、推送与预加载

#### Scenario: 前台事件数为 0

- **WHEN** 某类事件全部发生在后台
- **THEN** 前台 MUST 渲染 `0`
- **AND** MUST 与「状态未知」用不同符号区分

#### Scenario: 前后台状态取不到

- **WHEN** 事件既无 `process_state` 也无前后台自埋值
- **THEN** MUST 计入独立的「未知」计数，MUST NOT 并入前台或后台任一侧

### Requirement: 前后台只给绝对数不给率

前后台分布 MUST 只呈现绝对数与占该类事件的比例，MUST NOT 呈现「前台崩溃率」一类以会话为分母的比率。

理由：`firebase_sessions` 表无 `process_state` 字段，前后台的会话分母不存在。MUST NOT 借用其他数据源的样本量充当分母。

#### Scenario: 有人要求前台崩溃率

- **WHEN** 需要「前台崩溃率」
- **THEN** MUST 拒绝并说明会话分母不存在
- **AND** MUST NOT 使用性能表的屏幕 trace 样本数等其他总体作为替代分母
