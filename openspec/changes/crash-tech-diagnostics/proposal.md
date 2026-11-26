## Why

日报 / 周报只看 Crashlytics（FATAL / ANR / NON_FATAL），**App 自己上报的技术诊断（GA4 `app_diagnostic`）没有任何链路在看**。2026-11-23 17:13–22:59（MYT），沙特、韩国上线的支付墙变体策略实验让已完成引导的老用户被派回引导，`/app/v2/onboarding-journey/bootstrap` 返回 409，客户端循环重试：

| 日期 | 碰到该 409 的用户 | 其中沙特 |
| --- | --- | --- |
| 11-18～11-22 日均 | 约 50 | 约 10 |
| **11-23** | **165** | **93** |
| 11-24 | 43 | 5 |

（BigQuery `analytics_538991439.events_*`，`event_name='app_diagnostic'`，`code='http_409'` 且 `target` 含 `onboarding-journey/bootstrap`，按 `user_id` 去重；2026-11-26 实测。）

这不是崩溃，日报一个字没提；值班群里客服机器人对其中两个付费账号回答了 4 次，每次都只查单个用户、写「责任未定位」。是后端 11-24 15:18 自己发现并提交修复（`580a667`），实验在沙特 23:00 暂停。**用户先于任何告警发现了故障。**

回测（同一数据源，11-16～11-25，每小时按「接口 × 错误码」统计受影响设备，≥10 台且 ≥4× 前 7 天小时均值即触发）：11-23 17 点第一个小时就能报出（13 台 vs 基线 2.2）；同期还会报出 11-16 08–14 点学习计划首页 `http_500`（最多 32 台 vs 0.1–0.6）、11-25 21 点 `auth/refresh` `http_401`（51 vs 12.1）两起无人察觉的异常；误报主要是购买接口 `biz_40010` 每晚 21 点的作息高峰（基线改成同小时对比可压）。

## What Changes

- **技术诊断报错口径**（新）：从 GA4 `app_diagnostic` 取两类签名——接口类（`diagnostic_id='api_result'` 的 `target × code`，排除 2xx）与流程类（`diagnostic_id × reason`，`result` 为 `tech_fail`）；按平台 × 版本统计受影响设备 / 用户，判「激增 / 平稳」。判定是纯函数，不调模型。
- **每小时激增告警**（新链路 L0）：每小时扫当天实时表，接口类签名命中激增规则即发告警卡片，附平台 / 版本 / 国家 / 策略配置（`config_source_type`、`config_data_id`）分布和首次出现时刻；同一签名 6 小时内不重复报。**首周只发维护者能看到的会话**（2026-11-26 上线时定为「Dino AI 客服测试」群，群里唯一的真人是维护者）（投递目标走 `$STATE/local.env`），一周后按真实误报情况由维护者决定是否改发「Dino 崩溃 & 性能日/周报」群。
- **日报**：文档新增「技术诊断报错」一节（最新 2 版，按受影响设备排序的头部签名，附前一日与 7 日基线）；当日有签名命中日级激增时卡片摘要加一行，否则卡片不变。
- **周报**：新增「技术诊断报错」一节：本周头部签名的环比、本周新出现的签名、持续高位的签名；变化检测用 jq 确定性计算。
- **不做**：根因判断；改 Crashlytics 各段的口径、阈值、三档；改 support 机器人（它的「影响面查询工具」在 daily-machine-hermes-ops 另开 change）。

## Capabilities

### New Capabilities

- `crash-perf-tech-diagnostics`: 技术诊断报错的签名口径、激增判定、每小时告警（去重、投递目标、分布附件）、日报与周报的呈现。

### Modified Capabilities

- `crash-perf-daily-weekly-report`: 「两条相互独立的无人值守报告链路」改为三条，新增 L0 每小时诊断告警；L0 与 L1 / L2 各自定时触发、独立失败、互不阻塞。

## Impact

- 新增 SQL（`bin/sql/diag-*.sql`）、纯函数判定（`bin/lib/core/diag.sh` 或同等位置）、L0 入口脚本与 Hermes cron 包装（`install.sh` 生成）、`$STATE/diag/` 运行数据（小时聚合、去重状态）。
- 改 `crash-daily.sh`、`crash-weekly.sh` 的取数与渲染（新增一节，原有各段不变）；`check-scripts.sh` 覆盖新脚本。
- BigQuery 扫描量增加（2026-11-26 实测，见 tasks 2.4 / 8.4）：
  - L0 每小时一次、只扫当天实时表，每次 0～4.3 GB，约 33 GB / 天；命中时分布查询每次约 3.8 GB。
  - L1 每天约 6～8.6 GB，L2 每周约 8.6 GB。
  - 上线时一次性回填 L1 / L2 日聚合 35 天，约 47 GB（维护者已批准，执行前再报当天的 dry-run 字节数）。
  - L0 首次运行自动回填 7 天小时基线约 24 GB。原估 13 GB 偏低：现在单张日表 2.8～4.3 GB。
- 日报机多一个 Hermes cron 任务（default profile），需维护者同意后注册。
- 文档：`docs/CLAUDE-架构与数据口径.md`、`docs/CLAUDE-部署与运维.md`（调度表、运行数据布局）、`bin/INSTALL.md`、`bin/test/artifacts.sh`。
