---
name: eqv-check
description: 零行为重构的冻结缓存等价性验收——改前抓基线、同缓存严格 diff、L2 双跑、数字盲比对。改 bin/ 下取数或渲染代码前必用。
---

# 等价性验收（冻结缓存协议）

适用：声称「零行为变更」的任何改动（重构、收口、迁移）。核心：用 `CRASH_REPORT_BQ_CACHE`
按 SQL 哈希冻结数据，让 diff 里只剩代码差异。活数据 6 分钟就漂，直接 diff 永远非空。

## 步骤（顺序不可换）

1. **改代码之前**，在干净工作区抓基线（baseline.sh 跑的是活代码，跑完前禁止动 bin/）：
   ```bash
   C=<scratchpad>/bqcache
   BASELINE_BQ_CACHE=$C bash bin/test/baseline.sh L1 <out>/A
   CRASH_REPORT_SKIP_ANALYSIS=1 BASELINE_BQ_CACHE=$C bash bin/test/baseline.sh L2 <out>/W0
   ```
   期间可在 scratchpad 起草编辑脚本：**先断言每个锚点恰好出现一次、全部通过才落笔**。
2. 应用改动 → `bash bin/check-scripts.sh; echo RC=$?`（全量输出，禁止 tail）。
   新加了 lint 的话当场负向测试：塞一个违规样本，确认真的红，再删掉。
3. 改后验收：
   ```bash
   BASELINE_BQ_CACHE=$C bash bin/test/baseline.sh L1 <out>/B
   diff -r <out>/A <out>/B --exclude=run.log        # 必须为空
   BASELINE_BQ_CACHE=$C2 ... baseline.sh L2 <out>/W1   # 新缓存目录，灌一次
   BASELINE_BQ_CACHE=$C2 ... baseline.sh L2 <out>/W2   # 同缓存重放
   diff -r <out>/W1 <out>/W2 --exclude=run.log      # 必须为空
   ```
4. 改前改后活数据只能**数字盲比对**验结构：
   `sed -E 's/[0-9]+([.][0-9]+)?/N/g'` 两边后 diff，0 结构差异即过。

## 坑（都踩过）

- 预期差异要逐条解释掉：两次基线间做过真投递 → docs.json 多日期键，是环境变化不是回归。
- 跑批放后台并给足时限：外部 timeout 杀进程会触发 ERR trap 向飞书发**假故障告警**。
- 刻意的产物变化（如新增一行标注）应在 diff 里**恰好**只出现那几行——多一行都要追。
