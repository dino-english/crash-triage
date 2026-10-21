## Why

「已上线」一直靠推测：Android 认「修复进了 main 或任一 V* tag」，iOS 认「修复后出现过上架包特征的 build」。
2026-10-19 推测说反：`V1.9.0` 10-18 打 tag、合进 main，日报 10-19 起把 6 条 Android 修复移出「⏳ 等发版 · 催上线」，
周报写「已修未发版 0 / 已发版待验 12」——而 **Google Play 上仍是 1.8.2**（10-21 实测），Firebase 里 1.9.0 每天只有 1~3 台、
1.8.2 约 500 台。修复没到用户手里，催上线的清单却空了。

用户 2026-10-21：「发不发版，不能在 App Store / Google Play 看？为什么靠猜测？」——以商店为真值。两端公开商店都**不需要凭证**即可查到当前版本。

## What Changes

- 「已上线」两端统一为：**公开商店当前版本 ≥ 含修复的最低版本**
  - iOS 商店版本：苹果官方公开接口 iTunes Lookup（`bundleId=com.prime.dino.english&country=my`）
  - Android 商店版本：Google Play 公开详情页内嵌数据（非正式接口，取不到即不可得）
  - Android 含修复的最低版本 = 最早包含提交的 V* tag（仓库是这项的真值）；没进任何 tag → 未上线
  - iOS 含修复的最低版本 = 修复后首现的上架包中最低的版本
- 「含修复的包」判据不变（决定「修了仍在」）。
- 商店版本取不到 → 该端整端「发版判定不可得」（复用现有态），⛔ 不回落成 tag / main / 设备数。

## Capabilities

### Modified Capabilities

- `crash-perf-fix-status-reconcile`：「已上线」的判据改为以公开商店版本为准。

## Non-goals

- ⛔ 不用 Google Play Developer API / App Store Connect API（要凭证；Play 服务账号只在 ShipNow 服务端按单次打包下发，见 design）。
- ⛔ 不按设备数门槛判上线（10-21 讨论过，用户否决：靠猜测）。

## Impact

- `bin/lib/core/fixrelease.sh`（`fix_release_verdict` 加第 4 参）、新增 `bin/lib/store.sh`、`bin/fix-release-status.sh`
- L1 / L2 每轮多两次公开 HTTP 请求（各约 1s）；Google Play 页面改版会让 Android 整端「不可得」，在卡片上可见
