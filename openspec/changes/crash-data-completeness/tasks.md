## 1. 完整日窗口（A）

- [ ] 1.1 `bin/lib/core/format.sh` 新增 `last_complete_day()`：入参 `DATA_UNTIL`，出参 `YYYY-MM-DD`（`DATE(DATA_UNTIL) - 1`）。`DATA_UNTIL` 为 `—` 时返回空，调用方走既有缺数三态第 2 态
- [ ] 1.2 `win_full()` / `win_compact()` 增完整日模式：锚点由 `RUN_EPOCH` 改为 `LCD`，整日闭区间。⚠️ **保留旧签名兼容**——崩溃段与放量段仍走原模式（Non-goal）
- [ ] 1.3 `crash-daily.sh` 性能段 SQL 改为 `DATE(event_timestamp) BETWEEN {{LCD_START}} AND {{LCD_END}}`，**不再用 `TIMESTAMP_SUB(CURRENT_TIMESTAMP(), ...)`**。占位符经 `q_render` 收口，漏传当场失败
- [ ] 1.4 `crash-weekly.sh` 性能段同步改为 `[LCD-6, LCD]`
- [ ] 1.5 DoD 取日改为 `LCD` vs `LCD-1`；WoW 改为 `LCD` vs `LCD-7`。⚠️ 现有 `perf_day` / `perf_prev_day` 语义随之改变，落库前确认下游无硬编码依赖
- [ ] 1.6 标注文案升级为「性能数据 X ~ Y（完整日）· 滞后 N 天 · Z 起未合并」，卡片与文档同步。**`DATA_UNTIL` 仍要显示**（design D2）
- [ ] 1.7 确认**未新增 BigQuery 查询**：`LCD` 由既有 `table_max()` 结果在 shell 侧算出（design D1）
- [ ] 1.8 验证：用 2026-08-27 数据 dry-run，iOS 1.5.4 启动 P95 应从 **1038ms 变为 927ms**；DoD「今日」不再等于半天值 1044ms

## 2. 性能段分域选版（B，仅 L1）

- [ ] 2.1 版本选取拆为 `pick_versions_crash()`（最新 2 版，**现状不变**）与 `pick_versions_perf()`
- [ ] 2.2 `pick_versions_perf()`：候选按版本号降序，逐个查该版本在性能窗口内是否有值，凑满 2 个即停，**最多回溯 2 版**（design D4）
- [ ] 2.3 ⛔ 判据只看**性能数据有无**，**MUST NOT** 引入任何会话量门槛——`MIN_SESSIONS` 中和为 1 是 2026-08-22 的实测决定，不得以等价手段绕回（Non-goal）
- [ ] 2.4 4 个候选皆无数据时转既有「⚠️ 数据未同步」告警，不继续回溯
- [ ] 2.5 性能段表头标注「性能数据可得的最新 2 版」；`ver_tag()` 增「性能兜底」角标
- [ ] 2.6 验证：2026-08-27 数据下性能段列应为 **1.5.4 + 1.5.3**，崩溃/放量段仍为 **1.5.5 + 1.5.4**（1.5.5 不得从报告消失）

## 3. 第 3 态细分（C，L1 + L2）

- [ ] 3.1 ⛔ 先确认既有缺数三态的判据、顺序、文案**一字未动**，尤其第 2 态「不带版本过滤的探测」（design D5）
- [ ] 3.2 新增 `hist_lookup(平台, 版本, 指标)` → 返回「历史最后一个非 null 值 + 其日期」
- [ ] 3.3 第 3 态分叉：历史全 null → 「预计 X 到位」；历史有值 → 「253ms（沿用 08-25，本轮未更新）」
- [ ] 3.4 ⚠️ 判据 **MUST 显式判 `null`**，MUST NOT 用 `[ -z "$v" ]`——慢帧/冻结/错误率的 `0` 是合法值（design D6）
- [ ] 3.5 「沿用」文案**必须带日期**（design D7）
- [ ] 3.6 L2 接同样逻辑，读 `weekly-metrics.jsonl`。⛔ 与 L1 的 `metrics-history.jsonl` **口径不同不可混用**（`crash-weekly.sh:527` 既有注释）
- [ ] 3.7 验证：构造四种输入——全 null、历史有值本轮 null、两侧相等、本轮取到 `0`——确认文案分别命中且 `0` 不被误判为缺失
- [ ] 3.8 文档与注释统一称「第 3 态细分」，不再叫「三态」（design D5）

## 4. 跑批时间（D）

- [ ] 4.1 hermes cronjob 07:00 → 08:30（+08）。⚠️ **不在本仓库**，改动位置与回退方式记进 `docs/CLAUDE-部署与运维.md`
- [ ] 4.2 与第 1 组同批切换，不拆两次发布（design D9）
- [ ] 4.3 切换后首轮核对 `health-daily.json` 的 `data_until` 应前进一天

## 5. 口径断裂标记（design D8）

- [ ] 5.1 `metrics-history.jsonl` 与 `weekly-metrics.jsonl` 新行增 `window_mode`（`legacy` / `complete_day`）
- [ ] 5.2 **不回填、不重算**历史
- [ ] 5.3 跨口径 WoW 标注「口径切换于 2026-08-27，此前含部分日数据」，切换后 7 天内生效

## 6. 文档与 spec

- [ ] 6.1 spec `crash-perf-data-staleness-guard` 增「性能窗口只取完整日」requirement，与既有「放宽到 3 天容忍滞后」并存（放宽是为了够得着，完整日是为了别掺半天，不冲突）
- [ ] 6.2 spec `crash-perf-latest-2-versions` 补性能段分域选版 Scenario，并注明崩溃/放量段口径不变
- [ ] 6.3 `docs/CLAUDE-架构与数据口径.md`：「版本口径」节补分域说明（并保留既有「刻意接受」段落，说明二者关系）；「缺数三态」节补第 3 态细分
- [ ] 6.4 `docs/CLAUDE-失效模式登记.md` 增两条：①「窗口容忍滞后 ≠ 窗口内数据完整」②「历史缓存缺『本轮未取到』态会把故障读成持平」

## 7. 验收

- [ ] 7.1 新旧两版输出并排 diff，差异**全部**可归因到 A/B/C，无意外变化
- [ ] 7.2 `bin/check-scripts.sh` 静态检查通过
- [ ] 7.3 `bin/test/` 补回归用例：完整日判据、第 3 态细分（含 `0` 值）、兜底回溯上限
- [ ] 7.4 连跑 2 天观察 DoD 稳定性（两边同为完整天后，环比不应再出现 +30pp 级构成性跳变）
