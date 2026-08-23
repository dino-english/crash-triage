## MODIFIED Requirements

### Requirement: 版本解析的唯一源与粒度

日报 SHALL 从 `firebase_sessions` 活表解析版本清单，取版本号最大的 N 个 `display_version`（默认 N=2），并以此清单驱动全部数据段。

版本清单 MUST NOT 按会话数设置准入门槛。版本清单回答的是「线上在跑哪些版本」这个事实，不该由展示门槛来裁剪——门槛会把**刚开始放量或已被叫停的新版**静默剔除，而那恰恰是最该被盯住的时刻。

样本量不足 MUST 由呈现层在单元格上标注，MUST NOT 通过让版本消失来处理。

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

- **WHEN** 某版本在解析窗口内会话数极少
- **THEN** 该版本 MUST 仍进入候选清单并正常呈现
- **AND** 其数值 MUST 附带小样本提示，使读者知道该比率不具统计意义
- **AND** MUST NOT 因会话数少而将该版本排除——版本消失且无任何说明，比呈现一个带提示的小样本值更糟

#### Scenario: 版本号更高的内测或灰度包出现在线上数据中

- **WHEN** 某个版本号高于当前发布版的构建在窗口内产生了会话
- **THEN** 它按版本号排序规则进入「最新 N 版」并被呈现
- **AND** 这是刻意接受的结果——一个内测包出现在线上数据里，本身就是需要被看见的事实

#### Scenario: 版本解析失败

- **WHEN** 版本解析查询失败或返回空清单
- **THEN** 该平台各数据段 MUST 显式输出「版本解析失败」
- **AND** MUST NOT 退回全版本聚合值（静默改口径比缺数更危险）
