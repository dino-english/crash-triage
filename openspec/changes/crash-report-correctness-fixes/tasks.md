## 1. CSV 解析（周报维度 / 归因 / 接口错误率）

- [x] 1.1 `crash-weekly.sh` 增 `csv2tsv()` 辅助（python3 `csv.reader` → TSV），紧邻使用处定义
- [x] 1.2 `dims_md()`（:587）改经 `csv2tsv` 后 `awk -F'\t'`，字段号不变
- [x] 1.3 `blame_md()`（:613）同上
- [x] 1.4 接口错误率（:446）同上——`event_name` 是 URL，同类风险
- [x] 1.5 实测：`- "Apple iPad7 · 11" 事件 / 1 人 · 集中度 `（错）→ `- Apple iPad7,11 · 1 事件 / 1 人 · 集中度 1.0`（对）；Android 无引号行输出**逐字节不变**

## 2. 时间线幂等与占位符

- [x] 2.1 追加前查重：键取 ` · [周报](` 之前的正文（design D2）
- [x] 2.2 本轮不投递时，时间线条目不带链接后缀（design D3）
- [x] 2.3 清理完成：时间线 **36 → 12** 条（实际重复比初估多——08-22 那 6 条各 ×5，那天跑了 5 次），30 条悬空占位符后缀已去；**现状表与备份逐字节一致**，备份留在 scratchpad
- [ ] 2.4 负向测试：连跑两次，第二次时间线**不得**增长

## 3. 生命周期三态

- [x] 3.1 新增 `$STATE/issue-seen.json`，结构 `{id:{first,last}}`，保留 90 天，超期清理
- [x] 3.2 「上一轮」取基准最大 `last`，不假设为上周（design D4，照抄 `crash-daily.sh:830` 的教训）
- [x] 3.3 `render-ledger.sh` 增第 7 个入参（基准路径），`status_badge` 扩为三态
- [x] 3.4 `first_seen` 优先取基准 `first`，回退上一版表格，再回退今天
- [x] 3.5 基准为空 → 不标任何态（spec 硬要求）
- [x] 3.6 ⚠️ 登记进 `bin/test/artifacts.sh` 的 `artifacts_baseline_files()`（不登记则等价性验收失效）
- [x] 3.7 三态实测：`last==上一轮`→🔁遗留(first 2026-08-01 保留) · `last` 更早→**🔁回归**(first 2026-07-10 保留) · 不在基准→🆕新增(first 今天)。另验降级路径：无基准/空基准时输出与改动前**逐字节一致**

## 4. 验收

- [x] 4.1 `check-scripts.sh` rc=0。⚠️ 首次跑 **rc=1**：抓到我新加的 `day_ago` 与 `crash-daily.sh` 重复定义 → 收口到 `bin/lib.sh`，两入口各自删除，daily 的 lib.sh 缺失回落分支同步补上
- [ ] 4.2 ⚠️ 备份 `last-snapshot.json` 与 `ledger/`
- [ ] 4.3 冻结缓存整跑两轮，第二轮时间线零增长、台账现状表稳定
- [ ] 4.4 抽查周报机型段数值对 BigQuery 原始 CSV
