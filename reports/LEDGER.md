# 崩溃专项总台账（LEDGER）— iOS

> 最近更新：2026-08-06（1.5.0，首轮专项）。图例：🆕新增 🔁遗留 🛠️已修待验 ⚠️修了仍在 ⬇️收敛中 ✅已消失
>
> **2026-08-06 首轮专项已跑**：快照报告 `reports/2026-08-06-1.5.0.md`。首建骨架（2026-07-24）的两条 issue 处置结论已补齐。
>
> **数据核对纪律**（承 Android 台账已验证结论）：`crashlytics_get_report{topIssues}` **只返回 OPEN issue**（关闭即从列表消失）；「活跃/回归」判定须标 `✅钻取确认`（读过 `list_events` 版本分布）或 `⚠️聚合推断`。窗口不等长时不给趋势箭头，只记绝对值。

## 项目常量（供后续报告复用）

- App ID：`1:465344775452:ios:610bc2f8ea0750fff466d9` · project `dino-english-497507`（与 Android 同项目，项目号 `465344775452`）
- Bundle ID：`com.prime.dino.english`；版本真源：Xcode 工程 `MARKETING_VERSION` / 构建号如 `1.5.0.1`（`版本.构建序号`）
- Crashlytics 接入：`AppLaunch.setupCrashReporting`（Eager 组件，处理器启动即挂）；用户绑定 `syncCrashlyticsUserID`（只回填内部 userId，禁 PII）
- 数据通道：Firebase MCP。**两处配置**——Cursor 走 `~/.cursor/mcp.json`，Claude Code 走仓库根 `.mcp.json`（均 gitignore，每台机器各配一份）。**`--only crashlytics` 必须显式指定**（工作区无 `firebase.json` 时 MCP 默认只暴露 core 工具组，Crashlytics 工具不加载，2026-07-24 实测坑）；授权走 `firebase login` 浏览器流程
- **无人值守抓取**（2026-08-06 实测通）：`claude -p "<prompt>" --allowedTools "mcp__firebase" < /dev/null`，需从仓库根执行（`.mcp.json` 按 cwd 加载）；`< /dev/null` 不可省，否则等 stdin 3 秒

## 项目崩溃收口点登记

- **上报收口**：FATAL 由 Crashlytics 默认 UncaughtExceptionHandler 自动捕获。
  **NON_FATAL 通路已建**（2026-08-10，change `ios-nonfatal-reporting`，分支 `dev-nonfatal-reporting`，**尚未合入发版**）：
  - 收口点 `NonFatalReporting.record(_:keys:)` / `.recordThrottled(...)`，
    契约在零依赖叶子包 `Packages/DinoEnglishFaultReporter/`，Firebase 实现在 `Common/App/FirebaseNonFatalReporter.swift`
  - 闸门判定序：Debug 覆盖（MMKV 持久化）→ 远程 `nonFatalReportingEnabled` → **fail-open**；
    远程只用来关停，实时监听生效实测 2ms
  - **实现内无错误类型过滤**（对齐 Android），控量靠调用纪律 + 高频点限流（`NonFatalRateLimiter`，默认同签名 3 次/进程）
  - 已接落点 8 处：TTS 4（`tts_player_node_play` / `tts_audio_engine_start` / `tts_engine_init` / `tts_engine_stop_speaking`）、
    PAG 3（`pag_cache_http_error` / `pag_cache_corrupt` / `pag_cache_parse_failed`）、ASR 1（`asr_session_start`）、
    以及 `safe_decode_fallback`（`safeDecode` 3 个泛型重载内部收口，调用侧 36 个文件零改动）
  - `safeDecode` 标量重载（7 个）也已接入（2026-08-10），但**判据比泛型重载严**：只在
    「字段存在 && 非 null && 所有类型都转不了」时报（`scene: safe_decode_scalar_fallback`）。
    兼容转换成功是设计内宽容、字段缺失或 null 是可选字段常态，两者均不报——放宽任一条都会刷屏
- **ObjC NSException 防御**：`DinoObjCExceptionCatcher.catchException`（`DinoTTSObjCSupport`），CoreAudio 状态敏感调用必包
- **Agora RTC/RTM 收口**：`Packages/DinoClass/DinoClass/Classes/DinoClass/AgoraRTC/`（`DCAgoraConvoAIAdapter` 建连 / `DCAgoraRTCManager` teardown / `ConversationalAIAPIImpl` + `TranscriptController` delegate 注册）。**delegate 增删必须与 `AgoraEvent` 事件线程串行**，详见 `3fd09886`
- **开发侧预防对照**：`.claude/skills/crash-prevention/SKILL.md`（七崩溃族硬规则）
- **排查流程**：`.claude/skills/firebase-crash-triage/SKILL.md`（2026-08-06 自 Android 仓库移植）

## Issue 台账

| Issue ID | 标题 | 类型 | 首次纳入 | 处置状态 | 本次状态 | 事件量趋势 | 备注 |
|---|---|---|---|---|---|---|---|
| 3fd09886 | [aosl] aosl_shrink_resources NSGenericException（NSHashTable mutated while enumerated） | FATAL | 2026-07-24 / 首建 | **已修复（合入 dev-1.5.1，2026-08-06）· 1.5.1 已上架 App Store** | 📦 已发版·观察中 | 近 90 天 1（v1.3.2）→ 08-06 上午 **5** → 08-06 **8** → 08-07 **12** → 08-10 **16**（全部 v1.5.0(1.5.0.1)，即修复前的包） | ✅钻取确认（5 条事件全读）。**根因（2026-08-06 定位）**：`DCAgoraConvoAIAdapter.swift:84` 的 `client.login` completion **在 Agora 回调线程执行且无主线程切换**，其内 `setupConvoAI` → `ConversationalAIAPIImpl.init` 连做 3 次 `addDelegate`（`:35` rtc / `:36` rtm / `TranscriptController:526` rtm），与 `AgoraEvent` 线程遍历 `NSConcreteHashTable` 撞车。breadcrumb 全部为 `rtc_joined→rtc_connected` 后 14ms 内崩，5 例签名 100% 一致、全落 variant `766e5ef5b5d0311ea258ed38c136f1b3`。**既有三个修复 `6510080d`(6-30) / `e2a96f24`(7-3) / `ed37c562`(7-9) 全在 HEAD 祖先链且早于两个崩溃版本，但全部只动 teardown 侧，join 侧从未覆盖**。内存是放大器非根因（5 例 free 36~126MB，2 例 `mem_tier: low`）。**已落地修复（2026-08-06，dev-1.5.1）**：`setupConvoAI` 拆为 `makeConvoAI`（建连前同步调，完成全部 delegate 注册）+ `subscribeConvoAI`（login 成功后调，订阅依赖登录态）。**注意排除的错误方向**：切主线程无效——`AgoraEvent` 是 SDK 自有线程，换哪个线程写都仍是并发；逐点加锁会漏 `ConversationalAIAPIImpl.init` / `TranscriptController.setupWithConfig` 内部的后续注册。编译已过（`BUILD SUCCEEDED`）。**真机回归已做**（2026-08-06，iPhone 17 Pro Max / iPhone18,2，Debug 包）：进→用→退 ×2 轮全通，14638 行控制台日志零 `NSGenericException` / `mutated while` / `NSFastEnumerationMutationHandler`；RTM 双向通（`sendRTMMessage` 成功 = login + subscribe + delegate 注册均生效）；teardown 干净、退-进循环无残留。**时序为结构性保证非时序保证**：`DCAgoraRTCManager.m:578` 同步调 setup（内含 `makeConvoAI`）→ 方法返回 → `:600` 才 `joinChannel`，同线程直线调用，不存在先后不定。**残留风险**：2 轮不足以证伪窄竞态，发版后须看 Crashlytics 复核。**📦 2026-08-10 追加：1.5.1 已上架 App Store，进入观察期。**
BigQuery sessions 表交叉核对（Crashlytics 单独给不出这个视角）：

| 版本 | 会话 | 设备 | 崩溃 |
|---|---|---|---|
| 1.5.0 (1.5.0.1) | 694 | 304 | 16 |
| 1.5.1 (1.5.1.16) | 36 | 25 | **0** |
| 1.5.1 其余构建 | 67 | 12 | **0** |

**⚠️ 现在还不能判定修复生效**：1.5.1 会话数只有 1.5.0.1 的 1/19。按 1.5.0.1 的崩溃密度（16/694 ≈ 2.3%）外推，36 个会话的期望崩溃数仅 0.8 次——观察到 0 次与「已修好」「样本不足」两种解释都相容，统计上区分不了。
**判定标准**：1.5.1 累计 **300+ 会话仍 0 崩溃** → 判修复生效；**出现哪怕 1 次** → 立刻回落「⚠️ 修了仍在」并重查根因。
注：BigQuery 批量同步滞后约一天（上表数据截至 08-09 06:51），今日放量未计入。

**⚠️ 2026-08-10 修正前述「内存是放大器」的表述**：08-09 那次崩溃发生在 **iPhone 16 Plus / `mem_tier: high` / free 111MB**，而此前样本清一色 `mem_tier: low`。**内存压力不是必要条件**——join 侧 delegate 并发注册本身即足以触发，内存紧张只是让 `aosl_shrink_resources` 更频繁遍历该集合、提高命中概率。崩溃面同期扩大到 **iPad 6th Gen（iPadOS 15.5）** 与 **iOS 26.6**，不再局限于旧 iPhone。

**2026-08-07：事件量 12，100% 落在修复前的包。** ⚠️ 2026-08-06 下午：当日新增 3 例全在 v1.5.0（07:30:45Z / 07:29:59Z / 03:40:20Z UTC），v1.5.0 累计 5 例、事件量加速中。修复只在 dev-1.5.1 未发版，线上用户仍在崩——发版优先级应上调。** 完整 ID `3fd098868d1760e0238997f19e65e9e5` |
| 680260c4 | InterfaceOrientationRestorer.enforceCurrentSupportedOrientation 闭包 EXC_BREAKPOINT | FATAL | 2026-07-24 / 首建 | **已修复（合入 `a0863cbe`，2026-06-19）** | ✅Firebase已关闭（2026-08-06） | 近 90 天 6/5（全 v1.1.0）→ 近 7 天 **0** | ✅钻取确认：2026-08-06 单独复核 `get_issue` 仍 `state=OPEN` 但 `list_events` **0 事件**，非「掉出 pageSize」误报。修复生效，v1.2.0 后绝迹。**2026-08-06 已调 `update_issue{state:"CLOSED"}` 关闭并复核 `VERIFY=CLOSED`**（软关闭，回归会自动 regressed 重开，正好作修复验证）。完整 ID `680260c45391451e58c8ad1c51e136d9` |

## 勘误记录

- **2026-08-06**：首建条目将 `6510080d` 记为「Android 的修复」，实为**本仓库 iOS commit**（`git log -1 6510080d` 可验：`fix(class): 修复进退教室时 RTM delegate 并发修改导致崩溃`，2026-06-30）。已订正。

## 事故记录

- **2026-08-06 · `3fd09886` 被误关闭**：自动化调试期间，`claude -p --allowedTools "mcp__firebase"` 的**前缀匹配放行了全部 firebase 工具**（含写操作 `crashlytics_update_issue`），子代理越界把该 issue 关成 CLOSED。当日下午发现并已恢复 `OPEN`（`update_issue{state:"OPEN"}` 复核通过）。
  - **暴露的二级问题**：`get_report{topIssues}` 只返回 OPEN issue，所以一旦被误关，**这条正在加速的崩溃线会从周报里彻底消失，且报告会显示「iOS 0 个 FATAL」= 看起来很健康**。周报指标不能只建立在 topIssues 上，须改用事件级统计（BigQuery）。
  - **纪律**：给自动化 agent 的 `--allowedTools` **禁止用 server 前缀通配**，必须显式列出只读工具（`mcp__firebase__crashlytics_get_report` / `_get_issue` / `_list_events` / `_batch_get_events`），写操作 `_update_issue` 只在人工会话中由人确认后调用。

## 跨端观察（2026-08-07 首份自动化周报）

来源：`scripts/crash-report/` 的 L2 每周 triage，产出见飞书「崩溃周报 · 2026-08-07」。**根因与方案未经人工复核**，此处仅登记待跟进事实。

- **Android `4cfe6e36`**：`DeepLinkDispatcherActivity.launchApp` NPE，6 事件 / 6 用户，**100% 发生在会话第一秒**，全在 1.5.0。报告判定 0 风险可修，已在飞书群同步 Android 侧
- **Android `62f88f39`**：Speech SDK SIGSEGV **修了仍在**。7/21 自持麦克风重构 `fff27f23` 经 `merge-base --is-ancestor` 确认已在 1.5.0，1.5.0 仍有 3 例
- **Android 低内存崩溃族**：NON_FATAL `2bfffedd` / `4739ca37` 各 64 例（ASR teardown `close()` 失败被吞 → native 泄漏），与 `3e827b74`（libutils.so，19 例全 1.5.0，样本空闲内存 <160MB）疑为同族。**这条侧面印证 iOS NON_FATAL 通路缺失的代价——同类问题 iOS 完全不可见**（见 change `ios-nonfatal-reporting`）

## 归因窗口提醒（2026-08-10 立）

**下个版本的崩溃率变化会同时受两个因素影响，解读时勿归因到单一原因**：

1. `3fd09886` 的修复效果（1.5.1 起生效）
2. **NON_FATAL 通路上线**（`626a5c17` 已 squash 合入 `dev-1.5.1`）——线上 NON_FATAL 将从
   恒为零变成有量，且首批数据必然难看（12 处落点一次性生效）。**这是通路建起来的正常现象，
   不是稳定性突然变差**

**`3fd09886` 的判定不受影响**：其判定标准只看 1.5.1 这个已发布版本的会话数与崩溃数
（300+ 会话仍 0 崩溃才算生效），与本次合并无关。受影响的是「下个版本崩溃率为什么变了」这类跨版本比较。

**首批 NON_FATAL 数据到达后**：先按 change `ios-nonfatal-reporting` 任务组 4 做首轮分诊
（逐条给必修 / 建议修 / 已覆盖 / 暂缓），再校准限流参数（当前默认同签名 3 次/进程是保守估计非实测结论）。
量级失控时用远程开关 `nonFatalReportingEnabled` 置 false 止血，无需发版。

## 自动化限制登记

- **`current_screen` 维度 iOS 缺失（2026-08-10 决策不补）**：Android 经 `ActivityLifecycleCallbacks` 持续写入该 Crashlytics custom key，iOS 无等价物——补齐需 swizzle `UIViewController.viewDidAppear`（有风险且可能与 Firebase Analytics 现有 screen 追踪冲突）或全 VC 基类改造（本项目无此约定），收益与成本不成比例。**后果**：Crashlytics 控制台与 BigQuery 上 **iOS 无法按页面切片崩溃/非致命分布**，Android 可以。**兜底**：iOS 崩溃事件 breadcrumb 内含 `firebase_screen_class`（实测确认），信息存在但需逐条读取、不可聚合查询。

- **Android 无法按 issue ID 自动反查修复状态**：Android 未采用「提交信息带 Crashlytics issue ID」的约定（2026-08-07 核实：全仓 0 处 32 位 hex 引用），`git log --grep=<issueId>` 恒为空。**因此自动化表格中 Android 的修复状态显示为 `—` 而非「未修」**——后者会得出错误结论。其修复情况以每周 triage 报告的语义分析为准。
  - 打通前提：推动 Android 侧采用同样约定（iOS 侧由 `crash-prevention` 定为硬规则）。
