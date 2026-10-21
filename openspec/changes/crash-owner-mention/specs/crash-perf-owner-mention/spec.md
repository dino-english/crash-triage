## ADDED Requirements

### Requirement: 紧急项按模块 @ 负责人

日报 🚨 紧急与周报 🚨 必修的每一条 SHALL 附该条的负责人 @ 及归属依据。⏳ 等发版 / 👀 观察 MUST NOT @ 任何人。

理由：三档改版后紧急项可见但未落到人；负责人表由团队提供（2026-10-21）。

#### Scenario: 能归到模块

- **WHEN** 一条 🚨 按归属规则命中某模块
- **THEN** MUST @ 该模块在对应平台的负责人，并写明模块与依据（修复 scope / 责任帧 / SDK / 页面）

#### Scenario: 归不到模块

- **WHEN** 所有信号都不命中
- **THEN** MUST @ 该平台的 `crash_fallback`，并写明「兜底」

#### Scenario: 负责人不可用

- **WHEN** 模块负责人未配置或不在群
- **THEN** MUST 改 @ 该平台的 `platform_fallback`
- **AND** 若兜底也取不到，MUST 不 @ 并在该条写明「负责人未配置」——⛔ 不得静默省略

### Requirement: 归属判定为确定性规则

模块归属 SHALL 由脚本按固定优先级判定：修复提交 scope → 自家代码责任帧 → 已知 SDK 责任帧 → 页面众数 → 兜底。
规则正则 MUST 存于版本控制的内容文件，MUST NOT 由模型决定。

#### Scenario: 无信息的页面值

- **WHEN** Android `current_screen` 为 `MainActivity`
- **THEN** 该信号 MUST 视为缺失，不得据此归属

### Requirement: 负责人配置不含姓名

负责人配置 SHALL 只存模块键、平台与 open_id，MUST NOT 含人员姓名。

#### Scenario: 增改负责人

- **WHEN** 负责人变更
- **THEN** 只改 `notes/owners.tsv` 对应行的 open_id，MUST NOT 改代码

### Requirement: 跑批失败告警 @ 维护人

`alert.sh` 发出的跑批失败卡片 SHALL @ 两端 `monitor_maintainer`。

#### Scenario: 跑批失败

- **WHEN** 日报或周报跑批失败并发出告警卡
- **THEN** 卡片 MUST @ 两端 `monitor_maintainer`

### Requirement: 周报呈现模块归属覆盖率

周报 SHALL 给出两端近 7 天受影响设备中能归到具体模块的占比；日报 MUST NOT 呈现该项。

#### Scenario: 某端样本过小

- **WHEN** 某端受影响设备不足 10 台
- **THEN** MUST 只给分数，MUST NOT 给补埋点建议——10-21 iOS 0/3 台触发过建议，3 台说明不了埋点缺失

#### Scenario: 某端覆盖率低

- **WHEN** 某端能归到具体模块的设备占比低于 50%，且该端受影响设备 ≥ 10 台
- **THEN** 周报 MUST 附一句补埋点建议（在崩溃 custom keys 补模块 / 路由字段）
