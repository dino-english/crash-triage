# 数据源停更排查记录（2026-08-15）

> 日报「版本放量 / 性能」空表根因诊断。排查人：架构师（default）。时间：2026-08-15 09:14 +0800。

## 结论（一句话）

「版本放量」空表 = 脚本查了 **停更 4 天的 sessions 批量表**（但 REALTIME 活表就在旁边）；「性能」空表 = **窗口 1 天太窄**，装不下 performance 表约 2 天的每日批量同步滞后。

## 数据源实测状态

| 表 | 最新 event_timestamp | 状态 |
|---|---|---|
| `firebase_sessions.com_prime_dino_english_IOS`（批量） | 08-11 06:50 UTC | ❌ 停更，08-12 起 0 行 |
| `firebase_sessions.com_prime_dino_english_ANDROID`（批量） | 08-11 06:58 UTC | ❌ 停更，08-12 起 0 行 |
| `firebase_sessions.com_prime_dino_english_IOS_REALTIME` | 08-15 01:15 UTC | ✅ 正常 |
| `firebase_sessions.com_prime_dino_english_ANDROID_REALTIME` | 08-15 01:15 UTC | ✅ 正常 |
| `firebase_performance.com_prime_dino_english_IOS` | 08-14 06:59 UTC | ⚠️ 滞后 ~2 天 |
| `firebase_performance.com_prime_dino_english_ANDROID` | 08-14 06:58 UTC | ⚠️ 滞后 ~2 天 |
| `firebase_crashlytics.*_REALTIME` | 08-14 16:xx UTC | ✅ 正常 |

## 关键证据

- **sessions 批量表停更**：iOS 08-12 起 0 行，Android 08-12 起 0 行；按天计数最后一天 08-11（iOS 99 行 / Android 308 行）。
- **sessions REALTIME 表是活的**：数据到 08-15 01:15 UTC（排查当时），schema 与批量表**完全一致**；用 sessions-by-version.sql 逻辑直查 REALTIME 表，正常返回 `1.5.1 → 497 会话 / 1.5.2 → 251 会话 / 1.5.3 → 150 会话` 等。
- **performance 表是每日批量同步**：07:00 跑日报时表里最新仅 08-12 06:49（`DATA_UNTIL`），排查时已补到 08-14 06:59；按天计数连续（08-07~08-14），但「当天」数据不足一天，是典型批量导出滞后。

## 根因分层

1. **脚本侧（本次修复）**：放量段查错表（应查 REALTIME）；性能段窗口 1 天装不下 2 天滞后；空表静默不告警。
2. **数据源侧（需人工）**：`firebase_sessions` 批量表停更 4 天 = Firebase→BigQuery **每日批量导出链路故障**（REALTIME 流式导出正常，故可判定为批量导出任务停了，不是 SDK 上报停了）。需在 Firebase 控制台查 BigQuery 导出的 batch export 任务状态 / 是否被暂停 / 有无告警。

## 已采取的脚本侧修复（change `crash-perf-data-staleness-guard`）

- 放量段切 `*_REALTIME` 活表（缺失回退批量表）。
- 各段「窗口内 0 行」→ 显式告警「⚠️ 数据未同步，最新截至 XX」。
- 性能窗口 `DAYS=1 → PERF_DAYS=3`。
- 分表截止时间戳（性能 / 放量 / 崩溃各自标注）。

## 待人工（数据源侧）

- [ ] 在 Firebase 控制台查 `firebase_sessions` 批量导出的 BigQuery 集成状态，恢复 08-11 之后的数据。
- [ ] 确认 `firebase_performance` 批量同步是否可缩短滞后（或接受 2 天滞后 + 3 天窗口兜底）。
