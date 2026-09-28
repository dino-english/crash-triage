## Why

**已归档的 `crash-perf-disposition-store` 有一条 MUST 在生产上从未实现，而它的验收当时是绿的。**

正典条文（`openspec/specs/crash-perf-disposition-store/spec.md`）：

> 结论存储 MUST 被当作不可重算的人工资产对待，MUST 纳入与其他不可重建运行状态同等的备份与迁移范围。

2026-09-28 实测生产：

| 查的东西 | 实况 |
| --- | --- |
| 仓库里写 `$STATE/backup/` 的代码 | 只有 `fetch-snapshot.sh:436` 的 `corrupt-issues-*` 隔离区——那是隔离不是备份 |
| 生产 `backup/` 目录内容 | 全是人手扔的调试残留（`badscalar-*` / `corrupt-issues-*` / `eqv-l2-*`），最后一次 09-21 |
| `dispositions.json` 的备份份数 | **0** |
| crontab 备份任务 | 无 |

⛔ **根因是验收判据答非所问**：`crash-ledger-disposition-store` 的 task 1.3 verify 写的是
「备份**脚本/文档**中出现该路径」。往 `docs/CLAUDE-部署与运维.md` 写一句话，这条就绿了——
而条文要求的是「文件真的被备份」。判据回答的是「有没有人写下这件事」，
要求问的是「这件事有没有发生」。同 F6「规格要求了但从未实现，且没人发现」。

**为什么这个文件值得单独修**：`last-snapshot.json` 丢了顶多误报一屏「新增」，下一轮自愈；
而 `dispositions.json` 装的是人看完钻取报告得出的判断，⛔ **没有任何地方能重算**。
2026-09-28 它已有 6 条，其中 `c3184f91` 那条是钻到「1.8.0 上 10 次全部来自 adhoc 内测包、
且走另一条代码路径」才得出的——重做一遍是几十分钟的人工钻取。

## What Changes

- L2 跑批收尾落一份**内容变化时才写**的带时间戳副本到 `$STATE/backup/dispositions/`，只增不改、不清理。
- 备份成功的判据是 **`cmp` 与现役文件逐字节一致**，⛔ 不是「文件存在」——后者又是一次答非所问。
- 备份失败只告警不中止跑批：⛔ 备份是保护措施，不该成为新的单点故障。
- 明确写清能力边界：它防的是**误覆写 / 误删 / 内容损坏**，⛔ **防不住整台机器丢失**——
  异地那一层生产机推不了 git，只能靠人工 scp（文档已有命令）。

## Capabilities

### Modified Capabilities

- `crash-perf-disposition-store`: 把「纳入备份范围」从一句声明收紧为**可被产物证伪的要求**——
  必须存在与现役文件逐字节一致的副本，且要求对「备份不可得」与「备份内容不一致」给出不同处置。

## Impact

- `bin/crash-weekly.sh`：收尾段新增备份（⛔ 在完成哨兵之前，失败不改变退出码）
- `bin/test/fn-ledger-disposition.sh`：新增备份行为断言
- `docs/CLAUDE-部署与运维.md`：把「必须纳入备份」从文档承诺改为指向实现
- ⛔ `bin/crash-daily.sh` 不改（L1 与结论存储无关，边界不因备份而破例）

## Non-goals

- ⛔ **不做异地/离线备份**：生产机推不了 git，跨机同步要另外的凭证通路，超出本轮。
- ⛔ **不做版本历史或差异审计**：副本只增不改已足够回滚，结论的溯源看 `$STATE/ledger/snapshots/` 的专项报告。
- ⛔ **不做自动清理**：与 `report-index.jsonl` 同档——不可再生的东西不设过期。
- ⛔ **不顺手给其他 `$STATE` 文件加备份**：它们可重算，代价与收益都不同，混进来会让本 change 的判据糊掉。
