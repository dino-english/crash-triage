## Why

三档改版（`crash-report-attention-tiers`）之后，🚨 紧急项一眼可见，但**没有落到人**：卡片写了
「Android · [libc.so] 修了仍在」，谁该去看要读者自己判断。团队已有一张「模块 × 平台 → 首接人」的
负责人表（2026-10-21 用户提供），本 change 让崩溃能归到模块时直接 @ 对应的人。

2026-10-21 用近 30 天真实 issue 实测（crashlytics REALTIME，FATAL + ANR）：

| 平台 | issue | 能归到具体模块 | 归不到 → 兜底 |
| --- | --- | --- | --- |
| iOS | 9 | 4（account / dinoclass / startup / voice） | 5 |
| Android | 56 | 11，按影响设备约 19% | 45，约 81% |

Android 覆盖率低的根因在数据源：责任帧多在系统库（`libc.so` / `nativePollOnce`），而 `current_screen`
几乎恒为 `MainActivity`（单 Activity 架构）。⚠️ 这是数据可得性问题，不是规则问题——本 change 只把它
**量出来写进周报**，补埋点由 Android 侧决定。

## What Changes

- **负责人配置**（入库，内容不是配置——同 `notes/version-notes.tsv` 的边界）：`notes/owners.tsv`
  `模块键 <TAB> 平台 <TAB> open_id`，⛔ 只存 open_id，不写姓名。
- **模块归属规则**（入库）：`notes/module-rules.tsv` `信号 <TAB> 正则 <TAB> 模块键`。
- **归属判定**（确定性、纯函数）：修复提交 scope → 自家代码责任帧 → 已知 SDK 责任帧 → `current_screen` 众数 → crash_fallback。
- **@ 的范围**：只在日报 🚨 紧急、周报 🚨 必修的每一条上 @；⏳ / 👀 不 @。
- **兜底**：归不到模块 → `crash_fallback`；模块负责人不可用（配置缺 / 不在群）→ `platform_fallback`。
- **跑批失败告警**（`alert.sh`）@ `monitor_maintainer`。
- **周报**新增一行「模块归属覆盖率」，Android 覆盖率低时附建议：在崩溃 custom keys 补模块 / 路由。

## Capabilities

### New Capabilities

- `crash-perf-owner-mention`: 模块归属判定、负责人解析与兜底、@ 的呈现范围、覆盖率呈现。

### Modified Capabilities

- 无（三档的判定规则不变，只在 🚨 条目上追加 @）。

## Non-goals

- ⛔ 不改分档规则；不在 ⏳ / 👀 上 @。
- ⛔ 不替 Android 改埋点；只在周报给建议与覆盖率。
- ⛔ 不做「按 git blame 找提交人」——负责人以团队表为准。

## Impact

- `bin/crash-daily.sh`、`bin/crash-weekly.sh`（🚨 条目渲染）、`bin/alert.sh`
- 新增 `bin/lib/core/owner.sh`（纯函数）、`bin/sql/crash-issue-owner-signals.sql`、`notes/owners.tsv`、`notes/module-rules.tsv`
- 卡片 @ 会通知真人——**上线即对外可见**，部署前必须实发私聊验证 @ 渲染与通知
