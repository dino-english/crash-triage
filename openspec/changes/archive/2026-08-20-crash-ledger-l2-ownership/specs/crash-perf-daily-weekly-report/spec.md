## ADDED Requirements

### Requirement: L1 与 L2 的职责边界

L1 MUST 只负责高频数据呈现，MUST NOT 产出分析、结论或台账；L2 MUST 负责分析与结论沉淀，并独占台账的产出与同步。

#### Scenario: 崩溃结论的产生

- **WHEN** 某崩溃 issue 的处置结论需要更新
- **THEN** 该更新只能由 L2 链路写入台账
- **AND** L1 不参与

#### Scenario: 性能数据的呈现

- **WHEN** 性能指标需要呈现
- **THEN** L1 呈现日维度当期值
- **AND** L2 呈现周维度趋势
- **AND** 两者口径差异被显式标明，MUST NOT 直接混比

## MODIFIED Requirements

### Requirement: 两条自动化报告链路

系统 SHALL 提供两条相互独立的无人值守报告链路：L1 每日数据日报与 L2 每周变化播报，均产出发送到飞书群「Dino 崩溃 & 性能日/周报」。两条链路 MUST 各自定时触发、独立失败、互不阻塞。台账 MUST 只属于 L2 的产出物。

#### Scenario: 每日数据日报

- **WHEN** 到达每日触发时刻（默认本地时区 07:00）
- **THEN** L1 查询 BigQuery 性能数据与 Crashlytics 崩溃数据，生成日报并发送到飞书群
- **AND** 产出群卡片、当日日报文档与重建后的索引页
- **AND** MUST NOT 生成、投递或镜像台账
- **AND** 索引页中的台账以固定地址单独列出，其内容 MUST NOT 由 L1 产生

#### Scenario: 每周变化播报

- **WHEN** 到达每周触发时刻（默认每周一本地时区 05:30）
- **THEN** L2 抓取崩溃快照，与上一周快照做变化检测，生成播报并发送到飞书群
- **AND** 新建独立的周报文档（快照性质，需留痕可跨版本 diff）
- **AND** 在索引页的报告归档中追加一行
- **AND** MUST 同步台账
- **AND** 周报 MUST 同时含崩溃段与性能段

#### Scenario: 触发时间错开

- **WHEN** 两条链路的触发时间在同一台机器上安排
- **THEN** L2 与 L1 MUST 至少间隔 60 分钟以上
- **AND** 原因：L2 完整 triage 实测 12 分钟以上，且两者都调 lark-cli 会加剧限流（实测撞过 429）

### Requirement: 只读约束——不写业务仓库

两条链路 MUST 只通过只读 clone 访问业务仓库，MUST NOT 向任何业务仓库写入、commit、push 或安装钩子。

#### Scenario: git 反查修复状态

- **WHEN** 日报/周报需要判定某个 issue 的修复状态
- **THEN** 在只读 clone 上按 commit message 的崩溃标识约定反查
- **AND** 只读 clone MUST 是 `repos/` 下的独立副本，绝不能指向任何人的工作仓库
- **AND** 同步只读 clone 的 `git reset --hard` MUST 只作用于 `repos/` 下的 clone

#### Scenario: 台账更新

- **WHEN** 需要更新崩溃台账（LEDGER）
- **THEN** 由 L2 链路写入其本地台账源并同步到飞书台账文档
- **AND** MUST NOT 向任何业务仓库写入台账文件
- **AND** MUST NOT 在业务仓库安装任何钩子来触发台账更新

### Requirement: L2 自动档不产出根因与修复方案

L2 自动档产出根因与修复方案的边界按段落区分：崩溃段 MAY 产出根因与修复方案，但 MUST 标注未经人工复核；性能段 MUST NOT 产出根因或修复方案。任何自动产出的结论 MUST NOT 被后续跑批当作已验证事实使用。

原表述「L2 自动档一律不出根因」与实测不符：L2 崩溃段实际产出含风险分级与钻取确认的分析。禁止的不是分析本身，而是把未经复核的推断当结论沉淀。

#### Scenario: 根因分析留给人工

- **WHEN** 需要把某个崩溃的根因或修复方案作为已确认结论落进台账
- **THEN** MUST 由人复核后确认，自动档 MUST NOT 直接写入
- **AND** 理由：自动生成的方案可能看似合理实则错误，若被当作已确认结论会在下一轮被误判为「已修复」，错误自我强化

#### Scenario: 崩溃段产出分析

- **WHEN** L2 崩溃段对某 issue 给出根因判断或修复方案
- **THEN** MUST 在该内容处标注未经人工复核
- **AND** MUST NOT 据此改写台账的处置状态列

#### Scenario: 性能段不出根因

- **WHEN** 性能指标出现劣化
- **THEN** MUST NOT 产出根因判断或修复方案
- **AND** 只给出趋势、可定位对象与下一步取证方向

#### Scenario: 结论不自我强化

- **WHEN** 上一轮产出过某 issue 的根因推断
- **THEN** 本轮 MUST NOT 因存在该推断而判定其为「已修复」
- **AND** 修复状态只能由代码提交事实驱动

#### Scenario: 报告标注未经复核

- **WHEN** 周报附带完整报告文档
- **THEN** 卡片 MUST 标注「未经人工复核，落地前须验证」

### Requirement: 告警判定

日报 SHALL 在命中任一告警条件时在卡片顶部输出 🔴 告警块。告警 MUST 只在有事实依据时触发，MUST NOT 因某平台缺少判定依据而产生噪音。

#### Scenario: 新增 issue

- **WHEN** 今日快照中出现昨日基准之外的新 issue
- **THEN** 输出「🔴 iOS/Android 新增 N 个 issue」

#### Scenario: 已修未发版

- **WHEN** 存在已识别到修复提交、但含修复的版本尚未上线的 issue
- **THEN** 输出「🔴 N 个 issue 代码已修但未发版」
- **AND** 该判定对 iOS 与 Android 使用同一口径

#### Scenario: 无判定依据不告警

- **WHEN** 某 issue 在回溯窗口内没有携带崩溃标识的提交
- **THEN** MUST NOT 就其修复状态发出告警

#### Scenario: 接口错误率异常

- **WHEN** 自家 API 网络错误率 > 0
- **THEN** 输出「🔴 接口错误率 N%」

## REMOVED Requirements

### Requirement: 台账真相源是仓库文件

**Reason**: 前提已被证伪。`ab6748b` 把 iOS 仓库台账复制进 crash-triage 后未删原件，iOS 团队继续更新原件（`b8522526`），三份台账已分叉（153 / 98 / 70 行），「仓库文件是真相源」在生产中从未成立。台账真相源改由 L2 产出，只读镜像模型随之作废。

**Migration**: 台账的产出方、结构与同步方式由新能力 `crash-perf-ledger-ownership` 定义。旧台账文件保留在各业务仓库内供查阅，不迁移、不删除；新台账从零建立基线（项目常量与收口点登记两段例外迁移）。飞书台账文档 `TtpwdhgKroMH1DxJumojTflrppz` 复用，「请勿在此编辑」的只读镜像语义不再适用。

### Requirement: 修复状态判定口径

**Reason**: 该口径把双端结构性差异写死为契约——iOS 靠 32 位 issue ID 反查、Android 恒为不可判定。实测两端惯例均不满足该前提：iOS 把 32 位标识写在源码注释而非 commit message，Android 在 message 用 8 位短标识，`git log --grep=<32位id>` 在双端都命中不到，「iOS 可判定」本身不成立。

**Migration**: 修复状态判定整体移交新能力 `crash-perf-fix-status-reconcile`，改用双端统一的 `[crash:<8位id>]` commit message 约定与跑批期反扫。原口径中「无依据时显示为不可判定而非未修、且不因此告警」的行为在新能力中保持不变。告警条件「已修未发版」随之改由新能力提供的状态列驱动。

### Requirement: 索引页与台账镜像过渡

**Reason**: 过渡态两端均已了结。索引页的「固定 ID 覆盖」已由 `crash-perf-deterministic-delivery` 落地（换 lark-cli 后不再受 `docx_builtin_import` 只能新建的限制）；台账镜像则被整体取消，L1 不再承担台账职责。

**Migration**: 索引页行为以 `crash-perf-deterministic-delivery` 的「文档组织与归档」为准；台账行为以 `crash-perf-ledger-ownership` 为准。不再存在「台账镜像待办」这一过渡状态，产出中 MUST NOT 再出现台账镜像的待办声明。
