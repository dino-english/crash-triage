## Why

现有崩溃率 =「事件数 / 会话数」，**无法与任何外部基线对比**。Firebase 控制台首屏、App Store Connect、Play Console 用的都是 crash-free 口径。团队内部看一套数字、跟外部沟通用另一套。

而且事件数口径会**高估**：一个会话可以崩多次。实测 Android 近 7 天 62 个 FATAL 事件分布在 61 个会话上——本例差异小，但这是巧合不是保证。

**数据已确认就绪**（2026-08-22 实测）：`firebase_crashlytics` 有 `firebase_session_id`，覆盖率近 100%（FATAL 105/105、ANR 87/93）；`firebase_sessions` 有 `session_id`。

**但只能做到一半** —— 见下。

## What Changes

- **新增 crash-free 会话率**：`1 − 崩溃会话数 / 总会话数`，按版本分列，双端。
- **口径限定为 FATAL**：ANR 与 NON_FATAL 不计入，与 Firebase 的 crash-free 定义一致（ANR 有自己的率，见 change `crash-error-type-coverage`）。
- **现有「崩溃率 = 事件数/会话数」保留不动**：它回答「崩溃有多频繁」，crash-free 回答「多少会话是干净的」，两者互补。历史序列也不能断。
- **卡片置顶**：crash-free 会话率作为整体健康的单一指标放在卡片第一行（见 change `crash-card-brief`）。
- **必须标注两条限制**（见 Non-goals 与 design）。

## Non-goals

- ⛔ **不做 crash-free 用户率——算不出来。** 实测两张表的用户标识**不同源**：`crashlytics.installation_uuid` 是 64 字符十六进制（`B7207A8BD1…`），`sessions.instance_id` 是 22 字符 base64url（`dG2Kzp0MRX-Ycd2VVBGfQb`），**JOIN 匹配 0 行**。不是格式差异，是两个 ID 体系。

  ⚠️ **后果必须说清楚**：Firebase 控制台首屏给的是 **crash-free 用户率**。我们只能给**会话率**，两者数值不同（用户率通常更低——一个用户崩一次就算），**不可直接对照控制台数字**。做 crash-free 本是为了对齐外部，结果只对齐了一半。

- **不改现有崩溃率定义**。
- **不做 ANR-free / 非致命-free**。crash-free 是行业既定口径，扩展它只会制造新的不可比。

## Capabilities

### New Capabilities

- `crash-perf-crash-free-rate`：crash-free 会话率的口径、计算方式、与外部标准的差异标注，以及用户率不可得这一事实的呈现要求。

## Impact

| 文件 | 变更 |
|---|---|
| `bin/sql/crash-free-sessions.sql` | **新增** —— 分子：crashlytics 侧 `COUNT(DISTINCT firebase_session_id)` |
| `bin/sql/sessions-by-version.sql` | 复用（分母已有） |
| [bin/crash-daily.sh](../../../bin/crash-daily.sh) | 取数 + 新增行 + 阈值常量 |
| [bin/crash-weekly.sh](../../../bin/crash-weekly.sh) | 主力版本表增列 |
| `$STATE/metrics-history.jsonl` | 新增字段；旧行无该键按「无数据」处理 |

**与其他 change 的关系**：`crash-card-brief` 的卡片第一行依赖本 change，**必须先做**。与 `crash-error-type-coverage` 无依赖（ANR 不计入 crash-free），可并行。
