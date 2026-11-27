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
5. **L0 每小时诊断告警**（2026-11-26 起，job id `01c4ed7d509e`）：
   - `jq -c . $S/health-diag.json`：`ok:true`，且 `last_run` 在最近 1 小时内。`ok:false` 且 `error` 以「数据缺失」开头时，先查 GA4 实时表是不是停更了。
   - `sqlite3 ~/.hermes/cron/executions.db "SELECT status,claimed_at FROM executions WHERE job_id='01c4ed7d509e' ORDER BY claimed_at DESC LIMIT 6;"` 应该每小时一条。
   - PostHog 一侧（iOS 2.1.2 / Android 2.1.1 起的版本，2026-11-27 起）：`jq -r 'keys | join(" ")' $S/diag/coverage-posthog.json` 应包含今天的 UTC 日；`ok:false` 且日志里是「PostHog：…」时，先查 `local.env` 有没有 `CRASH_REPORT_POSTHOG_API_KEY`、PostHog 接口回了什么（日志里有 HTTP 码和 detail 原文）。
   - 命中记录看 `tail $S/diag/hits.jsonl`。日报卡片上出现「L0 … 没有运行 / 最近一次失败」那一行时，从这一项开始查。
6. 失败排查入口：`ls -t $S/logs | head` + `$S/runs/<日期>/L{1,2}/latest/`。
