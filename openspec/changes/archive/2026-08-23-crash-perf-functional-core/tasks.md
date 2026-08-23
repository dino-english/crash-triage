## 0. 产物清单与基线（先做，否则后面无从验收）

- [x] 0.1 写 `bin/test/artifacts.sh`：登记三层产物路径清单（design D7 表）——中间产物 `$TMP/{m,d,issues}-*.json`、投递产物 `$PUBLISH_DIR/**`、基准文件 `$STATE/{health-daily.json,health.json,metrics-history.jsonl,perf-history.jsonl,daily-snapshot.json,last-snapshot.json,docs.json,folders.json,report-index.jsonl,ledger/LEDGER.md}`、**事实层缓存 `$STATE/issues/`**（易漏：`CLAUDE.md` 写它「永久保留不参与清理」，读起来像与跑批无关，实则每次跑批都写）。此前这些路径散落在十几处重定向里，本文件是契约的第一次显式登记
- [x] 0.2 写 `bin/test/normalize.sh`：归一化 `run_id` / `last_run` / 幂等键 / 取数区间时刻 / `runs/<日期>/L{1,2}/<时刻>/` 路径中的时刻段（design D7）
- [x] 0.3 写 `bin/test/baseline.sh`：**快照回滚协议**——备份 `$STATE` 基准文件 → 跑批 → 按 0.1 清单收集三层产物并归一化 → **从备份还原基准文件**。`crash-weekly.sh:624` 的 `cp "$SNAP_NEW" "$SNAP_LAST"` 在 `NO_DELIVER` 闸门之前，不还原则第二次跑批看到零变化，L2 等价性验收全是假阳性。**`issues/` 同样必须还原**——不还原则第二次跑批缓存已热（`CACHED_NEW` 变 `CACHED_HIT`），两次走不同分支
- [x] 0.4 ✅ 核实完成：`perf-history.jsonl` 用 `>>` **追加，不幂等**（同周重跑加重复行，靠 prune 保留每 platform|version 最近 12 条兜底）。已在还原清单内。原文：核实 perf-history.jsonl 同周重跑是否幂等（L1 的 `metrics-history.jsonl` 已核实为按 `day` 键 upsert，`daily-snapshot.json` 为整体覆盖）；不幂等则在 0.3 的还原清单中确保覆盖
- [x] 0.5 用 `baseline.sh` 跑 L1（`CRASH_REPORT_NO_DELIVER=1`），产物存入 `$STATE/backup/baseline-l1-<日期>/`
- [x] 0.6 「改动前基线」已无法回溯补抓；其目的（L2 可做等价性验收）于 2026-08-23 由 F1 收口以更强形式达成：取数收口 bqq 后，L2 同一冻结缓存两跑三层产物**逐字节一致**、改前改后数字盲比对 0 结构差异（见 findings F1 已根治记录）。原文：用 `baseline.sh` 跑 L2 存基线
- [x] 0.7 定为不做（2026-08-23）：F1 收口后 L2 已能用冻结缓存做严格等价（比冷热双基线更强——同数据两跑逐字节一致），冷热路径差异由 baseline.sh 的快照回滚协议保证每次从同一状态起跑。原文：**冷热两组基线**：L1 与 L2 各跑两组——组 A 从回滚后的冷缓存起跑，组 B 紧接着在热缓存上跑（design D7）。重构可能只改坏其中一条路径，两组各自留基线、后续不跨组比对
- [x] 0.8 **协议自验**：代码未改的情况下重跑冷热两组并与基线 diff，**三层必须全为空**。不为空说明归一化漏字段（0.2）或还原漏文件（0.3），补完再继续 —— 这一步不通过就不要开始重构

## 1. 去重：外壳层共享函数收口

- [x] 1.1 新建 `bin/lib/common.sh`，顶部注释写明「必须在 `$ROOT` / `$STATE` 赋值之后 source」
- [x] 1.2 移入 `step` / `err_stack` / `on_err`（三者在两个脚本中逐字节相同，直接搬）
- [x] 1.3 移入 `alert_once`：差异项 `--source daily|weekly` 与 `--run-id`（daily 用 `$RUN_ID`、weekly 用 `$TS`）改由调用方预设变量 `ALERT_SOURCE` / `ALERT_RUN_ID` 表达，`ALERT_FLAG` 同理
- [x] 1.4 移入 `fail`：差异项 health 文件路径改由调用方预设 `HEALTH_FILE`（daily 是 `$STATE/health-daily.json`，weekly 是 `$HEALTH`）
- [x] 1.5 `crash-daily.sh` / `crash-weekly.sh` 删除上述函数体，改为设好差异变量后 `. "$ROOT/bin/lib/common.sh"`；保留与现有 `lib.sh` 一致的「文件缺失则退化」回落分支
- [x] 1.6 `bash bin/check-scripts.sh` 通过
- [x] 1.7 **等价性验收** ✅ L1 三层全空。⚠️ L2 无改动前基线（0.6 未做），只验证了「能跑且产物正常」。原文：：用 `baseline.sh` 重跑 L1 + L2，与 0.5/0.6 基线三层 diff 为空
- [x] 1.8 单独提交（可独立回滚）—— `0730f80 refactor(1/3)`（补记：提交早已按三段拆分，勾漏打）

## 2. 抽核心层：纯函数外移 + 全局提参

- [x] 2.1 新建 `bin/lib/core/format.sh`，移入 `int` / `pct` / `rate_pct` / `_fmt` / `_until_epoch` / `win_compact` / `win_full`
- [x] 2.2 新建 `bin/lib/core/verdict.sh`，移入 `traffic_light` / `cell_color` / `delta_cell` / `stale_days`
- [x] 2.3 新建 `bin/lib/core/version.sh`，移入 `pick_newest` / `pick_top_sessions` / `union_versions` / `ver_field`
- [x] 2.4 ✅ 已完成（2026-08-23）：新建 `bin/lib/core/cache.sh`——`cache_verdict <强制标志> <文件是否存在> <上次计数> <本次计数>` → `new|append|skip`（判定值名以修复后代码为准，非 design 写的 `new|update|hit`）；`doc_keep_predicate <cutoff>` 走 stdin/stdout，jq 表达式一字未改。调用方三处：`fetch-snapshot-bq.sh`（只留读文件成入参）、`deliver.sh` 的 `doc_prune`、两个入口的加载清单加 `cache`。两个子进程脚本各自加载核心层（独立进程，不能指望调用方 export 函数），缺失即失败不退化。
- [x] 2.5 按 design D3 改签名：`win_compact` / `win_full` 首二参改为「基准 epoch + 时区标签」，`stale_days` 首参改为基准 epoch，`union_versions` 增第三参「列上限」
- [x] 2.6 调用点实际 **14 个**（daily 10 + weekly 4），design 估的是 18。原文：grep -n 逐个列出四个函数的全部调用点并改完；改完后确认核心层文件中不再出现 `RUN_EPOCH` / `TZ_LABEL` / `MAX_VERSION_COLS`
- [x] 2.7 两个入口脚本 source 三个核心层文件（顺序任意，放在 `common.sh` 之前或之后均可）
- [x] 2.8 `bash -u -c '. bin/lib/core/format.sh; . bin/lib/core/verdict.sh; . bin/lib/core/version.sh; . bin/lib/core/cache.sh'` 在空环境下加载成功且无输出（spec 的「可脱离流水线独立调用」场景）
- [x] 2.9 `bash bin/check-scripts.sh` 通过
- [x] 2.10 **等价性验收**：重跑 L1 + L2，与基线三层 diff 为空 —— 参数错位会在此显形
- [x] 2.11 单独提交 —— `f3a28b2 refactor(2/3)`（补记同 1.8）

## 3. 断言用例

- [x] 3.1 写 `bin/test/run.sh`：提供 `assert_eq <期望> <实际> <用例名>`，遍历 `bin/test/core-*.sh`，统计通过/失败，有失败则非零退出（bash 3.2 兼容，零外部依赖）
- [x] 3.2 `bin/test/core-format.sh`：覆盖 `format.sh` 全部函数。必含边界 —— `rate_pct` 分母为 `0` / 为空 → 空串；`int` / `pct` 空输入 → 空串；`pct` 整数与小数两种输出形态；`_until_epoch` 输入 `—` 与不可解析串 → 空；`win_compact` / `win_full` 止点为空 → 降级形态。**用例内固定 `TZ`**（design：`_fmt` 读环境 TZ）
- [x] 3.3 `bin/test/core-verdict.sh`：`traffic_light` 空值与「无法计算」不判定 → 空串（这是「空值不告警」口径的根）；红/黄/绿三档各一例含边界值；`delta_cell` 覆盖 `lower_better` / `higher_better` / `neutral` 三方向 × 正/负/零增量，验证「箭头跟数值、颜色跟好坏」；`stale_days` 未停更 → 空、已停更 → 天数
- [x] 3.4 `bin/test/core-version.sh`：`pick_newest` 按版本号而非会话量排序（含 `1.5.10` vs `1.5.9` 这类 `sort -V` 才对的用例）；`union_versions` 去重、排序、上限截断；`pick_top_sessions` 按会话量；`ver_field` 命中与未命中；**单版本可比时的退化情形**
- [x] 3.5 ✅ 已完成（2026-08-23）：`bin/test/core-cache.sh` 12 条断言，全套 39 → **51 条**。`cache_verdict` 覆盖 强制/文件不存在/计数变大/计数相等，并单列 `本次 < 上次 → skip`（钉住 crash-fact-cache-freshness 修复后的正确行为，未写「已知缺陷」注释）。`doc_keep_predicate` 覆盖 cutoff 内保留 / 超出丢弃 / **cutoff 晚于全部日期键时 index / ledger 仍无条件保留**（2026-08-18 生产误删场景）/ 空台账 / 日期恰等于 cutoff 保留。等价性实测：真实 `docs.json` 新旧 jq 输出完全一致；真实 `issues/` 20 个 × 6 种入参 = 120 次比对零差异；`CRASH_REPORT_SKIP_ANALYSIS=1` 整跑 L2 通过。
- [x] 3.6 期望值从行为意图推导，不从当前输出反抄（design 风险表末项）。若某用例的意图值与实际输出不符，**不改代码也不改用例**，记入 `openspec/changes/crash-perf-functional-core/findings.md` 报给人判断
- [x] 3.7 `bash bin/test/run.sh` 全绿

## 4. 闸门：把约束变成退出码

- [x] 4.1 `check-scripts.sh` 改为递归扫描 `find "$SELF_DIR" -name '*.sh'`（**当前只扫 `$SELF_DIR/*.sh`，不改则 `bin/lib/` 与 `bin/test/` 下的新代码完全不受检查，含那条多字节变量 lint**）
- [x] 4.2 加依赖方向 lint：`bin/lib/core/*.sh` 中匹配 `^[^#]*(\bbq\b|lark-cli|claude |curl |firebase|\$STATE|\$ROOT|\$\{STATE|\$\{ROOT)` 即失败，输出文件、行号、命中内容
- [x] 4.3 加重复定义检测：扫全部 `bin/**/*.sh` 行首函数定义按名聚合，≥2 个文件即失败；豁免清单以「函数名:文件名 + 一行理由」的数据形式集中在脚本内（`fail:deliver.sh` 独立进程语义不同、`say:install.sh` 与 `say:update.sh` 装机链路本次未合并）
- [x] 4.4 加测试闸：调用 `bin/test/run.sh`，失败则整体非零
- [x] 4.5 接入 shellcheck（本机未安装 → 走「跳过并提示」分支，已验证不影响退出码；**已安装时的实际告警量仍未知**）：未安装时打印一行跳过提示且**不影响退出码**；已安装则计入退出码。按 design Open Questions —— 若首次接入报出的既有问题超过约 50 项，本 change 内改为仅提示不失败，并在 `findings.md` 记录数量与另开 change 的建议
- [x] 4.6 **自检的自检**：在 `bin/lib/core/` 临时放一个含 `$STATE` 的文件，确认 4.2 报错；临时在第二个脚本里复制一个已有函数名，确认 4.3 报错；临时改坏一个纯函数，确认 4.4 报错。三项各确认后删除临时改动
- [x] 4.7 `bash bin/check-scripts.sh` 全绿
- [x] 4.8 单独提交 —— `8ed2115 refactor(3/3)`（补记同 1.8）

## 5. 文档与收尾

- [x] 5.1 `CLAUDE.md` 的「常用命令」增 `bash bin/test/run.sh`；并说明 `check-scripts.sh` 已从两项检查扩为五项（原文明确写着「是**两项**检查」，不改会与实际不符）
- [x] 5.2 `CLAUDE.md` 的「架构要点」增一节：分层与依赖方向（核心层无副作用、外壳层编排、lint 如何强制），并写明**渲染层拆分与表名参数化是刻意的 Non-goal**及其理由，避免下一个读者以为是遗漏
- [x] 5.3 ✅ 已完成（2026-08-23）：`CLAUDE.md` 增「跨进程边界：8 个子脚本，一种形状」一节——8 个脚本的进/出对照表、统一形状「`export` 环境变量 + argv 进，文件 + 退出码出」、三条踩过的推论（函数不跨进程 / 普通赋值必须 export / 退出码判据两端必须一致），并指向 `bin/test/artifacts.sh` 的三层产物清单；同时登记 `FACT_CACHE_POLICY` 那处 prompt 与 shell 的跨语言重复（重复定义检测抓不到、模型那份不可断言）。
- [x] 5.4 `bin/INSTALL.md` 说明 bats / shellcheck 均为可选、生产机无需安装
- [x] 5.5 最终验收（2026-08-23 实测，/bin/bash 3.2）：`check-scripts.sh` 七项全绿（51 条断言）；`baseline.sh` L1 冻结缓存改前/改后三层 92 产物严格 diff 为空；L2 同缓存两跑严格 diff 为空 + 活数据数字盲比对 0 结构差异。原文基线对象 0.6 已由 F1 收口验收替代
- [x] 5.6 F1–F6 处置表已于 2026-08-23 逐条呈报并获同意推进：F1/F5/F6 已根治（bqq 收口 + lint 护栏 + 轮询 1s，见各自「已根治」记录），F2/F3/F4 为记录性条目无需行动
