- [x] 1.1 L1 `crash-daily.sh`：MCP 段后挂断言，产出 `FACT_CACHE_MSG`
- [x] 1.2 L1：`add_alert "$FACT_CACHE_MSG"` 排在告警链**最后**——摘要按加入顺序渲染，🔴 线上问题必须在前
- [x] 2.1 L2 `crash-weekly.sh`：分析段后挂断言，产出 `FACT_CACHE_NOTE`
- [x] 2.2 L2：拼进 `NOTE_MD`（照 `PERF_STALE_NOTE` 的既有范式）——⚠️ `NOTE_MD` 有**三个**消费点
      （群消息 / 卡片 `--arg nm` / 文档六段），走同一份文案是刻意的
- [x] 2.3 L2 判据用「快照在不在」而不是 `ANALYSIS_OK`：full 模式下 `report.md` 缺失但
      `snapshot.json` 已写出是实测存在的组合（2026-08-23），那种情况事实层同样该被断言
- [x] 3.1 ⛔ 双向测试（生产 shell 设置下：`set -euo pipefail` + `errtrace` + ERR trap）
      - 违规样本变红：文案含 issue 个数 / 停滞日期 / 补救办法 / 「日报数字不受影响」
      - 全量代码不误报：`last_synced` 是本轮时不产出任何告警
      - MCP 段失败时不叠第二条（那条路径已有自己的告警）
      - 三种情形都验「不触发 ERR trap」
      结果：18 通过 0 失败
- [x] 3.2 真实产物渲染核对（2026-09-04 生产快照 + issues/）：6 个 issue 全部命中，文案如实
- [ ] 4.1 部署后首个跑批日核验（`morning-verify`）：断言在生产上真的跑到、文案在卡片上真的可见
