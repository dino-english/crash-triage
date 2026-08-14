# SQL 片段

L1 日报用的 BigQuery 查询，每个文件一个指标块。

## 占位符约定

脚本用 `sed` 替换后再喂给 `bq query`：

| 占位符 | 替换为 | 示例 |
|---|---|---|
| `{{TABLE}}` | 完整表名 | `dino-english-497507.firebase_performance.com_prime_dino_english_IOS` |
| `{{DAYS}}` | 回看天数 | `1`（日报）/ `7`（周报） |

```bash
sed -e "s|{{TABLE}}|$TBL|g" -e "s|{{DAYS}}|1|g" sql/perf-screens.sql | bq query --use_legacy_sql=false --format=csv
```

## 文件

| 文件 | 指标 | 数据源 |
|---|---|---|
| `perf-screens.sql` | 页面慢帧率 / 冻结帧率 | `firebase_performance` |
| `perf-network.sql` | 自家 API 的 P50/P95 延迟与错误率 | `firebase_performance` |
| `perf-traces.sql` | 启动耗时等自定义 trace | `firebase_performance` |
| `sessions-by-version.sql` | 各版本会话数 / 设备数（**修复验证的分母**） | `firebase_sessions` |

## 阈值说明（Firebase 定义，非我们设的）

- **慢帧**：单帧渲染 > 16ms
- **冻结帧**：单帧渲染 > 700ms（用户直接可感知的卡死）

## 待补

崩溃率的 SQL 等 `firebase_crashlytics` 出表后补（分母 `firebase_sessions` 已就绪，分子还缺）。
