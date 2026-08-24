## ADDED Requirements

### Requirement: TOP N issue 的多维下钻

周报 MUST 为最严重的若干 issue 各提供一个下钻块，回答「这个 issue 影响谁、集中在哪」。

每块 MUST 含：规模（事件 / 安装 / 集中度）、崩溃页面、前后台分布、机型判定、系统版本、内存档、责任帧。

排序 MUST 按受影响安装降序，MUST NOT 按集中度排序——集中度的分母是安装数，按它排会选出全是单设备的榜单。

#### Scenario: 某端主要错误类型不是致命崩溃

- **WHEN** 某端在窗口内的致命事件不足以支撑 TOP N
- **THEN** MUST 改用该端主要错误类型口径，并在该段标注所用口径
- **AND** 两端的块 MUST NOT 被并读为同一指标

#### Scenario: 下钻取数失败

- **WHEN** 下钻取数未能返回数据
- **THEN** MUST 明确渲染为「取数失败，本段缺失」
- **AND** MUST NOT 渲染为「本窗口无可下钻的 issue」——那会把故障读成好消息

### Requirement: 机型 MUST NOT 作为 per-issue 的结论呈现

per-issue 的机型分布 MUST NOT 以「top 机型」的形式作为结论。MUST 先判定是否存在机型特异性，并区分三种情形：样本仅一台设备、确实集中、分散。

理由：实测 per-issue 的唯一机型数 ≈ 影响安装数（一设备一机型），此时「top 机型」只是随机一台设备。同批数据里页面集中度 58%–100%、机型仅 19%–33%。

#### Scenario: 只影响一台设备

- **WHEN** 某 issue 的受影响安装数为 1
- **THEN** MUST 说明样本仅一台、判不了机型特异性、需复现
- **AND** MUST NOT 呈现为「集中于该机型」——那与「只有一台设备」是同一句话
