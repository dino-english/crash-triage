## Why

`crash-daily.sh` 2144 行 / 79 个函数，核心层只有 162 行——**倒挂**。现状量化见 [docs/CLAUDE-分层与复用.md](../../../docs/CLAUDE-分层与复用.md)。

本 change 只做该文档里**优先级 1 与 2** 两项：收益确定、且都是「消除已经咬过人的分歧」，不是美化。⛔ 渲染层拆分（优先级 5）仍是 Non-goal，理由与前提复核见该文档。

### ① CSV 解析：两套实现，其中一套是错的

同一份 bq CSV，仓库里有两种解析方式：

| 位置 | 方式 | 正确性 |
|---|---|---|
| `crash-daily.sh:1529` `md_csv_table` | Python `csv.reader` | ✅ |
| `crash-daily.sh` 另外 **7 处** | `awk -F,` / `cut -d,` | ❌ |
| `crash-weekly.sh` | `csv2tsv`（2026-08-24 新加） | ✅ |

⚠️ **L1 的 `md_csv_table` 正确并不代表 L1 没问题**——它的 python 解析发生在**下游**。上游 `dim_csv()`（`:1495`）先用 `awk -F,` 把原始 CSV 切坏、再重新加引号输出，下游解析的已经是坏数据。

受影响的是**含逗号字段**：Apple 机型标识符自带逗号（`iPad7,11` 是官方格式）、`perf-network` 的 `event_name` 是 URL。实测原始行 `"Apple iPad7,11",1,1,0,,1.0` 被切成机型=`"Apple iPad7`、事件=`11"`——**1 个事件渲染成 11**。

L2 侧已于 2026-08-24 修复，但**修的是 L2 自己的那份**，L1 的 7 处仍在。这正是「同一目的两份实现」的典型代价。

### ② SQL 包装：8 份 SQL 在两个脚本里各包装一遍

| SQL | L1 | L2 |
|---|---|---|
| `crash-rate.sql` | 3 | 3 |
| `crash-dimensions.sql` | 4 | 1 |
| `latest-versions.sql` | 2 | 2 |
| `crash-blame.sql` | 1 | 2 |
| `crash-error-types.sql` | 1 | 1 |
| `perf-{traces,screens,network}.sql` | 各 1 | 各 1 |

L1 叫 `qdim` / `qc`，L2 叫 `ver_dim` / `ver_crash` / `ver_blame` / `ver_etypes` / `perf_row`——**名字不同、占位符替换逻辑相同**。

⛔ `check-scripts.sh` 第 4 项只抓**同名**函数，改了名的重复它一个都抓不到。

## What Changes

- **新增 `bin/lib/csv.sh`**（外壳层，与 `bq.sh` 平级）：`csv2tsv` 为全仓唯一的 bq CSV 解析入口。
- **L1 的 7 处裸切改为经 `csv2tsv`**——⚠️ 含逗号字段的输出会**变化**（那是修 bug，不是回归）。
- **新增 `bin/lib/query.sh`**（外壳层）：`q_dim` / `q_crash` / `q_blame` / `q_etypes` / `q_perf` / `q_versions`，窗口天数作**显式参数**。
- 两条链路各自 source，替换各自的包装函数。

## Non-goals

- ⛔ **不动渲染层**（三种渲染共享 `cell()` / `delta_of()` 的判定，见分层文档 ③）。
- ⛔ **不下沉 `collect_*`**（写全局变量，副作用面大，需先改成参数进/stdout 出）。
- ⛔ **不改任何 SQL 文件本身**，也不改窗口天数与口径。
- ⛔ **不放进 `bin/lib/core/`**：`query.sh` 要用 `bqq` 与 `$ROOT`，会被 `check-scripts` 第 3 项（核心层纯度）当场拦下；`csv2tsv` 依赖 `python3` 在 PATH 中，不满足「`env -i` 可调用」。

## Capabilities

- `crash-perf-functional-core`（修改）：新增「同一解析目的只允许一份实现」与「跨链路共享的取数包装必须收口」两条要求。
