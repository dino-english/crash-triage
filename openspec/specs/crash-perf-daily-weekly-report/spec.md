# crash-perf-daily-weekly-report Specification

## Requirements

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

### Requirement: 变化检测确定性完成

L2 的变化检测（新增 / 暴涨 / 消失）MUST 由 jq 基于快照 JSON 确定性计算完成，MUST NOT 依赖模型判断。

#### Scenario: 首次运行建立基线

- **WHEN** L2 首次运行且无上一周快照
- **THEN** MUST NOT 把全部 issue 当「新增」播报（实测首跑会刷出 26 条）
- **AND** 标记为「建立基线」，只报总数

#### Scenario: 暴涨判定

- **WHEN** 某 issue 本周事件量达到上周的 2 倍及以上且至少 5 次
- **THEN** 判定为「暴涨」并播报

### Requirement: 发送状态三态

L2 周报 SHALL 按「建立基线 / 有变化 / 平稳」三态发送，MUST NOT 因无变化而完全静默。

原规则「无变化不发」立于周报只承载变化播报时；周报补入主力版本放量段后，平稳的一周同样有实数值，而完全静默会让读者无法区分「这周很好」与「流水线挂了」。

#### Scenario: 首次运行

- **WHEN** L2 首次运行且无上一周快照
- **THEN** MUST 发送，标题标注「建立基线」
- **AND** MUST NOT 列出新增清单（实测首跑会刷出 26 条），只报总数

#### Scenario: 有变化的一周

- **WHEN** 出现新增 / 暴涨 / 消失 / 已修待验
- **THEN** MUST 发送，卡片头部标红

#### Scenario: 平稳的一周

- **WHEN** 本周快照与上周快照相比无任何变化
- **THEN** MUST 仍然发送，标题标注「✅ 本周无新增」，头部保持蓝色
- **AND** 正文 MUST 收敛为「无变化声明 + 主力版本放量表」，MUST NOT 罗列空的变化清单
- **AND** 若同时没有根因报告，MUST NOT 另建文档（内容与卡片完全重复）

### Requirement: 数据截止时间如实标注

日报 MUST 打印数据实际截止时间戳，MUST NOT 假设「数据截至昨天」。

#### Scenario: BigQuery 每日批量同步滞后

- **WHEN** 生成日报
- **THEN** 查询并显示 BigQuery 中最新事件的时间戳作为「数据实际截止」
- **AND** 卡片与文档 MUST 标注「BigQuery 每日批量同步，非实时」

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

### Requirement: 崩溃数据源过渡

崩溃数据源 SHALL 从 Firebase MCP 的 `topIssues` 过渡到 BigQuery `firebase_crashlytics` 事件级统计；在过渡完成前，日报 MUST 标注 `topIssues` 的口径限制。

#### Scenario: topIssues 口径限制

- **WHEN** 崩溃数据仍来自 MCP `topIssues`
- **THEN** 日报 MUST 标注「只统计 OPEN 状态的 issue，被关闭的 issue 即使仍有事件也不会出现」
- **AND** 崩溃率 MUST 标注待 `firebase_sessions` 表就绪后补充

#### Scenario: 迁移到事件级统计

- **WHEN** BigQuery `firebase_crashlytics` 表就绪
- **THEN** 崩溃统计 MUST 改为事件级（BigQuery），消除「误关 issue 即从统计消失」的问题
- **AND** 崩溃率 SQL 分母用 `firebase_sessions`、分子用 `firebase_crashlytics`

### Requirement: NON_FATAL 维度展示

日报 SHALL 展示 NON_FATAL（非致命异常）维度；在 iOS NON_FATAL 通路尚未合入发版分支前，MUST 显式标注「通路建设中，数据不完整」而非展示裸数字。

#### Scenario: iOS 通路建设中

- **WHEN** iOS NON_FATAL 收口点已落地（change `ios-nonfatal-reporting`）但尚未合入发版分支
- **THEN** 日报 NON_FATAL 段 MUST 标注「🚧 建设中，数据不完整——不要按此判断 iOS 比 Android 稳」
- **AND** MUST NOT 把零值读成健康

#### Scenario: 通路发版后

- **WHEN** iOS NON_FATAL 通路合入发版并上线
- **THEN** 替换为双端 NON_FATAL 事件量与 TOP issue

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
