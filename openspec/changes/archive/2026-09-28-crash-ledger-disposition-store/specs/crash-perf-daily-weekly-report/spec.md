## MODIFIED Requirements

### Requirement: L1 与 L2 的职责边界

L1 MUST 只负责高频数据呈现，MUST NOT 产出分析、结论或台账；L2 MUST 负责分析与结论沉淀，并独占台账的产出与同步。

「产出结论」与「呈现结论」是两件事：L2 MAY 在周报正文中呈现已沉淀的处置结论；L1 MUST NOT 呈现处置结论，因为在日报中呈现结论会使读者无法分辨该判断出自当期数据还是既往沉淀。

#### Scenario: 崩溃结论的产生

- **WHEN** 某崩溃 issue 的处置结论需要更新
- **THEN** 该更新只能由 L2 链路写入台账
- **AND** L1 不参与

#### Scenario: 崩溃结论的呈现

- **WHEN** 某 issue 已有人工处置结论
- **THEN** L2 周报 MAY 在其正文中呈现该结论
- **AND** L1 日报 MUST NOT 呈现该结论
- **AND** 周报呈现时 MUST 标明结论为人工沉淀，非当期数据推导

#### Scenario: 性能数据的呈现

- **WHEN** 性能指标需要呈现
- **THEN** L1 呈现日维度当期值
- **AND** L2 呈现周维度趋势
- **AND** 两者口径差异被显式标明，MUST NOT 直接混比

## ADDED Requirements

### Requirement: 周报 NON_FATAL 段呈现处置结论

周报呈现 NON_FATAL issue 时，MUST 一并呈现该 issue 已沉淀的处置结论。结论 MUST 取自处置结论存储，MUST NOT 由当期数据推断生成。

理由：iOS 主力版本 FATAL 常年为 0，周报的 iOS 段本就以 NON_FATAL 为主口径。结论只存在于台账时，周报读者需另行跳转才能知道某条是否已被复核判定为假警报。

#### Scenario: NON_FATAL issue 已有结论

- **WHEN** 周报呈现某 NON_FATAL issue 且其在结论存储中有记录
- **THEN** 该结论随其数据一并呈现
- **AND** 明确标示为人工结论

#### Scenario: NON_FATAL issue 无结论

- **WHEN** 某 NON_FATAL issue 在结论存储中无记录
- **THEN** 仅呈现其数据
- **AND** MUST NOT 以空白暗示「无问题」或「已处理」

#### Scenario: 结论存储不可得

- **WHEN** 周报生成时结论存储缺失或损坏
- **THEN** 周报照常产出 NON_FATAL 数据段
- **AND** MUST 标明结论不可得
- **AND** MUST NOT 因此中止周报投递
