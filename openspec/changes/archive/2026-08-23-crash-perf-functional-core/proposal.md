## Why

四千行 bash 里**没有一行断言**。[bin/check-scripts.sh](../../../bin/check-scripts.sh) 只做两件事：`bash -n` 语法检查，以及「`$VAR` 紧邻多字节字符」的 lint。而 `rate_pct` / `traffic_light` / `delta_cell` / `pick_newest` / `union_versions` / `stale_days` 这些**纯函数**——输入输出完全确定、无副作用——正是最该被测、也最容易被测的部分。它们改错了不会报语法错，只会在群卡片上安静地显示一个错的数字。

同时 `lib.sh` 形同虚设：48 行 2 个函数，而 **10 个函数在 `crash-daily.sh` 与 `crash-weekly.sh` 之间整段复制**（`step` `alert_once` `err_stack` `on_err` `fail` `_until_epoch` `_fmt` `win_compact` `win_full` `stale_days`）。其中 `stale_days` 逐字节相同，错误处理段连「bash 3.2 下 `$LINENO` 不准」那段 6 行考据注释都是复制的。2026-08-21 的告警风暴修复（`ALERT_FLAG` 文件标记）就是在两个文件里各改一遍——**下一次修必然漏一个**。

之所以现在做：`crash-daily.sh` 已经 1485 行、约 90 个函数，取数（`bqq`/`q`/`qc`）、阈值判定、三种渲染（卡片 JSON / DocxXML / markdown）、历史持久化全在一个文件里。再长下去，剥离纯函数的成本只增不减。

## What Changes

采用 **Functional Core / Imperative Shell**（Gary Bernhardt, 2012）而非完整 Clean Architecture——保留其「依赖规则」内核，舍弃 Ports & Adapters 的仪式（bash 无类型系统兜底，接口反转在这里只有成本没有强制力）。

- **新建 `bin/lib/core/`**：把纯函数从 `crash-daily.sh` 剥离到三个文件，按职责分组
  - `format.sh` — `int` / `pct` / `rate_pct` / `_fmt` / `_until_epoch` / `win_compact` / `win_full`
  - `verdict.sh` — `traffic_light` / `cell_color` / `delta_cell` / `stale_days`
  - `version.sh` — `pick_newest` / `pick_top_sessions` / `union_versions` / `ver_field` / `ver_tag`
  - `cache.sh` — 缓存判定：事实层的 `new|update|hit` 三态、`docs.json` 的日期键保留谓词（design D10）
- **新建 `bin/lib/common.sh`**：10 个重复函数的唯一收口点（`step` / `alert_once` / `err_stack` / `on_err` / `fail` 等）。两个入口脚本改为 `source`，各减约 60 行。
  - `alert.sh --source` 与 health 文件路径的差异由调用方传参消除（daily/weekly 是仅有的两处差异）
- **新建 `bin/test/`**：bats-core 风格的纯函数断言（不强制依赖 bats，无 bats 时用内建 `assert` 回落，见 design）。覆盖三个 core 文件的全部导出函数，含边界：空串 / `0` 分母 / 「无法计算」/ 负增量 / 单版本。
- **`check-scripts.sh` 增两道闸**（本 change 的核心新能力）：
  - **依赖方向 lint**：`bin/lib/core/*.sh` 中出现 `bq ` / `lark-cli` / `claude ` / `curl` / `$STATE` / `$ROOT` 即失败。这是 bash 里唯一能落地的「依赖规则」强制形式——没有编译器，就用 grep。
  - **测试闸**：`bin/test/` 全部用例必须通过。
- **接入 ShellCheck**（可选依赖，未安装则跳过并提示）：现有 `bash -n` 查不出 SC2155（`local x=$(...)` 吞掉退出码）这类本仓库反复踩的坑。

**零运行时行为变更**是硬约束。验收覆盖**三层产物**：中间产物（`$TMP/m-*.json`，取数层）、投递产物（`$PUBLISH_DIR/**`，渲染层）、基准文件（`$STATE/*.json*`，状态写入）——归一化后逐字节 diff 为空。

跑批**不幂等**，协议必须配合状态快照回滚：`crash-weekly.sh:624` 的基线提升在 `NO_DELIVER` 闸门之前，直接跑两次会让第二次看到零变化。详见 design D7。

## Non-goals

明确**不做**（避免范围蔓延，各自理由见 design）：

- **不拆渲染层**。三种渲染共享 `cell()` / `delta_of()` 的判定，且 `crash-daily.sh` 顶层有副作用（`source` 即执行取数），拆分需要逐段对照，风险与本 change 的「零行为变更」目标冲突。留待独立 change。
- **不做表名参数化**。`com_prime_dino_english` 硬编码 16 处，但已确认未来 12 个月不接第三个 app —— 现在抽象属于投机。仅在 design 中记录位置与将来的收口方式。
- **不引入 Ports & Adapters / 依赖注入**。见上文。
- **不改 `deliver.sh` 的投递流程**。但其纯判定（`doc_prune` 的日期键保留谓词）与核心层其余部分同等对待——它删错一次的代价是重建整套飞书文档，却一个用例都没有（design D10）。
- **不动 `bin/sql/`**。SQL 已是独立的声明层，占位符替换机制不变。

## Capabilities

### New Capabilities

- `crash-perf-core-purity-guard`：纯函数核心层的边界约束与自检闸门。规定 `bin/lib/core/` 的无副作用契约、`check-scripts.sh` 必须拒绝违反依赖方向的提交、纯函数必须有断言覆盖。这是**可观测的新行为**（自检脚本的退出码），不是实现细节。

### Modified Capabilities

无。本 change 不改变任何运行时行为，现有 16 份 spec 的要求一字不动——`crash-perf-daily-card` 的卡片形态、`crash-perf-data-staleness-guard` 的三态判定、`crash-perf-latest-2-versions` 的版本口径，重构后必须逐字节产出相同结果，这正是验收标准。

## Impact

| 文件 | 变更 |
|---|---|
| `bin/lib/common.sh` | **新增** — 10 个重复函数收口 |
| `bin/lib/core/{format,verdict,version}.sh` | **新增** — 纯函数层 |
| `bin/test/core-*.sh` + `bin/test/run.sh` | **新增** — 断言与运行器 |
| `bin/test/{artifacts,normalize,baseline}.sh` | **新增** — 三层产物清单、归一化、快照回滚协议（产物契约的第一次显式登记，design D9） |
| `bin/lib.sh` | 保留原位（`run_with_timeout` / `cleanup_old_runs` 是编排辅助，非纯函数），路径不动以免影响现有 `source` 回落分支 |
| [bin/crash-daily.sh](../../../bin/crash-daily.sh) | 1485 → 约 1300 行；删除被上移的函数体，改为 `source` |
| [bin/crash-weekly.sh](../../../bin/crash-weekly.sh) | 728 → 约 660 行；同上 |
| [bin/check-scripts.sh](../../../bin/check-scripts.sh) | 29 → 约 70 行；加依赖 lint + 测试闸 + shellcheck |
| `CLAUDE.md` | 「常用命令」增测试入口；架构要点增一节说明分层与依赖方向 |

**风险**：`source` 顺序错误会导致函数未定义。缓解见 design（core 层不依赖任何全局变量，可任意顺序 source；`common.sh` 依赖 `$ROOT`/`$STATE`，必须在两者赋值之后）。

**无外部依赖变更**：bats 为可选，ShellCheck 为可选，两者缺失时自检降级但不失败——生产机装机流程（`install.sh`）不受影响。
