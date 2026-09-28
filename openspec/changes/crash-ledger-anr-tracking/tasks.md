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
- [x] 2.4 **部署日人工动作**：台账飞书文档「Issue 现状表」标题下方的**静态说明**
      补一句「本表含 FATAL 与 ANR 两类，见类型列」。⚠️ 静态文字不参与同步，只能手改。
      2026-09-28 完成（与 4.5 同一段，一次 `block_replace`），`result:"success"` 且读回确认。
      ⚠️ 顺带修掉一处泄漏：该位置原本是 `<!-- LEDGER:ISSUES:BEGIN -->` **被飞书当可见文字渲染**
      （导入时 `Unsupported tag <!--> was removed; inner content was retained`），读者一直看得到。
      ⛔ 替换前确认过它不承重：飞书侧定位靠「标题文字 + 标题下第一个 `<table>`」，锚点只在本地
      `LEDGER.md` 的 awk 抽取里用；替换后复查第一个 `<table>` 仍在，下周同步不受影响。

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
      **2026-09-28 生产首轮实测与取数结论**：
      - 冷启动是**真的**，⛔ 不是「永远判新增」那个 bug：09-21 那轮台账 0 条 ANR、基准无该 id；
        今早跑完 `issue-seen.json` 里已有 `4d05f9e7 first=last=2026-09-28`（共 36 条）
        ⇒ `SEEN_NEXT` 收 ANR 的修复生效，**下周该行会自动变 🔁遗留**，不需要人工干预生命周期列。
      - ⛔ **但「首次纳入」的真值查不到，BigQuery 答不了**：
        `…ANDROID_REALTIME` 表实测 floor=`2026-08-29` / ceiling=`2026-09-28`，**保留期只有 30 天**；
        该 issue 在 floor 当天就有事件（50 事件 / 42 安装，版本跨 **1.3.2 → 1.8.1**）
        ⇒ 「first_event=2026-08-29」是**窗口边界不是事实**，真实起点更早（至少 1.3.2）。
        ⚠️ 同 [[l2-lifecycle-baseline-cold-start]] 与性能表停更那两次：⛔ 不得把窗口边界读成事实。
      - **待人决定**：要么去 Firebase 控制台取真实 first-seen 回填，要么接受「首次纳入 = 纳入台账那天」
        这个既有语义（ANR 那条注解本来就写明「首次纳入 = 越过阈值那天，不是首次发生那天」）。
        ⛔ 后者其实与现状自洽，本条可能应当直接结项而非订正——由人拍板。
- [x] 4.5 **部署日人工动作**（同 2.4）：台账飞书文档现状表标题下的静态说明加一句类型列的解释
      2026-09-28 与 2.4 合并为同一段落写入：含「类型」列说明、ANR 入选判据不是 top N 的理由、
      「首次纳入 = 越过阈值那天」的语义差异、以及 ANR 不参与变化摘要统计。

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

## 6. 实发验证（2026-09-22，⛔ 本地全绿但实发又挖出三个缺陷）

- [x] 6.1 L2 实发到开发机私聊：周报文档 + 卡片。读回文档发现 **ANR 判据长版与「本次运行」
      被合并进同一个 💡 callout**——`$(printf …)` 吞尾换行导致缺空行，md2docx「连续 > 合成
      一个 callout」把排障信息塞进了 ANR 说明里。直接验过 md2docx 规则（无空行→1 个、
      有空行→2 个），修为 `printf '%s\n'`（提交 941749b）。
      ⚠️ **DRY_RUN / NO_DELIVER / 本地 markdown 全都看不出来**，只是少一个空行。
- [x] 6.2 台账同步用 `CRASH_REPORT_LEDGER_DOC_ID=<测试文档>` 单独验（deliver.sh 自己提示的办法，
      它还会拒绝指向生产台账）。⛔ **首轮打了 ✅ 但文档 revision 一动没动**——
      `sync_ledger` 的 bootstrap 分支只判退出码且把输出丢进 /dev/null，而飞书在身份无权限时
      返回 `ok:true` / rc=0 / `result:"failed"`（F41）。`overwrite_doc` 同一个洞（提交 664c35c）。
- [x] 6.3 台账 9 列现状表**飞书渲染实测**：16 行、每行恰好 9 个单元格、含 2 行 ANR
      （`4d05f9e7` 类型列=ANR、20 次）；NON_FATAL 表 9 行 7 列。
- [x] 6.4 ~~未验~~ **已验（2026-09-28 生产首轮）**：台账 `block_replace` **稳态路径**实发走过。
      日志 `✅ 台账「Issue 现状表」已同步（block_replace，block-id=doxjp49ei1PPEckPFAaPd6OBOjf）`，
      ⛔ 但不采信日志——读回生产台账逐项比对才算数：
      Issue 现状表 **12 行 / 0 条 ANR（09-21 那轮产物）→ 13 行 / 1 条 ANR**，
      每行恰好 9 个单元格，ANR 行为 `4d05f9e7` 类型列=ANR。文档内容真的变了，不是 bootstrap。
- [x] 6.5 **已闭（2026-09-28）**，三项拆开：
      - [x] **带分析层的完整 L2** —— 生产周报第 196 行 `分析层：✅ 本周含深度分析`，整轮 rc=0
      - [x] `anr_truncated=true`（需 >50 条 ANR）—— **结项：不验，按业务设计不会发生**（2026-09-28 用户判定）。
            理由：ANR 被持续清理与修复，不太可能积到 50 条。实测佐证：本轮 `anr.android=1`、
            `anr_below=13`（单设备长尾）、`anr_truncated={"ios":false,"android":false}`，
            与「持续清理」一致，⛔ 不是检测坏了（那种形态见 [[zero-means-suspect-detection]]：
            业务上每周发生却常年报 0）。
            ⚠️ 截断标志与 LIMIT 50 的安全上界**代码保留**——它防的是「哪天真堆起来而无人察觉」，
            ⛔ 不因本次不验而删；只是不再把「让它为 true」当验收前提。
      - [x] **ANR 带修复提交的处置状态** —— **改用夹具验，⛔ 不再等线上样本**（2026-09-28）。
            生产至今无样本：本轮 fixmap 命中 9 条全是 FATAL/非致命（`2a800b33` `8baf564f`
            `470ed3ef` `e8a9ce84` `26335e5d` `85c581ed` `a34175e5` `ce481263` `fa48b2eb`），
            唯一的 ANR `4d05f9e7` 是「未处理」。⛔ 「等样本」等于永远不验。
            `build_rows()` 对 FATAL 与 ANR 的处置状态判定是**同一段 jq**（只有取哪个数组与
            「类型」列取值随 `etype` 变），于是在 `bin/test/fn-ledger-anr.sh` 里喂一个带
            fixmap 命中的 ANR 把该路径走完，新增 8 条断言（夹具 17 → 25）：
            类型列=ANR · 反扫 status 落进处置状态 · 备注写 commit+subject ·
            ⛔ CLOSED 压过反扫（R4，ANR 侧同样成立）· ⛔ MUTED 单独成态 ·
            负向「无命中回落未处理且不残留上次修复信息」。
            ⚠️ **双向测试已做**：把 `$fix != null` 改成排除 ANR → 该断言变红（24/1）；
            还原后 25/0，全量 `check-scripts.sh` 不误报。
