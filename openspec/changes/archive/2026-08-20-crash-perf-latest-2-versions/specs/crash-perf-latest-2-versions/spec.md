## Purpose

定义日报「只看最新 2 个版本」的取数与呈现契约：版本解析的唯一源与粒度、三段全量版本过滤、「该版本无数据」与「数据未同步」的严格区分、版本间对比指示器、按版本存储的环比基准，以及周报承接的「主力版本」互补视角。

## ADDED Requirements

### Requirement: 版本解析的唯一源与粒度

日报 SHALL 从 `firebase_sessions` 活表解析版本清单，取版本号最大的 N 个 `display_version`（默认 N=2），并以此清单驱动全部数据段。

#### Scenario: 以 sessions 为唯一解析源

- **WHEN** 日报开始取数
- **THEN** 版本清单 MUST 来自 `firebase_sessions`（REALTIME 优先，回退规则沿用既有放量段）
- **AND** MUST NOT 由崩溃段 / 性能段各自解析版本（各表最新版本不同步，各自解析会造成段间错位）

#### Scenario: 版本号排序而非会话量排序

- **WHEN** 从候选版本中选出「最新 N 个」
- **THEN** MUST 按版本号语义排序（`sort -V`）后取最大的 N 个
- **AND** MUST NOT 按会话数排序（会话量最大的通常是旧版本，与「看新版发得怎么样」的目的相反）

#### Scenario: 版本粒度钉死 display_version

- **WHEN** 同一 `display_version` 下存在多个 `build_version`
- **THEN** MUST 合并统计为一个版本
- **AND** MUST NOT 按 build 细分（会退化为「最新 2 个构建」，可能同属一个对外版本）

#### Scenario: 噪声版本门槛

- **WHEN** 某版本在解析窗口内会话数低于 `MIN_SESSIONS`（默认 5）
- **THEN** MUST 排除出候选清单
- **AND** 门槛值 MUST 为可配置常量

#### Scenario: 版本解析失败

- **WHEN** 版本解析查询失败或返回空清单
- **THEN** 该平台各数据段 MUST 显式输出「版本解析失败」
- **AND** MUST NOT 退回全版本聚合值（静默改口径比缺数更危险）

### Requirement: 三段全量版本过滤且按版本分列

崩溃 / 性能 / 版本放量三段 SHALL 全部按解析出的版本清单过滤，且每个指标 MUST 按版本分列呈现，MUST NOT 输出跨版本合计值。

#### Scenario: 崩溃段版本过滤

- **WHEN** 查询崩溃 issue 聚合、崩溃率、受影响安装、天级单日崩溃值
- **THEN** MUST 附加版本谓词，且崩溃率的分子（crashlytics）与分母（sessions）MUST 落在同一版本上

#### Scenario: 性能段版本过滤

- **WHEN** 查询启动 trace、页面渲染、网络请求及其天级单日值
- **THEN** MUST 附加版本谓词

#### Scenario: 不输出跨版本合计

- **WHEN** 呈现任一指标
- **THEN** MUST 按版本分列
- **AND** MUST NOT 额外输出两版合计值（合计会引入第三套口径）

#### Scenario: 放量明细保留全版本

- **WHEN** 生成日报文档的版本放量明细表
- **THEN** MAY 保留全版本列表（回答「盘子里还有多少旧版本」）
- **AND** MUST 显式标注该表为全版本口径，与卡片指标不可比

### Requirement: 主力版本补列

日报 SHALL 在「会话量 top2」与「最新 N 版」不重合时，把缺失的主力版本追加为补充列，使承载多数用户的版本不会从日报消失。

#### Scenario: 并集与上限

- **WHEN** 会话量 top2 中存在不属于最新 N 版的版本
- **THEN** 该版本 MUST 追加为补充列
- **AND** 列集合 MUST 为「最新 N 版 ∪ 会话量 top2」，按版本号新→旧排列，列数 MUST NOT 超过 4

#### Scenario: 列头标注来源

- **WHEN** 渲染版本列头
- **THEN** 属于最新 N 版的列 MUST 标注「最新」，属于会话量 top2 的列 MUST 标注「主力」，两者兼具 MUST 标注「最新·主力」

#### Scenario: 集合重合时形态不变

- **WHEN** 会话量 top2 完全落在最新 N 版内
- **THEN** 列集合 MUST 退化为最新 N 版
- **AND** MUST NOT 出现空的补充列

#### Scenario: 补充列的跟踪范围

- **WHEN** 计算天级单日值、DoD/WoW、sparkline 与历史存储
- **THEN** MUST 只覆盖最新 N 版
- **AND** 补充列 MUST 只呈现窗口值（成本控制，见 design D11）

#### Scenario: 补充列不触发告警

- **WHEN** 补充列的指标命中红档
- **THEN** MUST 只做单元格着色
- **AND** MUST NOT 进入告警摘要或置卡片头部为红

### Requirement: 版本无数据与数据未同步严格区分

数据缺失 SHALL 按三态判定并分别呈现，判定顺序 MUST 为：表不存在 → 表整体无数据 → 该版本无数据。

#### Scenario: 表整体无数据判定不带版本过滤

- **WHEN** 判定某表是否「数据未同步」
- **THEN** MUST 使用不带版本过滤的探测
- **AND** MUST NOT 用版本过滤后的 0 行推断数据源故障

#### Scenario: 该版本无数据

- **WHEN** 表在窗口内有数据但目标版本 0 行
- **THEN** MUST 呈现为「该版本无数据」
- **AND** MUST NOT 呈现为「数据未同步」或数值 0

#### Scenario: 新版在性能段常态无数据

- **WHEN** 最新版本在滞后的性能批量表中尚无数据
- **THEN** 性能列 MUST 显示「该版本无数据」且 MUST NOT 触发告警
- **AND** MUST NOT 回退到更旧的版本取数充数

### Requirement: 版本间对比指示器

卡片 SHALL 为每个指标提供「最新版相对上一版」的对比指示，方向沿用「数值变大 = 变差 = ↑」约定。

#### Scenario: 对比列渲染

- **WHEN** 两个版本该指标均有值
- **THEN** MUST 输出差值 + 方向箭头，变差 MUST 着红、变好 MUST 着绿

#### Scenario: 一端缺数据

- **WHEN** 任一版本该指标无值
- **THEN** 对比 MUST 输出 `—`
- **AND** MUST NOT 以 0 参与计算

#### Scenario: 与 DoD/WoW 分工

- **WHEN** 呈现环比信息
- **THEN** 卡片 MUST 只出版本间对比，同版本 DoD/WoW MUST 放到日报文档
- **AND** 同一单元格 MUST NOT 同时承载两套对比

### Requirement: 阈值与小样本提示作用于最新版

红绿灯阈值与小样本提示 SHALL 以最新版本的值为判定对象。

#### Scenario: 告警只由最新版触发

- **WHEN** 最新版命中红档
- **THEN** MUST 出告警并置卡片头部为红
- **AND** 上一版命中红档 MUST NOT 单独触发告警（只展示）

#### Scenario: 小样本提示版本级

- **WHEN** 某版本当日会话数低于 `SAMPLE_SESSION_MIN`
- **THEN** 该版本列 MUST 追加「样本量小，仅供参考」
- **AND** 本要求取代 `crash-perf-daily-monitoring` 中「小样本提示 MUST NOT 按版本细分」的断言

### Requirement: 环比基准按版本存储且旧口径自愈丢弃

`metrics-history.jsonl` SHALL 按版本存储天级单日值，并在读取时自动丢弃全版本口径的旧格式行。

#### Scenario: 按版本存储

- **WHEN** 写入当日历史
- **THEN** MUST 按 `{day, versions, <platform>:{<version>:{…}}}` 结构存储
- **AND** MUST 按 `day` upsert（同日重跑覆盖而非追加）

#### Scenario: 旧格式行自愈丢弃

- **WHEN** 读取到不含 `versions` 键的历史行
- **THEN** MUST 丢弃该行并打印口径变更提示
- **AND** MUST NOT 参与任何环比或 sparkline 计算

#### Scenario: 版本首次出现无基准

- **WHEN** 某版本在历史中无同版本记录
- **THEN** 该指标环比 MUST 显示「无基准」
- **AND** MUST NOT 与其他版本的历史值比较

### Requirement: 周报承接主力版本视角

周报 SHALL 新增主力版本放量段，按会话量取 top2 版本，与日报的「版本号最新 2 个」形成互补。

#### Scenario: 主力版本按会话量选取

- **WHEN** 生成周报放量段
- **THEN** MUST 按会话数降序取 top2 版本
- **AND** MUST 显式标注与日报口径的差异（日报=最新 2 版，周报=主力 2 版）
