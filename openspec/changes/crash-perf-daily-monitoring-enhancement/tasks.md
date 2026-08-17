# 任务清单 — crash-perf-daily-monitoring-enhancement

> 本 change 契约规模：**7 条 requirement / 22 个 scenario**（`specs/crash-perf-daily-monitoring/spec.md`）。
> 实现范围：`bin/crash-daily.sh` + `scripts/crash-report/crash-daily.sh`（双副本）、`bin/sql/crash-rate.sql`（+ 镜像 `scripts/crash-report/sql/crash-rate.sql`）、新增天级单日值查询、慢帧/冻结平台聚合查询、`state/daily-snapshot.json` 扩展 + 新增 `state/metrics-history.jsonl`。

## 1. 每日指标持久化与 7 日滚动历史（R7，前置依赖）

- [x] 1.1 定义 metrics-history 每行 schema：`{day, ios:{crash_events_1d,sessions_1d,affected_installs_1d,net_err_pct_1d,slow_pct_1d,frozen_pct_1d,start_p50_1d,start_p95_1d}, android:{...}}`，字段带 `_1d` 天级口径标识
- [x] 1.2 脚本末尾把「今日全指标天级单日值」追加一行到 `state/metrics-history.jsonl`（append），并原子写（临时文件 + mv）
- [x] 1.3 截断保留最近 7 行（超出删除最旧）
- [x] 1.4 扩展 `state/daily-snapshot.json`：保留既有 `ios_events/android_events/start_p50/ios_ids/android_ids`，新增全指标单日值字段（供明日 DoD 基准）
- [x] 1.5 口径注释：区分「天级单日值（`_1d`）」与「滚动窗口展示值（现有字段）」两种口径，代码注释写明不可混比

## 2. 天级单日值查询（D2）

- [x] 2.1 新增日历日锚定的天级单日值 SQL（`event_timestamp ∈ [D-1, D)` 等整日区间），覆盖崩溃率分子分母、受影响安装数、接口错误率、慢帧、冻结、启动 P50/P95、平台会话数
- [x] 2.2 复用 `{{TABLE}}/{{SESSIONS_TABLE}}/{{DAYS}}` 占位符风格，与既有 `qc()`/`q()` 参数约定一致
- [x] 2.3 崩溃/放量（REALTIME）严格按「昨日」取天级值；性能（批量，滞后 ~2 天）按「最新可用单日值」取（D7）
- [x] 2.4 慢帧/冻结的天级单日值取「平台级聚合帧级占比」（iOS/Android 各自汇总页面帧数），非「最差页」单页值（D9）

## 3. 受影响安装数（R2 / D3）

- [x] 3.1 `crash-rate.sql` 新增第三标量子查询 `COUNT(DISTINCT installation_uuid) WHERE is_fatal=TRUE AND 窗口内`，产出 `affected_installs`
- [x] 3.2 脚本提取 `IOS_AFFECTED/AND_AFFECTED`（json 解析），崩溃统计与「事件数/会话数」并列展示为「受影响安装 iOS N / Android M」
- [x] 3.3 天级版受影响安装数并入 metrics-history（供明日 DoD/WoW）

## 4. 环比 DoD/WoW（R1 / D6 / D7 / D9）

- [x] 4.1 实现 DoD（环比昨日）与 WoW（同比上周同日）计算：从 history 取昨日值与 D-7 值，与今日单日值对比
- [x] 4.2 百分比指标（崩溃率/接口错误率/慢帧/冻结）用 `±X.Xpp ↑/↓`；启动 P50/P95 用 `±Xms` 绝对差（D6）
- [x] 4.3 箭头沿用「数值变大 = 变差 = ↑」；iOS/Android 分开呈现
- [x] 4.4 无基准分支：无任何历史基准（首日/D-7 尚无历史/数据源不可得）时显示「无基准」/ 省略，不硬算
- [x] 4.5 perf 滞后回退：perf 指标 DoD 用「最新可用单日值」并标注实际对比日期；仅一个可用日时显示「无基准」（D7）
- [x] 4.6 五指标 DoD/WoW 追加到日报卡片与报告（崩溃块/性能块对应行）
- [x] 4.7 慢帧/冻结的 DoD/WoW 用平台级聚合值对比；最差页单页值不参与环比（D9）

## 5. 统一阈值红绿灯（R3 / D5）

- [x] 5.1 脚本顶部集中定义阈值常量（红=拍板、黄/绿=explore 建议值落地并注释「待对齐」）：`CRASH_RATE_RED=1.0`（黄 0.5–1%、绿 <0.5%）、`SLOW_FRAME_RED=50`（黄 30–50%、绿 ≤30%）、`FROZEN_RED=1.0`（黄 0.5–1%、绿 <0.5%）、`START_P95_RED=2000`（黄 1500–2000、绿 ≤1500）、`NET_ERR_RED=0`（首版沿用 >0，黄绿待对齐）、`SAMPLE_SESSION_MIN=30`（完整初值表见 design D5）
- [x] 5.2 实现统一判定函数：五指标（崩溃率/慢帧/冻结/启动 P95/接口错误率）走同一红黄绿判定，取代散落硬编码
- [x] 5.3 接口错误率纳入统一框架（红档沿用 >0，行为不倒退），删除现有 `awk 'i>0||a>0'` 独立分支
- [x] 5.4 命中红档输出 🔴 告警块（沿用现有 ALERTS 拼接方式），黄档在注释/标注中体现「待对齐」而非告警

## 6. 小样本量提示（R4）

- [x] 6.1 取平台级（iOS/Android 各自）当日会话数天级单日值（sessions 表，与 DoD/WoW 同口径，不按版本细分）
- [x] 6.2 会话数 < `SAMPLE_SESSION_MIN`（默认 30）时，该行数据后追加「⚠️ 样本量小，仅供参考」
- [x] 6.3 提示只标注不省略数据；阈值可配（改常量）

## 7. 慢帧定义注释（R5）

- [x] 7.1 卡片/报告注释区写明：慢帧最差页百分比 = 「慢帧（>16ms）帧数 ÷ 全部帧数」帧级占比，非「出现慢帧的会话占比」
- [x] 7.2 冻结率同理注明「>700ms 帧级占比」

## 8. 7 日 sparkline（R6 / D4）

- [x] 8.1 从 history 取崩溃率/接口错误率/启动 P95 的最近 7 日序列（仅这三个指标）
- [x] 8.2 用 Unicode 方块字符 `▁▂▃▄▅▆▇█` 按 min-max 归一化渲染成单行 markdown
- [x] 8.3 冷启动：历史不足 7 天按已有天数渲染，不用空值补齐伪装
- [x] 8.4 sparkline 追加到卡片对应指标行（崩溃率/接口错误率/启动 P95）

## 9. 双副本同步与 DRY RUN 校验（D8）

- [x] 9.1 同步双副本全部改动：`bin/crash-daily.sh` ↔ `scripts/crash-report/crash-daily.sh`、`bin/sql/` ↔ `scripts/crash-report/sql/`（crash-rate.sql 第三子查询、新增天级单日值 SQL、慢帧/冻结平台聚合 SQL），逐一 `diff` 复测一致
- [x] 9.2 `bash -n` 双副本通过
- [x] 9.3 `CRASH_REPORT_DRY_RUN=1` 跑脚本：核对 DoD/WoW 数值、阈值告警命中、sparkline 档位、小样本提示、`card.json` 合法（`jq empty`）且 <30KB
- [x] 9.4 核对指标数值与既有窗口展示值口径分离正确（天级 vs 窗口不混比）

## 10. 实跑投递与验收

- [x] 10.1 连续运行积累 ≥7 天 history（或注入历史数据）验证 WoW 与 sparkline 完整基准
- [ ] 10.2 实跑投递到私聊验证卡片渲染，再投群 `oc_655033f1f85fa04f9eac25d56f056fc9`
- [ ] 10.3 用户确认效果与数值 → 记录验收结论，进入 review(代码) / validate
