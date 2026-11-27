## Why

L0 每小时只在整点后 5 分钟判一次上一小时，用的是当时已进表的量。2026-11-27 用次日完整数据重算 11-26 20 点：
实时判定只见 lottie / manifest × 401 10 台，完整数据里同一小时有 3 个签名激增（lottie 19 台、auth/logout 14 台、
membership/current 10 台，GA4 原表独立核对一致）——实时只到约一半，漏报 2 个签名，且之后永远不会再报。

## What Changes

- 每次运行判完本小时后，**复判再往前一小时**：同一套激增判据与 6 小时去重，数据是这一轮整天重取后更完整的本地聚合。
- 复判时新达到阈值、且未在 6 小时内报过的签名，另发一张「复判补报」卡（标题写被复判的小时、脚注写晚报一小时的原因）；
  两小时都待发的签名只进本小时那张卡，卡上写「从 上一小时 起持续」。
- 判定 MYT 08 点那次（09:05 运行）复判的 07 点在前一个 UTC 日：把那天的 GA4 表与 PostHog 再取一次（每天多扫一张表，约 0.7～4.3 GB）。
- 基线完整性按「本小时 + 复判小时」两组前 7 天的并集判，跨 UTC 日时不把多出的那天当基线 0。
- `hits.jsonl` / `evals.jsonl` 的复判行带 `recheck:true`；`health-diag.json` 增加 `recheck_sent`。

## Capabilities

### Modified Capabilities

- `crash-perf-tech-diagnostics`：「每小时激增告警」增加复判上一小时与补报。

## Impact

- 只改 L0：`bin/diag-hourly.sh`、`bin/lib/core/diag.sh`（`diag_plan` 的 last 只前移、`diag_card` 加复判模式）。L1 / L2 不变。
- 费用：复判不另查（复用整天重取的数据）；只在 09:05 那次多取一张前一日的表；补报时多一次分布查询（约 3 GB）。
- 回退：revert 本 change 的提交，日报机 `update.sh`。
