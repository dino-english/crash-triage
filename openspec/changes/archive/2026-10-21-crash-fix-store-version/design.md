## Context

可选的真值来源（2026-10-21 逐一核过）：

| 来源 | 结果 |
| --- | --- |
| iTunes Lookup（公开、官方） | ✅ iOS 1.8.2，上架 2026-10-03 |
| Google Play 公开详情页 | ✅ Android 1.8.2，更新于 2026-10-01（与 Firebase 1.8.2 10-01 首日 91 台吻合） |
| Google Play Developer API | ❌ 无凭证：打包机 `credentials.yml` 只有 iOS 钥匙串；共享构建 gem `android_build_record.rb:559-606` 显示服务账号由 ShipNow 内部接口 `/internal/builds/<build_id>/credentials` **按单次打包下发**，不落盘 |
| Firebase | ❌ 只看得到设备上跑的版本，看不到商店状态 |

## Decisions

### D1 判据

`已上线 = 商店版本 ≥ 含修复的最低版本`（版本号拆数字数组比较，1.10.0 > 1.9.0）。
- Android：含修复的最低版本 = `fixed_in_version`；为 null（只进 main 没进 tag）→ **未上线**。
  旧判据「进 main 即上线」作废——商店不可能有一个没打 tag 的版本（团队发版必打 V* tag）。
  ⚠️ 残余风险：同版本号热更新不打 tag → 一直「已修未发版」（偏保守，可见）。
- iOS：含修复的最低版本 = `rel` 清单里首现晚于提交、`perf_on > 0` 的 build 的最低版本；没有 → 未上线。

### D2 取不到

`store_version` 恒返回 0、取不到返回空串（格式不是纯数字点号也当取不到）。调用方把该端整端标「发版判定不可得」，
复用现有呈现（卡片 ❔、L1 告警不计、不进台账时间线）。⛔ 不回落成任何推测信号。

### D3 测试与等价性

`CRASH_REPORT_STORE_VERSIONS='{"ios":"…","android":"…"}'` 覆盖网络取值，夹具与冻结等价性用；⛔ 生产不设。

## Risks

- Google Play 页面结构变化 → Android 整端不可得（可见，不会静默说错）。
- 分阶段发布期间，详情页给的是匿名访客看到的版本，可能比灰度中的新版晚——对「多数用户拿到了没有」这个问题是对的口径。
