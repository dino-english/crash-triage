## 1. 改造 table_exists（bin/crash-daily.sh）

- [x] 1.1 重写 `table_exists()`：捕获 `bq show` 的 stderr，退出码 0 → 返回真；stderr 匹配 `not found`（大小写不敏感）→ 返回假且不重试；其余非零 → 视为瞬时错误
- [x] 1.2 加有界重试：瞬时错误最多重试 3 次、线性退避（`sleep $((attempt * 2))`）
- [x] 1.3 重试耗尽仍未确证「不存在」→ 返回真（按「存在」处理，让后续查询失败走既有「数据未同步」告警）

## 2. 同步两份副本

- [x] 2.1 将上述改动同步到 `scripts/crash-report/crash-daily.sh`
- [x] 2.2 `diff bin/crash-daily.sh scripts/crash-report/crash-daily.sh` 确认两文件一致

## 3. 验证

- [x] 3.1 `bash -n bin/crash-daily.sh` 语法通过
- [x] 3.2 单测 `table_exists` 三分支：对「存在的表」返回真、对「不存在的表名」返回假、对模拟瞬时错误（如临时 `PATH` 里放个假 `bq` 返回 429）重试后返回真
- [x] 3.3 `CRASH_REPORT_DRY_RUN=1` 跑 L1，核对放量段仍走 REALTIME 表正常出数、无「回退批量表」标注、各段截止时间戳正确
- [x] 3.4 `openspec validate --strict` 通过

## 4. 收尾

- [x] 4.1 回填 `dino-crash-perf-report` skill「已知坑」：新增「table_exists 只把 bq 的 not found 当不存在，瞬时错误有界重试、耗尽默认存在，防止误回退停更批量表」
