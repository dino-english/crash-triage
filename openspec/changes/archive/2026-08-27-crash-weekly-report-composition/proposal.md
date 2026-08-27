## Why

**分析层跑通的那几周，周报文档里没有任何维度与指标。**

`crash-weekly.sh` 的投递分支是 `cp` 覆盖，不是合并：

```bash
if [ -s "$TRIAGE_REPORT" ]; then
  cp "$TRIAGE_REPORT" "$PUBLISH_DIR/docs/weekly.md"   # 模型报告
elif [ -s "$REPORT" ]; then
  cp "$REPORT" "$PUBLISH_DIR/docs/weekly.md"          # 数据层周报
fi
```

数据层周报 `$REPORT` 里的「二、主力版本」「三、影响面分布」「四、性能」「取数区间 / run_id / 口径」是 BigQuery 纯脚本产出；`$TRIAGE_REPORT` 是 `firebase-crash-triage` skill 按自己的模板写的根因报告——`fetch-snapshot.sh:110` 的 prompt 只要求「根因、版本流转、风险分级与修复方案」，**从未要求它带维度与指标**。两者互斥投递，于是分析越成功，周报的数据面越空。

实证（`$STATE/runs/` 与飞书投递物）：

| 跑批日 | 分析层 | 投递文档 | 主力版本 | 影响面 | 性能 | crash-free | 取数区间 |
|---|---|---|---|---|---|---|---|
| 2026-08-20 | ✅ 跑通 | triage 报告 30,991 字符 | 0 | 0 | 0 | 0 | 0 |
| 2026-08-22 | 跳过 | 数据层周报 | ✅ | ✅ | ✅ | ✅ | ✅ |
| 2026-08-23 | 跳过 | 数据层周报 | ✅ | ✅ | ✅ | ✅ | ✅ |

（08-20 那份的数据层周报 2,766 字节照常写进了 `$STATE/reports/`，只是没进 `publish/`。）

这是一次**回归**，不是原始设计：`git log -S'TRIAGE_REPORT'` 显示互斥分支自 Initial commit 就存在，而影响面维度段是后来 `2303dcc` 才加进数据层的——加的时候没有回头动投递分支。

同一处代码的注释（`crash-weekly.sh:738-743`）已经写明了这条理由：

> 跳过建文档会让「本周平稳」的那几周**永久丢失性能趋势记录**，而平稳周恰恰是趋势最该被留档的时候

该理由在**成功分支上同样成立**，却只在 fallback 分支被兑现。

## What Changes

- **投递分支从「二选一」改为「合并」**：文档主干恒为数据层周报 `$REPORT`；分析层产物作为「分析层 · 根因分析」段追加在末尾。`REPORT_FILE` 恒指向 `$REPORT`。
- **追加时只删 triage 的第一行 h1**，其余标题层级**一律不动**。
- 无分析的一周行为完全不变（数据层五段照旧）。

## Non-goals

- **不改 `fetch-snapshot.sh` 的 full 模式 prompt**。让模型去带维度与指标违反「数据层零模型」——维度数值必须由 BigQuery 确定性产出。
- **不重排 triage 内部的中文序号**。模型产出的序号每周漂移，脚本按序号重编号不可靠。
- **不投递两份文档**。会改动 manifest schema、`deliver.sh`、索引页与归档口径，代价远超收益。

## Capabilities

- `crash-perf-daily-weekly-report`（修改）：新增「周报文档构成」要求——数据层段落 MUST 恒在投递物中，MUST NOT 因分析层成功而被替换掉。
