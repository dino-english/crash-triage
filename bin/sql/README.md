# SQL 片段

L1 日报用的 BigQuery 查询，每个文件一个指标块。

## 占位符约定

脚本用 `sed` 替换后再喂给 `bq query`：

| 占位符 | 替换为 | 示例 |
|---|---|---|
| `{{TABLE}}` | 完整表名 | `dino-english-497507.firebase_performance.com_prime_dino_english_IOS` |
| `{{DAYS}}` | 回看天数 | `1`（日报）/ `7`（周报） |
| `{{VERSIONS}}` | 版本白名单（**带引号的逗号列表**，非裸值） | `"1.5.4"` / `"1.5.4","1.5.3"` |
| `{{MIN_SESSIONS}}` | 版本候选门槛（仅 `latest-versions.sql`） | `5` |

```bash
sed -e "s|{{TABLE}}|$TBL|g" -e "s|{{DAYS}}|1|g" -e 's|{{VERSIONS}}|"1.5.4"|g' \
    sql/perf-screens.sql | bq query --use_legacy_sql=false --format=csv
```

## 版本过滤：两套字段路径，谓词写在 SQL 文件里

版本字段在三个数据集里路径不同，**不可共用一套谓词模板**（bq 实测 schema）：

| 数据集 | 字段路径 |
|---|---|
| `firebase_performance` | `app_display_version`（顶层 STRING） |
| `firebase_crashlytics` | `application.display_version`（RECORD 嵌套） |
| `firebase_sessions` | `application.display_version`（RECORD 嵌套） |

因此脚本只替换 `{{VERSIONS}}` 的**值**，`IN (...)` 谓词与字段路径由各 SQL 文件自己写——
让「哪张表的版本字段叫什么」这个知识留在知道表结构的地方。

## 文件

| 文件 | 指标 | 数据源 |
|---|---|---|
| `perf-screens.sql` | 页面慢帧率 / 冻结帧率 | `firebase_performance` |
| `perf-network.sql` | 自家 API 的 P50/P95 延迟与错误率 | `firebase_performance` |
| `perf-traces.sql` | 启动耗时等自定义 trace | `firebase_performance` |
| `sessions-by-version.sql` | 各版本会话数 / 设备数（**修复验证的分母**） | `firebase_sessions` |
| `crash-issues.sql` | 致命崩溃 issue 聚合（issue_id / title / 事件数 / 最新时间戳） | `firebase_crashlytics` |
| `crash-rate.sql` | 崩溃率（分子 `firebase_crashlytics` 事件数 / 分母 `firebase_sessions` 会话数） | 双表 |
| `crash-error-types.sql` | ANR 与 NON_FATAL 的事件数 / 受影响安装数（**一次查询取两类**） | `firebase_crashlytics` |
| `crash-nonfatal-issues.sql` | NON_FATAL issue 聚合（含 `subtitle`，见下方注意） | `firebase_crashlytics` |
| `latest-versions.sql` | 版本清单解析（**日报唯一版本源**，返回候选版本 + 会话/设备数） | `firebase_sessions` |

### `error_type` 三类，不要用 `is_fatal` 代替

`is_fatal = TRUE` **等价于** `error_type = 'FATAL'`。ANR 与 NON_FATAL 的 `is_fatal` 都是 FALSE——
崩溃系 SQL 沿用致命过滤，会让这两类**整体不可见**（2026-08-22 前一直如此）。

实测分布（近 14 天）：

| 平台 | FATAL | ANR | NON_FATAL |
|---|---|---|---|
| Android | 105 | 93 | 131 |
| iOS | 4 | **无此行** | 1020 |

iOS 系统层无 ANR 概念，数据源不产出该类事件——渲染处必须写「无此概念」，不能留空或填 0。

### ⚠️ NON_FATAL 必须取 `issue_subtitle`

iOS 的 NON_FATAL `issue_title` **恒为 Crashlytics SDK 的包装帧**
（`FIRCLSNonFatalError.m - -[FIRCLSNonFatalError initWithError:...]`），top issue 三条标题一模一样、
零区分度；信息全在 subtitle（`DinoEnglishKit.SafeDecodeFallback (1)` / `com.apple.coreaudio.avfaudio (-50)`）。

Android 两者互补：title 是位置（`MicrosoftRecognizer.releaseRecognizerLocked`）、
subtitle 是异常类型（`java.util.concurrent.TimeoutException`）。故两列都出，渲染层分列呈现。

同一 `issue_id` 可能有多个 subtitle（实测 iOS 一个 issue 有 3 个错误码变体），
按 issue_id 分组、subtitle 取 `APPROX_TOP_COUNT` 的头部——**不用 `ANY_VALUE`**，
它可能挑中只出现一次的边缘变体，让读者以为那是主要形态。

## 阈值说明（Firebase 定义，非我们设的）

- **慢帧**：单帧渲染 > 16ms
- **冻结帧**：单帧渲染 > 700ms（用户直接可感知的卡死）

## 待补

- 崩溃率升级为 crash-free：**会话率可做**（`firebase_session_id` 覆盖率近 100%），见 change `crash-free-session-rate`；
  **用户率不可做**——`crashlytics.installation_uuid`（64 字符十六进制）与 `sessions.instance_id`（22 字符 base64url）
  是两个 ID 体系，实测 JOIN 匹配 0 行。当前崩溃率保持「事件数/会话数」口径不变。
- `firebase_crashlytics` 目前只有 REALTIME 表（行数少，可能仍在回填），若后续出每日批表需复评 D3。
