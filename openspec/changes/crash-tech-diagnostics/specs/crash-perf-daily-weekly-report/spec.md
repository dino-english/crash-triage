# Spec Delta

## ADDED Requirements

### Requirement: L0 每小时诊断告警链路独立于日报与周报

系统 SHALL 在 L1 日报、L2 周报之外提供第三条无人值守链路 L0：每小时检查技术诊断报错并按 spec `crash-perf-tech-diagnostics` 发送告警。L0 MUST 独立定时触发、独立失败，MUST NOT 阻塞、延后或改变 L1 / L2 的运行与产出；L0 MUST NOT 生成或修改日报文档、周报文档、索引页与台账，也 MUST NOT 改写 L1 / L2 依赖的基准文件。

#### Scenario: L0 失败不影响日报

- **WHEN** 某次 L0 运行失败（查询报错或被杀）
- **THEN** 当天 08:30 的 L1 日报照常运行与投递，其内容不受影响

#### Scenario: 与 L1 / L2 时间重叠

- **WHEN** L0 的整点运行与 L1（08:30）或 L2（周一 05:30）同时在跑
- **THEN** 两者各自完成，L0 不写 L1 / L2 的运行数据文件，互不覆盖
