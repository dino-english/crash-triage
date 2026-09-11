## Why

报告能说出「哪些 issue 最严重」，但说不出**「这个 issue 影响谁、集中在哪」**——读者拿到一个 issue id 之后还得自己去 Firebase 控制台翻。

实测下钻后能直接得到的结论（Android 近 7 天）：

```
15c1049c · Native method - android.os.MessageQueue.nativePollOnce
  规模 17 事件 / 11 安装 · 页面 SplashActivity 76% · 内存档 low 65%
```

**启动页 ANR、集中在低内存设备、影响 11 台**——这三件事现在一件都看不到。

## What Changes

- 新增 `bin/sql/crash-issue-drilldown.sql`：每个 top issue × 六个维度取占比最高的取值，附取值基数与 issue 总量。
- L2 周报增「四、TOP N 事件下钻」段，性能与口径顺延为五 / 六。

## Non-goals

- ⛔ **不给 top 机型当结论**（见 design D2）。
- ⛔ 不进 L1（30 行的块不适合「3 分钟判断要不要拉人」的日报），⛔ 不进卡片（列宽撑爆）。
- ⛔ 不出根因——只给可定位对象与取证方向。

## Capabilities

- `crash-perf-impact-summary`（修改）：新增 per-issue 下钻要求，含「机型不得作为结论」这条。
