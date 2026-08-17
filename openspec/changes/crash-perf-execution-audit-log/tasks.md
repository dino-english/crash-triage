## 1. 事件日志基础设施（sidecar）

- [ ] 1.1 在 `bin/crash-daily.sh` 初始化段（TS/DAY 计算处）新增 `RUN_ID="$TS"`、`AUDIT_DIR="$ROOT/state/audit"`、`AUDIT_FILE="$AUDIT_DIR/$RUN_ID.events.jsonl"`、`SEQ=0`，`mkdir -p "$AUDIT_DIR"`，并落首条 `run.start` 事件（含 run_id/DAY/attempt=1/脚本版本）
- [ ] 1.2 新增 `audit()` helper：以 `jq -c -n` 组装单行事件 `{seq, ts, run_id, attempt, type, step, payload}` 并 `>> "$AUDIT_FILE"`（seq 自增）；事件写入失败不得导致脚本失败（`|| true`，审计是 sidecar 不阻塞主链路）
- [ ] 1.3 在 `bin/crash-weekly.sh` 同款加 RUN_ID / AUDIT_FILE / `audit()` helper 与 `run.start` 事件
- [ ] 1.4 将 `bin/*.sh` 与 `scripts/crash-report/*.sh` 双副本改动保持一致（先改 scripts/crash-report 再复制到 bin/，或两处同步改，验收用 `diff -q` 复测）

## 2. bq 汇聚点插桩（query 事件）

- [ ] 2.1 `q()`（crash-daily.sh:77）末尾追加 `query` 事件：sql 文件、表、DAYS、行数、耗时、rc
- [ ] 2.2 `q1d()`（:197）末尾追加 `query` 事件（format=json 查询，行数 = 返回 JSON 是否为空）
- [ ] 2.3 `qc()`（:335）末尾追加 `query` 事件（崩溃 issue 查询）
- [ ] 2.4 `table_exists()`（:87）落 `query{type:table_exists, attempt:N, rc, verdict}`，每次 attempt 各一条
- [ ] 2.5 `table_max()`（:99）与 `perf_day_offset()`（:202）追加 `query` 事件，保证无漏网（每个卡片数字可溯源）

## 3. 步骤级与生命周期事件

- [ ] 3.1 在 crash-daily.sh 各步骤（探活/性能/版本放量/崩溃/天级单日/基准/MCP/组装/卡片/索引/投递清单/持久化/收尾，对应 `echo` 断点）落 `step.start` / `step.end`（step 名、耗时、rc）
- [ ] 3.2 成功路径（:950 附近）落 `run.end{ok:true}`
- [ ] 3.3 `fail()`（:68）落 `run.end{ok:false, error}` 后再写 health 并 exit 1；crash-weekly.sh 的 `fail()`（:45）同款处理
- [ ] 3.4 crash-weekly.sh 各步骤（探活/同步仓库/抓快照/变化检测/组装/收尾）落 step 事件 + `run.end{ok:true}`

## 4. 决策与降级事件

- [ ] 4.1 版本放量选表（crash-daily.sh:277-284）落 `table_select` 事件（平台、选中表、`SESS_*_FALLBACK` 回退标记）
- [ ] 4.2 MCP 对照（crash-daily.sh:527-535 与 crash-weekly.sh:74-82）落 `fetch` 事件（success/degraded/timeout + reason）

## 5. 产出事件与 run_id 贯通

- [ ] 5.1 报告组装（:537-588）落 `report` 事件（路径、字节数）；投递清单（:869-907）落 `publish` 事件（manifest 路径、投递项）
- [ ] 5.2 `health-daily.json`（:950）与 `fail()` 写出的 health 均加 `run_id` 字段；`health.json`（crash-weekly.sh:194 / :45）同款
- [ ] 5.3 报告头（`reports/$DAY-daily.md` 与 `reports/$DAY-weekly.md`）首部加 `> 本次运行：<run_id> · 审计：state/audit/<run_id>.events.jsonl`

## 6. 保留期与重复 run 检测

- [ ] 6.1 `crash-daily.sh:951` 的 `rm -rf "$TMP"` 改为 `find "$TMP" -mtime +30 -delete`（对齐 :953 的 crash-daily-* 30d 保留）
- [ ] 6.2 落 `duplicate_run` 事件：检测 `state/audit/` 下 `run_id` 前缀 `$DAY`（YYYYMMDD-）的其它 `.events.jsonl`，存在即记录先前 run_id 列表（不中止本次运行）
- [ ] 6.3 新增 `find "$ROOT/state/audit" -mtime +60 -delete`（审计日志 60d+ 保留）

## 7. 投递台账（T1）

- [ ] 7.1 cron agent（L1/L2）投递事件写入独立文件 `state/audit/delivery-<DAY>.jsonl`（与脚本 `<run_id>.events.jsonl` 分文件）；每个 lark-mcp 调用返回后立刻写 `delivery.doc_created{label,url}` / `delivery.card_sent` / `delivery.index_appended`
- [ ] 7.2 L1 prompt（jobs.json `4b0c7362063b`）增加「查台账 → 建文档 → 立刻记台账 → 回填占位符 → 发卡片 → 记 card_sent」流程与 `card_sent` 闸门
- [ ] 7.3 L2 prompt（jobs.json `1190a07e345c`）增加同款台账查/记流程与 `index_append` 台账记录
- [ ] 7.4 台账读取容错：损坏/无法解析时按「未投递」处理，并在审计流落可见记录供人工核对

## 8. 顺带修复

- [ ] 8.1 `metrics-history.jsonl` 写入（crash-daily.sh:933-937）改为按 `day` 键 upsert（`jq 'map(select(.day != $DAY)) + [新行]'`，保留最新 7 个 day，原子写 `.tmp`+`mv`）
- [ ] 8.2 crash-weekly.sh 把 `:188`（写 manifest）与 `:193`（`cp SNAP_NEW SNAP_LAST`）顺序对调：先提升基线、落 `baseline_promoted` 事件，再写 manifest

## 9. 验收

- [ ] 9.1 DRY RUN（`CRASH_REPORT_DRY_RUN=1`）跑 crash-daily.sh，验证 `state/audit/<run_id>.events.jsonl` 事件流完整（含 run.start/step/query/table_select/report/publish/run.end），每行 `jq -c` 可解析
- [ ] 9.2 验证 metrics-history upsert：连续两次运行同一 DAY 后 `metrics-history.jsonl` 该 day 仅一行
- [ ] 9.3 验证同日二次运行：首次投递未完成（card_sent=false）→ 二次运行补投；已完成 → 复用 URL 跳过
- [ ] 9.4 `diff -q bin/crash-daily.sh scripts/crash-report/crash-daily.sh`（及 crash-weekly.sh/lib.sh）双副本一致
- [ ] 9.5 `openspec validate --strict` 通过
