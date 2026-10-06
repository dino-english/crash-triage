## 1. 取数（只取数，不判定）

- [x] 1.1 新增 `bin/sql/fix-release-builds.sql`：输入 fixmap 条目（`UNNEST([STRUCT(id, commit_ts)])`，占位符只替换值），输出 `(issue_id, build, display_version, first_seen, perf_on_devs, events_after_commit)`；事件取 crashlytics 批量表 ∪ REALTIME 按 `event_id` 去重（D3）；`first_seen` 取四表最早（D4）；⛔ 用 JOIN 不用关联子查询（BigQuery 不支持，2026-10-06 实测）
- [x] 1.2 同文件或另一份 SQL 输出 build 清单 `(build, display_version, first_seen, perf_on_devs)`，供 iOS「已上线」判定
- [x] 1.3 实测 1.1/1.2 在生产项目上的扫描量与耗时，记入本文件；超过 L1 可接受范围则回 design 改窗口
  - 2026-10-06 dry-run：iOS **2.8 MB** / Android **3.0 MB**；实跑 3–4 s / 端；整个子脚本生产影子跑 19 条 **8 s**。远低于 L1 可接受范围，不改窗口

## 2. 反扫补 git 事实

- [x] 2.1 `scan-fix-commits.sh` 的 mapped 条目补 `commit_epoch`（`%ct`，与现 epoch 同源）
- [x] 2.2 Android 条目补 `release_ref`（最早包含提交的 `V*` tag → tag 名；否则在 `origin/main` → `main`；否则 null）与 `fixed_in_version`（tag 去掉 `V` 前缀；无 tag 为 null）
- [x] 2.3 头注释 schema 补齐 `状态未知` 与新字段（现注释漏写「状态未知」）
- [x] 2.4 ⛔ 仍只读：只用 `merge-base --is-ancestor` / `tag --contains`，不 checkout / reset

## 3. 判定纯函数

- [x] 3.1 `bin/lib/` 新增四态判定 jq 函数：输入 fixmap 条目 + 该 issue 的 build 行 + build 清单，输出 `{status, old_build_events, release_check}`；按 D1/D2 逐端实现
- [x] 3.2 Android 版本比较走 `split(".") | map(tonumber)` 数组比较（D2），⛔ 不从 versionCode 反推
- [x] 3.3 夹具：用 2026-10-06 生产实测的 19 条作为期望值（见 proposal 表 + design Context），至少覆盖：8bc4b97e→已修未发版；8b297547→已发版待验（旧包仍崩 2）；62f88f39→修了仍在（1.7.1 计为旧包）；09ee5ad3→已修未发版；iOS 内部包事件不改判；查询失败→`release_check: unavailable`
- [x] 3.4 夹具跑在 `bin/test/harness.sh` 的生产 shell 设置下（`set -e` + ERR trap）

## 4. 子脚本 `fix-release-status.sh`

- [x] 4.1 argv：fixmap 路径、输出路径；读 SQL → 调 bq → 调 3.1 → 写改判后的 fixmap；退出码是唯一失败信号
- [x] 4.2 失败路径（D6）：照写原 fixmap 并逐条加 `release_check: "unavailable"`，退出非零；调用方 `|| RC=$?`
- [x] 4.3 issue_id / commit 注入前校验 `^[0-9a-f]+$`，不合规跳过并记日志（D7）
- [x] 4.4 审计：bq 调用走既有 audit 事件（与其他 SQL 同一时间线）
  - ⚠️ L2 已成立（`AUDIT_FILE` export）；**L1 不 export**，子脚本的 bq 调用不进 L1 时间线——调用处以环境前缀传 `AUDIT_FILE` / `RUN_ID`（不全局 export，免得改变其他子进程行为），改后重跑 L1 验 → ✅ 10-06 重跑：子进程（pid 82751）2 条 bq.call 进了 L1 审计，rc=0

## 5. L2 接入

- [x] 5.1 `crash-weekly.sh` 反扫之后、`fetch-snapshot-bq.sh` 之前调用 4，产物覆盖 `$FIXMAP_FILE`（保留原文件为 `fixmap-scan.json` 便于对照）
- [x] 5.2 `_chg_rows` / `_fix_rows`：状态→图标逐态显式映射（D8），删除「其余一律修了仍在」的 else 兜底；「旧包仍崩 N 次」与「发版判定不可得」作为括注
- [x] 5.3 `render-ledger.sh` 处置状态列与时间线：确认新文案原样透传、不破坏表格列数；「旧包仍崩 N 次」放备注列还是状态列，实发后定（列宽只能实发验证）
- [x] 5.4 ⚠️ 新变量过子进程边界一律 `export`，逐个列出核对

## 6. L1 接入

- [x] 6.1 `crash-daily.sh` 反扫前 fetch 两个业务仓库（照抄 `crash-weekly.sh:128`），失败不中断、卡片标注「仓库未同步，发版判定可能滞后」（D5）
- [x] 6.2 反扫后调用 4；`FIXED_PENDING` 改数 `status == "已修未发版"` 且 OPEN；`release_check == "unavailable"` 的不计（D6）
- [x] 6.3 反扫失败时的现有回落（`fix_commit != null` 计数，`crash-daily.sh:1414-1416`）：⛔ 它正是「不判发版就报未发版」，改为不告警 + 标注
- [x] 6.4 索引页图例（`crash-daily.sh:2676-2680`）与四态对齐

## 7. 夹具随改

- [x] 7.1 `fn-fix-status.sh`、`fn-fixed-pending.sh`、`fn-l1-fixed-pending.sh`、`fn-issue-state-filter.sh`、`fn-ledger-closed.sh`、`fn-ledger-anr.sh`、`fn-ledger-fingerprint.sh` 中两态字面量按新语义改写；逐个确认改的是期望值而不是放宽断言
- [x] 7.2 双向测试：删掉 5.2 的逐态映射、恢复 else 兜底 → 夹具必须变红

## 8. 文档

- [x] 8.1 `docs/CLAUDE-架构与数据口径.md`「台账口径」补四态定义与按端判据，注明两张 REALTIME 表 30 天保留、sessions 08-11~09-06 空洞
- [x] 8.2 `docs/CLAUDE-失效模式登记.md` 登记：时间规则把「旧包存量」报成「修了仍在」、L1「未发版」告警名不副实

## 9. 验收（全部完成前不提交、不部署）

- [x] 9.1 `bash bin/check-scripts.sh` rc=0，且无夹具被跳过
- [x] 9.2 备份开发机 STATE（L2 会提升基线），整跑 `CRASH_REPORT_NO_DELIVER=1` L2 与 L1，rc=0；产物里 19 条（或当日实际条数）的四态与 BigQuery 手算一致
- [x] 9.3 实发私聊，`docs +fetch` 读回周报、日报、索引页：状态文案、图标、括注、列宽逐处核
- [x] 9.4 生产只读影子跑：新 `scan-fix-commits.sh` + `fix-release-status.sh` 在生产 /tmp 跑，与当日生产 fixmap 逐条 diff，每条变化拿原始数据核
- [x] 9.5 还原开发机 STATE
  - 9.2：L2 rc=0（18 条判出）、L1 rc=0（fetch 后 19 条）；四态与生产影子跑一致；L1 告警 2 条（旧判据会报 6 条）
  - 9.3：日报读回告警「🔴 2 个 issue 代码已修但未发版」；周报 27/27 行到达（`<init>` 被转义、多行说明换行，按片段核）；
    测试台账（FOV2dF1SFohFB7x9pYYjrxlIpzb）走 block_replace，现状表 11 行 0 格不一致、标题各 1 次
  - 9.4：生产 /tmp 影子跑 scan + fix-release-status：19 条全判出、8 s；Android 15 条与 V* tag 逐条对照一致
  - 9.5：STATE 哈希还原至测试前；两业务仓工作区指纹与 HEAD 不变
- [x] 9.6 生产影子（台账）：新 `render-ledger.sh` 吃生产真实输入（最近一轮 L2 的快照 / 上一版表格 / 基准 / 结论存储）+ 新 fixmap，
  算出「下一轮 L2 会写进生产台账」的现状表与时间线；与生产当前现状表**逐格 diff**，每处变化拿原始数据核
- [x] 9.7 生产影子（卡片 / 周报）：`_fix_rows` / `_chg_rows` 用生产 fixmap 渲染，逐条核文案与图标
- [x] 9.8 生产影子（L1）：用生产 fixmap + 生产 issue 状态算出明早的「代码已修但未发版」计数与索引页修复列，
  与今早生产 L1 卡片对比，差异逐条解释
- [x] 9.9 L1 新增的 fetch：与 L2 周一在同一 hermes 上下文执行同一条命令，以生产 L2 日志里 fetch 成功为据（不在 ssh 上下文代测）

  - 9.6（10-06，生产 /tmp，新旧两版同一份输入）：现状表 21 行仅 **3 格**变化，全在处置状态列——
    09ee5ad3 已修待验→已修未发版 · 8bc4b97e 修了仍在→已修未发版 · 8b297547 修了仍在→已发版待验·旧包仍崩 2 次；
    其余列逐格不变。时间线将新增 8 行状态更正（旧行保留）
  - 9.7：生产 fixmap 渲染卡片 19 条，CLOSED 优先、四态图标与旧包次数正确，无 ❓ / 不可得
  - 9.8：**今早生产 L1 告警「5 个代码已修但未发版」5 条全是已发版的修复**（2a800b33 / 8101c07c / 0055b556 /
    e8a9ce84 / 26335e5d）；新判据明早报 2 条（09ee5ad3、8bc4b97e），均为真未发版。索引页 5 条命中显示「commit · 状态」
  - 9.9：生产 10-05 L2 日志「同步仓库」两仓通过（L2 fetch 失败即 fail，整轮完成即成功）

> ⛔ 以上全部完成、结果经人确认后才提部署。部署后的 morning-verify 是**监控**，不是本 change 的验证项。
