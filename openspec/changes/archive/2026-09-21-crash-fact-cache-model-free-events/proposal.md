## Why

事实层的事件明细补不回来，**根因不是模型不配合，是它根本拿不到数据**。

2026-09-18 实测（`fetch-snapshot.sh` 的 agent 轨迹）：`crashlytics_list_events`
的结果一超限就不下发给模型——

```
<persisted-output>
Output too large (55.1KB / 77.7KB / 312.9KB). Full output saved to:
  ~/.claude/projects/…/tool-results/call_*.json
Preview (first 2KB): …
```

模型手里只剩 2KB 预览和一个磁盘路径。要把事件写进 `$STATE/issues/<id>.json`，
它就得解析那个文件，而解析需要解释器——解释器被 `--allowedTools` 正确禁掉了
（CLAUDE.md 硬约束：逐个列只读工具、禁前缀通配）。⛔ **这是结构性死锁。**

**观测证据**（五轮，⛔ 与「随机/看心情」不相容）：

| 轮次 | 待抓 | 结果大小 | 模型写进 `issues/` |
| --- | --- | --- | --- |
| 09-13 | 2 | 小 | 1 |
| 09-18 08:30 | 4 | 混合 | 1（且**不是**缺失的那个） |
| 09-18 09:48 | 1 | 5 条，内联 | 1 ✅ |
| 09-18 空 STATE 复跑 | 6 | 55/77/312KB 全部卸载 | **0** |

⇒ 待抓越多越补不回来。⛔ 归档 change `crash-fact-cache-events-backfill` 里那句
「模型 25 轮里 20 轮没写、事件合计 6 vs 声称 55」，以及「清单里 3 个补上 2 个」，
现在有了统一解释——不是节流没生效，是大结果压根没进上下文。

**⛔ 第二个独立阻塞点**（2026-09-18 实测）：生产机 `/usr/bin/python3`（Xcode 3.9）
与 `/opt/homebrew/bin/python3` **都没有 PyYAML**，而模型写的每个脚本都 `import yaml`。
⇒ 即使当初放开了权限，也只会换成另一种静默失败。**「放开 allowedTools」这条路是死的，
而且它的死法比现在更隐蔽。**

## What Changes

**事实层的事件明细改由确定性路径抓取，不再经过模型。**

裸调 MCP（stdio JSON-RPC：initialize → notifications/initialized → tools/call）
在生产机实测可用，2026-09-18 取回 `227fc097` 的事件，字段完整：

```
{"appId":"1:465344775452:android:…", "filter":{"issueId":"227fc097…"}, "pageSize":N}
```

⚠️ **参数是 camelCase 且 `issueId` 必须嵌在 `filter` 里**——`app_id` / 平铺 `issueId`
都会被拒（实测报 `Must specify 'appId'` / `Must specify 'filter.issueId'`）。

模型路径**只保留它独有的能力**：堆栈判读、blameFrame、OPEN/CLOSED 状态——
即 `fetch-snapshot-bq.sh` 顶部已列明的那三项「本脚本拿不到」的东西。

## Non-goals

- ⛔ **不放开 `--allowedTools`**。见上，那条路死得更隐蔽。
- ⛔ 不动 `snapshot.json` 的结构与下游 diff / 台账渲染。
- ⛔ 不改抓取判定 `cache_verdict` 的语义（`crash-fact-cache-events-backfill` 已定）。
