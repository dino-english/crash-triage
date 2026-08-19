## Purpose

定义修复状态的自动对账机制：通过约定的 commit message 标记，在跑批时反扫业务仓库的提交历史，自动更新台账中各 issue 的处置状态，无需在业务仓库安装任何钩子。

## ADDED Requirements

### Requirement: commit message 携带崩溃标识

修复某崩溃 issue 的提交，其 message MUST 包含该 issue 的短标识，格式为方括号包裹的 `crash:` 前缀加 8 位十六进制标识。

#### Scenario: 提交带合规标记

- **WHEN** 提交 message 含 `[crash:<8位十六进制>]`
- **THEN** 该提交被识别为对应 issue 的修复提交

#### Scenario: 提交无标记

- **WHEN** 提交 message 不含该标记
- **THEN** 该提交不参与修复状态对账
- **AND** 不产生告警

### Requirement: 反扫在跑批期进行，不侵入业务仓库

修复状态对账 MUST 在流水线自身的跑批过程中完成， MUST NOT 在业务仓库安装提交钩子或写入任何文件。

#### Scenario: 跑批执行对账

- **WHEN** 跑批链路运行到修复状态对账步骤
- **THEN** 以只读方式扫描两个业务仓库的提交历史
- **AND** 业务仓库的工作区与提交历史不被修改

#### Scenario: 业务仓库不可读

- **WHEN** 某个业务仓库无法读取提交历史
- **THEN** 对账跳过该平台并在产出中显式标明
- **AND** 另一平台的对账照常进行

### Requirement: 对账幂等且可补漏

对账 MUST 在固定回溯窗口内重复扫描，同一提交多次扫到不产生重复记录，漏过一轮的提交在下一轮仍可被捕获。

#### Scenario: 同一提交被多轮扫到

- **WHEN** 某修复提交在连续多轮跑批中都落在回溯窗口内
- **THEN** 台账中该 issue 只记录一次修复提交
- **AND** 重复扫描不改变台账内容

#### Scenario: 上一轮跑批失败

- **WHEN** 上一轮跑批未执行对账
- **AND** 该窗口内存在修复提交
- **THEN** 本轮对账仍能识别该提交

### Requirement: 对账只更新机器可判定的列

对账 MUST 只改写由代码提交事实推导出的字段， MUST NOT 覆盖结论性判断。

#### Scenario: 识别到修复提交

- **WHEN** 某 issue 被识别出修复提交
- **THEN** 其处置状态更新为「已修待验」并记录提交标识
- **AND** 该行的既有结论性备注保持不变

#### Scenario: issue 线上仍在发生

- **WHEN** 某 issue 已有修复提交
- **AND** 本轮线上仍有新事件
- **THEN** 状态标注为「修了仍在」
- **AND** 不擅自判定为已修复

### Requirement: 标识匹配须避免误判

短标识匹配 MUST 限定在约定格式内， MUST NOT 因提交 message 中出现相似字符串而误判。

#### Scenario: message 含相似但非标记的字符串

- **WHEN** 提交 message 含 8 位十六进制但不在 `[crash:...]` 格式内
- **THEN** 不被识别为修复提交

#### Scenario: 短标识对应多个 issue

- **WHEN** 某 8 位短标识在当前 issue 集合中匹配到多于一个
- **THEN** 不自动更新任何一个
- **AND** 在产出中标明该歧义待人工确认
