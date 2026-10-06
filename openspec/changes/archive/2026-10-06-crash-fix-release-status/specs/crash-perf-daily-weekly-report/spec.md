## MODIFIED Requirements

### Requirement: 告警判定

日报 SHALL 在命中任一告警条件时在卡片顶部输出 🔴 告警块。告警 MUST 只在有事实依据时触发，MUST NOT 因某平台缺少判定依据而产生噪音。

#### Scenario: 新增 issue

- **WHEN** 今日快照中出现昨日基准之外的新 issue
- **THEN** 输出「🔴 iOS/Android 新增 N 个 issue」

#### Scenario: 已修未发版

- **WHEN** 存在已识别到修复提交、但含修复的版本尚未上线的 issue
- **THEN** 输出「🔴 N 个 issue 代码已修但未发版」
- **AND** 该判定对 iOS 与 Android 使用同一口径，且 MUST 与台账「处置状态」的「已修未发版」为同一判定
- **AND** MUST NOT 以「修复提交之后无新事件」代替「含修复的版本尚未上线」——前者包含修复已发版且生效的 issue，会把好消息报成告警

#### Scenario: 发版判定不可得

- **WHEN** 本轮发版判定不可得
- **THEN** MUST NOT 输出「已修未发版」告警
- **AND** MUST 在卡片标注发版判定不可得，MUST NOT 以只比时间的结果代替

#### Scenario: 无判定依据不告警

- **WHEN** 某 issue 在回溯窗口内没有携带崩溃标识的提交
- **THEN** MUST NOT 就其修复状态发出告警

#### Scenario: 接口错误率异常

- **WHEN** 自家 API 网络错误率 > 0
- **THEN** 输出「🔴 接口错误率 N%」
