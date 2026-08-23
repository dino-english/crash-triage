# 实施中发现（2026-08-23 实施）

## F1 DRY RUN 当场晒出一个既有渲染 bug：口径行 `${CRASH_DAYS}d` 字面量

验证 4.2 的 DRY RUN 日志里，卡片口径行印着 `Android=ANR 率（${CRASH_DAYS}d，…`——
printf 的格式串是单引号，变量不展开。`git log -S` 定位为 2303dcc（2026-08-22 卡片改版）引入，
**此后每天的卡片与文档都带着这行字面量**。已修（%s 占位 + 传参），单独提交。
这正是本 change 的论据：没有对产物的系统性检视，渲染层的小错会一直沉默地随卡片投递。

## F2 事件未覆盖的取数尾巴（记录在案，不在本轮范围）

- `crash-daily.sh` 的 sessions-by-version 直调 bqq（放量明细）
- `crash-weekly.sh` 的 ver_* / top2_versions / tbl_max / perf_row（design D4 的范围本就是 L1）
- `fetch-snapshot-bq.sh` 的 bq_json

三者都已收口到 bqq（change crash-perf-functional-core F1），日后若要补齐，
在 bqq 单点埋通用事件即可覆盖全部三个进程——比本轮的逐函数埋点便宜得多。

## F3 fail() 的遮蔽死代码（顺带修复）

两个入口脚本都在 source common.sh **之后**无条件重定义 fail()，共享版实为死代码；
重复定义检测的豁免清单误记它们为「回落分支」（真正的回落分支定义带缩进，
恰好躲过了 `^[a-zA-Z_]` 锚定的检测——两层巧合叠出的盲区）。已删除两处遮蔽，
行为逐字相同（写的正是各自预设的 HEALTH_FILE）。副作用：common.sh 缺失的降级路径下
fail 不再写 health/发告警（原遮蔽版在该路径下仍全功能）——双重故障场景，接受。

> **F2 已补（2026-08-23 当日）**：在 bqq 单点埋传输层事件 `bq.call`（与语义层 `query`
> 类型不同，不构成重复计数），weekly `export AUDIT_FILE RUN_ID` 让子进程汇入同一时间线。
> 实测：L1/L2 冻结缓存改前改后产物逐字节一致；weekly 流 37 条 bq.call 含 2 个 pid
> （父 + fetch-snapshot-bq）；L1 的 77 条 bq.call 对 72 条 query——5 条差值正是原盲区。
