# crash-perf-daily-weekly-report Specification

## Purpose

定义 L1 日报与 L2 周报两条链路的顶层契约：各自的触发、产出与职责边界，对业务仓库的只读约束，L2 自动档不越界给根因与修复方案，以及变化检测、发送状态三态、数据截止标注、告警判定、崩溃数据源过渡与 NON_FATAL 维度展示的共同约束。

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

### Requirement: 三类事件必须可区分前后台

报告 MUST 能区分崩溃事件发生在前台还是后台。当某端某类事件绝大多数发生在后台时，MUST 显式说明，MUST NOT 让读者按「事件总数」判断严重度。

理由：实测 iOS 非致命 995 次中 981 次（98.6%）发生在后台，用户无感；同窗口 Android 95 次中 93 次在前台。只看总数会得出「iOS 问题比 Android 多一个数量级」的相反结论。

#### Scenario: 某端某类事件以后台为主

- **WHEN** 某端某类事件的后台占比达到阈值且样本量足够
- **THEN** MUST 输出说明，含总数、后台数与占比
- **AND** 文案 MUST NOT 表述为「无需处理」——后台崩溃仍会中断上传、推送与预加载

#### Scenario: 前台事件数为 0

- **WHEN** 某类事件全部发生在后台
- **THEN** 前台 MUST 渲染 `0`
- **AND** MUST 与「状态未知」用不同符号区分

#### Scenario: 前后台状态取不到

- **WHEN** 事件既无 `process_state` 也无前后台自埋值
- **THEN** MUST 计入独立的「未知」计数，MUST NOT 并入前台或后台任一侧

### Requirement: 前后台只给绝对数不给率

前后台分布 MUST 只呈现绝对数与占该类事件的比例，MUST NOT 呈现「前台崩溃率」一类以会话为分母的比率。

理由：`firebase_sessions` 表无 `process_state` 字段，前后台的会话分母不存在。MUST NOT 借用其他数据源的样本量充当分母。

#### Scenario: 有人要求前台崩溃率

- **WHEN** 需要「前台崩溃率」
- **THEN** MUST 拒绝并说明会话分母不存在
- **AND** MUST NOT 使用性能表的屏幕 trace 样本数等其他总体作为替代分母

### Requirement: 周报文档构成——数据层段落不得被分析层替换

L2 周报投递的文档 MUST 同时包含数据层段落与（若本轮产出了）分析层段落。数据层段落 MUST NOT 因分析层成功而从投递物中消失。

数据层段落指由确定性脚本产出、不经模型的内容：取数区间与 run_id、本周变化、主力版本指标、影响面维度分布、性能趋势、口径注记。

理由：分析层产物按 triage skill 自己的模板成文，其 prompt 从未要求携带维度与指标；两者互斥投递会让「分析越成功、数据面越空」。实测 2026-08-20 投递文档 30,991 字符，主力版本 / 性能 / crash-free / 系统版本 / 取数区间命中数均为 0。

#### Scenario: 分析层跑通

- **WHEN** 本轮 L2 产出了根因分析报告
- **THEN** 投递文档 MUST 以数据层周报为主干
- **AND** 分析层内容 MUST 作为独立段落追加，且该段标题 MUST 标注未经人工复核
- **AND** 取数区间、run_id 与口径注记 MUST 位于文档头部

#### Scenario: 分析层缺失

- **WHEN** 本轮无分析报告（模型不可用 / 超时 / 显式跳过）
- **THEN** 投递文档为数据层周报本体
- **AND** MUST 保留「本周无深度分析 — 原因」的显式注记

#### Scenario: 合并不得改动分析层的标题层级

- **WHEN** 把分析层内容并入投递文档
- **THEN** MUST NOT 调整其内部标题的层级
- **AND** 理由：下游 `split-fix-list.py` 以二级标题定位「修复清单」段，降级会使其静默失效——找不到段落即原样返回，无退出码、无告警

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
