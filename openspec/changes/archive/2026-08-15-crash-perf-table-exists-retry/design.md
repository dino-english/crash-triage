## Context

`bin/crash-daily.sh` 当前探测表存在性用一行函数：

```bash
table_exists() { bq show --format=none "${1/./:}" >/dev/null 2>&1; }
```

`${1/./:}` 把 `project.dataset.table` 的首个 `.` 换成 `:`，得到 `bq show` 需要的 `project:dataset.table`。问题在 `>/dev/null 2>&1`：所有错误（限流 429、5xx、网络、超时）与「Not found」一样都返回非零，调用方无法区分，于是瞬时故障被当作「表不存在」。见 proposal.md - Why。

调用方（同文件）：
- 第 154–160 行：放量段 `if table_exists "$SESS_IOS_RT" ... elif table_exists "$SESS_IOS_BATCH"`——RT 误判缺失会错误 fallback 到停更批量表。
- 第 216 行（crash_section）、231/234 行（crash_metrics / crash_rate）：同样依赖 `table_exists` 的布尔语义。

`lib.sh` 已有 `run_with_timeout`（不依赖 gtimeout），但 `bq show` 的问题是瞬时错误而非挂起，不需要套超时。

## Goals / Non-Goals

**Goals:**
- `table_exists` 只把「Not found」当作「不存在」，瞬时错误不误判。
- 瞬时错误有界重试（带退避），重试耗尽默认「存在」，杜绝误回退到停更批量表。
- 两份脚本副本（`bin/crash-daily.sh` 与 `scripts/crash-report/crash-daily.sh`）保持一致。

**Non-Goals:**
- 不改任何 SQL 文件、不改数据源、不改投递逻辑。
- 不动 crash-weekly.sh（它没有 `table_exists`）。
- 不做 bq 的全局重试框架（只针对 `table_exists` 这一处探测）。

## Decisions

### D1：用 stderr 关键字判定「Not found」为唯一「不存在」信号

`bq show` 表不存在时 stderr 含 `Not found: Table ...`；429 含 `429`、503 含 `503`、网络错误含 `connection` 等。因此捕获 stderr，仅当匹配 `not found`（大小写不敏感）时立即返回假；其余非零一律视为瞬时错误。

备选：解析 JSON 错误码——`bq show` 用 `--format=json` 出错时输出不稳定，关键字匹配更简单可靠，且本脚本上下文 `not found` 不会与数据内容混淆。

### D2：有界重试 3 次、线性退避

循环 3 次：`bq show` 成功 → 返回真；stderr 匹配 `not found` → 返回假；否则 `sleep $((attempt * 2))`（2s/4s）后重试。3 次上限兼顾「短抖动能自愈」与「不让日报被长阻塞拖垮」（L1 整体有 `set -e` 与 cron 时长预算）。

备选：指数退避（2/4/8s）——总时长更长、收益有限；线性退避在 3 次内足够覆盖秒级限流。

### D3：重试耗尽默认「存在」（返回真），不默认「不存在」

这是消除误回退的关键。若连续 3 次都失败且从未收到 `not found`，说明是持续瞬时故障（如 bq 整体 503）。此时返回真：脚本按原计划用 REALTIME 表查询，查询若仍失败则命中既有「数据未同步 / 表尚未同步」告警路径（诚实暴露），而不是错误 fallback 到停更批量表（静默造假象）。且脚本第 57 行有 `bq query 'SELECT 1'` 探活，bq 彻底不可用会在更早处 `fail`，不会走到这里。

备选：重试耗尽返回假 → 会复现本次「误回退批量表」bug，否决。
备选：重试耗尽直接 `exit 1` → 会让一次瞬时故障把整份日报打挂，比「用 REALTIME 查询后告警」更糟，否决。

### D4：改动落在两份脚本副本

`bin/crash-daily.sh` 与 `scripts/crash-report/crash-daily.sh` 内容一致（当前 diff 为空、非硬链接），实现须两处同步修改，避免下次 `setup.sh` 同步后覆盖丢改。

## Risks / Trade-offs

- [重试让瞬时故障也引入 2–6 秒延迟] → 可接受：L1 脚本实测 126 秒、cron 留有余量；且仅在瞬时故障时发生。
- [`not found` 关键字误匹配] → 仅匹配 stderr 里的 `not found`，且只用于「返回假」的判定；`bq show` 成功路径根本不看 stderr。
- [重试耗尽返回真，查询失败路径的告警文案为「数据未同步」而非「表不存在」] → 语义上仍诚实（数据确实没同步出来），可接受。
- [两副本手动同步易漏] → tasks 里显式列两处修改 + 实现后 `diff` 校验两文件一致。
