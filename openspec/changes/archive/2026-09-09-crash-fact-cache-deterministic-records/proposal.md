## Why

事实层缓存的**观测字段由模型执行 prompt 写入**（`fetch-snapshot.sh` 第 ③ 段 `FACT_CACHE_POLICY` 的「判定二」）。
2026-09-08 在生产机核 09-07 那批改动的首个跑批时，把这条路径的历史产物全量点了一遍——**它基本没在工作**：

| 观测（2026-09-08 采样，`$STATE/issues` 25 个文件） | 数字 |
|---|---|
| 08-19 以来 25 轮日报中，观测字段**真正刷新过**的轮次 | **5 轮** |
| 其余：模型自陈「权限被拒」/ MCP 整体抓取失败 / 上游空 | 9 / 5 / 1 |
| 文件声称的事件合计 vs 实存 `events` 合计 | 55 vs **6**（20/24 短缺） |
| `last_synced` 的时间口径 | **三种并存**（见下） |

`last_synced` 的三种口径，按写入方分：

- 确定性 shell（`fetch-snapshot-bq.sh:174` 的 `date -u`，**仅 L2 调用**）—— 恒为真 UTC；
- 模型路径 —— **不稳定**：09-02 写真 UTC，09-07 把 run_id 的**本地时间**加个 `Z`（快 8 小时）。

现有断言 `assert-fact-cache.sh` 抓不到这些：它只比 `last_synced` 的**日期前缀**（`date -u +%Y-%m-%d`）。
2026-09-08 夹具实测三种情形（详见失效模式登记 F45）：

| 情形 | 结果 |
|---|---|
| 本地时间标 Z + UTC 前一天（**L2 场景**，内容刚刷新） | ❌ 判「不是本轮」——**假告警** |
| 真 UTC（同一时刻） | ✅ |
| 本地时间标 Z + UTC 同日（**L1 场景**，错 8 小时） | ✅ ——**被掩盖** |

三次夹具的 `events` 均为 `[]`，两次照样 ✅ —— 断言**判不到内容**。

⛔ 最反直觉的一条：L2 的调用顺序是 shell 写（`crash-weekly.sh:186`）→ 模型写（`:241`）→ 断言（`:300`），
模型写在**后**，可以覆盖掉正确的 UTC 时刻。历史 4 轮 L2 模型路径一次都没写成，断言才一直是绿的——
**「模型失败」是这条假告警至今没炸的唯一原因**。也就是说，若先去修模型的写入能力，
周报会在事实层终于正常的那天先发一条假的「事实层缓存未刷新」。

`2026-08-23-crash-fact-cache-freshness/design.md:112` 已经把方向写下了：
「彻底的解法是把事实层维护移出 prompt……超出本 change」。当时缺的是**值不值得做**的证据，现在有了。

## What Changes

**观测字段的写入方从模型改为确定性 shell**，模型只保留「要不要抓事件明细」这一个判定。

- `fetch-snapshot.sh` 在模型返回后，用模型已经拿回来的 `snapshot.json`（内含每个 issue 的
  `events` / `users` 计数）**确定性回写** `issues/*.json` 的观测字段：
  `events_count_last_seen` · `users_last_seen` · `window_days` · `last_synced`（`date -u`）·
  `latest_event`（取 max，语义不变）。
- ⚠️ **不损失原 design 的硬约束**「保住模型路径省 MCP 调用的收益」：观测字段所需数据全部已在
  `snapshot.json` 里，回写它是 **0 次额外 MCP 调用**。省钱的 `crashlytics_list_events` 原封不动留给模型。
- 两条路径的合并逻辑抽成 `bin/lib/factcache.sh` 的一个函数，`fetch-snapshot-bq.sh` 与
  `fetch-snapshot.sh` 各自 source（⚠️ 函数不跨进程）。**跨执行模型的策略重复就此物理消失**——
  这正是 `crash-perf-functional-core` design D10 登记的那个 lint 抓不到的缺口。
- prompt 的「判定二·无条件更新观测字段」整段**删除**，改为一句「观测字段由调用方回写，不要写」。
- `assert-fact-cache.sh` 的 `last_synced` 判据从「UTC 日期前缀」改为「与本轮时刻的差值在容差内」，
  并**新增一行非 gating 的内容覆盖率输出**（声称事件数 vs 实存 `events` 长度）。

## Non-goals

- **不修「`events` 内容为空」**。那是模型抓取行为的问题，根因至今不可判定——`run_agent` 没有
  工具级日志（F45）。本 change 只让它**可见**（覆盖率输出），修它另起 change，且**必须排在本 change 之后**。
- **不把事实层并进 `artifacts_ok()`**。那会让 `fetch-snapshot.sh` 返回非零 → `crash-daily.sh` 判
  `MCP_OK=0` → 索引页「跟踪中的 issue」整块丢失，把次要降级升级成主要故障，与现行「只告警不失败」
  的取舍正面冲突（理由见 `crash-daily.sh` 该段注释）。
- **不改 `events` 累积数组的合并语义**（沿用 `crash-perf-issue-fact-cache` 现有约束）。
- **不迁移历史文件**。下一轮跑批自然覆盖观测字段，`latest_event` 取 max 保证不倒退。
- **不改断言的 gating 属性**：仍是「只告警不失败」。

## Capabilities

### Modified Capabilities

- `crash-perf-issue-fact-cache`：观测字段的写入方 MUST 是确定性执行路径，MUST NOT 依赖模型执行；
  `last_synced` MUST 是真 UTC 时刻；断言 MUST 判定时刻而非日期前缀。

## Impact

| 文件 | 变更 |
|---|---|
| `bin/lib/factcache.sh`（新增） | 观测字段合并函数，路径全部走参数（⛔ 不放 `lib/core/`——它要碰 `$STATE` 路径，会被第 3 项依赖方向 lint 拦下） |
| `bin/fetch-snapshot.sh` | 模型返回后回写观测字段；`FACT_CACHE_POLICY` 删去「判定二」整段 |
| `bin/fetch-snapshot-bq.sh` | 改用共享函数，行为不变 |
| `bin/test/assert-fact-cache.sh` | `last_synced` 改判时刻 + 容差；新增内容覆盖率输出（非 gating） |
| `bin/test/fn-factcache.sh`（新增） | 函数级夹具，挂进 `check-scripts.sh` 第 8 项 |

**风险**：模型路径此后每轮都会重写命中 issue 的 JSON（当前 25 个，量级可忽略）。
⚠️ 回写发生在模型进程**退出之后**，若模型半截写坏了文件，回写的 `jq` 会失败——
该失败必须落进现有的「落盘校验 / 隔离」路径，不得静默。
