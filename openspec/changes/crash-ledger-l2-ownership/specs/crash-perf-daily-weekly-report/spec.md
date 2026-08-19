## MODIFIED Requirements

### Requirement: L1 日报产出物集合

L1 日报链路 MUST 产出群卡片、当日日报文档与重建后的索引页。台账 MUST NOT 属于 L1 的产出物。

#### Scenario: L1 完整跑批成功

- **WHEN** L1 日报链路完整跑完并投递成功
- **THEN** 产出群卡片、当日日报文档、重建后的索引页
- **AND** 不产出台账镜像

#### Scenario: 索引页呈现导航

- **WHEN** 索引页被重建
- **THEN** 标明报告的组织结构与查找路径
- **AND** 台账以固定地址单独列出，不由 L1 生成其内容

### Requirement: L2 周报产出物集合

L2 周报链路 MUST 产出周报文档、群卡片与索引页归档条目，并 MUST 同步台账、MUST 在周报中包含性能段。

#### Scenario: L2 完整跑批成功

- **WHEN** L2 周报链路完整跑完并投递成功
- **THEN** 产出周报文档、群卡片、归档条目
- **AND** 同步台账
- **AND** 周报含崩溃段与性能段

#### Scenario: 无变化的平稳周

- **WHEN** 本周相对上周无变化
- **THEN** 不发送卡片以避免播报噪音
- **AND** 台账仍按实际状态同步

### Requirement: L1 与 L2 的职责边界

L1 MUST 只负责高频数据呈现，MUST NOT 产出分析或改写结论；L2 MUST 负责分析与结论沉淀。

#### Scenario: 崩溃结论的产生

- **WHEN** 某崩溃 issue 的处置结论需要更新
- **THEN** 该更新只能由 L2 链路写入台账
- **AND** L1 不参与

#### Scenario: 性能数据的呈现

- **WHEN** 性能指标需要呈现
- **THEN** L1 呈现日维度当期值
- **AND** L2 呈现周维度趋势
- **AND** 两者口径差异被显式标明
