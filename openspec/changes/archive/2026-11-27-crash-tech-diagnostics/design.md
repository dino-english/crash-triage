# Design

## Context

- 动机见 proposal.md「Why」。
- 现有两条链路（L1 `crash-daily.sh` 08:30、L2 `crash-weekly.sh` 周一 05:30）都由 Hermes cron（default profile，`no_agent=true`）触发，取数全部经 `bin/lib/bq.sh` 的 `bqq`（直连被 `check-scripts.sh` 第 6 项拦），判定逻辑在 `bin/lib/core/*.sh` 纯函数层（可在 `env -i` 下调用，依赖规则由检查项 4 的 grep lint 强制）。告警投递已有 `bin/alert.sh`：`CRASH_REPORT_ALERT_CHAT_ID` 优先、`ou_` 走私聊。投递目标由 `$STATE/local.env` 决定，命令行同名变量会被它覆盖。
- 数据源：`dino-english-497507.analytics_538991439`。2026-11-26 在日报机实测：日报机的 `bq` 能读 `events_intraday_<日期>`，表内最新 `app_diagnostic` 事件与查询时刻同为 11:23（MYT），即实时表基本无延迟；当天实时表到 11:23 时单次取数约 107 MB，整日表 `events_20261125` 约 2.67 GB（只取所需列的 dry-run）。
- 字段（分析仓库 query-kit `references/topics/network.md:37-38`、`event-fields.md:48-49`）：`api_result.target` 为规范 API path，`api_result.trace_id` 为物理请求；`api_request_result` 为整次逻辑请求，二者不可相加。策略配置在 `diagnostic_id='strategy_config_result'` 的 `config_source_type`（direct / experiment）、`config_data_id`。

## Goals / Non-Goals

**Goals:**
- 非崩溃类线上故障在发生的第一个小时被看见，并附上足以指向「哪次发布 / 哪组实验」的分布。
- 日报、周报对技术诊断有固定一节，口径与 L0 同源。
- 判定确定、可回测、可在夹具上测试。

**Non-Goals:**
- 不判断根因，不给修复方案（与 `crash-perf-daily-weekly-report` 对 L1 的约束一致）。
- 不改 Crashlytics 各段（FATAL / ANR / NON_FATAL）的口径、阈值、三档分档。
- 不改 support 机器人；它的「影响面查询」能力在 daily-machine-hermes-ops 另开 change，口径参照本 change 的签名定义。
- 不做流程类签名的每小时告警（见决策 2）。

## Decisions

### 1. 签名 = 接口类 `target × code` + 流程类 `diagnostic_id × reason`，按设备去重

接口类只用 `api_result`（物理请求），与 `api_request_result` 相加会把一次请求算两次（11-24 support 回答里「117 次」就是这样算出来的）。受影响数用 `user_pseudo_id`（设备）为主、`user_id`（账号）为辅：访客状态下 `user_id` 为空，只按账号会漏掉登录前的失败。
备选：按事件数排序——会被单个循环重试的设备放大（11-23 单设备 38 次被拒），否决。
备选：口径 B——`result` 非 success / user_abort 都算，`code` 为空或 2xx 时用 `reason` 当错误码。这样能看见 Android `dns_failed` / `timeout`（`code` 为空，单日 1861 / 429 台）、`http_200 + decode_failed`、iOS 不带 code 的 401（`reason=unauthorized`）。回测（tasks 1.2）没有一组阈值能同时满足「≤1 次 / 天」和两条必中：传输层失败随用户网络环境大幅波动（11-03～11-07 `open/bootstrap × dns_failed` 持续爬升，每 6 小时重报一次），否决。L0 维持 spec 口径；传输层失败要监控的话另开 change，给它单独定基线。

### 2. 每小时告警只覆盖接口类；流程类只进日报 / 周报

流程类只取 `result='tech_fail'`、`record_type='outcome'`，排除接口层三个 id（维护者 2026-11-26 定）。原写法「result 非 success」实测头部被业务正常态占满：11-25 单日 `rejected` 头部是 `no_restorable_purchase`（2363 台）、`policy_override`、`not_applicable`、`not_logged_in`、`not_visible`，`user_abort` 头部是 `cancelled`、`interrupted`、`superseded`、`page_leave`；`tech_fail` 头部才是 `launch_journey_state × timeout`、`dns_lookup_result × system_resolution_unknown`、`network_probe_result × dns_failed`、`signature_refresh_result × network_error` 这类技术失败（tasks 1.4）。代价：业务拒绝类流程（如签名校验被拒）不进这一节。


回测只验证了接口类（10 天里命中 4 类，其中 1 类是作息误报）。流程类的取值更多、基线更不稳（`strategy_invalid_resource` 平时每小时 80–150 台设备），未回测就上告警会制造噪音。流程类先在日报 / 周报里呈现，攒够数据后另开 change 决定要不要进 L0。

### 3. 基线 = 前 7 天同一小时；默认阈值「≥10 台设备且 ≥4× 基线」，实施时重新回测定稿

初版回测用「前 7 天小时均值」，购买接口 `biz_40010` 每晚 21 点因作息高峰天天触发。改为同小时对比后需要重跑回测（tasks 第 1 组），验收口径：近 30 天每天平均命中 ≤ 1 次，且 11-23 17 点的 409、11-16 的 `learning-plan/home` 500 仍命中。阈值是常量，可配，回测结果和最终取值写回本节。
基线为 0 时按 1 计算倍数（防止 0→3 台被判成无穷倍），同时受设备下限约束。

**回测定稿（2026-11-26，tasks 1.2 / 1.3，MYT 10-27～11-25 共 30 天）：**
- 小时级（L0）：**≥10 台且 ≥4× 前 7 天同小时均值**，同签名 6 小时去重。30 天命中 16 次（0.53 / 天），11-23 17 点 409（13 vs 2.4）与 11-16 learning-plan 500 都命中；`biz_40010` 21 点误报消失。下限提到 15 或倍数提到 6 都会漏掉 11-23 17 点。中位数基线与均值差别不大，取均值。
- 同一小时多个签名同时命中时合成**一张卡**（10-29 20 点 8 个接口同时 `http_404`）；按卡计 30 天 8 张。
- 日级（L1 卡片那一行）：**≥50 台且 ≥3× 前 7 天均值**，签名级（跨平台与版本相加）。30 天 2 次（0.47 / 周），两条必中。409 的日基线约 50 台 / 天（引导页平时就有少量 409），当天 178 台只高 3.6×，所以倍数取 3 不取 4。
- 「基线 < 1 按 1 计」在默认参数下不起作用（下限 10 ≥ 1 × 4），只在下限低于倍数时生效；保留它防止日后调低下限时出现无穷倍。

### 4. L0 只扫当天实时表，基线存本地小时聚合

每小时重扫 7 天历史约 15 GB × 24 次，太贵。L0 每次只查当天实时表（必要时加昨天的，用于跨零点），按小时聚合后追加写 `$STATE/diag/hourly.jsonl`；基线从本地聚合读。首次启用时一次性回填前 7 天：原估约 13 GB，2026-11-26 实测 dry-run 为 24.3 GB（11-19～11-25 七张表）。本地聚合丢失时自动回填，不当作「基线为 0」。
GA4 表的日期边界按 property 时区切分，实施时先核实 property 时区（tasks 第 1 组），跨零点的小时要从两张表取。

**1.1 实测（2026-11-26）：property 时区是 UTC。** `events_20261124` 的 `event_timestamp` 从 UTC 11-24 00:00:00 起（= MYT 08:00），`event_date` 与表后缀一致；`intraday_20261126` 同样从 UTC 00:00 起。由此：
- MYT 的一天横跨两张表：MYT D 日 = 表 `D-1` 的 UTC 16:00–24:00 + 表 `D` 的 UTC 00:00–16:00。日报取「前一完整 MYT 日」要读两张表。
- MYT 与 UTC 相差整 8 小时，小时边界对齐。L0 在 MYT hh:05 判定的上一小时，它所在的 UTC 日期就是当前 UTC 日期；只有 MYT 08:05 那一次（判定 MYT 07 点 = UTC 前一日 23 点）要读 UTC 前一日的表。
- ⚠️ 日表生成后同日 intraday 表不会立刻删除：11-26 11:28 MYT 时 `events_20261125`（378.1 万行）与 `intraday_20261125`（378.2 万行）同时存在，内容几乎一样。同一 UTC 日只能取一张，两张都在时取日表，⛔ 不能两张都读（会重复计数，扫描量也翻倍）。按 UTC 日选表由外壳层查元数据（`__TABLES__`，不计扫描字节）决定，SQL 只接收选好的表后缀。
- 晚到事件：日表里有少量 `event_timestamp` 越过 UTC 次日 00:00（最多约 3 分钟），按 `event_timestamp` 换算 MYT 小时归桶，不按表归桶。

### 5. 告警卡片附分布，不给结论

卡片内容：签名、当前小时设备 / 用户数与基线、首次进入激增时刻、平台 × 版本 × 国家头部分布、受影响设备同时段 `strategy_config_result` 的 `config_source_type × config_data_id` 头部分布。11-23 的事故里，单看签名无法区分「后端发布」与「实验配置」；配置分布一眼就能看到 49%～95% 的命中集中在三组实验配置（直接配置只有 2.2%）。
去重：同一签名 6 小时内只发一次，状态写 `$STATE/diag/alerted.json`。投递复用 `alert.sh` 的卡片与重试，目标走新变量 `CRASH_REPORT_DIAG_ALERT_CHAT_ID`（只从 `$STATE/local.env` 读，未设置则跳过投递并记录，不回落到 `CRASH_REPORT_CHAT_ID`）。

### 6. 日报一节在文档、卡片只在激增日加一行；周报变化检测用 jq

沿用 `crash-perf-daily-card-v2` 的边界：卡片只放要立刻看的东西，明细在文档。日报的「技术诊断报错」一节的版本列与日报其他按版本分列的表一致（最新 2 版 ∪ 主力补充列，`IOS_COLS` / `AND_COLS`），取数窗口是前一完整日。为什么不只取最新 2 版：iOS 最新两版常常是内部包，11-26 时 2.2.0 只有 4 个会话、2.1.2 没有诊断数据，只取它们的话 iOS 整段为空，读者会读成「无报错」。版本过滤在渲染层做，SQL 取全版本（日级基线按签名跨版本算）。周报一节按周报自身的版本口径（窗口 top2 ∪ 当日 top1），新签名 / 持续高位由 jq 对本地聚合和上周快照确定性计算。

### 7. 调度：default profile 新增 Hermes cron 任务 `diag-hourly`

`5 * * * *`（整点后 5 分钟，避开 GA4 写入尾部），包装脚本由 `install.sh` 生成，与 L1 / L2 同一套。L0 写的文件只在 `$STATE/diag/` 下，不碰 L1 / L2 的基准文件。

### 8. 双数据源：GA4 + PostHog Logs，读取时按「平台 × 版本 × 天」二选一（2026-11-27 增补）

起因：11-27 首个生产日报核验发现 iOS 诊断设备 4 天里从 4513 掉到 884。GA4 原表实测 iOS 2.1.2 有 1382 台设备、`app_diagnostic` 0 条。原因是 App 从 iOS 2.1.2、Android 2.1.1 起把技术诊断改发 PostHog Logs（项目 423878 的 Logs，不是 Events），Firebase 停发（iOS 提交 `2be0e62c2`，2026-11-19）。只查 GA4 的话，iOS 的诊断会随用户升级归零，读者会读成「无报错」。维护者 2026-11-27 定：2.1.2 的 `app_diagnostic` 从 PostHog 取。

- **取法**：HogQL（`POST /api/projects/423878/query/`），模板在 `bin/sql/diag-{daily,hourly,breakdown}.hogql`，列与对应的 GA4 SQL 完全相同，下游判定和渲染不用改。用日报机上 support 已有的那把只读 Personal API Key，放在 `$STATE/local.env` 的 `CRASH_REPORT_POSTHOG_API_KEY`，写成普通赋值、不 export（只有主进程用它，export 会进 claude -p、MCP 等子进程的环境）；经 `curl -K -` 从 stdin 传，不上命令行。
- **口径对齐**：设备按 `firebase_id` 去重，它就是 GA4 的 `user_pseudo_id`；用户按 `uid`；只算 `env=production`，Logs 里有大量 debug 包测试数据，support 的 `error_impact` 也是同一口径。去掉没有 `firebase_id` 的行（约 1%，GA4 每条都有 `user_pseudo_id`）；流程类排除空 `diagnostic_id`（GA4 里 `NULL NOT IN` 不成立）。失败记录不采样（`sampling_ratio=1.0`，11-27 实测）。接口类谓词有两种方言（`bq.sh` 的 `SQL_DIAG_API_PRED`、`posthog.sh` 的 `PH_DIAG_API_PRED`），改一处必须改另一处，check-scripts 抓不到 SQL 文本里的重复。
- **存时两边原样存，读时二选一，不相加**：本地行带 `src`，两边各取各的、各记各的覆盖（`daily-coverage-posthog.json`、`coverage-posthog.json`），按来源整段替换。读取时由核心层纯函数 `diag_pick` 对每个「平台 × 版本 × MYT 日」只留设备数之和较大的一边，相等取 PostHog。
  - **为什么不按版本号划分界**：初版写的是「iOS ≥ 2.1.2、Android ≥ 2.1.1 取 PostHog」，11-27 审查推翻了它。还没合入迁移的开发分支照样发 GA4：Android 2.2.0 在 GA4 一直有数据（11-25 还有 8 行），PostHog 里没有。按版本号判会把它判给 PostHog，结果两边都看不到。「版本号越大越晚迁移」不成立，按数据在哪边就取哪边。
  - **为什么不相加**：分界前后的 QA / 内部包两边都可能有零星数据（11-27 影子跑：GA4 里有 Android `2.1.1-qa`、`2.2.0`）。
  - **为什么按天选**：同一版本迁移前后几天两边都有数据，按天取多的一边，基线不会被另一边的零星数据带偏。读取时选，加 `src` 字段之前写入的旧行也会参与选择，不必迁移旧数据。
  - 上线时只需补 PostHog 一侧，不计费；GA4 那 35 天不用重扫（上次花了 47 GB）。任一边取数失败，整节降级为「取数失败」，⛔ 不拿一半的数据冒充全量。
- **断数按来源各判各的**：
  - L0 的「数据缺失」：⛔ 两边合起来判，GA4 导出中断会被 PostHog 的行盖住（11-27 双向测试证实）。判据从「前 7 天同小时任一天有行」收紧为「每天都有行」。原因是量小的一边（刚放量的 PostHog，用户迁走后的 GA4）夜里连续两小时为 0 是常态：iOS 2.1.2 的接口失败 11-26 一天只有 18 个小时有数据。量大的来源每小时都有数据，照样抓得到中断。代价：一次中断后的 7 天里，同一小时再断不报。
  - L1 / L2：某来源某天 0 行、而前 7 天每天都有，判为断数（`diag_day_gaps`），这一节降级为「取数失败」。PostHog 摄入中断时接口照样回 200 加空结果，那天会被记成「已取过」，不在这里拦就再也不会重取。
- **告警分布**：PostHog Logs 没有国家，k2 为空，卡片显示「未知」。策略配置经 `firebase_id` 关联同一小时的 `strategy_config_result`，但多数报错设备关联不到（11-26 全天只有 41 台上报），所以经常为空。分布附件不做二选一（cfg 行没有版本列），两边合并后 affected 相加。

## Risks / Trade-offs

- [阈值没在真实环境跑过，首周误报未知] → 首周只发「Dino AI 客服测试」群（维护者 2026-11-26 由私聊改定；群里唯一的真人是维护者）；一周后按实际命中记录决定是否改发群（观察项，到期日 2026-12-04）。
- [实时表 schema 或字段名随客户端版本变化，签名突然消失] → 某签名族连续 2 小时完全无数据而前 7 天同小时有数据时，告警写成「数据缺失」而不是「平稳」（spec：检查失败不冒充平稳）。
- [BigQuery 费用] → 单次查询经 `bqq` 设扫描上限（`BQ_MAX_BYTES`，超了 BigQuery 拒绝执行、不计费）。首周费用汇总从 `region-asia-southeast1.INFORMATION_SCHEMA.JOBS_BY_USER` 按查询文本取实际计费字节，报给维护者。
  - 原写法「审计事件流记录每次字节数」没有实现：`bq query` 的输出里没有字节数（审查 G2）。
- [L0 只在 hh:05 判一次，晚到事件可能让当时的计数偏低（审查 G3，推测）] → 每轮把达到下限一半以上的签名追加记进 `$STATE/diag/evals.jsonl`。首周汇总时和次日完整数据对比，量出偏差再决定要不要复判上一小时。
  - 必中案例 11-23 17 点只有 13 台，比下限 10 台只高 3 台，余量很小。
- [L1 / L2 / 回填并发写日聚合（审查 G5）] → `diag_daily_store` 加目录锁（最多等 120 秒，超过 10 分钟的锁视为残留）。
- [跨零点、时区切分错一小时] → 实施前核 property 时区；夹具覆盖跨零点小时。
- [PostHog 查询接口悄悄截断] → 不写 LIMIT 只回 100 行（`hasMore:true`）；LIMIT 写得再大也截到 50000 行，而且这时 `hasMore` 是 null（11-27 实测）。模板一律写 `LIMIT 50000`，回满 50000 行就判失败。当前量级：小时聚合每个 UTC 日 64 行，日聚合每天约 120 行。
- [PostHog 查询缓存] → 请求带 `refresh: force_blocking`，当天重取不会拿到旧结果。
- [L0 与 L1 同时跑撞 lark-cli 限流] → L0 只在命中时投递，平时零调用；整点后 5 分钟跑，与 08:30 的 L1 不重叠。

## Migration Plan

1. 开发机（维护者 Mac，`$STATE/local.env` 指向私聊）实现、回测、整跑 `NO_DELIVER`、实发私聊并读回产物。
2. 维护者同意后合并，日报机 `update.sh` 更新代码。接下来每一步都要维护者同意，完整清单见 `.claude/skills/deploy-prod/`「首次启用 L0」：
   - L1 / L2 日聚合一次性回填 35 天：先跑 `bin/diag-backfill.sh 35 --dry-run` 报字节数，批准后执行；
   - 在日报机 `$STATE/local.env` 写 `CRASH_REPORT_DIAG_ALERT_CHAT_ID`（2026-11-26 维护者定为「Dino AI 客服测试」群；改发私聊的话要用日报机应用下的 open_id）；
   - 生成 diag-hourly 包装脚本：⛔ 只执行 `install.sh` 里生成这一份的那一段。整体跑会把 `HERMES_HOME` 补进生产机 L1 / L2 的包装，那两份现在没有这一行；
   - 注册 `diag-hourly` cron。
3. 回退：`hermes cron pause <diag-hourly job id>` 停 L0；日报 / 周报的新增一节随代码回退 `git revert` 后 `update.sh`。L0 只写 `$STATE/diag/`，删掉即可，不影响 L1 / L2 基准。

## Open Questions

- 一周后告警改发哪个群（日报群还是值班群），由维护者看首周记录后定；不影响本次实现。
