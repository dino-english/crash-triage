## ADDED Requirements

### Requirement: 两条自动化报告链路

系统 SHALL 提供两条相互独立的无人值守报告链路：L1 每日数据日报与 L2 每周变化播报，均产出发送到飞书群「Dino 崩溃 & 性能日/周报」。两条链路 MUST 各自定时触发、独立失败、互不阻塞。

#### Scenario: 每日数据日报

- **WHEN** 到达每日触发时刻（默认本地时区 07:00）
- **THEN** L1 查询 BigQuery 性能数据与 Crashlytics 崩溃数据，生成日报并发送到飞书群
- **AND** 日报 v1 每次新建一份飞书文档（`docx_builtin_import`，非固定 ID 覆盖）
- **AND** 重建索引页、同步台账镜像 v1 暂未实现（待办，见「索引页与台账镜像过渡」）

#### Scenario: 每周变化播报

- **WHEN** 到达每周触发时刻（默认每周一本地时区 05:30）
- **THEN** L2 抓取崩溃快照，与上一周快照做变化检测，生成播报并发送到飞书群
- **AND** 新建独立的周报文档（快照性质，需留痕可跨版本 diff）
- **AND** 在索引页的报告归档中追加一行

#### Scenario: 触发时间错开

- **WHEN** 两条链路的触发时间在同一台机器上安排
- **THEN** L2 与 L1 MUST 至少间隔 60 分钟以上
- **AND** 原因：L2 完整 triage 实测 12 分钟以上，且两者都调 lark-cli 会加剧限流（实测撞过 429）

### Requirement: 只读约束——不写业务仓库

两条链路 MUST 只通过只读 clone 访问业务仓库，MUST NOT 向任何业务仓库写入、commit 或 push。

#### Scenario: git 反查修复状态

- **WHEN** 日报/周报需要判定某个 issue 的修复状态
- **THEN** 在只读 clone 上执行 `git log --grep=<issueId>` 反查
- **AND** 只读 clone MUST 是 `repos/` 下的独立副本，绝不能指向任何人的工作仓库
- **AND** 同步只读 clone 的 `git reset --hard` MUST 只作用于 `repos/` 下的 clone

#### Scenario: 台账更新

- **WHEN** 需要更新崩溃台账（LEDGER）
- **THEN** 由开发者在修复提交时顺手更新仓库 `reports/LEDGER.md`
- **AND** 自动链路 MUST NOT 修改该文件

### Requirement: 台账真相源是仓库文件

崩溃专项台账（LEDGER）的真相源 SHALL 是仓库文件 `reports/LEDGER.md`；飞书上的在线版（v1 落地后）MUST 是只读镜像，且 MUST 带「请勿在此编辑」警告。

#### Scenario: 台账镜像同步

- **WHEN** L1 每日运行（v1 落地后）
- **THEN** 把仓库 `reports/LEDGER.md` 同步（overwrite）到飞书台账文档
- **AND** 镜像顶部 MUST 标注「请勿在此编辑」
- **AND** v1 现状：台账镜像（与索引页的「固定 ID 覆盖」）尚未实现，此 Scenario 属过渡态待办（见「索引页与台账镜像过渡」）

#### Scenario: 冲突仲裁

- **WHEN** 飞书镜像与仓库文件内容冲突
- **THEN** 以仓库文件为准

### Requirement: L2 自动档不产出根因与修复方案

L2 每周变化播报（自动档）MUST 只报告「变了什么」（新增 / 暴涨 / 消失 / 已修待验），MUST NOT 生成根因分析与修复方案。

#### Scenario: 根因分析留给人工

- **WHEN** 需要定位某个崩溃的根因或给出修复方案
- **THEN** 由人跑 `firebase-crash-triage` skill 完成
- **AND** 理由：自动生成的方案可能看似合理实则错误，且会被下一轮 `git log --grep` 误判为「已修复」，错误自我强化

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

### Requirement: 无变化不发

L2 周报 SHALL 在无任何变化时静默跳过发送，避免播报噪音化。

#### Scenario: 无变化的一周

- **WHEN** 本周快照与上周快照相比无新增、无暴涨、无消失、无已修待验
- **THEN** 不发送任何消息

### Requirement: 数据截止时间如实标注

日报 MUST 打印数据实际截止时间戳，MUST NOT 假设「数据截至昨天」。

#### Scenario: BigQuery 每日批量同步滞后

- **WHEN** 生成日报
- **THEN** 查询并显示 BigQuery 中最新事件的时间戳作为「数据实际截止」
- **AND** 卡片与文档 MUST 标注「BigQuery 每日批量同步，非实时」

### Requirement: 修复状态判定口径

日报/索引页对 issue 修复状态的自动判定 SHALL 遵循：iOS 可判定（依赖「提交信息带 Crashlytics issue ID」硬规则），Android MUST 显示为不可判定而非「未修」。

#### Scenario: iOS 修复状态推导

- **WHEN** 对 iOS issue 做 `git log --grep=<issueId>`
- **THEN** 无结果判「🔴 未修」；找到 commit 但线上无该版本事件判「🛠️ 代码已修·未发版」；含修复版本已上线判「📦 已发版·观察中」；发版后事件归零判「✅ 已消失」
- **AND** v1 现状：自动判定只落地前两态（「🔴 未修」/「🛠️ 代码已修·未发版」，渲染 `fix_commit`）；「📦 已发版·观察中」「✅ 已消失」需版本-事件对照，尚未实现，留人工 triage

#### Scenario: Android 修复状态不可判定

- **WHEN** Android 未采用「提交信息带 issue ID」约定（全仓 0 处 32 位 hex 引用，`fix_commit` 恒 null）
- **THEN** MUST 显示为 `—`（不可判定），MUST NOT 显示「🔴 未修」
- **AND** 其修复情况以每周 triage 报告的语义分析为准

### Requirement: 告警判定

日报 SHALL 在命中任一告警条件时在卡片顶部输出 🔴 告警块。

#### Scenario: 新增 issue

- **WHEN** 今日快照中出现昨日基准之外的新 issue
- **THEN** 输出「🔴 iOS/Android 新增 N 个 issue」

#### Scenario: 已修未发版

- **WHEN** 存在 `fix_commit != null` 但含修复的版本尚未上线的 iOS issue
- **THEN** 输出「🔴 N 个 issue 代码已修但未发版」

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

### Requirement: 索引页与台账镜像过渡

索引页重建与台账镜像的「固定 ID 覆盖」SHALL 作为过渡态待办：v1 日报/周报文档每次新建（`docx_builtin_import`），不覆盖同一份固定 ID 文档；在固定 ID 覆盖能力落地前，MUST NOT 声称已重建索引页或已同步台账镜像。

#### Scenario: v1 每次新建文档

- **WHEN** 固定 ID 覆盖能力尚未落地（lark 块 API 不支持表格，`docx_builtin_import` 每次新建）
- **THEN** 日报/周报文档每次新建，卡片链接到当天新文档
- **AND** 重建索引页、同步台账镜像标记为待办，不产出「已同步」的假状态

#### Scenario: 固定 ID 覆盖落地后

- **WHEN** 固定 ID 覆盖能力就绪
- **THEN** L1 重建索引页、同步台账镜像（覆盖同一份固定 ID 文档）
- **AND** 镜像顶部标注「请勿在此编辑」

### Requirement: NON_FATAL 维度展示

日报 SHALL 展示 NON_FATAL（非致命异常）维度；在 iOS NON_FATAL 通路尚未合入发版分支前，MUST 显式标注「通路建设中，数据不完整」而非展示裸数字。

#### Scenario: iOS 通路建设中

- **WHEN** iOS NON_FATAL 收口点已落地（change `ios-nonfatal-reporting`）但尚未合入发版分支
- **THEN** 日报 NON_FATAL 段 MUST 标注「🚧 建设中，数据不完整——不要按此判断 iOS 比 Android 稳」
- **AND** MUST NOT 把零值读成健康

#### Scenario: 通路发版后

- **WHEN** iOS NON_FATAL 通路合入发版并上线
- **THEN** 替换为双端 NON_FATAL 事件量与 TOP issue
