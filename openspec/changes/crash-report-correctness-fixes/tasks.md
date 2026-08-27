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
- [x] 2.4 负向测试跑了，**并且抓到一个漏网的幂等泄漏**（2026-08-27，冻结缓存沙箱连跑三轮）。

  条目数确实零增长（23 → 23），但**空行 6 → 7**：`LEDGER_TL_DEDUP` 去重后内容为空时，
  上一行的 `printf '%s\n' "$(cat …)"` **仍然写出一个换行**，文件 1 字节 →
  `[ -s ]` 判非空 → 把那个空行追进时间线，而「跳过追加（幂等）」那条分支**永远走不到**。

  ⚠️ 只数条目会判它通过——每一轮「无新增条目」的跑批都在往台账里塞空行。
  判据改为 `[ -n "$(cat …)" ]`（判内容不判字节，`$(cat)` 会剥掉尾随换行）。

  修后第三轮实测：日志出现「时间线增量全部已存在于台账，跳过追加（幂等）」，空行停在 7，
  run2 → run3 三段（时间线 / FATAL 现状表 / NON_FATAL 现状表）**逐字节一致**。
  登记为失效模式 **F37**。

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
- [x] 4.2 2026-08-27 已备份 `last-snapshot.json` / `issue-seen.json` / `weekly-metrics.jsonl` / `perf-history.jsonl` / `ledger/` 到 scratchpad。
  ⚠️ 实际做法比「备份」更稳一层：整个验收跑在**沙箱 `XDG_STATE_HOME`** 里（真实 STATE 全程未被写），
  备份只作二次保险。⛔ 这一步不能省——L2 的基线提升在 NO_DELIVER 闸门**之前**，跑一次 `last-snapshot.json` 就前进了
- [x] 4.3 冻结缓存沙箱整跑**三轮**（两轮不够，见下），真实 STATE 全程未被写。

  ⚠️ **「第二轮现状表稳定」这个判据在同日重跑下天然不成立**，不是台账被扰动：
  第一轮把新 issue 写进 `issue-seen.json`（`first`=`last`=今天），第二轮读基线时
  「上一轮」取 `issue_seen` **最大日期** = 今天（既有硬约束：不是「昨天」，漏跑一天会把全部 issue
  误判回归），于是 `last == 上一轮` → 4 条从 `🆕新增` 翻成 `🔁遗留`。
  FATAL 表 8 行差异**全部**是这一个字段，其余一字未变；NON_FATAL 表两轮就已逐字节一致。
  ⛔ 生产 L2 是周跑，同日重跑不会发生。

  故正确的判据是 **run2 → run3**（两轮都已过那个生命周期转换）：
  时间线 / FATAL 现状表 / NON_FATAL 现状表**三段全部逐字节一致**，且时间线条目 23 → 23、空行 7 → 7。
- [x] 4.4 2026-08-27 抽查：报告机型段 **7 行全部与原始 bq 逐字段一致**（三组：Android 1.5.4 / Android 1.5.3 / iOS 1.5.4）。

  最关键的一行是带逗号的机型——它正是本 change 1.2~1.5 修的那个失效模式：

  ```
  原始 bq CSV:  "Apple iPad7,11",2,2,1.0     ← 机型名自带逗号，bq 给它加了引号
  报告渲染:     | iOS | 1.5.4 | Apple iPad7,11 | 2 | 2 | 1.0 |
  ```

  逗号完整保留、未错列。⚠️ 裸 `awk -F,` 会把这 1 个事件渲染成 11 且不报错（F1/F2），
  现在在**活数据**上确认 `csv2tsv` 挡住了。

  对照口径与 `crash-dimensions.sql` 一致：`CONCAT(device.manufacturer,' ',device.model)`、
  `error_type IN ('FATAL','ANR')`、`ORDER BY users DESC, events DESC, dim`。
