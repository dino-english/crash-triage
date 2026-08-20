## Purpose

定义投递链路的契约：投递必须是确定性的（不经 LLM）、可重复执行不产生重复投递、拒绝投递陈旧内容。

## ADDED Requirements

### Requirement: 投递不经 LLM

飞书投递 SHALL 由确定性脚本用 CLI 完成，MUST NOT 交给 LLM agent 执行。

#### Scenario: 投递步骤

- **WHEN** 执行投递
- **THEN** 导入文档、获取 URL、回填占位符、发送卡片 MUST 全部由脚本以 CLI 调用完成
- **AND** 卡片内容 MUST 原样投递，MUST NOT 被任何环节改写

#### Scenario: LLM 的保留边界

- **WHEN** 判断某环节是否该用 LLM
- **THEN** 仅「需要判断力」的环节（如周报的根因分析）MAY 使用
- **AND** 确定性 API 调用 MUST NOT 使用

### Requirement: 投递幂等

同一次运行的投递 SHALL 可重复执行而不产生重复卡片。

#### Scenario: 幂等键

- **WHEN** 发送群卡片
- **THEN** MUST 传入以 `run_id` 为值的幂等键
- **AND** 重跑投递 MUST NOT 产生第二张卡片

#### Scenario: 不再需要投递台账

- **WHEN** 保证投递不重复
- **THEN** MUST 依赖 CLI 原生幂等能力
- **AND** MUST NOT 引入由 LLM 维护的投递台账（写入方不可靠，读取方必须容错，复杂度不成比例）

### Requirement: 陈旧清单闸门

投递前 SHALL 校验清单新鲜度，陈旧则拒绝投递。

#### Scenario: 日期不符

- **WHEN** manifest 的 `day` 不等于当天
- **THEN** MUST 拒绝投递并以非零退出码报错
- **AND** MUST NOT 投递（生成脚本失败时 manifest 不会被重写，照投即发出昨天的内容）

#### Scenario: 清单必备字段

- **WHEN** 生成投递清单
- **THEN** MUST 包含 `day` 与 `run_id`

### Requirement: 投递顺序与失败隔离

投递 SHALL 按固定顺序执行，且失败 MUST NOT 影响数据生成的成功判定。

#### Scenario: 占位符先于导入

- **WHEN** 导入索引页文档
- **THEN** 其中的日报 / 台账 URL 占位符 MUST 已回填
- **AND** 导入接口只能新建不能覆盖，MUST NOT 依赖事后修改

#### Scenario: 归档追加时机

- **WHEN** 周报投递
- **THEN** 归档索引 MUST 在卡片发送成功之后追加
- **AND** MUST NOT 先追加后发送（发送失败会留下指向「已投递报告」的假记录）

#### Scenario: 失败隔离

- **WHEN** 投递失败
- **THEN** 生成脚本 MUST NOT 因此返回失败退出码（数据已落盘）
- **AND** MUST 输出告警说明可重跑投递补投

#### Scenario: 同位置导入串行

- **WHEN** 一次运行导入多份文档到同一位置
- **THEN** MUST 串行执行（并发会触发服务端冲突错误）

### Requirement: 文档组织与归档

云文档 SHALL 按目录收纳，日报与周报 SHALL 统一归档在同一份索引里。

#### Scenario: 目录结构

- **WHEN** 投递文档
- **THEN** 日报 MUST 进 `L1 日报` 子目录，周报 MUST 进 `L2 周报` 子目录，两者同属一个父目录
- **AND** 目录 MUST 按名字幂等查找（查到复用、查不到才建），MUST NOT 每次运行新建同名目录

#### Scenario: 固定文档原地覆盖

- **WHEN** 配置了索引 / 台账镜像的文档 ID
- **THEN** MUST 原地覆盖该文档，URL 保持不变
- **AND** 未配置时 MUST 沿用新建，并输出新文档 URL 供固定

#### Scenario: 统一归档

- **WHEN** 日报或周报投递成功
- **THEN** MUST 追加一条记录到同一份归档 JSONL（含 type / day / url）
- **AND** 索引页 MUST 渲染日报与周报两张归档表
- **AND** 归档文件 MUST 纳入版本控制（URL 不可再生）
