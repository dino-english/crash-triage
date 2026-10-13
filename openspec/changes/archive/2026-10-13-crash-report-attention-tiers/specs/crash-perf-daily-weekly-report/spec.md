## MODIFIED Requirements

### Requirement: 告警判定

日报 SHALL 把告警信号按 spec `crash-perf-attention-tiers` 的三档分档呈现，卡片 header 颜色随最高档切换。告警 MUST 只在有事实依据时触发，MUST NOT 因某平台缺少判定依据而产生噪音。

#### Scenario: 新增 issue

- **WHEN** 今日快照中出现昨日基准之外的新 issue
- **THEN** 7 天影响台数 ≥ `TIER_NEW_MIN` 的 MUST 进 🚨，其余 MUST 进 👀
- **AND** 每条 MUST 列出 issue 短 id 与台数，MUST NOT 只给「新增 N 个」计数

#### Scenario: 已修未发版

- **WHEN** 存在已识别到修复提交、但含修复的版本尚未上线的 issue
- **THEN** MUST 进 ⏳ 档，并按 7 天影响台数降序列出 issue id
- **AND** 该判定对 iOS 与 Android 使用同一口径，且 MUST 与台账「处置状态」的「已修未发版」为同一判定
- **AND** MUST NOT 以「修复提交之后无新事件」代替「含修复的版本尚未上线」——前者包含修复已发版且生效的 issue，会把好消息报成告警

#### Scenario: 修了仍在

- **WHEN** 某 issue 修复状态为「修了仍在」且报告版本集内 7 天影响台数 > 0
- **THEN** MUST 进 🚨，理由写明修复提交与所在发版

#### Scenario: 发版判定不可得

- **WHEN** 本轮发版判定不可得
- **THEN** MUST NOT 依据修复状态判入 🚨 或 ⏳
- **AND** MUST 在卡片标注发版判定不可得，MUST NOT 以只比时间的结果代替

#### Scenario: 无判定依据不告警

- **WHEN** 某 issue 在回溯窗口内没有携带崩溃标识的提交
- **THEN** MUST NOT 就其修复状态发出告警

#### Scenario: 性能慢性超标

- **WHEN** 某性能指标命中红档，但未构成相对上一版本的退化
- **THEN** MUST 在健康度面板着红并附下钻
- **AND** MUST NOT 进 🚨——慢性状态不是今天要开发动手的事

#### Scenario: 接口错误率异常

- **WHEN** 自家 API 网络错误率命中红档（`NET_ERR_RED`，现值 1.0%）
- **THEN** MUST 在健康度面板着红，并以接口 top3 下钻
- **AND** 未构成相对上一版本的退化时 MUST NOT 进 🚨
- **AND** 原「> 0 即告警」的写法作废——实现自 v2 迁移起即为 `NET_ERR_RED=1.0`，本场景使 spec 与实现一致

### Requirement: 周报文档构成——数据层段落不得被分析层替换

L2 周报投递的文档 MUST 同时包含数据层段落与（若本轮产出了）分析层段落。数据层段落 MUST NOT 因分析层成功而从投递物中消失。

数据层段落指由确定性脚本产出、不经模型的内容：取数区间与 run_id、本周变化、主力版本指标、影响面维度分布、性能趋势、口径注记。

文档头部之后 MAY 设「本周必修 / 修复进度」首屏段，其中「本周必修」引用经校验的 `priorities.json`（标注未经人工复核）或回落的规则判定（标注规则判定）。该首屏段是**引用**，MUST NOT 替代或删减分析层段落。

理由：分析层产物按 triage skill 自己的模板成文，其 prompt 从未要求携带维度与指标；两者互斥投递会让「分析越成功、数据面越空」。实测 2026-08-20 投递文档 30,991 字符，主力版本 / 性能 / crash-free / 系统版本 / 取数区间命中数均为 0。

#### Scenario: 分析层跑通

- **WHEN** 本轮 L2 产出了根因分析报告
- **THEN** 投递文档 MUST 以数据层周报为主干
- **AND** 分析层内容 MUST 作为独立段落追加，且该段标题 MUST 标注未经人工复核
- **AND** 取数区间、run_id 与口径注记 MUST 位于文档头部

#### Scenario: 首屏引用分析层优先级

- **WHEN** 本轮 `priorities.json` 校验通过
- **THEN** 头部之后 MAY 呈现「本周必修」，条目来自该文件
- **AND** 分析层段落 MUST 仍完整追加于文档后部

#### Scenario: 分析层缺失

- **WHEN** 本轮无分析报告（模型不可用 / 超时 / 显式跳过）
- **THEN** 投递文档为数据层周报本体
- **AND** MUST 保留「本周无深度分析 — 原因」的显式注记
- **AND** 「本周必修」MUST 标注为规则判定

#### Scenario: 合并不得改动分析层的标题层级

- **WHEN** 把分析层内容并入投递文档
- **THEN** MUST NOT 调整其内部标题的层级
- **AND** 理由：下游 `split-fix-list.py` 以二级标题定位「修复清单」段，降级会使其静默失效——找不到段落即原样返回，无退出码、无告警

### Requirement: issue 级条目提供外部下钻入口

以单条 issue 为单位呈现的内容 MUST 提供指向该 issue 数据源控制台的直达入口。

卡片侧的可行性 MUST 按**载体**判定，⛔ MUST NOT 一刀切禁止——2026-09-01 实发实测：markdown 块里的链接可点且不改变宽度；表格组件单元格不支持链接。2026-10-11 实发实测：markdown 块中的**表格语法**内链接可点。

#### Scenario: 文档中的 issue 条目

- **WHEN** 文档呈现一条 issue
- **THEN** MUST 附直达链接
- **AND** 链接 MUST 使用完整 issue 标识构造

#### Scenario: 卡片中的 issue 条目

- **WHEN** issue 条目在卡片里以 markdown 块呈现（含 markdown 表格语法）
- **THEN** MUST 附直达链接
- **AND** 链接 MUST 以 issue 标识为锚文本（⛔ 不得裸露 URL——那才是会挤占宽度的形态）
- **AND** 理由：卡片是多数读者唯一会看的产物，最该能下钻的地方不能只给灰色文本

#### Scenario: 卡片中的紧急条目

- **WHEN** issue 条目以 🚨 色底块呈现
- **THEN** MUST 附「控制台」按钮直达该 issue

#### Scenario: 卡片的表格单元格中的 issue 条目

- **WHEN** issue 条目在卡片里以 `{tag:"table"}` 单元格呈现
- **THEN** MUST NOT 附外部链接
- **AND** 理由：实测 CardKit 表格组件单元格不渲染链接，写进去只会显示字面 markdown 并撑宽

#### Scenario: 卡片能力判断的证据要求

- **WHEN** 判断某种内容在卡片上是否可行
- **THEN** 结论 MUST 来自真实发送一张卡片的实测
- **AND** MUST NOT 由 DRY RUN、markdown 预览或类推得出
