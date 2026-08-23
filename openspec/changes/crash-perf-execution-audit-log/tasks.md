# Tasks — crash-perf-execution-audit-log

> **2026-08-20 重写**：原 32 项里约三分之二的前提已不成立（双副本机制废弃、cron 改 `no_agent=true`、
> metrics upsert 与基线顺序已修）。收窄为只做查询级审计，14 项。被取代部分见 proposal「已被取代的原始范围」。

## 1. 事件流基础设施

- [x] 1.1 `bin/lib.sh` 新增 `audit()` helper：`jq -c -n` 组装 `{seq, ts, run_id, type, step, payload}` 追加到 `$AUDIT_FILE`，seq 自增；**写入失败不得影响主链路**（`|| true`）—— audit() 落 bin/lib.sh；偏差：seq 用文件行数不用变量自增（事件在命令替换子 shell 里落，自增传不回，同 ALERTED 的坑）
- [x] 1.2 `crash-daily.sh` 初始化段新增 `RUN_ID="$TS"`、`AUDIT_FILE="$STATE/audit/$RUN_ID.events.jsonl"`，`mkdir -p`，落首条 `run.start`（run_id / DAY / 脚本 git sha）—— 偏差：文件名带 daily- 前缀（同 logs/ 命名；L1/L2 共用 audit/，不带前缀会把对方误判成同日重复）
- [x] 1.3 `crash-weekly.sh` 同款接入
- [x] 1.4 `$STATE/audit/` 按 mtime 保留 60 天，挂在收尾清理处（与 logs 同一段）—— 挂在 logs +60d 清理同段

## 2. 查询级插桩

- [x] 2.1 `q()` 落 `query` 事件：sql 文件名、目标表、`{{DAYS}}` 值、返回行数、耗时、rc
- [x] 2.2 `q1d()` 落 `query` 事件（format=json，行数按返回是否为空判定）—— empty 布尔代行数（q1d 恒单对象）
- [x] 2.3 `qc()` 落 `query` 事件（崩溃 issue 查询）—— 另补 qdim/qhours（任务清单写就时尚不存在）
- [x] 2.4 `table_max()` 与 `perf_day_offset()` 落 `query` 事件——补齐后**每个卡片数字都有对应事件**
- [x] 2.5 `table_exists()` 每次 attempt 各落一条 `query{type:table_exists, attempt:N, rc, verdict}`，三种结局可区分：重试后成功 / 确证不存在 / 有界重试后按存在处理—— verdict: exists/not_found/transient_retry×N/assumed_exists，fake bq 实测三种结局可辨

## 3. 生命周期与 run_id 贯通

- [x] 3.1 成功路径落 `run.end{ok:true}`；`fail()` 落 `run.end{ok:false, error}` 后再写 health 并退出（两个脚本都要）—— 收口进 common.sh 的 fail（顺带删除两处 source 后无条件遮蔽它的死代码，行为逐字相同）
- [x] 3.2 `health-daily.json` / `health.json` 加 `run_id` 字段—— daily 成功路径本就有 run_id；weekly 成功路径与 fail 补齐
- [x] 3.3 日报与周报正文头部加一行审计指针：`> 本次运行 <run_id> · 审计 $STATE/audit/<run_id>.events.jsonl`—— 日报 md+XML、周报 md 各一行
- [x] 3.4 `duplicate_run` 事件：检测 `$STATE/audit/` 下同 `$DAY` 前缀的其它 `.events.jsonl`，存在即记录先前 run_id 列表（**不中止本次运行**）—— 只记录不中止

## 4. 验收

- [x] 4.1 `bash bin/check-scripts.sh` 全绿（两项：`bash -n` + `$VAR` 紧邻多字节字符）—— 七项全绿（/bin/bash 3.2）
- [x] 4.2 DRY RUN 跑 L1：事件流每行 `jq -c` 可解析，含 `run.start` / `query` / `run.end`—— 82 行全部 jq -c 可解析：run.start/step.start×8/query×72/run.end
- [x] 4.3 抽一个卡片数字，验证能从事件流回指到 sql 文件 + 表 + 窗口 + 行数—— 卡片「崩溃 7d」Android 26 次 → seq39 事件 crash-rate.sql×ANDROID_REALTIME×7d×1.5.3
- [x] 4.4 造一次 `table_exists` 重试（改 bq 路径或断网），验证三种 verdict 各自可辨—— fake bq 仿真：exists rc0 / not_found rc1 / transient×3→assumed_exists rc0
- [x] 4.5 审计写入失败不影响主链路：把 `$STATE/audit` 置为只读后跑 DRY RUN，脚本仍 exit 0—— chmod 555 audit/ 后 DRY RUN 仍 exit 0，事件静默丢弃
