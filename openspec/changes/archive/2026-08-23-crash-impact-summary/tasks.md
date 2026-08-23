## 0. 先核实分母（决定维度表形态）

- [x] 0.1 ~~核实 `firebase_sessions` 是否含 OS / 机型字段~~ **已确认可得**（2026-08-22 实测）：`device.model` · `device.manufacturer` · `operating_system.display_version`
- [x] 0.2 维度表给**崩溃率**——**仅系统版本维度**。⚠️ 实测发现机型维度加不了分母：Android 机型碎片化到最大桶只有 75 会话，门槛设 50 只剩 1 行、设 100 一行不剩。机型给绝对数 + 影响安装 + 集中度（design D6a）
- [x] 0.3 ⚠️ 有了率**不等于**有了根因：某机型崩溃率高仍可能源自该机型用户的网络环境或功能路径。design D6 的「不得断言根因」约束依然成立

## 1. SQL

- [x] 1.1 新建 `bin/sql/crash-dimensions.sql`（含 `{{DIM}}` / `{{SESS_DIM}}` 占位符，机型与 OS 共用同一模板）。**不在 SQL 里按样本量过滤**——过滤掉就看不见影响面了，而影响面恰是机型维度唯一可靠的信息；率列由渲染层在样本不足时替换。原文：新建 `bin/sql/crash-dimensions.sql`：按 `device.manufacturer`+`device.model`、`operating_system.display_version`、小时分桶（`FORMAT_TIMESTAMP('%H', event_timestamp, 'Asia/Shanghai')`）三个维度聚合事件数与 `COUNT(DISTINCT installation_uuid)`，各取 top N；含 0.2 的分母（若可得）
- [x] 1.2 `crash-issues.sql` 增 `COUNT(DISTINCT installation_uuid) AS users` 列，并把 `ORDER BY events DESC` 改为 `ORDER BY users DESC, events DESC`（design D3）
- [x] 1.3 新建 `bin/sql/crash-hours.sql`。⚠️ **改为按绝对小时分桶**：只按「一天中的第几小时」分桶**答不了聚集**——一次爆发会被摊进 24 个桶里看不出来。现返回绝对小时桶 + hour_cst，渲染层再汇总一次得峰值，一次查询两个都能算。时区固定 Asia/Shanghai（UTC 分桶会把晚高峰劈成两半）（最密集窗口的事件数与占比）。⚠️ **不引入统计检验**——双端两周合计两百余事件，任何显著性检验都会给出不可靠结论（design D4）
- [x] 1.4 `bin/sql/README.md` 增说明
- [x] 1.5 手工验证：`sed` 替换占位符喂 `bq query`，数值与 proposal 里的实测表对得上（OPPO CPH2591 14/7、Pixel 8 Pro 9/1、Android 16 的 51/44、14:00 与 21:00 各 19）

## 2. 汇总段渲染

- [x] 2.1 报告结构调整为 **一、汇总 / 二、版本对照 / 三、明细 / 四、环比与口径**，现「一、结论」的版本 delta bullet 并入汇总
- [x] 2.2 汇总块 A「影响多少人」：受影响安装数 + 集中度（事件/安装），双端分列
- [x] 2.3 汇总块 B「集中在哪」：机型 + OS 版本，按版本拆，每维度每版本 top 3。⚠️ **只有系统版本给率**——机型维度桶太小（design D6a）
- [x] 2.3a 维度块按**平台分组、版本并列**，不是四段平铺——同一维度两版并排才能看出「新版是否引入新机型问题」，这是按版本拆的唯一价值（design D1a）
- [x] 2.3b **无差异不展开**：某维度两版 top3 完全一致时合并呈现并标注「两版一致」。稳态下这是常态，能把约 60 行压回 20 行左右
- [x] 2.4 汇总块 C「什么时候」：峰值时段 + 聚集提示。**两者分开呈现**——峰值是常态分布描述，聚集是异常提示，合并会让常态被读成事故（design D4）。时段标注时区，沿用既有双时区惯例
- [x] 2.5 集中度以数值直接呈现在每一行（`集中度 N`），并在块 A 下方解释其含义。~~相对均值标记~~ 未做——当前数据下集中度普遍在 1.0–2.4，没有需要单独标出的离群项；标记规则留到出现离群数据时再定，避免凭空造阈值。原文：相对该端均值判定（**不用固定阈值**——不同端基线差异大，固定值在一端准在另一端误报），高出显著者标注「高度集中，疑似单设备/单环境」
- [x] 2.6 维度截断标注：超过上限时标明被截断，**不静默丢弃**（沿用仓库既有的「no silent caps」惯例）
- [x] 2.7 ⛔ 汇总段措辞审查：只给事实与取证方向，**不得出现任何根因断言**（design D6，spec 的 MUST NOT）。例：可写「事件集中于 Android 16」，不可写「Android 16 适配存在问题」

## 3. 明细段

- [x] 3.1 issue 明细表增「安装数」与「集中度」两列，保留事件数列（不隐藏——读者需要自行判断的空间）
- [x] 3.2 排序改为按安装数（design D3）
- [x] 3.3 首期在表头或表下标注「已改为按影响安装数排序」，避免读者以为数据变了

## 4. 卡片与文档分工

- [x] 4.1 **汇总段完全不进卡片**（design D0/D5，已拍板）——卡片改版由独立 change 承载
- [x] 4.2 三块全部进文档（XML + markdown 两处渲染），卡片经既有 `__DETAIL_URL__` 指向文档
- [x] 4.3 确认卡片渲染未因本 change 增加任何行

## 5. L2 周报

- [x] 5.1 主力版本段增机型 / OS top3，用于跨周对比适配面变化
- [x] 5.2 口径段说明维度数据的分母状况（承接 0.2/0.3 的结论）

## 6. 验证

- [x] 6.1 `bash bin/check-scripts.sh` 通过
- [x] 6.2 L1 整跑 ✅ 汇总段三块齐全。集中度已逐行呈现；**离群标记未做**——当前数据集中度普遍 1.0–2.4，无离群项，不凭空造阈值（findings F5）
- [x] 6.3 崩溃率、崩溃次数、受影响安装三行与改动前一致（口径未动的验收）
- [x] 6.4 `CRASH_REPORT_NO_DELIVER=1 CRASH_REPORT_SKIP_ANALYSIS=1 bash bin/crash-weekly.sh` 整跑
- [x] 6.5 抽查 2–3 个维度数值与 Firebase 控制台对得上 —— 2026-08-23 裸调 Crashlytics API（控制台同源）三组比对全过，见 findings F5

## 7. 收尾

- [x] 7.1 `CLAUDE.md` 报告结构说明更新为「汇总 / 版本对照 / 明细」，并写明汇总段的三问边界与「不给结论」约束
- [x] 7.2 记录后续候选：`remote_config_feature_rollouts`（能直接回答「是不是某个 flag 灰出去导致的」，design D1 评为价值最高的后续维度）、`process_state`（前后台）、`memory.free`（OOM 信号）
