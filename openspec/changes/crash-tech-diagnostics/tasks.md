# Tasks

## 0. 拍板

- [x] 0.1 技术诊断进 crash-triage（日报、周报、每小时告警三者同源），support 侧只做回答时用的查询（维护者 2026-11-26 选「全放 crash-triage」） @lead
- [x] 0.2 每小时告警首周只发维护者私聊（维护者 2026-11-26 选「先发你私聊一周」） @lead。⚠️ **2026-11-26 上线时维护者改定**：首周发「Dino AI 客服测试」群（`oc_706585b425aa175d888509b372deaebe`，群里唯一的真人是维护者），生产机 `local.env` 已写；日报机经真实 `alert.sh --to` 实发测试卡到该群读回确认送达（`om_x100b7f499b3944aceeea113934a7b21`），卡内 @ crash-triage 应用的维护人 open_id 被飞书换算为日报机应用下的身份、正常渲染——跨应用 @ 不导致发送失败
- [x] 0.3 日报机 `bq` 可读 GA4 实时表、实时表无明显延迟（2026-11-26 11:23 实测，见 design Context） @lead

## 1. 口径核实与回测（先测再搭，结论写回 design 决策 3、4）

- [x] 1.1 核 GA4 property 时区与 `events_YYYYMMDD` / `events_intraday_*` 的日期边界：取同一时刻事件分别看 `event_date` 与 `event_timestamp`，结论写进 design 决策 4 @lead。**2026-11-26 完成**：property 时区为 UTC，结论见 design 决策 4
- [x] 1.2 用「前 7 天同一小时」基线重跑回测（近 30 天，接口类签名），对比 `≥10 台 且 ≥4×` 与 2～3 组备选阈值；验收：每天平均命中 ≤1 次，且 11-23 17 点 `/app/v2/onboarding-journey/bootstrap × http_409`、11-16 `/app/v1/learning-plan/home × http_500` 仍命中；回测 SQL、扫描字节数与逐条命中清单写入本文件 1.2 下方 @lead。**2026-11-26 完成**：定稿 **≥10 台且 ≥4× 前 7 天同小时均值**（design 决策 3）
  - 回测 SQL / 评估脚本 / 全部阈值组合结果：`backtest/backtest-2026-11-26.sql`、`backtest/bt_eval.py`、`backtest/summary-2026-11-26.json`；窗口 MYT 10-27～11-25（30 天）+ 前 7 天基线
  - 扫描：processed 47,619,163,854 字节 / billed 47,620,030,464 字节，16 秒（维护者 2026-11-26 批准这一条）
  - 对比（spec 口径，均值基线；「必中」= 11-23 17 点 409、11-16 learning-plan 500）：10/4 → 16 次、0.53/天、必中 ✅✅｜10/3 → 0.60/天 ✅✅｜10/5 → 0.50/天 ✅✅｜15/4、20/4、10/6 → 漏 11-23 17 点（13 台）｜中位数基线与均值基本相同（10/4 → 0.57/天），取均值
  - 逐条命中（10/4，签名 · 设备 · 基线）：10-29 20 点 8 条同时命中（`auth/guest/bootstrap`·26·0、`learning-report-records/profile`·10·0、`pages/login`·11·0、`pages/value`·35·0、`strategy/configs/resolve`·49·0、`onboarding-journey/bootstrap` 404·43·0 与 409·15·2.6、`payment/prepare`·11·0，全是 `http_404`，像一次后端路由故障）｜10-29 22 `user/info × http_404`·10·0｜11-05 20 `user/info × http_404`·15·0.6｜11-14 10 `chat/messages × http_400`·10·0.6｜11-16 08 / 14 `learning-plan/home × http_500`·10·0 / 27·0.1｜**11-23 17 `onboarding-journey/bootstrap × http_409`·13·2.4**｜11-25 18 `chat/speech × http_400`·11·2.4 与 `× http_409`·10·2
  - 按「每次运行一张卡」计（同一小时多条合成一张），30 天共 8 张卡；`biz_40010` 21 点误报消失；proposal 里的 11-25 21 点 `auth/refresh × http_401`（51 台）对同小时基线 30.9 只有 1.65×，按同小时口径不报（与 biz_40010 同属晚间作息高峰）
  - 生产判定函数 `diag_evaluate` 对 11-23 17、10-29 20、11-25 21、11-16 14 四个小时交叉核对，与评估脚本逐条一致
  - 备选口径 B（`result` 非 success，code 空 / 2xx 时用 reason 当错误码，可看见 `dns_failed` / `timeout` / `decode_failed` / iOS 无 code 的 401）：10/4 → 1.33/天，没有一组阈值同时满足 ≤1/天与两条必中；多出来的命中主要是 11-03～11-07 `open/bootstrap × dns_failed` 持续爬升（11→57 台/小时），每 6 小时重报一次。L0 维持 spec 口径
- [x] 1.3 日级激增阈值同法回测（日报卡片那一行用），验收同 1.2 的「平均 ≤1 次 / 天」改为「≤1 次 / 周」 @lead。**2026-11-26 完成**：定稿 **≥50 台且 ≥3× 前 7 天均值**（签名级，跨平台与版本相加）：30 天 2 次（11-16 learning-plan 500 126 台 vs 3.1；11-23 409 178 台 vs 49.9）= 0.47/周，必中 ✅✅。其余：20/3 → 2.33/周｜30/3 → 1.87/周｜40/3 → 1.17/周（按「有命中的天」计 0.93/周，能多抓 10-29 的 404，但按签名次数计超标，取严）｜20/4、40/4、50/4 → 漏 11-23（409 日基线约 50 台/天，只高 3.6×）
- [x] 1.4 流程类签名（`diagnostic_id × reason`）近 7 天头部 20 条及其日波动导出，只用于日报 / 周报排序口径，不做告警 @lead。**2026-11-26 完成**（数据取自 1.2 同一次扫描，MYT 11-19～11-25，设备数/天）。⚠️ 发现：按 spec「result 非 success」取，头部被业务正常态占满（`no_restorable_purchase`、`not_applicable`、`deduped`、`missing_deeplink`、`not_visible` 等都是 `rejected` / `user_abort`），待维护者定是否收窄为只取 `tech_fail`（11-25 单日按 result 拆分核对过，扫描 2.5 GB）
  | # | 签名 | 11-19 | 11-20 | 11-21 | 11-22 | 11-23 | 11-24 | 11-25 | 日均 | 最大/最小 |
  |---|---|---|---|---|---|---|---|---|---|---|
  | 1 | `launch_journey_state × timeout` | 2359 | 2344 | 2481 | 2552 | 2506 | 2511 | 2413 | 2452 | 1.1 |
  | 2 | `subscription_operation × no_restorable_purchase` | 2133 | 2124 | 2282 | 2398 | 2324 | 2356 | 2385 | 2286 | 1.1 |
  | 3 | `dns_request_result × cancelled` | 1129 | 1547 | 2383 | 2960 | 2886 | 2764 | 2330 | 2286 | 2.6 |
  | 4 | `signature_refresh_result × network_error` | 1780 | 1903 | 1871 | 1756 | 1696 | 1705 | 1671 | 1769 | 1.1 |
  | 5 | `network_probe_result × dns_failed` | 1716 | 1779 | 1743 | 1696 | 1682 | 1711 | 1708 | 1719 | 1.1 |
  | 6 | `subscription_operation × network_error` | 1371 | 1454 | 1466 | 1421 | 1385 | 1398 | 1376 | 1410 | 1.1 |
  | 7 | `strategy_config_result × strategy_invalid_resource` | 1407 | 1512 | 1550 | 1783 | 1502 | 1173 | 535 | 1352 | 3.3 |
  | 8 | `launch_journey_state × not_applicable` | 1509 | 1435 | 1513 | 1729 | 1455 | 953 | 775 | 1338 | 2.2 |
  | 9 | `voice_tts_result × interrupted` | 1148 | 1220 | 1405 | 1462 | 1166 | 1190 | 813 | 1201 | 1.8 |
  | 10 | `dns_lookup_result × system_resolution_unknown` | 111 | 397 | 1165 | 1448 | 1580 | 1714 | 1737 | 1165 | 15.6 |
  | 11 | `auth_refresh_result × network_error` | 1061 | 1105 | 1122 | 1045 | 1073 | 1037 | 1021 | 1066 | 1.1 |
  | 12 | `tab_conversion_availability × unobserved` | 1058 | 1100 | 1228 | 1324 | 1046 | 1052 | 569 | 1054 | 2.3 |
  | 13 | `page_ready_result × cancelled` | 977 | 1049 | 1125 | 1225 | 992 | 962 | 479 | 973 | 2.6 |
  | 14 | `appsflyer_deeplink_result × missing_deeplink` | 1047 | 998 | 1037 | 1196 | 1091 | 625 | 494 | 927 | 2.4 |
  | 15 | `push_bind_result × deduped` | 915 | 976 | 1000 | 1198 | 1022 | 855 | 460 | 918 | 2.6 |
  | 16 | `dns_request_result × policy_override` | 87 | 254 | 915 | 1093 | 1236 | 1330 | 1357 | 896 | 15.6 |
  | 17 | `push_bind_result × cancelled` | 897 | 986 | 992 | 1133 | 994 | 809 | 391 | 886 | 2.9 |
  | 18 | `page_ready_result × not_logged_in` | 716 | 733 | 921 | 915 | 757 | 780 | 749 | 796 | 1.3 |
  | 19 | `classroom_resource_manifest × invalid_manifest_entries` | 767 | 648 | 822 | 907 | 815 | 758 | 741 | 780 | 1.4 |
  | 20 | `tab_conversion_opportunity × not_visible` | 699 | 724 | 907 | 892 | 732 | 764 | 721 | 777 | 1.3 |

## 2. 取数 SQL（全部经 `bqq`）

- [x] 2.1 `bin/sql/diag-hourly.sql`：当天实时表（跨零点时含前一日表），按小时 × 平台 × 版本 × `target` × `code` 聚合设备 / 用户 / 事件数，只用 `api_result`，排除 2xx 与空 `code`；验收：对 11-23 全天跑出的 409 小时序列与本 change proposal 的数字一致 @lead。**2026-11-26 完成**：`bin/sql/diag-hourly.sql`；接口类谓词收口为 `bin/lib/bq.sh` 的 `SQL_DIAG_API_PRED`（与 diag-daily 共用，全仓唯一）；表后缀由外壳层选好传入（同 UTC 日日表优先），每行只取事件时间所在 UTC 日 = 表日期的事件。11-23 实跑（表 20261122 + 20261123）：409 小时序列 16 点 3 台 → **17 点 13 台** → 18–20 点 35 / 43 / 40 → 21 点 26 → 22 点 13 → 23 点 7，与 proposal 一致
- [x] 2.2 `bin/sql/diag-breakdown.sql`：给定签名与小时，取国家 × 版本分布，以及同设备同时段 `strategy_config_result` 的 `config_source_type × config_data_id` 分布；验收：11-23 18 点 409 的配置分布里三组实验配置占主导 @lead。**2026-11-26 完成**：`bin/sql/diag-breakdown.sql`（「同时段」= 同一 MYT 小时，只取带配置字段的 strategy_config_result）。11-23 18 点实跑：受影响 35 台，配置 experiment `2124743975533666306` 18 台、experiment `2124744244396941313` 14 台、另两组 experiment 各 1 台，direct 合计 4 台——实验配置占主导；国家 × 版本头部为沙特 iOS 2.1.1（14）、韩国 Android 2.1.0（11）、沙特 iOS 2.1.0（6）
- [x] 2.3 `bin/sql/diag-daily.sql`：前一完整日，按 `{{VERSIONS}}`（最新 2 版）过滤，两类签名各取头部 N；验收：11-24 日报口径跑出 11-23 的 409 为接口类第一 @lead。**2026-11-26 完成**：`bin/sql/diag-daily.sql`。⚠️ 与原写法的差异：**不按 `{{VERSIONS}}` 过滤**，全版本输出、版本作为一列，「最新 2 版」在渲染层筛——日级基线按签名跨版本算，SQL 里只留最新 2 版会让新版本一上线所有签名基线归零、全部判激增。MYT 11-23 实跑：接口类第一为 `onboarding-journey/bootstrap × http_409`，178 台 / 166 账号（proposal 按 user_id 全局去重为 165；差 1 是按平台 × 版本分行相加时，同日升级版本的账号被数两次）
- [x] 2.4 生产 dry-run 扫描量与耗时记入本文件（每条 SQL 一行）；单次超过 3 GB 的要说明原因或改写 @lead。**2026-11-26 完成**（dry-run，字节随 `app_diagnostic` 量增长）：diag-hourly / diag-daily 单张日表 11-01 0.70 GB · 11-19 2.27 GB · 11-25 2.77 GB · 11-22 / 11-23 各约 4.3 GB；当天实时表到 11:30 为 0.11 GB。diag-daily 每次读两张 UTC 表（MYT 一天横跨两张），约 5–6 GB / 天；diag-breakdown 只读一张，11-23 为 3.75 GB，只在命中时跑。L0 每次约 0～2.8 GB（随当天实时表增长），估约 33 GB / 天。超 3 GB 的原因：费用几乎全在 `event_params` 这一列，GA4 导出表不分区不聚簇，按 event_name 过滤省不了，没有改写空间

## 3. 判定纯函数（`bin/lib/core/diag.sh`）

- [x] 3.1 `diag_spike <设备数> <基线> <下限> <倍数>` → 激增 / 平稳；基线为 0 按 1 计；`diag_dedupe <签名> <上次时刻> <当前时刻> <窗口>` → 发 / 不发 @lead。**2026-11-26 完成**：`bin/lib/core/diag.sh`；去重实现为 `diag_dedupe <alerted.json 内容> <签名> <当前 epoch> <窗口秒>`（从状态内容里按签名取上次时刻，比原写法少一次调用方查表），另加签名级判定 `diag_evaluate`；激增规则只有一份 jq 定义，两个函数共用
- [x] 3.2 夹具 `bin/test/core-diag.sh`：11-23 17 点 409（应激增）、21 点 `biz_40010` 同小时基线（应平稳）、基线 0 + 3 台（应平稳）、基线 0 + 12 台（应激增）、6 小时内第二次命中（不发）、6 小时后再命中（发）；⛔ 双向——去掉基线按 1 计、去掉下限、去掉去重任一分支都要有用例变红 @lead。**2026-11-26 完成**：`bin/test/core-diag.sh` 17 条全过；双向已测——去掉「基线按 1 计」「设备下限」「去重」各有 1 条变红，还原后 145/145 通过
- [x] 3.3 `check-scripts.sh` 十项全绿（含第 4 项核心层依赖 lint） @lead。**2026-11-26 完成**：`check-scripts.sh` 输出「✅ 全部通过」（预先存在的跳过项 `fn-fetch-events-mcp.sh` 缺依赖，与本 change 无关）

## 4. L0 每小时链路

- [x] 4.1 `bin/diag-hourly.sh`：取数 → 追加 `$STATE/diag/hourly.jsonl` → 读本地基线判定 → 命中且未去重则调 `alert.sh` 发卡片 → 写 `$STATE/diag/alerted.json`；完成哨兵与非零退出照 L1 / L2 约定；验收：`fn-*` 函数级测试在 `bin/test/harness.sh` 生产 shell 设置下跑通 @lead。**2026-11-26 完成**：`bin/diag-hourly.sh`。与原写法的差异：①去重状态写 `$STATE/diag/alerted.json` 为 `{签名:{sent,first,last}}`，`first` 用来给出「本轮首次激增时刻」；②激增卡片不走 `alert.sh` 的失败卡样式，由 `core/diag.sh` 的 `diag_card` 渲染，经 `lib/lark.sh` 的 `lk` 发送（复用 429 退避）；L0 自身失败仍走 `alert.sh`，新增 `--to` 参数把失败告警限定在诊断告警目标，且只在「上次成功 → 本次失败」时发一次；③同一小时多个签名合成一张卡、分布查询一次查完；④回包无 `message_id` 判投递失败（F57）。`bqq` 新增两个可选上限 `BQ_MAX_BYTES` / `BQ_MAX_ROWS`，L1 / L2 不设、命令行不变。⚠️ 实测踩到：`bq query` 默认只返回 100 行且不报错，L0 设 `BQ_MAX_ROWS=1000000`。验收：`bin/test/fn-diag-hourly.sh` 40 条全过（跑真脚本，桩掉 bq / lark-cli，零字节零投递）；双向——去掉「只从 local.env 读」、去掉 `ALERT_TO`、失败标记每轮清，各有用例变红
- [x] 4.2 基线回填：`$STATE/diag/hourly.jsonl` 缺失或不足 7 天时先回填，回填失败非零退出（⛔ 不当作基线为 0）；验收：删掉本地聚合后跑一次，回填完成且判定结果与未删时相同 @lead。**2026-11-26 完成**：缺失的 UTC 日由 `diag_need_dates` 判定（日表或次日 00:05 UTC 后取的 intraday 才算完整），一次查询回填。实跑（临时 STATE，MYT 11-01 10 点，dry-run 4.62 GB）：当天 296 行 + 回填 7 天 1829 行；删掉 `hourly.jsonl` / `coverage.json` 重跑，`last-eval.json` 逐字节相同；与已批准回测的独立计算逐条一致（19 个签名的设备数 / 基线 / 判定）
- [x] 4.3 数据缺失判定：签名族连续 2 小时无数据而前 7 天同小时有数据 → 卡片写「数据缺失」；查询失败、表不存在 → 非零退出；验收：用 `CRASH_REPORT_BQ_CACHE` 冻结空结果复现 @lead。**2026-11-26 完成**：`diag_missing`（本小时与上一小时都无行、前 7 天同小时有行 → 数据缺失卡，橙色，6 小时去重）；表不存在 / 查询失败 → 非零退出。验收用夹具复现（桩 bq 对当天返回空结果、表元数据返回空），未用 `CRASH_REPORT_BQ_CACHE`——夹具更直接，且零字节。⚠️ **2026-11-26 收尾自查订正**：原实现发完「数据缺失」卡后退出码 0，与 spec「数据未更新 → 非零退出并留下失败记录」不符；改为发卡后置告警标记再 `fail`（`health-diag.json` 写 ok:false、非零退出，不叠泛化失败卡），夹具 ⑦ 改断言并双向测过（45 / 45）
- [x] 4.4 投递目标 `CRASH_REPORT_DIAG_ALERT_CHAT_ID` 只从 `$STATE/local.env` 读，未设置跳过投递并记录；验收：未设置时日志有跳过原因、没有任何 lark-cli 发送调用 @lead。**2026-11-26 完成**：脚本开头 `unset` 同名变量再 source local.env；未设置时不跑分布查询、不调 lark-cli，日志写「未设置 CRASH_REPORT_DIAG_ALERT_CHAT_ID…跳过投递」。夹具 ① 验证命令行传 `oc_` 目标被忽略、lark-cli 零调用
- [x] 4.5 卡片：签名、设备 / 用户数与基线、首次激增时刻（MYT）、国家 × 版本头部、策略配置头部；⛔ 不写根因；验收：开发机对 11-23 18 点冻结数据实发私聊，`docs +fetch` / 读回卡片逐项核 @lead。**2026-11-26 完成**：开发机临时 STATE（基线用已批准回测的数据灌入，0 字节；当天 20261123 一张表 + 分布查询），回放 MYT 11-23 18 点实发维护者私聊（message_id `om_x100b7f4eba14aca0edacc52b1e34979`），`+messages-mget` 读回逐项核：签名、35 台 / 32 账号 vs 前 7 天同小时均值 4 台（6+6+4+2+4+1+5 / 7，回测数据核过）、本轮首次激增 18:00、国家 × 版本头部（沙特 iOS 2.1.1 14 台、韩国 Android 2.1.0 11 台…）、策略配置头部（experiment `2124743975533666306` 18、`2124744244396941313` 14…）、无根因。读回后给配置计数补了「台」单位
- [x] 4.6 `install.sh` 生成 `~/.hermes/scripts/diag-hourly.sh` 包装（写死 ROOT / STATE / LARK_PROFILE），`bin/test/artifacts.sh` 登记 `$STATE/diag/` 产物；验收：开发机 `install.sh` 后包装脚本存在且 `env -i` 下可跑 @lead。**2026-11-26 完成**：`install.sh` 生成 `~/.hermes/scripts/diag-hourly.sh`（不导出 `CRASH_REPORT_CHAT_ID`；cron 只打印注册命令不执行）；`update.sh` 缺这个包装时提示；`artifacts.sh` 登记 `health-diag.json` 与 `diag/`。⚠️ 验收方式与原写法不同：开发机**未跑完整 install.sh**——它会用当前环境重写开发机已有的 crash-daily / crash-weekly 包装（现有那份投递目标是正式群）；改为抽出生成段在临时目录生成，`env -i` 下跑通（rc=0）
- [x] 4.7 L1 卡片显示 L0 停摆：`health-diag.json` 存在且超过 3 小时没跑、最近一次失败或读不出时加一行 @lead。**2026-11-26 完成**（收尾自查时补：cron 停了 L0 不跑、它的失败告警也发不出，原设计没有任何东西会发现）：判定在 `core/diag.sh` 的 `diag_l0_line`（4 条单测），接线在 `crash-daily.sh`；`bin/test/fn-diag-l0-line.sh` 抽接线段在生产 shell 设置下验五态（未启用 / 健康 / 停摆 / 失败 / 损坏），双向测过（改回 `[ ] && …` 收尾即变红）；平稳日整跑卡片与改前逐字节一致（见 5.2）

## 5. 日报一节

- [x] 5.1 `crash-daily.sh` 取数接入 `diag-daily.sql`；文档新增「技术诊断报错」一节（两类各一张表，列：平台 | 版本 | 签名 | 设备 | 用户 | 前 7 日同日基线 | 激增）；验收：整跑 `CRASH_REPORT_NO_DELIVER=1` 产物里有该节 @lead。**2026-11-26 完成**：取数 / 存储在共享外壳层 `bin/lib/diag.sh`（L1 / L2 / 回填共用），本地日聚合 `$STATE/diag/daily.jsonl`；文档「五、技术诊断报错」追加在原有各段之后（md / xml 两个渲染点共用同一份 CSV）。整跑 `NO_DELIVER`（baseline.sh，诊断日 11-25）产物里有该节，rc=0。⚠️ 与原写法的差异：流程类「激增」列写「不判」（日级阈值只对接口类回测过，spec 已同步）
- [x] 5.2 卡片：仅日级激增时摘要加一行并链接到文档该节；平稳日卡片与改前逐字节一致；验收：两份冻结数据（11-24 激增、11-26 平稳）各跑一次，平稳那份卡片 JSON 与改前 diff 为空 @lead。**2026-11-26 完成**：同一冻结缓存下与改前代码（HEAD worktree）对照——平稳日（诊断日 11-25）`card.json` 逐字节相同；激增日（诊断日 11-23）`card.json` / `message.md` 恰好多一行「🚨 技术诊断报错激增（11-23）：/app/v2/onboarding-journey/bootstrap × http_409 全版本 178 台（前 7 日均值 49.9）」。⚠️ 取数失败时卡片也加一行（写明取数失败，不冒充平稳），spec 已改为此口径（审查 8.5 指出代码与 spec 字面不符）
- [x] 5.3 原有崩溃 / 性能 / 放量各段零变化；验收：等价性验收 `bin/test/baseline.sh` 三层产物除新增一节外 diff 为空 @lead。**2026-11-26 完成**：A（改前）vs B（改后）三层产物 diff：daily.md / daily.xml 只有新增一节（xml 为第 455～498 行纯插入，0 行删改）；中间层多 diag-*.csv / diag-rows.json、基准层多 diag/；`snapshot.json` 差异为 git 反查的分支列表（模型 / git 路径不受冻结缓存覆盖，eqv-check 已注明，与本改动无关）。⚠️ 三次跑批里 `fetch-issue-states.py`（既有脚本）读 MCP 回包无超时、每次都卡住，由看门狗 90 秒杀掉后走既有的「沿用缓存」降级——三次处理一致，不影响对照

## 6. 周报一节

- [x] 6.1 `crash-weekly.sh` 新增「技术诊断报错」一节：本周头部签名环比、本周新出现（前 4 周未出现且达下限）、连续高位；jq 确定性计算，⛔ 不进 `claude -p` 分析层；验收：用 11-17～11-23 冻结数据跑出 409 为本周新出现 @lead。⚠️ **2026-11-26 验收前提订正**：`onboarding-journey/bootstrap × http_409` 不是新签名——回测日数据显示 10-23 起每天都有（10-24～11-22 每天 22～62 台，11-23 178 台），按「前 4 周未出现」它不会进「本周新出现」。改为验收：用 11-17～11-23 数据跑，409 出现在头部签名环比里且为上升（本周日均 68.1 vs 上周 48.0，+42%），不出现在「本周新出现」里。**2026-11-26 完成**：jq 确定性计算（`core/diag.sh` 的 `diag_weekly`，数据从本地日聚合取，⛔ 不进 `claude -p`）。跑批日 11-24 回放（本周 11-17～11-23）：409 在头部签名里为签名级 68.1 vs 48.0（+42%），不在「本周新出现」里；「本周新出现」报出 `/app/v1/chat/speech × http_400` / `× http_409`（11-20 首现）与 4 条语音流程类；「持续高位」为 `auth/refresh × http_401`（136.6 / 110.7）。⚠️ 与原写法的差异：①数字是「日均受影响设备」（周内去重设备数不能由日数相加）；②头部签名的环比按**签名级**算，附主力版本分布——按平台 × 版本算时新版放量会得出 +50289% 这种假激增（首版 W1 实测）
- [x] 6.2 周报按自身版本口径（窗口 top2 ∪ 当日 top1）过滤；验收：整跑 `NO_DELIVER` 产物中该节版本列与周报其他段一致 @lead。**2026-11-26 完成**：「主力版本分布」列只列周报主力版本，W2 产物中出现的 iOS 2.1.0 / 2.1.1、Android 2.0.0 / 2.1.0 均在二段主力版本表内（iOS 2.1.2 为当日 top1、本周无诊断数据，不出现）；改前（HEAD worktree）vs 改后同一冻结缓存对照：周报卡片、群消息逐字节相同，weekly.md / weekly.xml 只有新增一节（0 行删改）
- [x] 6.3 ⚠️ L2 基线提升在 NO_DELIVER 闸门之前——测试前备份 `last-snapshot.json`，测后还原 @lead。**2026-11-26 完成**：L2 测试一律经 `bin/test/baseline.sh`（跑前备份、跑后还原 `last-snapshot.json` 等 13 项基准）；`artifacts.sh` 已登记 `diag/`。⚠️ 开发机 iOS 业务仓本地 tag `v2.1.1` / `v2.1.2` 与 `super` 远端冲突，L2「同步仓库」`fetch --tags` 必败（既有问题，未改用户仓库）；测试改用 scratchpad 里 `git clone --shared` 的临时 REPOS_ROOT

## 7. 文档

- [x] 7.1 `docs/CLAUDE-架构与数据口径.md` 新增「技术诊断报错」一节：签名口径、`api_result` 与 `api_request_result` 不可相加、基线与阈值（回测结论）、为什么流程类不进 L0 @lead。**2026-11-26 完成**：新增「技术诊断报错」一节（签名口径、两类不可相加、UTC 时区与选表、bq 默认 100 行截断、阈值与回测结论、流程类为何不进 L0、版本过滤在渲染层、费用）
- [x] 7.2 `docs/CLAUDE-部署与运维.md`：调度表加 `diag-hourly`、运行数据布局加 `$STATE/diag/`、回退命令 @lead。**2026-11-26 完成**：调度表加 `diag-hourly`（job id 待注册后补）、注册 / 回退命令、`$STATE/diag/` 布局与各文件丢失后果、链路对照表加 L0 一列（✅ 上线后已补 `01c4ed7d509e`）
- [x] 7.3 `bin/INSTALL.md`、`bin/local.env.example` 加 `CRASH_REPORT_DIAG_ALERT_CHAT_ID`（示例值用占位符，⛔ 不写真实 open_id） @impl-worker。**2026-11-26 完成**（⚠️ 未派发：几分钟能做完，按委派规则「不派的情形 ①」由 lead 做）：INSTALL.md §0 / §5 / §7.3 与 local.env.example 加 `CRASH_REPORT_DIAG_ALERT_CHAT_ID`，示例值为占位符
- [x] 7.4 `CLAUDE.md` 首段「两条独立链路」改为三条 @lead。**2026-11-26 完成**

## 8. 验收（三步，按 CLAUDE.md「测完」口径）

- [x] 8.1 `check-scripts.sh` 十项全绿（原文贴本文件） @lead。**2026-11-26 完成**（最终一次原文摘录）：`纯函数断言：190 通过，0 失败 ✅` · 函数级夹具 42 个全部 0 失败（含新增 `fn-diag-hourly.sh` 43 条、`fn-diag-daily-fail.sh` 4 条）· `⚠️ 1 个夹具被跳过（缺依赖）：fn-fetch-events-mcp.sh`（既有，与本 change 无关）· ShellCheck `共 74 处`（与改前相同）· `✅ 全部通过`，rc=0
- [x] 8.2 开发机整跑 L1、L2 `NO_DELIVER` 各一次、L0 一次，退出码 0，产物齐全（`assert-artifacts.sh`） @lead。**2026-11-26 完成**：L1 整跑 `NO_DELIVER`（baseline.sh）A / B / B2 / C / C2 共 5 次 rc=0；L2 W0 / W2 rc=0；L0 真数据回放（4.2 / 4.5）rc=0。`assert-artifacts.sh`：L1 激增日产物 4 / 4 通过，L2 产物 2 / 2 通过。⚠️ 每次 L1 / L2 整跑，既有脚本 `fetch-issue-states.py`（读 MCP 回包无超时）都会卡住，由测试驱动的看门狗 90 秒杀掉后走既有降级——生产是否同样会卡未核，已报维护者。**收尾自查补测**：最终版 L0（13:23 之后的修改未经真数据）用真数据重跑 11-23 18 / 17 点两次 rc=0（当天 348 行、无截断；判定与中午一致；evals.jsonl 写入）；最终版回填工具 dry-run 35 天 47.4 GB；日报机只读核对：bash 3.2.57 / jq 1.7.1 与开发机一致，`bq` 读 `__TABLES__` 0 字节可用，生产 L1 近 5 天 `fetch-issue-states` 均正常、L2 近 3 周同步仓库正常（开发机的卡住与 tag 冲突只在开发机）
- [x] 8.3 开发机实发维护者私聊：L1 日报、L2 周报、L0 告警卡片各一份，读回逐项核（新增一节在、原有各段不变、卡片字段齐） @lead。**2026-11-26 完成**（全部只发维护者私聊；文档为 bot 临时建，不进共享文件夹、不碰索引页 / 台账）：①L0 告警卡 `om_x100b7f4eba14aca0edacc52b1e34979`（11-23 18 点回放，读回五项齐，见 4.5）；②L1 日报激增日卡片 `om_x100b7f48f4340ca4ed05e044eef3130`，读回含技术诊断一行且链接可点；临时日报文档 `JFJGdBncboWy4JxaH3IjQizppxO`，`docs +fetch` 读回：「五、技术诊断报错（2026-11-23）」两张表 32 行、两行带「🚨 全版本 178 台 vs 均值 49.9」、流程类「不判」、原有一～四段在；③L2 临时周报文档 `J33ddhHMuoFjd7xFzLkjuOWBpKd`，读回「七、技术诊断报错」三张表 30 行，409 行 68.1 / 48 / +42%；说明消息 `om_x100b7f48f5e98ca8ed897bffc675a0c`。两份临时文档核完已删除（2026-11-26 收尾，按标题核对后 `drive +delete --as bot`）
- [x] 8.4 BigQuery 实际扫描字节：L0 单次、L1 / L2 增量，从审计事件流取数记入本文件 @lead。**2026-11-26 完成**（来源 `region-asia-southeast1.INFORMATION_SCHEMA.JOBS_BY_USER` 的 `total_bytes_billed`，⚠️ 审计事件流不记字节，见 design Risks）：L0 单次 = 当天一张表约 3.8 GB（11-23 整天）+ 命中时分布查询 3.75 GB；L1 增量 = 每天重取前一日两张表 6.0 GB（11-25）～ 8.58 GB（11-23）；L2 增量 = 重取一天 8.58 GB（历史完整时）。本 change 今天合计约 187 GB（回测 47.62 + 开发机回填 48.07 + 其余验证 ≈ 91，单条均 < 20 GB）。⚠️ 同账号今天另有约 580 GB 来自本 change 以外的查询（10:38～11:18 的 409 排查、带 `@tz` 参数的查询等），不计入
- [x] 8.5 对 `bin/` 全部 diff 做对抗审查（bash 3.2、跨进程边界、口径标注三类镜头），问题清单回 lead 复核 @crash-reviewer。**2026-11-26 完成**（crash-reviewer 审查后 lead 复核）：S1（`$( )` 内失败触发 ERR trap → L1 / L2 降级路径发假故障卡，可能进正式群）已复现并修复（`trap - ERR`），新增 `fn-diag-daily-fail.sh` 双向测试；G1 计费上限放宽；G2 字节数改从 INFORMATION_SCHEMA 取；G3（推测：hh:05 判定时数据不全）改为记 `evals.jsonl` 首周量化，未改判定；G4 表格渲染提前、三处结论一致；G5 日聚合写锁；G6 L0 失败卡写具体原因并加夹具场景；建议项（空版本集提示、阈值单处定义、`|` / `<` 转义、锁年龄上限、临时文件清理）已改。审查指出的「取数失败时卡片加一行」与 spec 字面冲突，按「缺数可见」改 spec，已报维护者

## Workflow follow-up

**上线记录（2026-11-26，每一步都经维护者同意）**：
- 合并推送：super / origin 都到 `4987c43`。
- 日报机 `update.sh`：自检全过；`setup.sh 失败` 是已登记的假故障，`path.env` 未被改动。
- 35 天回填：dry-run 47.41 GB，实际计费 47,406,120,960 字节，写入 19507 行。
- `local.env` 追加 `CRASH_REPORT_DIAG_ALERT_CHAT_ID`：首周发「Dino AI 客服测试」群，备份为 `local.env.bak-20261126`。经真实 `alert.sh --to` 实发测试卡到该群，读回确认送达。
- L0 包装脚本：只执行 `install.sh` 里生成这一份的那一段；L1 / L2 两份包装与备份 `cmp` 一致。
- `env -i` 首跑 rc=0：判定 14:00，无激增；自动回填 7 天小时基线 2235 行。
- 注册 cron `diag-hourly`（`01c4ed7d509e`），首个定时运行在 16:05。
- 16:01 日报机更新到 `a3045e7`。两个新脚本的权限位仓库补成 755；日报机先 `git checkout --` 恢复再 pull，工作区干净。
- 16:05 首个定时运行 `completed`，7 秒：判定 15:00，12 个签名，无激增，未回填。


- 合并、推送、日报机 `update.sh`、注册 `diag-hourly` cron、写日报机 `$STATE/local.env`：每一步都要维护者同意。
- 观察项（不挡归档）：2026-12-04 汇总首周 L0 命中记录与实际 BigQuery 费用报维护者，由维护者定是否改发群；改发群是投递目标变更，不需另开 change。
