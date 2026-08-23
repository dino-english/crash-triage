---
name: morning-verify
description: 生产 cron 跑批后的核验——executions.db、health run_id、审计事件流、台账同步四查。部署新代码后的首个跑批日必用。
---

# 跑批后核验（生产机）

前置：`ssh dino911@dino911s-mac-mini`，`S=~/.local/state/crash-triage`，
bq/hermes 需先 `. $S/path.env; export PATH`。

1. **调度层**：`sqlite3 ~/.hermes/cron/executions.db "SELECT job_id,status,claimed_at,finished_at FROM executions ORDER BY claimed_at DESC LIMIT 8;"`
   ——看 crash-daily / crash-weekly 的 status（⚠️ `hermes cron run` 的 `Ran now: failed` 是假故障，以这里为准）。
2. **健康层**：`cat $S/health-daily.json $S/health.json`——`ok:true` 且 `run_id` 是今晨时间戳。
3. **审计层**（2026-08-23 起有）：
   ```bash
   A=$(ls -t $S/audit/daily-*.jsonl | head -1)
   jq -c type $A >/dev/null && echo 可解析; jq -r .type $A | sort | uniq -c
   jq -c 'select(.type=="run.end")' $A     # 必须存在且 ok:true
   ```
   查任何可疑数字：`jq -c 'select(.payload.sql=="<某>.sql")' $A` 给出表/窗口/行数/耗时/rc。
4. **台账同步**（仅周一 L2 后）：核对飞书台账 `TtpwdhgKroMH1DxJumojTflrppz`——
   FATAL 现状表未被扰动、NON_FATAL 表正确替换、变更时间线历史未丢（sync_ledger 全程不 overwrite）。
5. 失败排查入口：`ls -t $S/logs | head` + `$S/runs/<日期>/L{1,2}/latest/`。
