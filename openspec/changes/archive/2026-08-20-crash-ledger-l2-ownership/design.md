## Context

见 proposal.md — Why。以下只列约束实现选型的既有事实：

- `run_with_timeout` 内部以 `&` 起后台任务，POSIX 规定异步列表的 stdin 在显式重定向前被指定为 `/dev/null`。已实测：管道与 `< file` 均读到空，须包一层 `bash -c 'exec cmd < "$1"'`（`bqq()` 已按此实现）。
- `lark-cli docs +update` 支持 `str_replace` / `block_delete` / `block_insert_after` / `block_copy_insert_after` / `block_replace` / `block_move_after` / `overwrite` / `append`。CLI 自身文档警告 `overwrite` 会「discard unrelated rich content」。
- 飞书 markdown 导入不支持颜色与高亮框，配色只能走 DocxXML。既有 `bin/md2docx.py` 已实现 markdown → 带配色 DocxXML 的通用转换。
- `snapshot.json` 现有结构为每端一个数组，元素含 `id / title / events / users / fix_commit / fix_branches` 六个字段。变化检测（`crash-weekly.sh` 第 4 步）是纯 jq，依赖 `id` 与 `events` 两个字段做 diff。
- 两个业务仓库的既有 commit 惯例不统一：iOS 把 32 位标识写在源码注释、不入 message；Android 在 message 用 8 位短标识。既有 `git log --grep="<32位id>"` 的反查方式在双端结构上都命中不到。
- `$STATE` 顶层现有 107 个条目，其中 91 个是按时间戳平铺的跑批目录（26 个为空）。既有清理逻辑按 `find -maxdepth 1 -name 'metrics-*' -mtime +30` 工作。
- `bin/check-scripts.sh` 是唯一的自动检查，含 bash 语法自检与「变量紧邻多字节字符」校验（本轮已两次拦下真实缺陷）。

## Goals / Non-Goals

**Goals:**
- 台账写入路径唯一化：只有 L2 一条链路能改台账，消除多写者。
- 事实层与度量层分离：不可变的历史事件一次抓取永久可用，可变的计数每轮刷新。
- 台账飞书同步具备结构保护：现状表可刷新的同时，时间线历史不被破坏。
- 修复状态由代码提交事实驱动，而非模型推断。
- `$STATE` 布局改造零迁移风险：不移动任何既有基准文件。

**Non-Goals:**
- 不改造 L1 的取数逻辑、版本口径、阈值判定、卡片结构。
- 不迁移历史台账内容（Sir 已定：从零生成，旧台账留在业务仓库）。
- 不把事实层抓取从 MCP 改为 REST（现有 MCP 路径已通，改造无收益）。
- 不做性能优化（`run_with_timeout` 轮询粒度问题本轮不处理，收益不足以抵消风险）。
- 不在业务仓库安装任何钩子或写入任何文件。

## Decisions

### D1 台账所有权归 L2，而非 L1

**决策**：移除 L1 的台账渲染与投递，台账由 L2 独占产出。

**理由**：台账承载的是崩溃处置结论，而结论只在 L2 产生（L1 是纯数据链路、无分析）。让 L1 搬运 L2 的产出是职责错配，也是本轮分叉事故的结构性成因。

**备选**：保留 L1 每日同步以提高时效 → 否决。台账是周维度的结论沉淀，日更无信息增量，反而制造多写者。

### D2 台账同步用 `block_replace` + `append`，不用 `overwrite`

**决策**：现状表定点替换，时间线追加。`overwrite` 在任何阶段都不使用 —— 首次建立四段结构也走 `append`，既有内容保留在其上方，由人工确认后另行清理。

**理由**：时间线是只增不改的历史记录，`overwrite` 会连同它一起重写。CLI 文档已明确警告该命令丢弃无关富文本。

**备选**：本地维护完整 markdown 后整份 `overwrite` → 否决。这要求本地源与飞书永远一致，任何一端的漂移都会静默丢内容。

**已验证（2026-08-19 spike，见 tasks.md 1.1–1.6）**：`block_replace` 依赖 block ID；实测确认见 D3。

### D3 定点更新的定位方式：block ID 优先，锚点兜底

**决策**：优先用 `docs +fetch --detail with-ids` 取得现状表的 block ID 后 `block_replace`；若实测 ID 不稳定，改用 `str_replace` 配一对不可见锚点标记包裹现状表区域。

**理由**：block ID 是 CLI 的原生定位方式，精确且无需污染文档内容。锚点方案更鲁棒但会在文档中留下标记文本。

**取舍**：先验再选，不预设。

**2026-08-19 spike 结论（bot 身份 `cli_aaf7b44ddeb8de14`，对台账文档 `TtpwdhgKroMH1DxJumojTflrppz` 实测）**：

1. **备份路径**：`--profile crash-triage` 不存在（`lark-cli profile list` 只列出 appId `cli_aaf7b44ddeb8de14`，`crash-triage` 是历史 alias 未生效）。**实际必须用 `--profile cli_aaf7b44ddeb8de14`**（或不传 `--profile`，因为它是唯一激活的 profile）。CLAUDE.md 中 `LARK_PROFILE=crash-triage` 的环境变量写法需核对生效方式——`install.sh` 生成的 wrapper 里这个变量是否真的传给了 `lark-cli --profile`，需要在任务组 9 文档收尾时一并核实措辞，避免误导。
2. **备份取数**：`docs +fetch --doc-format xml --detail full` 配 `-q '.content'`（jq 路径）会取到 `null`——正确字段路径是 `.data.document.content`（顶层 `.content` 不存在，`--jq`/`-q` 在这个命令下作用于完整响应体而非"文档内容"这个别名）。已验证：`lark-cli docs +fetch --doc <token> --doc-format xml --detail full --format json` 输出，`jq -r '.data.document.content'` 拿到完整 24134 字节 XML，非空可解析。**实现脚本请用这个字段路径，不要假设 `--jq '.content'` 能直接拿到正文。**
3. **`--content` 不接受绝对路径的 `@file`**：CLI 报错 "`--file` must be a relative path within the current directory"。**实测可行方案**：管道 `cat file | lark-cli docs +update ... --content -`（stdin），或先 `cd` 到内容文件所在目录用相对路径 `@./file`。`bqq()` 式的 wrapper 若要写临时内容文件，必须放在允许的相对路径下，或统一走 stdin。
4. **block_replace 会生成新 block ID**（这是 API 固有行为，非 bug）：对表格块 `doxjp9BBwuU4Fm8cgSeCT5s9Oyc` 执行 `block_replace`（内容原样回填）后，新表格块 ID 变为 `doxjp8oDIJtXkJ7tYCIlrX7bRRf`——**旧 ID 立即失效**，再次 `+fetch` 该文档已查不到旧 ID。
5. **但新 ID 在不相关操作下保持稳定**：`block_replace` 之后连续两次 `append`（在文档末尾追加不相关内容）不影响该表格的 block ID，两次 append 后重新 `+fetch` 确认 ID 仍是 `doxjp8oDIJtXkJ7tYCIlrX7bRRf`。**结论：`append` 不会扰动其他块的 ID，`block_replace` 只会改变被替换的那个块自己的 ID。**
6. **设计含义（写入 D2/D3 最终选型）**：**block ID 方案有效，不需要锚点兜底**，但有一个必须处理的约束——**block ID 不能跨轮跑批缓存复用**。因为每次 `block_replace` 都会让现状表拿到一个新 ID，下一周想再替换它时，必须先重新 `+fetch --detail with-ids` 取当前 ID，不能读上周记的 ID（会 404 或误伤其他块）。**实现方式**：`crash-weekly.sh` 每次同步台账前，先用稳定的章节标题 block ID（如"Issue 台账" `h2`，它本身不被 `block_replace` 触碰、跨轮不变）做 `--scope section --start-block-id <该标题ID>` 或 `--scope range` 圈定范围，在返回内容里用正则/jq 找到其下第一个 `<table id="...">`，取这个**当次现查**的 ID 去做 `block_replace`。**不要把表格 block ID 存进 `docs.json` 之类的持久缓存**——存了也没用，下一轮必须重查。
7. **`crashlytics_list_events` 字段确认**（appId `1:465344775452:ios:610bc2f8ea0750fff466d9`，issueId `5ac8785ef88998bfaf4f9a6af4a39ac3`，pageSize=1，单次调用耗时约 8 秒）：
   - **堆栈帧**：有，但**不是结构化数组**——`threads` 字段是一段纯文本（"Thread: (crashed)" + 若干 "at <symbol>" 行，无 file/line/offset 分字段）；唯一结构化的单帧是 `blameFrame`（symbol / offset / address / library / owner / blamed）。事实层落盘时按原样存文本块，不要假设能按帧数组解析。
   - **设备**：`device`（manufacturer/model/architecture/marketingName/formFactor）✓
   - **系统**：`operatingSystem`（displayVersion/os/type）✓
   - **`memory.free`**：✓ 存在（`memory.used` / `memory.free`，字符串数字）
   - **`processState`**：✓ 存在（示例值 `FOREGROUND`）
   - **`current_screen`**：**不是顶层字段**，出现在 `customKeys.current_screen`（本例值 `WKImagePreviewViewController`）——但这是个案（该崩溃走 `safe_decode_fallback` 场景才带这个 key），**不能假设每条事件都有**；更可靠的页面上下文来源是 `breadcrumbs` 里的 `firebase_screen_class`（CLAUDE.md 已有此结论，本次复核一致）。
   - **breadcrumb**：✓ 存在，`breadcrumbs` 字段是带时间戳的事件文本块（`app_diagnostic` / `screen_view` / `page_view` 等）。
   - **variant**：字段名是 `issueVariant`（非 `variant`），结构为 `{id: <hex>}`。事实层若要做变体分组，用这个字段名。
   - `crashlytics_get_report{topIssues}` 单次约 9 秒，`crashlytics_list_events` 单次约 8 秒，两次共 17 秒——**首轮全量抓取（15 个 issue 量级）预估在 4–5 分钟内**，远低于 `TRIAGE_TIMEOUT`（1800s），4.6 的实测项风险可控。

### D4 事实层以完整 32 位标识为文件名，永久保留

**决策**：`$STATE/issues/<32位id>.json`，一 issue 一文件，不参与任何按时间的清理。

**理由**：
- 崩溃事件是不可变历史 —— 8 月 11 日那次崩溃的堆栈，今天读和下月读完全一致。
- 单文件粒度让增量合并简单：新增事件直接 append 进该文件的事件数组。
- 用 32 位而非 8 位作文件名，避免短标识碰撞。

**命中判定**：以「本地已存事件数 vs 线上 `events` 计数」比较。相等则跳过，线上更多则只抓增量。

**备选**：按周存快照 → 否决。同一 issue 会在多周快照中重复存储同样的历史事件，且增量判定要跨文件扫描。

### D5 修复状态用跑批期反扫，不用 git hook

**决策**：在 crash-triage 的跑批过程中 `git log --all --grep='\[crash:'` 扫两个业务仓库。

**理由**（四条，逐条对比 hook 方案）：
1. **零侵入**：不在团队共用的业务仓库装任何东西。
2. **无凭证外泄**：hook 若要同步飞书，需在业务仓库内配 lark-cli 凭证。
3. **幂等可补漏**：hook 是一次性触发，漏了不补；反扫每轮重扫固定窗口，漏一轮下轮仍能捞到。
4. **不影响他人**：hook 会在团队成员提交时触发。

**代价**：延迟。hook 是实时，反扫最迟延至次日跑批。台账是周维度结论载体，该延迟可接受。

**回溯窗口**：14 天（覆盖两个周报周期，容忍一轮跑批失败）。

### D6 commit message 约定 `[crash:<8位id>]`

**决策**：新约定采用 8 位短标识，方括号包裹。

**理由**：对齐 Android 现有惯例（已在用 8 位）；8 位十六进制在单个 app 的 issue 集合内足够唯一。方括号前缀让正则匹配精确，避免误判 message 中偶然出现的十六进制串。

**歧义处理**：若某 8 位短标识在当前 issue 集合中匹配到多于一个，不自动更新任何一个，在产出中标明待人工确认。

### D7 `$STATE` 只动跑批产物，基准文件原地不动

**决策**：
```
$STATE/
├── issues/          新增：事实层
├── ledger/          新增：台账本地源
├── runs/<日期>/{L1,L2}/<时刻>/   新增：跑批产物（原 metrics-* / crash-daily-* / weekly-*）
├── logs/            不动
├── publish/         不动
└── *.json           不动：docs.json / folders.json / last-snapshot.json
                     / metrics-history.jsonl / health-*.json
```

**理由**：基准文件一旦丢失后果严重（`docs.json` 丢 → 新建整套重复文档，本轮 10:50 实际发生过；`last-snapshot.json` 丢 → 全部 issue 报成新增，2026-08-07 事故）。保持原位意味着**零迁移风险**，且现有 46 处 `$STATE/xxx.json` 引用一处都不用改。

**备选**：把基准文件收进 `$STATE/state/` 子目录 → 否决。顶层目录名已是 `crash-triage`（它本身就是 state），再套一层是冗余命名，且要改 46 处引用、两台机器各做一次迁移，风险远大于收益。

### D8 性能进周报但不进台账

**决策**：L2 周报新增性能段；台账只收崩溃 issue。

**理由**：台账的组织单位是「有唯一标识、可跨周追踪的对象」。崩溃有 issue ID，性能没有 —— 「启动 P95 493ms」是全局指标，无追踪对象。慢帧最差页虽有页面名，但它是连续指标的切片，不是离散事件。

**边界**：性能段只出趋势与可定位对象，不出根因。理由同 CLAUDE.md 既有硬约束 —— 自动生成的推断看似合理实则可能错误，且会被下一轮误判为「已修复」而自我强化。

### D9 性能段复用 L1 现有 SQL

**决策**：不新增 SQL 文件，复用 `perf-screens.sql` / `perf-network.sql` / `perf-traces.sql`，只改窗口天数参数。

**理由**：口径一致性 —— 若周报另写一套 SQL，两份报告的同名指标可能因谓词差异而对不上，这类不一致极难排查。

**代价**：L2 跑批新增约 6 条 BigQuery 查询。按实测单条扫描量（perf 系每条 40–48 MB），周增约 0.3 GB，月增 1.2 GB —— 相对 1 TiB 免费额度可忽略。

### D10 台账初始内容从零生成

**决策**：不迁移 iOS / Android 两份业务仓库台账，首次运行以本轮 `topIssues` 建立现状表基线。

**理由**（Sir 决策）：旧台账留在各自业务仓库，需要时可随时查阅；新台账只跟当前线上 issue 走，避免把已消失的历史 issue 带进来制造噪音。

## Risks / Trade-offs

| 风险 | 缓解 |
|---|---|
`block_replace` 的 block ID 在结构变动后失效 → 台账更新静默失败或错位 | tasks.md 排为**前置 spike**，实测通过才写实现；不通过改锚点方案（D3）。规格已要求「定位失效须报错，不得退化为 overwrite」 |
L1 移除台账段是 BREAKING，可能连带破坏索引页回填逻辑（`__LEDGER_URL__` 占位符） | 移除时同步清理占位符与索引页对应行；DRY RUN 校验产物中无残留占位符 |
事实层首次全量抓取耗时可能超出现有 1800s 超时 | 首轮以现有 15 个 issue 计算，量级可控；超时仍走既有降级路径（只发变化摘要）。tasks.md 中要求实测首轮耗时并记录 |
反扫依赖团队遵守 commit message 约定；不遵守则状态不更新 | 不产生告警噪音（规格已定：无标记不参与对账、不告警）。状态停留在上一轮，由 L2 的「本次状态」列反映线上实际，不会得出错误结论 |
台账从零生成 → 历史结论不在新台账中 | 旧台账仍在两个业务仓库内，未删除。台账首段可写明历史结论的查阅位置 |
L2 跑批时长增加（性能段 + 事实层首轮抓取） | L2 周一 05:30 跑，无人等待；cron 上限 3600s，现有耗时约 12–15 分钟，余量充足。仍需实测记录 |
两台机器同时跑会并发写坏 `docs.json` 与归档 | 既有约束不变：只能一台注册 cron。改造期 MacBook 侧保持 paused，Mac mini 跑现有代码 |

## Migration Plan

1. **改造期**：MacBook 本地开发，测试投递到私聊 `ou_edd20a8dbfcc5e3ee279a225aec044d0`；Mac mini 保持现状运行现有代码（生产链路不中断）。
2. **验收**：`check-scripts.sh` 全绿 → L1 DRY RUN → L2 DRY RUN → L2 私聊真实投递 → 抽查台账现状表与时间线结构 → 二次跑批验证 `block_replace` 不破坏时间线。
3. **同步**：验收通过后 push，Mac mini `git fetch && merge --ff-only`，重跑 `install.sh` 重生成 wrapper。
4. **回滚**：改造集中在 `crash-daily.sh` / `crash-weekly.sh` / `deliver.sh` / `fetch-snapshot.sh` 四个文件，`git revert` 即可。飞书侧台账文档在首次同步前需留一份内容备份（`docs +fetch` 存盘）；因为不使用 `overwrite`，回滚只需删除新追加的四段结构块，既有内容未被触碰。
5. **一次性清理**：现有 92 个跑批残渣目录（`metrics-*` / `crash-daily-*` / `weekly-*`，全部产生于 2026-08-18～08-19 的开发调试期，约 3.6 MB）删除，但**保留最近 1 组 L1 与最近 1 组 L2** 作为新旧布局的对照样本 —— 任务 2.4/2.5 换路径后，用 `diff <(ls 旧样本) <(ls runs/<日期>/L1/latest)` 验证产物文件集无遗漏，比目视检查确定。样本在 2.4/2.5 验收通过后可自行删除。仓库内 `LEDGER.md` / `weekly-index.jsonl` / 两份专项快照 md 移入 `$STATE`。

## Open Questions

无。以下曾为待定项，已在 propose 阶段解决：

- ~~台账首段「项目常量」与「收口点登记」的初始内容从何而来？~~
  **已定（D11）**：例外迁移。这两段是**项目事实**（App ID、版本真源、构建号约定、ABI 配置、上报通路、兜底位置），不是处置结论 —— D10 排除的是会过期、会被误判为「已修复」的结论性内容，项目事实不在此列。内容从两份业务仓库台账中提取合并，双端并列呈现。不迁移的代价是台账失去自包含性：读版本号要跳回业务仓库查构建号约定。

### D11 项目事实例外迁移，处置结论不迁移

**决策**：台账的「项目常量」与「收口点登记」两段从两份业务仓库台账提取；「Issue 现状表」从零建立。

**理由**：两类内容的性质与失效模式完全不同。项目事实客观且稳定（构建号约定、上报通路位置）；处置结论会随版本演进过期，且错误结论会被下一轮反扫误判为「已修复」而自我强化 —— 后者正是 D10 要规避的。

**备选**：两段留空后续人工填 → 否决，等于把已有信息丢掉再手动补。整段不要 → 否决，构建号约定在解读事件版本号时高频使用。

### D12 L2 数据层与分析层分离，数据走 BigQuery 不经模型

**决策**（2026-08-20 追加）：L2 拆成两层。数据层 `bin/fetch-snapshot-bq.sh` 用 BigQuery 事件级取数产出 `snapshot.json`，全程不调模型；分析层沿用 `fetch-snapshot.sh full` 产出 `report.md`，**失败只降级不中止**。周报与卡片显式标注本周有无分析及缺失原因。

**理由**：数据是确定性聚合，分析才需要模型，两者不该同生共死。旧实现把取数绑在 `claude -p` 里，`crash-weekly.sh` 拿不到快照就 `fail` —— 2026-08-19 18:21 与 08-20 09:30 两次 429，L2 群里什么都收不到。而快照之后的整条链路本来就不碰模型：变化检测纯 `jq`、修复反扫纯 git、台账渲染纯 bash、同步纯 lark-cli。只有取数这一环被绑死，且那些数字（事件数、影响面、issue 标题）本就躺在 BigQuery 里。

**取舍**：BigQuery 路径拿不到堆栈明细（台账「根因」列留空）、拿不到 issue 的 OPEN/CLOSED 状态（事件级表不含开关状态，这反而是 `crash-source-bigquery-migration` 迁移的动机）、拿不到深度分析。拿得到的 `id/title/events/users/latest` + 反扫来的 `fix_commit`，**足够渲染台账现状表、变更时间线与群卡片** —— 即「数据照发，只缺分析」。

**数据层用独立 SQL**：新增 `crash-issues-all.sql` 而非复用 L1 的 `crash-issues.sql`，差别是**刻意不加版本过滤**。台账按 issue 跨版本追踪一条崩溃的生命周期，加版本过滤会让「上一版修好、这版没复发」的 issue 凭空消失、时间线断档；这也与它替代的 MCP `topIssues`（无版本过滤能力）口径一致。L1 保持零改动。

**反扫提前**：`scan-fix-commits.sh` 纯 git、不依赖快照，因此移到取数之前跑，其结果直接填进 `snapshot.json` 的 `fix_commit` 字段，省掉后置合并。

**缓存判定移进 shell**：命中判定（文件存在性 + `events_count_last_seen` 比较）改由 shell 执行，不再写在 prompt 里靠模型自觉。bq 路径存的是聚合事实而非事件数组，用 `source:"bigquery"` 与模型路径的文件区分，互不覆盖。

**两端皆空判失败**：正常情况下至少一端有数据，两端都空说明 bq 出了问题。此时必须 `exit 1` —— 把「取数挂了」渲染成「本周零崩溃」是最坏的一种错误报告。

**备选**：给 `claude -p` 加重试 → 否决，429 是额度耗尽不是瞬时抖动，重试只是把失败推迟。降级发一条纯文本告警 → 否决，那等于承认本周没有数据，而数据其实拿得到。
