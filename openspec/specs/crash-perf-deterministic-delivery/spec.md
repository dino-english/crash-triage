# crash-perf-deterministic-delivery Specification

## Purpose

定义投递链路的契约：投递必须是确定性的（不经 LLM）、可重复执行不产生重复投递、拒绝投递陈旧内容。

## Requirements

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

投递 SHALL 按固定顺序执行，且失败 MUST NOT 影响数据生成的成功判定。台账同步 MUST 排在周报卡片发送之后，且 MUST NOT 出现在日报投递链路中。

#### Scenario: 日报投递顺序

- **WHEN** 日报投递执行
- **THEN** 顺序为：导入日报文档 → 回填索引页中的日报地址 → 导入索引页 → 回填卡片中的详情与索引地址 → 发送卡片
- **AND** MUST NOT 含台账镜像的导入与地址回填

#### Scenario: 周报投递顺序

- **WHEN** 周报投递执行
- **THEN** 顺序为：导入周报文档 → 回填卡片地址 → 发送卡片 → 追加归档 → 同步台账
- **AND** 台账同步 MUST 排在卡片发送成功之后

#### Scenario: 占位符先于导入

- **WHEN** 导入索引页文档
- **THEN** 其中的日报 URL 占位符 MUST 已回填
- **AND** MUST NOT 残留任何未回填的占位符

#### Scenario: 归档追加时机

- **WHEN** 周报投递
- **THEN** 归档索引 MUST 在卡片发送成功之后追加
- **AND** MUST NOT 先追加后发送（发送失败会留下指向「已投递报告」的假记录）

#### Scenario: 失败隔离

- **WHEN** 投递失败
- **THEN** 生成脚本 MUST NOT 因此返回失败退出码（数据已落盘）
- **AND** MUST 输出告警说明可重跑投递补投

#### Scenario: 台账同步失败

- **WHEN** 周报文档与卡片均已投递成功
- **AND** 台账同步步骤失败
- **THEN** 本轮周报仍判定为成功
- **AND** 失败原因 MUST 被记录，且台账同步 MUST 可单独重跑

#### Scenario: 周报未投递成功时不追加时间线

- **WHEN** 周报文档投递失败
- **THEN** MUST NOT 追加时间线条目
- **AND** 台账保持上一轮状态

#### Scenario: 同位置导入串行

- **WHEN** 一次运行导入多份文档到同一位置
- **THEN** MUST 串行执行（并发会触发服务端冲突错误）

### Requirement: 文档组织与归档

云文档 SHALL 按目录收纳，日报与周报 SHALL 统一归档在同一份索引里。已建立过的文档 MUST 以其记录的地址原地更新，MUST NOT 重复新建。

#### Scenario: 目录结构

- **WHEN** 投递文档
- **THEN** 日报 MUST 进 `L1 日报` 子目录，周报 MUST 进 `L2 周报` 子目录，两者同属一个父目录
- **AND** 目录 MUST 按名字幂等查找（查到复用、查不到才建），MUST NOT 每次运行新建同名目录

#### Scenario: 文档记录命中

- **WHEN** 目标文档在本地文档记录中存在
- **THEN** MUST 原地更新该文档，URL 保持不变

#### Scenario: 文档记录未命中

- **WHEN** 目标文档在本地文档记录中不存在
- **THEN** 新建文档并记入文档记录
- **AND** MUST 输出可直接留档的地址清单

#### Scenario: 固定文档原地覆盖

- **WHEN** 配置了索引页的文档 ID
- **THEN** MUST 原地覆盖该文档，URL 保持不变
- **AND** 未配置时 MUST 沿用新建，并输出新文档 URL 供固定
- **AND** 台账文档 MUST NOT 按此方式更新，须走定点更新

#### Scenario: 统一归档

- **WHEN** 日报或周报投递成功
- **THEN** MUST 追加一条记录到同一份归档 JSONL（含 type / day / url）
- **AND** 索引页 MUST 渲染日报与周报两张归档表
- **AND** 归档文件 MUST 纳入版本控制（URL 不可再生）

### Requirement: 台账文档采用定点更新

台账文档的更新 MUST 区分可替换区（Issue 现状表）与只追加区（变更时间线），任何阶段 MUST NOT 整份覆盖 —— 首次建立四段结构亦以追加方式完成。

#### Scenario: 更新台账现状表

- **WHEN** Issue 现状表需要刷新
- **THEN** 只替换现状表对应区域
- **AND** 文档其余部分保持不变

#### Scenario: 追加台账时间线

- **WHEN** 本轮产生新的变更记录
- **THEN** 追加至时间线末尾
- **AND** 既有条目 MUST NOT 被改写或删除

#### Scenario: 定点更新不可用

- **WHEN** 定点更新因定位标识失效而无法执行
- **THEN** MUST 报错并中止台账同步
- **AND** MUST NOT 退化为整份覆盖

#### Scenario: 首次建立文档结构

- **WHEN** 台账文档尚未含四段式结构
- **THEN** 四段结构 MUST 以追加方式写入
- **AND** 文档中既有内容 MUST 一字不改地保留
- **AND** MUST 在写入前把原文档内容存盘备份

### Requirement: 投递前对产物断言不变量

投递前 MUST 对本轮产出的产物执行一组不变量断言，断言集 MUST 独立于「本轮改动了什么」。

断言失败 MUST 显式告警，MUST NOT 静默；同时 MUST NOT 阻止投递——数据本身正确时，
延迟或取消投递的代价大于产物增强项失效的代价。

理由：仓库原有检查覆盖代码与函数，不覆盖产物。2026-09-02 一天内三次漏检同源——
验的都是「改动是否生效」而非「产物是否正确」，导致未改动维度与有变体的维度全部落空。

#### Scenario: 产物断言失败

- **WHEN** 投递前的产物断言未全部通过
- **THEN** MUST 在跑批日志中显式列出失败项
- **AND** MUST 继续投递
- **AND** MUST NOT 触发故障告警（数据无误，失效的是增强项）

#### Scenario: 断言执行本身出错

- **WHEN** 断言脚本缺失或执行失败
- **THEN** MUST NOT 中止跑批
- **AND** 调用 MUST 位于条件上下文中，避免在 `set -e` 与 ERR trap 下产生假故障告警

#### Scenario: 断言集的取舍

- **WHEN** 决定是否新增一条断言
- **THEN** MUST 限于「实际漏过、且能机械判定」的不变量
- **AND** MUST NOT 收录靠猜想得出的断言——假阳性会训练人忽略整个检查

#### Scenario: 判据必须红绿两侧都验证

- **WHEN** 新增或修改一条断言
- **THEN** MUST 用已知违规的产物验证其变红
- **AND** MUST 用已知正确的产物验证其变绿
- **AND** 理由：只跑正向会把假阴性当通过，只跑负向会把假阳性当有效——两种错误都实际发生过
