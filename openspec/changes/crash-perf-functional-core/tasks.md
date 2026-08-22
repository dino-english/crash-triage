## 0. 产物清单与基线（先做，否则后面无从验收）

- [x] 0.1 写 `bin/test/artifacts.sh`：登记三层产物路径清单（design D7 表）——中间产物 `$TMP/{m,d,issues}-*.json`、投递产物 `$PUBLISH_DIR/**`、基准文件 `$STATE/{health-daily.json,health.json,metrics-history.jsonl,perf-history.jsonl,daily-snapshot.json,last-snapshot.json,docs.json,folders.json,report-index.jsonl,ledger/LEDGER.md}`、**事实层缓存 `$STATE/issues/`**（易漏：`CLAUDE.md` 写它「永久保留不参与清理」，读起来像与跑批无关，实则每次跑批都写）。此前这些路径散落在十几处重定向里，本文件是契约的第一次显式登记
- [x] 0.2 写 `bin/test/normalize.sh`：归一化 `run_id` / `last_run` / 幂等键 / 取数区间时刻 / `runs/<日期>/L{1,2}/<时刻>/` 路径中的时刻段（design D7）
- [x] 0.3 写 `bin/test/baseline.sh`：**快照回滚协议**——备份 `$STATE` 基准文件 → 跑批 → 按 0.1 清单收集三层产物并归一化 → **从备份还原基准文件**。`crash-weekly.sh:624` 的 `cp "$SNAP_NEW" "$SNAP_LAST"` 在 `NO_DELIVER` 闸门之前，不还原则第二次跑批看到零变化，L2 等价性验收全是假阳性。**`issues/` 同样必须还原**——不还原则第二次跑批缓存已热（`CACHED_NEW` 变 `CACHED_HIT`），两次走不同分支
- [x] 0.4 ✅ 核实完成：`perf-history.jsonl` 用 `>>` **追加，不幂等**（同周重跑加重复行，靠 prune 保留每 platform|version 最近 12 条兜底）。已在还原清单内。原文：核实 perf-history.jsonl 同周重跑是否幂等（L1 的 `metrics-history.jsonl` 已核实为按 `day` 键 upsert，`daily-snapshot.json` 为整体覆盖）；不幂等则在 0.3 的还原清单中确保覆盖
- [x] 0.5 用 `baseline.sh` 跑 L1（`CRASH_REPORT_NO_DELIVER=1`），产物存入 `$STATE/backup/baseline-l1-<日期>/`
- [ ] 0.6 ⚠️ **未做**（跳过了，导致 L2 无改动前基线可比）：用 `baseline.sh` 跑 L2（加 `CRASH_REPORT_SKIP_ANALYSIS=1` 跳过模型层，避免额度影响），存入 `baseline-l2-<日期>/`
- [ ] 0.7 ⏸ 暂缓（L1 不写 issues/ 缓存，冷热之分主要对 L2 有意义）：**冷热两组基线**：L1 与 L2 各跑两组——组 A 从回滚后的冷缓存起跑，组 B 紧接着在热缓存上跑（design D7）。重构可能只改坏其中一条路径，两组各自留基线、后续不跨组比对
- [x] 0.8 **协议自验**：代码未改的情况下重跑冷热两组并与基线 diff，**三层必须全为空**。不为空说明归一化漏字段（0.2）或还原漏文件（0.3），补完再继续 —— 这一步不通过就不要开始重构

## 1. 去重：外壳层共享函数收口

- [x] 1.1 新建 `bin/lib/common.sh`，顶部注释写明「必须在 `$ROOT` / `$STATE` 赋值之后 source」
- [x] 1.2 移入 `step` / `err_stack` / `on_err`（三者在两个脚本中逐字节相同，直接搬）
- [x] 1.3 移入 `alert_once`：差异项 `--source daily|weekly` 与 `--run-id`（daily 用 `$RUN_ID`、weekly 用 `$TS`）改由调用方预设变量 `ALERT_SOURCE` / `ALERT_RUN_ID` 表达，`ALERT_FLAG` 同理
- [x] 1.4 移入 `fail`：差异项 health 文件路径改由调用方预设 `HEALTH_FILE`（daily 是 `$STATE/health-daily.json`，weekly 是 `$HEALTH`）
- [x] 1.5 `crash-daily.sh` / `crash-weekly.sh` 删除上述函数体，改为设好差异变量后 `. "$ROOT/bin/lib/common.sh"`；保留与现有 `lib.sh` 一致的「文件缺失则退化」回落分支
- [x] 1.6 `bash bin/check-scripts.sh` 通过
- [x] 1.7 **等价性验收** ✅ L1 三层全空。⚠️ L2 无改动前基线（0.6 未做），只验证了「能跑且产物正常」。原文：：用 `baseline.sh` 重跑 L1 + L2，与 0.5/0.6 基线三层 diff 为空
- [ ] 1.8 单独提交（可独立回滚）

## 2. 抽核心层：纯函数外移 + 全局提参

- [ ] 2.1 新建 `bin/lib/core/format.sh`，移入 `int` / `pct` / `rate_pct` / `_fmt` / `_until_epoch` / `win_compact` / `win_full`
- [ ] 2.2 新建 `bin/lib/core/verdict.sh`，移入 `traffic_light` / `cell_color` / `delta_cell` / `stale_days`
- [ ] 2.3 新建 `bin/lib/core/version.sh`，移入 `pick_newest` / `pick_top_sessions` / `union_versions` / `ver_field`
- [ ] 2.4 新建 `bin/lib/core/cache.sh`（design D10）：`cache_verdict <强制标志> <文件是否存在> <上次计数> <本次计数>` → `new|update|hit`（从 `fetch-snapshot-bq.sh:108-126` 的 while 循环上移）；`doc_keep_predicate` —— `doc_prune` 的日期键保留判定（从 `deliver.sh:252-258` 上移，保持 jq 表达式原样，只是移出并可独立调用）。三处调用方改为调用核心层，**保持行为一字不变**
- [ ] 2.5 按 design D3 改签名：`win_compact` / `win_full` 首二参改为「基准 epoch + 时区标签」，`stale_days` 首参改为基准 epoch，`union_versions` 增第三参「列上限」
- [ ] 2.6 `grep -n` 逐个列出四个函数的全部调用点并改完（design D3 表中计数为 grep 结果，实施时以实际为准）；改完后确认核心层文件中不再出现 `RUN_EPOCH` / `TZ_LABEL` / `MAX_VERSION_COLS`
- [ ] 2.7 两个入口脚本 source 三个核心层文件（顺序任意，放在 `common.sh` 之前或之后均可）
- [ ] 2.8 `bash -u -c '. bin/lib/core/format.sh; . bin/lib/core/verdict.sh; . bin/lib/core/version.sh; . bin/lib/core/cache.sh'` 在空环境下加载成功且无输出（spec 的「可脱离流水线独立调用」场景）
- [ ] 2.9 `bash bin/check-scripts.sh` 通过
- [ ] 2.10 **等价性验收**：重跑 L1 + L2，与基线三层 diff 为空 —— 参数错位会在此显形
- [ ] 2.11 单独提交

## 3. 断言用例

- [ ] 3.1 写 `bin/test/run.sh`：提供 `assert_eq <期望> <实际> <用例名>`，遍历 `bin/test/core-*.sh`，统计通过/失败，有失败则非零退出（bash 3.2 兼容，零外部依赖）
- [ ] 3.2 `bin/test/core-format.sh`：覆盖 `format.sh` 全部函数。必含边界 —— `rate_pct` 分母为 `0` / 为空 → 空串；`int` / `pct` 空输入 → 空串；`pct` 整数与小数两种输出形态；`_until_epoch` 输入 `—` 与不可解析串 → 空；`win_compact` / `win_full` 止点为空 → 降级形态。**用例内固定 `TZ`**（design：`_fmt` 读环境 TZ）
- [ ] 3.3 `bin/test/core-verdict.sh`：`traffic_light` 空值与「无法计算」不判定 → 空串（这是「空值不告警」口径的根）；红/黄/绿三档各一例含边界值；`delta_cell` 覆盖 `lower_better` / `higher_better` / `neutral` 三方向 × 正/负/零增量，验证「箭头跟数值、颜色跟好坏」；`stale_days` 未停更 → 空、已停更 → 天数
- [ ] 3.4 `bin/test/core-version.sh`：`pick_newest` 按版本号而非会话量排序（含 `1.5.10` vs `1.5.9` 这类 `sort -V` 才对的用例）；`union_versions` 去重、排序、上限截断；`pick_top_sessions` 按会话量；`ver_field` 命中与未命中；**单版本可比时的退化情形**
- [ ] 3.5 `bin/test/core-cache.sh`（design D10）：`cache_verdict` 覆盖 强制标志=1 / 文件不存在 / 计数变大 / 计数相等 四种入参组合；**并单列一条 `本次 < 上次`** —— **该缺陷已由 change `crash-fact-cache-freshness` 于 2026-08-22 修复**（抓取判定与记录更新拆开、`latest_event` 取 max）。用例直接钉住**修复后的正确行为**：`本次 < 上次` → 抓取判定为 `skip`，但观测字段仍刷新。⛔ 不要再写「已知缺陷」注释——那是修复前的状态。`doc_keep_predicate` 覆盖：日期键在 cutoff 内保留 / 超出丢弃 / **无日期后缀的固定键（`index` / `ledger`）无条件保留** —— 最后这条正是 2026-08-18 生产误删的那个场景（`deliver.sh:249-251` 注释），是本 change 里最高价值的一条用例
- [ ] 3.6 期望值从行为意图推导，不从当前输出反抄（design 风险表末项）。若某用例的意图值与实际输出不符，**不改代码也不改用例**，记入 `openspec/changes/crash-perf-functional-core/findings.md` 报给人判断
- [ ] 3.7 `bash bin/test/run.sh` 全绿

## 4. 闸门：把约束变成退出码

- [x] 4.1 `check-scripts.sh` 改为递归扫描 `find "$SELF_DIR" -name '*.sh'`（**当前只扫 `$SELF_DIR/*.sh`，不改则 `bin/lib/` 与 `bin/test/` 下的新代码完全不受检查，含那条多字节变量 lint**）
- [ ] 4.2 加依赖方向 lint：`bin/lib/core/*.sh` 中匹配 `^[^#]*(\bbq\b|lark-cli|claude |curl |firebase|\$STATE|\$ROOT|\$\{STATE|\$\{ROOT)` 即失败，输出文件、行号、命中内容
- [ ] 4.3 加重复定义检测：扫全部 `bin/**/*.sh` 行首函数定义按名聚合，≥2 个文件即失败；豁免清单以「函数名:文件名 + 一行理由」的数据形式集中在脚本内（`fail:deliver.sh` 独立进程语义不同、`say:install.sh` 与 `say:update.sh` 装机链路本次未合并）
- [ ] 4.4 加测试闸：调用 `bin/test/run.sh`，失败则整体非零
- [ ] 4.5 接入 shellcheck：未安装时打印一行跳过提示且**不影响退出码**；已安装则计入退出码。按 design Open Questions —— 若首次接入报出的既有问题超过约 50 项，本 change 内改为仅提示不失败，并在 `findings.md` 记录数量与另开 change 的建议
- [ ] 4.6 **自检的自检**：在 `bin/lib/core/` 临时放一个含 `$STATE` 的文件，确认 4.2 报错；临时在第二个脚本里复制一个已有函数名，确认 4.3 报错；临时改坏一个纯函数，确认 4.4 报错。三项各确认后删除临时改动
- [ ] 4.7 `bash bin/check-scripts.sh` 全绿
- [ ] 4.8 单独提交

## 5. 文档与收尾

- [ ] 5.1 `CLAUDE.md` 的「常用命令」增 `bash bin/test/run.sh`；并说明 `check-scripts.sh` 已从两项检查扩为五项（原文明确写着「是**两项**检查」，不改会与实际不符）
- [ ] 5.2 `CLAUDE.md` 的「架构要点」增一节：分层与依赖方向（核心层无副作用、外壳层编排、lint 如何强制），并写明**渲染层拆分与表名参数化是刻意的 Non-goal**及其理由，避免下一个读者以为是遗漏
- [ ] 5.3 `CLAUDE.md` 记下 8 个跨进程边界（`alert.sh` / `scan-fix-commits.sh` / `fetch-snapshot-bq.sh` / `fetch-snapshot.sh` / `render-ledger.sh` / `split-fix-list.py` / `md2docx.py` / `deliver.sh`）及其统一形状「`export` 环境变量 + argv 进，文件 + 退出码出」，并指向 `bin/test/artifacts.sh` 的产物清单（design D9）；同时登记一处**已知未修缺口**：`fetch-snapshot.sh:80-135` 用自然语言在 prompt 里复述了 `fetch-snapshot-bq.sh` 的同一套缓存策略，重复定义检测抓不到、模型那份不可断言（design D10）
- [ ] 5.4 `bin/INSTALL.md` 说明 bats / shellcheck 均为可选、生产机无需安装
- [ ] 5.5 最终验收：`bash bin/check-scripts.sh` → `bash bin/test/run.sh` → `bin/test/baseline.sh` 跑 L1 与 L2（走快照回滚协议），与 0.5/0.6 基线三层 diff 为空
- [ ] 5.6 若 `findings.md` 有条目（3.6 的意图不符项、4.5 的 shellcheck 数量），在归档前逐条与人确认处置
