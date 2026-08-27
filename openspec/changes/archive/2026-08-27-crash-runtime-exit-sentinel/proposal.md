## Why

**`set -u` 未定义变量的失败会被 EXIT trap 吞成退出码 0——三重静默的生产级隐患。**

bash 3.2 实测：`set -u` 致命退出时，**进 EXIT trap 那一刻 `$?` 已经是 0**（普通命令失败才是非零）。而四个脚本的 EXIT trap 是 `trap 'rm -f "$X"' EXIT`，`rm -f` 恒返回 0，于是整脚本退出码 = 0。

后果（2026-08-24 实测复现）：

- 退出码 0 → cron / baseline.sh 看到「成功」
- ERR trap **不触发**（shell 错误不是命令失败）→ 无告警
- `health.json` 停在**上一轮**的 `ok:true` → 健康检查正常

**群里收不到报告，而所有监控信号都说没事。** 且 unbound variable 恰是本仓库最常见的失败模式（bash 3.2 把多字节首字节并进变量名，CLAUDE.md 记「一天连踩五次」）。

⚠️ 保留 `$?` 的写法（`_rc=$?; …; exit $_rc`）**修不好**——`$?` 本来就是 0，第一版就这么修错的。

## What Changes

四个脚本（crash-daily / crash-weekly / deliver / fetch-snapshot-bq）改用**完成哨兵**：

```bash
trap 'rm -f "$X"; [ "${RUN_COMPLETED:-0}" = 1 ] || exit 1' EXIT
# …脚本末尾：
RUN_COMPLETED=1
```

⚠️ 两处合法的提前 `exit 0`（L1 DRY_RUN、deliver 仅重发卡片）已先置位。

## 验收

- 端到端负向：向 crash-weekly.sh 注入未定义变量 → **rc=1**（修复前 0）
- 正常路径 rc=0、提前 exit 0 路径 rc=0（构造脚本四态全验）
- 显式 `exit 3` 会被折成 1——可接受：非零仍非零，语义是「未完成」

## Capabilities

- `crash-perf-daily-weekly-report`（修改）：失败必须以非零退出码可见。
