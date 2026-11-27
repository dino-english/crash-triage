---
name: crash-report-debug
description: crash-triage 流水线的调试与验证流程（DRY_RUN / NO_DELIVER / 等价性测试），不真投递地验证卡片、索引页、manifest 与产物。用于：改完脚本想看效果、只验索引页或投递清单不发群、验证降级路径、等价性回归；或当用户提到 DRY_RUN、NO_DELIVER、不投递、验卡片、验索引页、跑批测试、等价性验收 时。
---

# crash-report-debug

## 核心事实（先读）

1. **DRY_RUN ≠ NO_DELIVER**：`CRASH_REPORT_DRY_RUN=1` 打完卡片预览就 `exit 0`，**跑不到 build_index / manifest**；要验索引页或投递清单必须用 `CRASH_REPORT_NO_DELIVER=1`（走完整链路，只是不投）。
2. ⚠️ **整跑要 5 分钟以上，别设短超时**——进程被信号杀掉会触发 ERR trap，把「被杀」当成故障告警发进群（2026-08-20 因 2 分钟超时误报实测）。
3. **投递目标由机器决定**：`$STATE/local.env` 的 `CRASH_REPORT_CHAT_ID`。开发机是 `ou_` 私聊，`deliver.sh` 据此**自动跳过归档 / 索引页覆盖 / 台账同步**——所以开发机上敢真投，正式产物不受影响。
4. ⚠️ **L2 的基线提升在 NO_DELIVER 闸门之前**（`crash-weekly.sh`）——「跑两次对比产物」在 L2 不成立，第二次必然零变化。**测试前先备份 `$STATE/last-snapshot.json`**，测完还原。
5. **活数据上 diff 永远不为空**（滚动窗口锚在跑批时刻）——等价性回归必须冻结缓存，完整协议走 `eqv-check` skill（`CRASH_REPORT_BQ_CACHE`，**生产禁用**）。

## 流程

```bash
bash bin/check-scripts.sh                            # ① 改脚本后必跑（十项静态检查）
CRASH_REPORT_DRY_RUN=1 bash bin/crash-daily.sh       # ② 快速看卡片预览（跑不到索引页）
CRASH_REPORT_NO_DELIVER=1 bash bin/crash-daily.sh    # ③ 完整链路：验索引页 / manifest / 产物
ls "$STATE/runs/$(date +%F)/L1/"                     # ④ 产物落在 runs/<日期>/L1/<时刻>/
CRASH_REPORT_SKIP_ANALYSIS=1 ...crash-weekly.sh      # 验 L2 降级路径（不必等额度耗尽）
FACT_CACHE_BASELINE=<跑批前快照> bash bin/test/assert-fact-cache.sh   # 事实层缓存断言
```

补投：产物已落盘时直接 `bash bin/deliver.sh <manifest路径>`，投递失败不影响生成脚本退出码。

## 用生产数据在本机验证（部署前，「测完」第二、三步）

⛔ **测试在本地机做，确认无误后才上生产；生产机只做只读查询**（维护者规则，钩子 R4 拦：在日报机上跑 bin/ 下的跑批脚本、`hermes cron run`、往 `~/.hermes/scripts/` 写文件，带 /tmp 影子副本也拦）。
开发机自己的 `$STATE` 陈旧，所以要用**生产 STATE 的只读副本**在本机跑：

1. 本机 `pgrep -fl "crash-daily|crash-weekly|diag-hourly"` 确认没在跑批。L1 整跑约 62 GB、L2 约 41 GB（2026-11-27 `JOBS_BY_USER` 实测），**超过 20 GB 先报维护者**。
2. 数据：`ssh dino911s-mac-mini 'tar czf - -C ~/.local/state crash-triage' | tar xzf - -C <scratchpad>/verify`，每条链路一份副本。
   - 副本里的 `path.env` 换成**本机**的，生产机的工具路径在本机无效。
   - 副本里的 `local.env` 换成**本机**的（投递目标是本机应用下的维护者私聊），再追加该链路需要的凭据，比如 `CRASH_REPORT_POSTHOG_API_KEY`（普通赋值），然后 `chmod 600`。
3. 业务仓：本机 iOS 仓有 tag 与远端冲突，L2 的 `fetch --tags` 会失败。用 `git clone --shared <本机仓> <scratchpad>/verify/repos/<仓名>`，再把 `REPOS_ROOT` 指过去。
4. 跑：`CRASH_REPORT_STATE_DIR=<副本> CRASH_REPORT_NO_DELIVER=1 REPOS_ROOT=<…> bash bin/crash-daily.sh`，放后台跑（钩子 R3）。本机 claude 登录正常，模型层也能验到。
5. 读回：`lark-cli docs +create --as bot --content - < <副本>/publish/docs/daily.xml` 建临时文档，`docs +fetch` 读回，核完删掉；遇到 429 就退避重试。
6. 收尾：删掉 scratchpad 里的副本。副本里有凭据和生产数据，⛔ 不留。

⚠️ 为什么不在生产机上做（2026-11-27 实测）：
- ssh 会话打不开登录钥匙串，`claude -p` 报 `OAuth session expired and could not be refreshed`，模型层验不到。失败的同时 claude 还会在生产 `~/.claude/` 写出一份空令牌的 `.credentials.json`。
- `fetch-issue-states.py` 在 ssh 下连 MCP 会一直挂着，只能手动 `kill -9`。
- 跑批进程和生产共用同一台机器、同一套凭据。

## 不负责什么

- 零行为重构的等价性验收 → `eqv-check` skill（冻结缓存严格 diff 协议）
- 改指标口径 → `crash-metric-change` skill（先做口径校验）
- 部署生产机 / 跑批后核验 → `deploy-prod` / `morning-verify` skill
- 深度定位某个崩溃 → `firebase-crash-triage` skill
- 部署 / 调度问题 → docs/CLAUDE-部署与运维.md

## L0 每小时诊断告警（change `crash-tech-diagnostics`）

- **回放某个小时**：`CRASH_REPORT_STATE_DIR=<临时目录> CRASH_REPORT_DIAG_HOUR="2026-11-23 18" bash bin/diag-hourly.sh`。
  - 投递目标只认临时目录里 `local.env` 的 `CRASH_REPORT_DIAG_ALERT_CHAT_ID`，没有这个文件就不投递。⛔ 不要在生产机的 `$STATE` 上回放，会写坏去重状态。
  - 判定结果看 `diag/last-eval.json`，渲染出的卡片看 `last-card.json`。
- **零字节、零投递的夹具**：`bash bin/test/fn-diag-hourly.sh`。它桩掉 bq、curl（PostHog，`bin/test/fake-posthog-curl.py`）和 lark-cli，跑真实的脚本。
- 日报 / 周报那一节回放用 `CRASH_REPORT_DIAG_DAY=<日>`，L1 填前一日，L2 填跑批日。冻结数据照旧用 `CRASH_REPORT_BQ_CACHE`。
- ⚠️ 大回填（`bin/diag-backfill.sh`）先 `--dry-run` 报字节数。只补 PostHog 一侧用 `--posthog-only`（不扫 GA4、不计费）。

