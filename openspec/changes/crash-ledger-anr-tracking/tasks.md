## 1. 取数

- [x] 1.1 ✅实测：Android 34 行 / iOS 0 行 / 过阈值 2 条 / 头条 `4d05f9e7` 20次·16台·跨3版本。
      新增 `bin/sql/crash-anr-issues.sql`：`error_type = 'ANR'`，输出对齐
      `crash-issues-all.sql`（id/title/events/users/latest/versions），
      `ORDER BY users DESC, events DESC, issue_id`（⛔ 确定性 tie-breaker），`LIMIT {{LIMIT}}`
      → verify：今天 Android 返回 34 行、iOS 返回 0 行
- [x] 1.2 ⛔ `crash-issues-all.sql` 一个字不改（`is_fatal = TRUE` 被崩溃口径依赖）
- [x] 1.3 `fetch-snapshot-bq.sh`：`anr_rows()` + 快照增 `anr.{ios,android}` / `anr_below.{ios,android}`
      → verify：今天 `anr.android` 2 条、`anr_below.android` = 32
- [x] 1.4 事实层写入循环纳入过阈值的 ANR（⛔ 只有过阈值的）
      → verify：跑完 `$STATE/issues/` 多出 2 个文件，且 `.source = "bigquery"`

## 2. 渲染

- [x] 2.1 `render-ledger.sh`：ANR 行进同一张现状表，`type` 取 `ANR`
- [x] 2.2 ⛔ **订正**：注解**放不进台账表块**——`deliver.sh` 的 `block_replace` 只替换单个
      `<table>`，塞文字会把段落挤进表格位置（NF 表的注释早就写明了这条）。
      ⇒ 改放**每周重算的周报口径行**（与 `FACT_CACHE_NOTE` / `PERF_STALE_NOTE` 同一机制），
      内容含：入选数 / 未入选数（命中上界时写「至少」）/ 判据不是 top N 的理由 /
      首次纳入语义 / ⛔ ANR 不进变化检测。
- [x] 2.3 同 2.2，已并入那条注解
- [ ] 2.4 **部署日人工动作**：台账飞书文档「Issue 现状表」标题下方的**静态说明**
      补一句「本表含 FATAL 与 ANR 两类，见类型列」。⚠️ 静态文字不参与同步，只能手改。

## 3. 断言与检查

- [x] 3.1 `assert-fact-cache.sh` 的遍历纳入 `anr.{ios,android}`
- [x] 3.2 新夹具 `bin/test/fn-ledger-anr.sh`（13 条，含 6 条源码断言）：阈值过滤 / 未入选计数 / type 列取值 / iOS 空
- [x] 3.3 ⛔ 双向测试：把阈值过滤摘掉 → 夹具必须变红

## 4. 验收

- [x] 4.1 `check-scripts.sh` 十项全过
- [x] 4.2 ⚠️ **L2 跑批前先备份四个文件**——L2 的基线提升在 NO_DELIVER 闸门**之前**，
      「跑两次对比产物」在 L2 不成立（`last-snapshot.json` / `issue-seen.json` /
      `weekly-metrics.jsonl` / `ledger/LEDGER.md`）
- [x] 4.3 L2 整跑 rc=0（`NO_DELIVER` + `SKIP_ANALYSIS`，分析层本 change 不碰）。实测：
      现状表出现 `4d05f9e7`（**类型列 = ANR** · 20 次）与 `29b3bd6b`（ANR · 2 次）；
      快照 `anr.android=2` / `anr_below.android=**32**` / `anr_truncated=false`——与预测逐数吻合；
      事实层 32→40，两条 ANR 记录 `source="bigquery"`；周报口径行渲染出「本轮 2 条入表，
      另有 32 条单设备 ANR 未列入」。台账**无 `__REPORT_URL__` 死链**。
      ⚠️ **第一次跑失败了**，是这一步逮住的 → 见下方第 5 节 F56。
- [x] 4.3b 顺带验到上一个 change 的端到端效果：`579db247` 在台账渲染为 `🔕已静音`
- [ ] 4.4 落地后首轮**人工订正 ANR 的首次纳入日期**（D4 冷启动）。
      实测本轮两条都是「首次纳入 2026-09-22 · 🆕新增」，而 `4d05f9e7` 至少从 1.5.6 起就在发生。
- [ ] 4.5 **部署日人工动作**（同 2.4）：台账飞书文档现状表标题下的静态说明加一句类型列的解释

## 5. 本轮发现（⛔ 是我自己引入又自己抓到的，登记以防复犯）

- ⛔ **`SEEN_NEXT` 只收 `.ios`/`.android`**：现状表渲染了 ANR，生命周期基准却不收它们
  ⇒ 每轮 `$s` 都是 null ⇒ **永远判「🆕新增」**。一个每周都说自己是新的条目比不显示更糟。
  ⚠️ 这类「渲染接了、基准没接」的半接线，静态检查与函数级夹具都看不见——
  是顺着 D5 那张「哪些通路进、哪些不进」的表逐格过才发现的。已加源码断言钉住。

- ⚠️ **新建的事实层记录本轮拿不到开关状态**（⛔ 不是本 change 引入，是既有执行顺序）：
  状态同步在数据层**之前**跑，本轮新建的记录（本次 8 条，含 2 条 ANR）`state` 为 null，
  台账渲染成「未处理」。实测 `fb6588bb`（Crashlytics 侧已 CLOSED）本轮显示「未处理」。
  **下一轮自愈**——L1 日报每天同步全部缓存文件，L2 周一跑时缓存已热。
  ⇒ 只在「issue 首次进缓存」那一轮不准，生产上罕见（缓存常年是热的），登记不修。
