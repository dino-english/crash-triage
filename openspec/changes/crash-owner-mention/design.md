## Context

负责人表由用户 2026-10-21 提供（模块键 × Android / iOS 首接人）。open_id 用 **crash-triage 应用**的机器人
列日报群成员取得（`lark-cli --profile crash-triage im +chat-members-list --as bot`），⚠️ open_id 按应用隔离，
开发机默认 profile 查出来的不能用。表上 11 人全部在群（10-21 核；其中一人群显示名与表上中文名不同，系同一人）。

## Decisions

### D1 负责人配置 `notes/owners.tsv`（2026-10-21 取值）

⛔ 入库只写模块键与 open_id，不写姓名（产物不写同事姓名）。

```
# 模块键	平台	open_id
startup	and	ou_5536eda75a97567574bed37c5ecff1c4
startup	ios	ou_edd20a8dbfcc5e3ee279a225aec044d0
account	and	ou_de209efbb6f6c098ee2caf7faf815ea2
account	ios	ou_24e6a37a4517f0877ccb7288e4799baa
core_network	and	ou_5536eda75a97567574bed37c5ecff1c4
core_network	ios	ou_2a99454a1726190d6f36083549341005
voice	and	ou_5536eda75a97567574bed37c5ecff1c4
voice	ios	ou_2a99454a1726190d6f36083549341005
dinoclass	and	ou_441b57984a3232f87cb2a4b1bbe67617
dinoclass	ios	ou_275b0a10722e301f33cca460d19f80fd
webview	and	ou_441b57984a3232f87cb2a4b1bbe67617
webview	ios	ou_275b0a10722e301f33cca460d19f80fd
pay	and	ou_07dfda3433dbc8cdf55f4783808b6ecd
pay	ios	ou_c8d5ce5a4a468bd439012b317d68dab8
pag	and	ou_aa2ee8f85c013f8e0887e23109ff7f66
pag	ios	ou_8ae48f5c310b080f77b65211d8ade871
crash_fallback	and	ou_aa2ee8f85c013f8e0887e23109ff7f66
crash_fallback	ios	ou_8ae48f5c310b080f77b65211d8ade871
platform_fallback	and	ou_5536eda75a97567574bed37c5ecff1c4
platform_fallback	ios	ou_2a99454a1726190d6f36083549341005
monitor_maintainer	and	ou_5536eda75a97567574bed37c5ecff1c4
monitor_maintainer	ios	ou_2a99454a1726190d6f36083549341005
```

平台键用 L1 内部的 `ios / and`（⚠️ F43：L2 / 状态反查用 `ios / android`，接入处换算）。

### D2 归属判定优先级（命中即停）

| 序 | 信号 | 来源 | 例（10-21 实测） |
| --- | --- | --- | --- |
| 1 | 修复提交的 conventional scope | fixmap `subject`，如 `fix(tts):` | `62f88f39` `fix(tts)` → voice；`8101c07c` `fix(pay)` → pay |
| 2 | 自家代码责任帧 | `blame_frame.owner = DEVELOPER` 的 symbol / file | `feature.dinoclass` → dinoclass；`core.ai.tts` → voice |
| 3 | 已知 SDK 责任帧 | `blame_frame.library` / symbol | Azure Speech、腾讯口语评测 → voice；billingclient → pay；chromium → webview |
| 4 | 页面 | `custom_keys.current_screen` 在该 issue 事件中的众数 | iOS `WelcomeLoginViewController` → account |
| 5 | 归不到 | — | → `crash_fallback` |

- 第 1 序只对有修复提交的条目生效（「修了仍在」占 🚨 的大头，scope 比责任帧准）。scope 别名表进 `notes/module-rules.tsv`（如 `tts / asr / ai → voice`、`classsdk → dinoclass`、`media` 不映射）。
- 第 3 序：**明显属于某模块的 SDK 归该模块**（用户 2026-10-21 认可），归属不明的第三方 SDK 才落 `crash_fallback`。
- ⛔ Android `current_screen = MainActivity` 不提供信息，规则表里不得有能命中它的正则。
- ⛔ **责任帧为 THIRD_PARTY 时不用页面信号**（2026-10-21 回放订正）：`4ade82c7` / `ed3883b1` 是 PAG 的 `nativeFinalize`（GC 回收线程），崩时停在 `CommonWebActivity` 是巧合，按页面会 @ webview，而同一崩溃拆出的 `29d4790c` 落兜底——三条互相矛盾。SDK 规则没认领的第三方崩溃一律兜底，与负责人表「第三方 SDK → crash_fallback」一致。
- **pag 单列**（用户 2026-10-26：「pag 可以单独开，先放兜底」）：首周兜底 13 次 @ 里 5 次是 PAG。规则按近 30 天 6 个 PAG FATAL/ANR 的责任帧实测写——scope `pag`、自家帧 `DinoPAGView`、SDK 帧 `^libpag ` / `org.libpag.`；负责人暂与 `crash_fallback` 同人，换人只改 `owners.tsv`。
- 规则是**内容**：放 `notes/module-rules.tsv`（`信号 <TAB> 正则 <TAB> 模块键`，信号 ∈ `scope / own / lib / screen`），改规则不改代码。

### D3 负责人解析与兜底

`模块 → owners.tsv[模块][平台]`；取不到 → `platform_fallback`；`crash_fallback` 自身取不到 → `platform_fallback`；
`platform_fallback` 也取不到 → 不 @，⛔ 并在卡片该条后写「（负责人未配置）」——缺配置必须可见。
「不在群」**不在运行时判定**（实现时订正）：每轮列群成员会让 L1 取数段多一个飞书依赖，且 cron（hermes 上下文）与 ssh 的 lark-cli 身份配置不同；表上人员 10-21 已核全部在群，@ 一个不在群的人也无害。换人时改 `owners.tsv` 前先用机器人核一次群成员。

### D4 呈现

- ⚠️ 只给 **issue 条目** @；性能指标类 🚨（慢帧 / 接口错误率等「性能退化」）不 @——它们没有对应的模块负责人，强行归属就是猜。
- 只在日报 🚨、周报 🚨 必修的每条末尾追加 `👤 <at id=ou_…></at>`，并标归属来源（`模块 · 依据`），例：`👤 @某人 · voice（修复 scope）`。归到兜底时写明「兜底」。
- ⏳ / 👀 不 @（用户 2026-10-21 认可：避免每天 @ 一串人）。
- `alert.sh` 失败卡片 @ 两端 `monitor_maintainer`。
- ⚠️ 卡片 `<at>` 的渲染与是否真的通知，**只能实发验证**（DRY_RUN 看不出），见 tasks 5。

### D5 周报覆盖率与建议

周报新增一行：两端「近 7 天受影响设备中能归到具体模块的占比」。某端占比 < 50% **且该端受影响台数 ≥ 10**（`OWNER_COV_MIN`，用户 2026-10-21）时附一句建议：
在崩溃 custom keys 补 `module` / 路由字段（当前 `current_screen` 恒为 `MainActivity`）。⛔ 不在日报出现（每天一样，是噪音）。

## Risks

- **错 @ 比不 @ 更伤信任**：规则先保守（宁落兜底不猜模块），上线后首周人工抽查每条 @。
- 周报 🚨 由模型给出 P0/P1，归属判定仍走 D2 确定性规则，⛔ 不让模型决定 @ 谁。

## Open Questions

- 无（2026-10-21 用户已定：@ 范围、SDK 归属、周报给建议；兜底人按负责人表）。
