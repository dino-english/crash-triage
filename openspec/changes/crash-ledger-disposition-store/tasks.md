## 1. 结论存储

- [x] 1.1 定义 `$STATE/ledger/dispositions.json` 格式：顶层为 `issue_id → {first_seen, disposition, note}`，
      ⛔ 不分平台、不分 `error_type`（D1 统一键空间）
      → verify：`jq -e 'to_entries|all(.key|test("^[0-9a-f]{32}$"))'` 通过
- [x] 1.2 写入 D6 冷启动五条：`359fadbc`(已验证生效) / `9c984b20`(存量待验) / `c2b2ecfe`(存量待验) /
      `c3184f91`(部分修复·另一路径) / `baa93993`(设计内哨兵·无需修复)
      → verify：`jq 'length'` = 5，且五条 note 均非空
- [x] 1.3 把该文件纳入 `$STATE` 备份范围，与 `last-snapshot.json` 同级对待（spec：人工资产不可重算）
      → verify：备份脚本/文档中出现该路径；模拟 `$STATE` 重建后结论仍在
- [x] 1.4 ⛔ 确认跑批对该文件只读：跑批前后 `shasum` 一致
      → verify：`NO_DELIVER` 整跑前后哈希相同

## 2. 台账渲染接入

- [x] 2.1 `render-ledger.sh` 增入参「结论存储路径」，`nf_rows()` 按 `issue_id` join 并输出 `处置状态` / `备注` 两列
      → verify：NON_FATAL 表由 7 列变 9 列，五条冷启动 issue 的结论正确呈现
- [x] 2.2 `crash-weekly.sh` 传入该路径。⚠️ 跨进程必须 `export`——`REPOS_ROOT` 漏过且不报错
      → verify：子脚本内 `echo` 该变量非空；故意不 export 时须报错而非静默用默认值
- [x] 2.3 无结论的行两列留空，机器列不受影响
      → verify：取一个不在存储中的 NON_FATAL issue，其机器列与接入前逐字段一致
- [x] 2.4 存储不存在 → 结论列留空 + 产出标注「结论存储不可得」+ 跑批继续（D5 前半）
      → verify：临时改名该文件后整跑 `rc=0`，且产物含该标注
- [x] 2.5 ⛔ 存储损坏 → 报错中止，且**不得以空内容覆写**（D5 后半，同 `block_replace` 不退化 `overwrite` 的纪律）
      → verify：写入非法 JSON 后整跑须非零退出；事后该文件内容未被改动
- [x] 2.6 ⛔ `build_rows()` 一个字不改（避开 `crash-ledger-anr-tracking` 在途范围）
      → verify：`git diff` 中 `build_rows()` 函数体为空差异

## 3. 周报正文接入

- [x] 3.1 周报 iOS NON_FATAL 段（TOP N 下钻）join 同一存储，呈现结论并标明「人工结论，非当期数据推导」
      → verify：周报 markdown 中五条冷启动 issue 带结论且带该标注
      ⚠️ **该 verify 判据本身漏算了 TOP N 截断，已按实际口径核**：正文是 `DD_TOP_N=3` 的下钻段，
      结构上最多出现 3 条。2026-09-23 整跑实测正文出 3 条（`9c984b20` / `c2b2ecfe` / `c3184f91`，
      均带「人工沉淀，非当期数据推导」标注），台账 NON_FATAL 表出全部 5 条。
      ⛔ 不为凑满 5 条去改 `DD_TOP_N`——那会改掉与本 change 无关的正文口径。
- [x] 3.2 无结论的 issue 只呈现数据，⛔ 不得以空白暗示「无问题」
      → verify：无结论行不出现结论区块，而非出现空区块
- [x] 3.3 存储不可得时周报照常产出并标注，⛔ 不中止投递
      → verify：临时改名该文件后周报整跑 `rc=0` 且含标注
- [x] 3.4 ⛔ `crash-daily.sh` 一个字不改（D4：L1 不呈现结论）
      → verify：`git diff --stat` 不含 `bin/crash-daily.sh`

## 4. 验收（「测完」三步，缺一不算完）

- [x] 4.1 `check-scripts.sh` 十项通过，⚠️ 确认递归扫到 `bin/**/*.sh` 而非只扫顶层
      → verify：输出十项全绿；故意在 `bin/lib/` 放一个违规样本须变红（双向测试）
- [x] 4.2 `NO_DELIVER` 完整整跑（⛔ 不用 `DRY_RUN`——它打完卡片就 exit 0，跑不到 build_index/manifest）
      → verify：`rc=0` 且 `$STATE/health.json` 正常、台账本地产物两列正确
- [x] 4.3 实发私聊并 `docs +fetch` 读回核对：两列渲染、列宽、斑马纹、结论备注是否被截断
      → verify：读回的文档中两列可见且未挤压既有列；⛔ 本地全绿不算证据（F57/F58 教训）
      2026-09-23 实发到测试台账 `Dz9ldi2yUor0EMxxeTljwQm7pep`（bot 建档，与生产台账不同档），
      `block_replace` 真把 7 列换成 9 列（`result=success` 且文档确有变更），读回逐字比对：
      五条结论**逐字节一致、零截断**（最长 `baa93993` 149 字符 / `c3184f91` 123 字符），
      四条无结论行末两列留空。列宽经人工目视确认可接受。
      ⚠️ **踩到 F57 两次**：前两次 `block_replace` 返回 `ok:true`/rc=0 但文档未变，
      根因是建档用了默认 profile（应用 `cli_aad59f45…`），而 `deliver.sh` 走
      `--profile crash-triage`（应用 `cli_aaf7b44d…`）——**两个不同应用**，bot 无权写。
      ⛔ 只判退出码会把这两次打成 ✅。
- [x] 4.4 掉榜回榜行为验证：构造某 issue 本轮不入选、下轮重新入选
      → verify：两轮之间其结论在存储中不变，回榜后原样呈现
- [x] 4.5 备份恢复验证：从备份重建 `$STATE` 后结论完好
      → verify：恢复后 `jq 'length'` 仍为 5 且 note 内容一致

## 5. 部署

- [ ] 5.1 ⛔ 确认无跑批在途再改 `bin/**`（判据是有没有进程在跑，不是改的哪个文件）
      → verify：`ps` 无 crash-daily / crash-weekly 进程；`hermes cron list` 确认不在窗口内
- [ ] 5.2 部署日人工动作：台账飞书文档 NON_FATAL 表标题下的静态说明加两列解释
      （与 anr-tracking 的 2.4 / 4.5 同类，静态内容不参与同步）
      → verify：`docs +fetch` 读回该段落含新说明
- [ ] 5.3 首轮跑批后复核台账飞书文档的 NON_FATAL 表
      → verify：两列内容与本地 `dispositions.json` 一致
- [x] 5.4 Open Question 结项：实测飞书表格内结论备注的长度上限，超限则定截断阈值并指向
      `$STATE/ledger/snapshots/` 的专项报告
      → verify：`c3184f91`（最长的一条）在飞书表格内完整可读或按既定阈值截断且有指向
      **结论：本轮不设截断阈值。** 2026-09-23 实测飞书未对任何一条备注截断，
      149 字符（`baa93993`，本轮最长）读回逐字节一致。
      ⚠️ 代价要说清：两列让 NON_FATAL 表最宽行的显示宽度从 **215 → 433**（Issue 现状表是 232），
      基本翻倍。本轮目视确认可接受，⚠️ 但若日后结论写得更长 / 表更宽而开始影响可读性，
      解法已备好：表内截断 + 指向 `$STATE/ledger/snapshots/` 的专项报告（不改存储格式）。
