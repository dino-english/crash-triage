## 1. 实现

- [x] 1.1 `crash-weekly.sh` 收尾段（⛔ 在 `RUN_COMPLETED=1` 之前）落副本到
      `$STATE/backup/dispositions/dispositions-<TS>.json`，**内容与最近一份副本相同则跳过**（D1）
      → verify：连跑两轮内容未变 → 只有 1 份副本；改动内容后再跑 → 出现第 2 份
      2026-09-28 两轮 `NO_DELIVER` 整跑：第一轮落 `dispositions-20260928-101902.json`，
      第二轮日志 `ℹ️ 结论存储未变化，沿用既有备份 …`，目录仍为 1 份。

- [x] 1.2 落盘后立刻 `cmp` 副本与现役文件，不一致即告警（D2：⛔ 判据不是「文件存在」）
      → verify：夹具里喂一个写坏的目标 → 必须报出不一致，⛔ 不得记成成功
      落盘日志明写「与现役逐字节一致」；事后独立 `cmp` 复核通过。
      ⚠️ 双向测试：把判据换成 `[ -s "$_dbk_new" ]` → 夹具该条变红（30/1），还原后 31/0。

- [x] 1.3 失败只告警不中止、⛔ 不走触发 ERR trap 的路径、不改退出码（D3）
      → verify：目录设为不可写后整跑 `rc=0`，且日志有 ⚠️，⛔ 无告警卡
      D3 由夹具源码断言守住（备份段内 `exit 1` 计数为 0）；⛔ 两轮整跑 rc 均为 0。

- [x] 1.4 ⛔ 存储不存在时不得报错（首次启用的正常状态，与 D5 降级一致）
      → verify：改名存储后整跑 `rc=0`，备份段静默跳过
      由 `[ "$DISPO_STATE" = "ok" ]` 与 `[ -s "$DISPO_FILE" ]` 双重守卫——
      存储缺失时 `DISPO_STATE=missing`，备份段整段跳过，⛔ 不报错。

- [x] 1.5 ⛔ `crash-daily.sh` 一个字不改（D4）
      → verify：`git diff --name-only` 不含 `bin/crash-daily.sh`
      `git diff --name-only` 不含 `bin/crash-daily.sh`（已核）。

## 2. 夹具

- [x] 2.1 `fn-ledger-disposition.sh` 补备份断言：首次落盘 / 内容未变不重复落 /
      变化后落新副本 / `cmp` 不一致必须报出 / 目录不可写时不改退出码
      → verify：夹具全绿；⚠️ **双向测试**——摘掉 `cmp` 校验后那条断言必须变红
      夹具 22 → 31 条。⚠️ 双向测试两条都精准变红（各 30/1）：①`cmp` 判据换成「文件存在」
      ②摘掉 `ok` 守卫；还原后 31/0。⛔ 回滚用文件副本不用 `git checkout`——
      实现当时尚未提交，`git checkout --` 会把它一起冲掉（本轮真踩了一次）。

- [x] 2.2 ⛔ 夹具跑在生产 shell 设置下（`harness.sh`），否则测不出 ERR trap 那一类
      → verify：用 `h_run` 调用，`H_ERR_HIT` 为 0
      全部经 `h_run` 调用，跑在 `set -euo pipefail` + errtrace + ERR trap 下。

## 3. 验收（「测完」三步）

- [x] 3.1 `check-scripts.sh` 十项通过
      rc=0，无 ❌。⚠️ 中途被第 7 项「先用后定」拦下一次——assert_src 的模式串里含字面量
      `$DISPO_STATE`，lint 是正则匹配、分辨不出它被单引号护住。⛔ 没有弱化 lint，
      改为把接线变量提前声明。

- [x] 3.2 `NO_DELIVER` 整跑 `rc=0`，`$STATE/backup/dispositions/` 出现与现役一致的副本
      → verify：`cmp` 通过；再跑一轮**不新增**副本（D1）
      两轮均 rc=0；副本与现役 `cmp` 通过；第二轮不新增副本。

- [x] 3.3 ⛔ 恢复演练：故意写坏现役文件 → 用副本恢复 → `jq length` 与内容复原
      → verify：恢复后 shasum 等于写坏之前
      现役文件写坏成 `{"broken": oops`（jq 解析失败）→ 用副本 `cp` 回来 →
      shasum 复原为 `1167baf6…`，6 条结论内容一致。

## 4. 部署与文档

- [x] 4.1 `docs/CLAUDE-部署与运维.md`：把「必须纳入备份」从**文档承诺**改为**指向实现**，
      并写明能力边界（⛔ 防不住整台机器丢失，异地仍靠人工 scp）
      目录树补 `backup/dispositions/`、基准文件表写明自动副本与其能力边界、
      备份小节补一句「本机副本已自动化，⛔ 异地拷贝仍必须人工」。

- [ ] 4.2 部署生产机，下一轮周报（2026-10-05 05:30）后确认副本存在且一致
- [x] 4.3 ⛔ 补登失效模式：verify 判据写成「文档/脚本里出现该路径」时，写文档就能让它变绿
      （本 change 的根因，F6 的一个具体形态）
      已登记 **F61**「verify 写成「文档/脚本里出现该路径」时，写一句文档就能让它变绿」。

