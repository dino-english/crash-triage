## Why

**`crash-perf-issue-fact-cache` 早就写着「观测字段每轮无条件更新」是 MUST，但没有任何东西验证它真的成立。**
而执行这条要求的不是 shell，是**模型**——`fetch-snapshot.sh` 把策略（`FACT_CACHE_POLICY`）
写成自然语言交给 `claude -p`。自然语言没有语法检查、没有退出码，**模型没照做时没有任何信号**。

2026-09-04 核查日报数据时发现事实层已经停更两天，两天的失效方式还不一样：

| 日期 | 模型的行为 | 真相 |
|---|---|---|
| 09-03 | 报「命中 6 个（跳过）」 | `62f88f39` 线上 9 事件、缓存记 7——按 spec 该走增量抓取，被判成了命中 |
| 09-04 | 报「事实层缓存的环境变量读取与写入均被权限拒绝」 | **权限根本没被拒**：实测 `Write` 到 `$STATE` 通畅、`permission_denials` 为空 |

09-04 那条已复现根因：同一模型（生产机 `claude -p` 背后是 `gpt-5.6-terra`）收到
`EROFS: read-only file system` 也回报 `DENIED:Write`——**它会把任意错误归因成权限**。
⛔ 由此得出的一般结论：**模型的自陈不可作为成功判据，只能对落盘产物断言**。

两天都无人发现，是因为 `fetch-snapshot.sh` 的 `artifacts_ok()` 只看 `snapshot.json`——
它写出来了，于是 rc=0、`health-daily.json` 照写 `ok:true`。**两端判据不一致，正是静默降级的温床。**

⚠️ 断言脚本 `bin/test/assert-fact-cache.sh` 早在 `crash-fact-cache-freshness`（2026-08-23）
就写好了，第一条断言就是 `last_synced` 必须是本轮——**它只是从没挂进任何一条链路**，
一直当手工命令用（失效模式 F13 记的正是这件事）。本 change 只是把它挂上，断言内容一字未改。

## What Changes

- L1 `crash-daily.sh`：MCP 对照段之后执行断言，失败时产出一行摘要告警（进卡片）。
- L2 `crash-weekly.sh`：分析段之后执行断言，失败时在口径段追加一条 🟡 注记（卡片/群消息/文档共用）。
- ⚠️ **只告警不失败**：事实层不参与日报任何数字（全部走 BigQuery），为它让整跑非零退出会把
  次要降级升级成主要故障；但必须在卡片可见——与「缺分析必须在卡片可见」同一条。
- ⛔ 调用放在 `if` 条件位。第一版写成 `_out="$(断言)" || _rc=$?`，实测**每次断言失败都触发 ERR trap**：
  `set -o errtrace` 把 ERR trap 传进命令替换的子 shell，断言的 `exit 1` 在那里就是最后一条命令，
  外层 `||` 根本来不及兜。与 `crash-artifact-assertions` 同一条教训，本仓库第二次踩。

## Non-goals

- ⛔ **不改断言内容**。`assert-fact-cache.sh` 一字未改，本 change 只解决「它没被调用」。
- ⛔ **不做成跑批闸门**。事实层滞后不影响日报任何数字，为它中止跑批不划算。
- ⛔ **不并入投递前的产物自检**（`assert-artifacts.sh`）。那组断言跑在 `$STATE/publish/` 上、
  在卡片**渲染之后**；而本断言的结果要**进卡片**，必须在渲染之前算出来。时序不同，不可合并。
- ⛔ **不并入 `check-scripts.sh`**。那是静态代码检查，不依赖产物存在（同 `crash-artifact-assertions`）。
- ⛔ **不改事实层的写入路径**。「为什么模型不照做」是模型行为问题，本 change 只保证它**被看见**。
