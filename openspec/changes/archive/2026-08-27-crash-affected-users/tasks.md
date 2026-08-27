## 1. SQL

- [x] 1.1 `crash-rate.sql` 增 `affected_users = COUNT(DISTINCT NULLIF(user.id,''))`
- [x] 1.2 既有四列实测**逐字节不变**（iOS `1,3467,1,1`／Android `31,7622,20,30`）
- [x] 1.3 ⛔ 不按平台分叉，Android 自然跑出 0（实测）

## 2. 渲染

- [x] 2.1 字段落进 `m-<key>.json` 的 `crash.affected_users`
- [x] 2.2 汇总段增列，Android 渲染 `— 不上报`（⛔ 不是 0、不是空；⚠️ 与 iOS ANR 的「— 无此概念」后缀刻意区分）
- [x] 2.3 三条标注：不可相加减 · 无用户率 · 不可与 Firebase 控制台对照
- [x] 2.4 markdown 表头 / XML / awk 列号四处同步

## 3. 验收

- [x] 3.1 函数级 3 用例（iOS 有值 / Android 不上报 / iOS 缺失渲染 `—`）
- [x] 3.2 L1 整跑 rc=0，产物 `| Android | 1.5.4 | 2 | — 不上报 | 3 | 1.5 |`
- [x] 3.3 ⚠️ 过程中踩 F22：标注文案里的 `96.6%` 进了 printf 格式串，跑批在取数 5 分钟后炸。已修并**做成 `check-scripts` 第 8 项 lint**（带负向测试）
