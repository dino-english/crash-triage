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
bash bin/check-scripts.sh                            # ① 改脚本后必跑（七项静态检查）
CRASH_REPORT_DRY_RUN=1 bash bin/crash-daily.sh       # ② 快速看卡片预览（跑不到索引页）
CRASH_REPORT_NO_DELIVER=1 bash bin/crash-daily.sh    # ③ 完整链路：验索引页 / manifest / 产物
ls "$STATE/runs/$(date +%F)/L1/"                     # ④ 产物落在 runs/<日期>/L1/<时刻>/
CRASH_REPORT_SKIP_ANALYSIS=1 ...crash-weekly.sh      # 验 L2 降级路径（不必等额度耗尽）
FACT_CACHE_BASELINE=<跑批前快照> bash bin/test/assert-fact-cache.sh   # 事实层缓存断言
```

补投：产物已落盘时直接 `bash bin/deliver.sh <manifest路径>`，投递失败不影响生成脚本退出码。

## 不负责什么

- 零行为重构的等价性验收 → `eqv-check` skill（冻结缓存严格 diff 协议）
- 改指标口径 → `crash-metric-change` skill（先做口径校验）
- 部署生产机 / 跑批后核验 → `deploy-prod` / `morning-verify` skill
- 深度定位某个崩溃 → `firebase-crash-triage` skill
- 部署 / 调度问题 → docs/CLAUDE-部署与运维.md
