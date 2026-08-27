## ADDED Requirements

### Requirement: 跑批失败 MUST 以非零退出码可见

任何未完成的跑批 MUST 以非零退出码结束。清理型 EXIT trap MUST NOT 使失败的退出码变为 0。

理由：实测在生产解释器（bash 3.2）上，未定义变量这条致命路径进入 EXIT trap 时退出状态已丢失为 0；若 trap 的最后一条命令返回 0，整脚本即以 0 结束。该失败模式恰是本仓库最常见的一种，且 ERR trap 不触发、健康文件停留在上一轮的成功状态——三重静默。

#### Scenario: 脚本中途因未定义变量终止

- **WHEN** 跑批因未定义变量在中途终止
- **THEN** 退出码 MUST 非零
- **AND** MUST NOT 依赖读取退出状态来判定（该状态此时已不可靠），MUST 以「是否执行到完成点」为判据

#### Scenario: 合法的提前退出

- **WHEN** 存在预期内的提前成功退出路径（如预览模式、仅重发）
- **THEN** 该路径 MUST 先标记完成，退出码 MUST 为 0
