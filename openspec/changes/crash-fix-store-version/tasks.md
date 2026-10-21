## 0. 拍板

- [x] 0.1 以公开商店为真值，不用设备数门槛（用户 2026-10-21）
- [x] 0.2 Play Developer API 无凭证可用（打包机核实：服务账号由 ShipNow 按单次打包下发，不落盘）→ 只用公开商店

## 1. 实现

- [x] 1.1 `bin/lib/store.sh`：`store_version ios|android`，取不到返回空、恒 rc=0；`CRASH_REPORT_STORE_VERSIONS` 覆盖
- [x] 1.2 `fix_release_verdict` 第 4 参商店版本；已上线 = 商店版本 ≥ 含修复的最低版本
- [x] 1.3 `fix-release-status.sh`：每端取一次；取不到该端整端不可得；`store_versions` 写进产物

## 2. 测试

- [x] 2.1 `fn-fix-release-verdict.sh` +6 条（10-19 V1.9.0 形态、商店 1.9.0 / 1.10.0 / 空、iOS 两条）；旧代码 4 红
- [x] 2.2 `fn-fix-release-status.sh` ④ 一端商店不可得；全部夹具走覆盖、零网络
- [x] 2.3 `check-scripts.sh` 十项全绿

## 3. 验证（⛔ 部署前）

- [x] 3.1 生产 /tmp 影子跑：新旧 fixmap 逐条 diff，每条状态变化拿商店版本与 tag 核
- [x] 3.2 卡片「⏳ 等发版」恢复列出 1.9.0 的修复；实发私聊读回

## 4. 文档

- [x] 4.1 口径文档「修复状态四态」改判据；失效模式登记 F66

## 实施记录（2026-10-21）

- 3.1 生产只读影子跑 `fix-release-status.sh`（输入 = 当日 08:30 生产 fixmap-scan.json，新旧代码各一次）：23 条中 9 条改判，全部「已发版待验 → 已修未发版」
  - Android 6 条：均 `fixed_in=1.9.0`，Google Play 1.8.2 → 正确
  - iOS 3 条（`09ee5ad3` `376127db` `3c8c9ac8`）：`git tag --contains` 只有 `v1.9.0`、提交晚于 1.8.2 上架（10-03），App Store 1.8.2 → 正确；
    旧判据被开着性能采集的 1.9.x 内测包骗过（失效模式 F66）
  - 其余 14 条不变
- 3.2 生产 /tmp 整跑 L1 NO_DELIVER rc=0：商店 iOS 1.8.2 · Android 1.8.2，23 条全判、0 不可得；卡片「⏳ 等发版」0 → 9；实发私聊 `om_x100b62b2b0a03938…` 读回正常
