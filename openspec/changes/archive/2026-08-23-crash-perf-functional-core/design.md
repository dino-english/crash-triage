## Context

动机见 [proposal.md](proposal.md) 的 Why。这里只记约束与实测事实。

**语言与运行时约束**：脚本实际跑在 macOS 系统 bash **3.2**（`#!/usr/bin/env bash` → `/bin/bash`）。没有 `declare -A`、没有 `${var^^}`、`$LINENO` 在函数内不准（已在 `err_stack()` 的注释里考据过）。任何依赖 bash 4+ 的测试框架或写法都不可用。

**生产机约束**：`install.sh` / `update.sh` 跑在无人值守的 Mac mini 上，那台机器**推不了 git、也不该为了开发期工具再多一项装机步骤**。所以测试运行器与静态检查器必须是可选依赖。

**实测的重复清单**（`grep` 全仓库函数定义后按名字聚合）：

| 函数 | 出现于 | 备注 |
|---|---|---|
| `step` `alert_once` `err_stack` `on_err` `_until_epoch` `_fmt` `win_compact` `win_full` `stale_days` | crash-daily.sh + crash-weekly.sh | 9 个，`stale_days` 逐字节相同 |
| `fail` | crash-daily.sh + crash-weekly.sh + **deliver.sh** | 前两者可合并；deliver.sh 那份语义不同，见 D6 |
| `say` | install.sh + update.sh | 装机链路，本 change 不动（见 Non-Goals） |

**实测的全局依赖**（决定了哪些函数能进核心层、以什么签名进）：

| 函数 | 引用的全局 | 处理 |
|---|---|---|
| `win_compact` `win_full` `stale_days` | `RUN_EPOCH` | 提为**首个位置参数** |
| `win_compact` `win_full` | `TZ_LABEL` | 由 `_fmt` 内部按 `date '+%z'` 得出改为参数传入 |
| `union_versions` | `MAX_VERSION_COLS` | 提为第三个位置参数 |
| `traffic_light` `cell_color` `delta_cell` `pick_newest` `pick_top_sessions` `ver_field` `int` `pct` `rate_pct` `_until_epoch` | 无 | 直接上移，签名不变 |

`_fmt` 在不传时区参数时读取环境 `TZ`——这是**环境**不是脚本全局，保留原样，但断言用例必须显式 `TZ=` 固定，否则用例在不同机器上结果不同。

## Goals / Non-Goals

**Goals:**

- 核心层可在空环境中加载并逐函数调用——这是「可测」的操作性定义。
- 重复函数只剩一处定义，并由自检防止回潮。
- 重构前后产物逐字节等价，且这个等价性是**可复现的验收动作**而非人工比对。

**Non-Goals**（proposal 已列范围外项，这里只加设计级边界）：

- **不追求 100% 纯函数覆盖率**。`collect_window` / `cell` / `build_table` 这类函数读 `$TMP` 下的中间 JSON，它们属于外壳层，本 change 不动。
- **不引入 mock / stub 机制**。核心层无副作用即无需 mock；外壳层的测试留待渲染层拆分那个 change。
- **不改 `bin/lib.sh` 的路径**。`crash-daily.sh` 里有一段 `[ -f "$ROOT/bin/lib.sh" ] || 退化定义` 的回落分支，改路径会让回落逻辑失配。新文件一律放 `bin/lib/` 子目录。

## Decisions

### D1：Functional Core / Imperative Shell，不是完整 Clean Architecture

**选择**：只取 Clean Architecture 的**依赖规则**（内层不知道外层），落地形式是 Bernhardt 的 Functional Core / Imperative Shell——纯函数集中在核心层，副作用全部留在入口脚本的编排段。

**否决 Ports & Adapters**：接口反转的价值来自「可替换实现 + 编译期校验签名」。bash 两样都没有——没有类型系统能保证某个「适配器」实现了约定的函数签名，替换实现的需求也不存在（BigQuery 与飞书都不会换）。在这里建适配器层只会多一层间接调用和一批空壳文件。

**否决「改用 Python 重写」**：这套东西的价值有一半在 `bq` / `jq` / `lark-cli` 的直接编排，重写等于把已经稳定运行、踩过几十个坑的逻辑推倒。而且换语言解决不了「没有测试」这个真问题——Python 版一样可以一行断言不写。

**为什么这个选择对**：核心层的判定标准（能否在空环境中调用）是**可机检的**，不依赖人的自觉。这是 bash 里唯一能把架构约束变成退出码的方式。

### D2：目录布局 `bin/lib/`，自检改为递归扫描

```
bin/
├── lib.sh                  编排辅助（run_with_timeout / cleanup_old_runs），原位不动
├── lib/
│   ├── common.sh           外壳层共享：step / alert_once / err_stack / on_err / fail
│   └── core/
│       ├── format.sh       int / pct / rate_pct / _fmt / _until_epoch / win_compact / win_full
│       ├── verdict.sh      traffic_light / cell_color / delta_cell / stale_days
│       └── version.sh      pick_newest / pick_top_sessions / union_versions / ver_field
├── test/
│   ├── run.sh              运行器（见 D4）
│   └── core-*.sh           断言用例，与 core 文件一一对应
```

**`check-scripts.sh` 当前只扫 `"$SELF_DIR"/*.sh`**——新文件在子目录里会被完全跳过，那条多字节变量 lint 也就失效。必须同步改成 `find "$SELF_DIR" -name '*.sh'`。**这一条容易漏，而漏了的后果是新代码不受任何检查**，列为 tasks 的独立一项。

**`stale_days` 归入 `verdict.sh` 而非 `format.sh`**：它输出的是「停更几天」这个判定值，消费方是三态机；`format.sh` 只放纯粹的表示转换。

### D3：全局提参 —— 签名变更清单

三个全局提为参数，调用点必须同步改。这是本 change 里**唯一会改调用方代码**的部分，也是最可能出错的部分：

| 旧签名 | 新签名 | 调用点数 |
|---|---|---|
| `win_compact <天数> <止点>` | `win_compact <基准epoch> <时区标签> <天数> <止点>` | daily 3 处 + weekly 2 处 |
| `win_full <天数> <止点>` | `win_full <基准epoch> <时区标签> <天数> <止点>` | daily 3 处 + weekly 2 处 |
| `stale_days <止点> <天数>` | `stale_days <基准epoch> <止点> <天数>` | daily 4 处 + weekly 2 处 |
| `union_versions <A> <B>` | `union_versions <A> <B> <上限>` | daily 2 处 |

**否决「用环境变量传」**（`RUN_EPOCH=... win_compact ...`）：那只是把全局依赖换了个写法，核心层照样读参数之外的状态，依赖 lint 也拦不住。

**否决「保留全局、只在测试里预设」**：能通过预设全局跑通的测试，掩盖的正是「这函数依赖看不见的状态」这个缺陷本身。

**调用点数必须在实施时逐个核对**（上表是本次 `grep` 的计数，实施时以实际为准）——漏改一处的表现是参数错位，输出一个格式怪异但**不会报错**的字符串。故 tasks 中要求改完后先跑等价性 diff 再继续。

### D4：自建极简运行器，bats 仅作可选加分

**选择**：`bin/test/run.sh` 约 30 行，提供 `assert_eq <期望> <实际> <用例名>`，遍历 `bin/test/core-*.sh` 执行并统计。零依赖、bash 3.2 兼容。

**否决「硬依赖 bats-core」**：bats 是 bash 测试的事实标准（Docker、nvm 在用），但它要 `brew install` 或 vendoring。生产机装机流程加一项依赖，换来的只是更漂亮的输出——而本 change 需要的全部能力就是「比较两个字符串、不等就非零退出」。

**折中**：用例文件写成普通 bash 函数集合，若将来要迁 bats，转换是机械的。

**测试的运行方式是 `source` 核心层文件后直接调函数**——这正是 D1 那个「能否在空环境中调用」判定标准的执行形式。核心层若引入了全局依赖，`set -u` 下用例会直接 unbound variable 失败，等于多一道保险。

### D5：依赖方向 lint 用 grep，不做语法解析

**选择**：对 `bin/lib/core/*.sh` 按行匹配违禁模式，跳过整行注释：

```
^[^#]*(\bbq\b|lark-cli|claude |curl |firebase|\$STATE|\$ROOT|\$\{STATE|\$\{ROOT)
```

**否决 AST 解析**：bash 没有可用的 AST 工具链（`bash -n` 不吐语法树）。写一个近似解析器会引入比它防住的更多的 bug。

**接受的假阳性**：行内注释里提到 `bq` 会误报（如 `foo # 由 bq 取数后传入`）。代价是偶尔改一句注释措辞，比漏报（核心层偷偷读 `$STATE`）便宜得多。**假阴性才是真风险**，所以模式宁可宽。

**为什么把 `$STATE` / `$ROOT` 列入违禁**：它们是外层路径概念。核心层一旦引用，就意味着它开始知道自己跑在什么目录下——依赖规则的第一道裂缝通常就是这个。

### D6：重复定义检测与豁免清单

检测方式：扫全部 `bin/**/*.sh` 的行首函数定义，按名字聚合，出现在 ≥2 个文件即失败。

**豁免两项，各有理由**：

- **`fail`（deliver.sh）**：deliver.sh 是**独立进程**，其 `fail()` 不写 health 文件（投递失败不改变生成脚本的健康状态，这是既定口径），且告警 `--source deliver`。语义不同，强行合并会让健康状态语义变模糊。
- **`say`（install.sh / update.sh）**：装机链路，与流水线运行时无关，本 change 不动它——但**记入豁免清单时要写明「未合并」而非「不该合并」**，避免下一个读者以为这里有什么深层理由。

**豁免清单以数据形式放在 `check-scripts.sh` 里**（一行一个 `函数名:文件名`），不要写成散落的 `if` 判断——清单要能一眼看全，否则它会悄悄长大。

### D7：等价性验收 —— 三层产物 + 状态快照回滚

产物分三层，**三层都要 diff**，且各自回答不同的问题：

| 层 | 内容 | 回答什么 |
|---|---|---|
| **中间产物** | `$TMP/m-<plat>-<ver>.json` / `d-<plat>-<ver>.json` / `issues-*.json` | 取数层是否等价 |
| **投递产物** | `$PUBLISH_DIR/` 全部：`card.json` `message.md` `manifest.json` `docs/{index.xml,daily.md,weekly.xml,weekly.md,ledger-table.md,ledger-timeline-delta.md}` | 渲染层是否等价 |
| **基准文件** | `$STATE/` 的 `health-daily.json` `health.json` `metrics-history.jsonl` `perf-history.jsonl` `daily-snapshot.json` `last-snapshot.json` `ledger/LEDGER.md` | 状态写入是否等价、有无意外改写 |

**中间层是关键**，它是数据层与渲染层的天然分界：中间层 diff 为空而投递层有差异 → 是渲染代码问题；中间层就有差异 → 是数据漂移。这比原方案「重跑基线人工确认」精确得多，也顺带消掉了那条风险。

**基准文件必须纳入**，理由是丢失/损坏的后果严重且静默：`last-snapshot.json` 被改坏 → 下周所有 issue 报成新增；`docs.json` 被改坏 → 新建一整套重复飞书文档。重构不该碰它们，而「不该碰」需要被验证，不是被假设。

#### 跑批不幂等 —— 协议必须快照回滚

**`crash-weekly.sh:624` 的 `cp "$SNAP_NEW" "$SNAP_LAST"` 在投递之前**，`CRASH_REPORT_NO_DELIVER` 只挡住第 713 行的投递调用。因此 L2 连跑两次：第一次检测到变化并提升基线，**第二次看到零变化**，周报正文与卡片完全不同——与重构无关，是「跑两次对比」这个协议本身在 L2 上不成立。

所以每次基线跑批前后 MUST 快照与回滚 `$STATE` 的基准文件：

```
备份基准文件 → 跑批 → 收集三层产物 → 从备份还原基准文件
```

L1 侧已核实幂等（`metrics-history.jsonl` 按 `day` 键 upsert：`select(.day != $d)` 后追加；`daily-snapshot.json` 整体覆盖），但**协议统一对两条链路都做快照回滚**——不为 L1 开特例，否则下一个读者会以为 L1 有什么特殊性。

`perf-history.jsonl`（L2 周维度）的同周重跑幂等性**未核实**，列入 tasks 逐条确认。

`docs.json` / `folders.json` / `report-index.jsonl` 只由 `deliver.sh` 写，`NO_DELIVER` 下不触及——但仍纳入基准文件快照，用于**验证它们确实没被碰过**。

**`$STATE/issues/` 必须一并快照回滚**（易漏：`CLAUDE.md` 写着它「一次抓永久留、不参与清理」，读起来像与跑批无关）。第一次基线跑批会写入事实层缓存，第二次跑批缓存已热——`CACHED_NEW` 变 `CACHED_HIT`，**两次走的是不同代码分支**。不回滚则冷启动路径根本没被验收到。

**冷热各验一次**：重构可能只改坏其中一条路径。协议对 L1 与 L2 各跑两组——组 A 从回滚后的冷缓存起跑，组 B 紧接着在热缓存上再跑。两组各自与对应基线比对，不跨组比。

#### 归一化规则

两次跑批的以下字段必然不同，diff 前替换为固定串：`run_id` / `last_run` / 幂等键 / 取数区间的具体时刻（保留格式、只替换时刻）/ `$STATE/runs/<日期>/L{1,2}/<时刻>/` 路径中的时刻段。

**残余风险**：BigQuery 数据本身随时间变化（滚动窗口锚在跑批时刻）。缓解是两次跑批紧邻；若中间层出现差异，先重跑基线确认是漂移。

### D9：产物是进程边界上的契约（本 change 只登记，不校验）

这套系统的模块边界**不在进程内，在进程之间**：8 个子进程（`alert.sh` / `scan-fix-commits.sh` / `fetch-snapshot-bq.sh` / `fetch-snapshot.sh` / `render-ledger.sh` / `split-fix-list.py` / `md2docx.py` / `deliver.sh`），每个的接口都是 **`export` 的环境变量 + argv 进，文件 + 退出码出**。

这已经是 Unix 形态的依赖反转——`crash-daily.sh` 不知道投递怎么做，只写一份 `manifest.json`。缺的不是端口，是**契约校验**：`manifest.json` 没有 schema，没有一处断言「子进程写出的东西符合调用方预期」。`export REPOS_ROOT` 那行注释（「不 export 它会退回自己的默认值」）正是这类契约靠注释维持的证据。

**本 change 只做两件事，不做校验**：

1. 把产物清单写进 `bin/test/artifacts.sh`（三层各一个文件路径列表），供归一化与 diff 复用——**清单本身就是契约的第一次显式登记**，此前它散落在十几处重定向里。
2. 在 `CLAUDE.md` 记下这 8 个边界及其「环境变量进、文件出」的形状。

**为什么不在本 change 做 schema 校验**：那会改变运行时行为（多一处可能失败的校验点），与「零行为变更」硬约束直接冲突。留作独立 change，清单是它的输入。

### D8：分三步落地，每步独立可回滚

顺序不可颠倒，每步结束都跑一次等价性 diff：

1. **去重**（`common.sh`）——不改任何签名，风险最低。diff 应完全为空（归一化后）。
2. **抽核心层 + 提参**（`core/*.sh` + D3 的签名变更）——唯一改调用方的一步。
3. **加闸门**（依赖 lint + 重复定义检测 + 测试闸 + shellcheck）——纯增量，不碰运行时代码。

**为什么闸门放最后**：闸门若先加，第 1、2 步的中间状态会被自己的检查卡住（去重进行到一半时必然存在重复定义）。

**回滚**：三步各自一个提交，`git revert` 单步即可。第 2 步回滚后第 3 步的检查会失败——这是正确行为，不是缺陷。

### D10：缓存 —— 判定进核心层，读写留外壳层

四个被称作「缓存」的文件里，只有两类是真缓存，区分要紧：**缓存丢了重算即可，基准丢了没得算**。

| 文件 | 性质 | 失效机制 |
|---|---|---|
| `$STATE/issues/<32位id>.json` | 事实层 memoization | `events_count_last_seen` 比较；`FORCE_REFETCH=1` 强制 |
| `$STATE/folders.json` / `docs.json` | token / 文档 id memoization | 前者永不失效；后者日期键 90 天（`doc_prune`） |
| `$STATE/path.env` | 探测结果缓存 | `setup.sh` 整体覆写 |
| `metrics-history.jsonl` / `last-snapshot.json` 等 | **不是缓存**，是历史与基准 | 不可重算 |

**分层判断**：缓存的 *policy*（该不该重取、该不该淘汰）是纯判定；*mechanism*（读写文件）是副作用。前者进核心层，后者留外壳层。

这与仓库已有的一次同向决策一致——`fetch-snapshot-bq.sh:41` 的注释「事实层缓存判定在 shell 里做，不在 prompt 里」把 policy 从模型手里收回到了 shell。**把它再从 IO 循环收进核心层是同一个方向的下一步，理由相同**：判定要能被断言。

两个上移对象：

1. **`cache_verdict <强制标志> <文件是否存在> <上次计数> <本次计数>` → `new|update|hit`**
   现埋在 `fetch-snapshot-bq.sh:108-126` 的 while 循环里。
   ⚠️ **`本次 < 上次` 落进 `hit` 不回写，是 BigQuery 迁移遗留的口径错配**（2026-08-22 查证）。用例钉住当前行为并在注释里指明它是已知缺陷；**修复不在本 change 内**（改运行时行为），另开 change。

   证据链：
   1. `crash-issues-all.sql` 的 `events` 是 `COUNT(*)` **在滚动窗口内**（`event_timestamp >= TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL {{DAYS}} DAY)`），老事件出窗即下降——**不是单调量**。
   2. spec `crash-perf-issue-fact-cache` 的 Purpose 写「崩溃事件是不可变的历史事实，一次抓取应永久可用」，是**累积语义**；三条 Scenario 只覆盖 `==` 与 `>`，`<` 未定义。
   3. 迁移 change `crash-source-bigquery-migration` 的 design 讨论了崩溃率口径（R2/R3），**未提事实层计数口径**——`-gt` 从 MCP topIssues 时代原样搬了过来。
   4. 现存数据已在模型路径显形：`3e827b74` 的 `events` 数组长 **65**，而 `events_count_last_seen` = **47**，累积数组已超过窗口计数。

   后果按严重度：**`latest_event` 冻结**（台账「最近一次发生」停在历史峰值那天，直接误导处置判断）> `last_synced` 冻结（正在衰减 = 正在被修好的 issue 看起来像「数据停更」，把好消息读成故障）> 字段名不副实（存的是「历史最大窗口计数」）> `CACHED_HIT` 虚高。

   bq 侧尚未显形：只有 6 条记录、最早 2026-08-20，窗口还没滑过去。**是定时炸弹不是已爆的。**

   修法方向（留给后续 change）：判定锚在 `latest_event`（它是 `MAX(event_timestamp)`，单调），或把字段拆成 `events_window_count` + `events_total_fetched` 显式区分两种口径。⛔ `-gt` 改 `-ne` 是错的——窗口滑动会导致天天回写。

2. **`doc_prune` 的日期键保留谓词**
   现为 `deliver.sh:252-258` 的一段 jq：带日期后缀的键按 cutoff 比较，无后缀的固定键（`index` / `ledger`）无条件保留。
   **这是全仓库最该有断言的一处**——`deliver.sh:249-251` 的注释记着 2026-08-18 它「实测把两个固定文档键删掉了，下次运行就会重新建两份新文档」。谓词是纯的（输入 JSON + cutoff → 输出 JSON），删错一次的代价是重建整套飞书文档。

**这一项扩了 proposal 原写的 Non-goal**：原文是「不改 `deliver.sh`」，现修正为——**不改 `deliver.sh` 的投递流程**，但其纯判定与核心层其余部分同等对待。理由是该谓词完全符合核心层定义，且是已知的高危无覆盖点；把它排除在外只因它碰巧住在另一个文件里，不是好理由。

**登记但不修的已知缺口**：`fetch-snapshot.sh:80-135` 把同一套事实层缓存策略**用自然语言写在 prompt 里**交给模型执行，与 `fetch-snapshot-bq.sh` 的 shell 实现是同一策略的两份表述。这是跨语言、跨执行模型的重复——D6 的重复定义检测抓不到（它只扫 bash 函数定义），模型那份也无法断言。统一它需要改运行时行为，超出本 change，记入 `CLAUDE.md` 与 `findings.md`，留作后续 change。

## Risks / Trade-offs

| 风险 | 缓解 |
|---|---|
| **D3 的签名变更漏改一处** → 参数错位，输出格式怪异但不报错 | 每步跑等价性 diff；`win_*` 的输出格式高度特征化（含 `→` 与 `UTC`），错位会在 diff 里立刻显形 |
| **`source` 顺序错误** → 函数未定义 | 核心层不依赖全局，可任意顺序；`common.sh` 依赖 `$ROOT`/`$STATE`，**必须在两者赋值之后 source**，在文件顶部注释写死这条 |
| **`check-scripts.sh` 未改递归扫描** → 新代码完全不受检查（含那条多字节 lint） | 列为独立 task，且加一条自检的自检：故意在 `core/` 放一个含违规写法的临时文件，确认自检报错后删除 |
| **等价性 diff 的数据漂移被误判为重构 bug** | D7 的中间层 diff 直接区分：中间层为空而投递层有差异 = 渲染问题；中间层就有差异 = 数据漂移 |
| **L2 基线提升导致两次跑批不可比**（`crash-weekly.sh:624` 在 `NO_DELIVER` 闸门之前） | D7 的快照回滚协议；不做这一步，L2 的等价性验收会给出「重构改坏了周报」的假阳性 |
| **重构意外改写基准文件**（`last-snapshot.json` / `docs.json`），后果严重且静默 | 基准文件纳入第三层 diff，验证「确实没被碰过」而非假设 |
| **`issues/` 缓存未回滚** → 冷启动路径未被验收，且两次跑批分支不同导致假阳性 | D7 已纳入快照回滚清单，并要求冷热两组各验一次 |
| **`cache_verdict` 的「本次 < 上次」分支已查证为缺陷**（口径错配，D10），用例会把它钉成规范 | 用例钉住当前行为并在注释里显式标注「已知缺陷，见 design D10，修复另开 change」；本 change 内不改，因为会变更运行时行为 |
| **豁免清单成为垃圾桶** | 清单以数据形式集中，每项必须带一行理由注释；review 时清单新增项要单独说明 |
| **测试用例写成「把当前输出抄进期望值」**（把 bug 也固化了） | 用例的期望值 MUST 从**行为意图**推导（如「分母为零返回『无法计算』」来自现有 spec `crash-perf-data-staleness-guard`），不从当前输出反推。发现当前输出与意图不符时，**记为待确认项报给人**，不擅自改行为 |

**接受的取舍**：本 change 只让约 15 个纯函数可测，`crash-daily.sh` 仍有约 1300 行、渲染逻辑仍混在其中。这是刻意的——一次性大重构无法用等价性 diff 稳妥验收，而分步走的每一步都能。

## Migration Plan

无数据迁移、无部署变更、无 cron 改动。生产机通过 `update.sh` 拉取新代码即生效；新增文件是纯增量，`install.sh` 无需改动。

**回滚**：`git revert` 对应提交。运行时不依赖任何新增的状态文件或配置，回滚无残留。

## Open Questions

- **shellcheck 首次接入会报出多少既有问题？** 未实测。若数量大（>50），实施时把 shellcheck 设为**仅提示不失败**，另开 change 逐批清理——不要让一个重构 change 顺带背上几十处历史告警的修复。这个问题不影响本 change 的规格、方案与任务拆分，可在实施时用实际数量决定。
