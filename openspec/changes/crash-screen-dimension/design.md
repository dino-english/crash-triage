## D1 — 为什么新建文件而不是改 crash-dimensions.sql

现有 `crash-dimensions.sql` **强制 JOIN sessions 取率**——它能给率，是因为 `firebase_sessions` 恰好含 `device.model` 与 `operating_system.display_version` 两个业务维度。页面没有对应字段，`{{SESS_DIM}}` 无值可填。

考虑过三条路：

| 方案 | 否决理由 |
|---|---|
| `{{SESS_DIM}}` 填 `NULL` 让 JOIN 落空 | 能跑，但产出的是「分母为 0 → 无法计算」。⛔ 语义错了：「分母为 0」是这次没数据，「本维度无分母」是数据源结构性没有。两者混同会让人以为等数据多了就有率 |
| 给现有文件加分支（CASE / 条件 CTE） | sed 模板替换整个 CTE，可读性与出错面都比两个文件差 |
| **新建无分母文件** | **采用** |

⚠️ 这不是 F1 意义上的「同一目的两份实现」——两者是**不同的查询**（一个 JOIN 取率、一个不 JOIN），共享的只有被模板化的 WHERE 子句。两份文件的头部互相交叉引用，说明各自适用范围。

## D2 — 列序刻意与 crash-dimensions.sql 不同

| | 1 | 2 | 3 | 4 | 5 | 6 |
|---|---|---|---|---|---|---|
| `crash-dimensions.sql` | dim | events | users | **sessions** | **rate_pct** | concentration |
| `crash-dimensions-nodenom.sql` | dim | events | users | **concentration** | — | — |

⛔ **渲染层不可共用同一套列号**——第 4 列在一份里是会话数、在另一份里是集中度，套错会把集中度读成会话数且不报错。两份 SQL 的头部都写明了这一点。

## D3 — `(未知)` 必须成行且参与排序

实测 Android 页面维度的 `(未知)` 桶是 **10 事件 / 10 安装**，在 top5 里排第 3；更早一轮实测（全版本口径）它按影响安装排第 2（19/18）。

⛔ 丢弃它会让表格各行合计对不上事件总数，而读者不会发现少了什么。SQL 里用 `IFNULL(NULLIF({{DIM}}, ''), '(未知)')` 兜住 NULL 与空串两种情况。

⚠️ ANR 的页面覆盖率最低（实测 49/63 = 77.8%），符合「应用卡死时 custom key 写入本身也受影响」的预期——这不是埋点漏了，是卡死的性质决定的。

## D4 — iOS 必须用 NON_FATAL 口径

实测 iOS 60 天仅 **5 次致命崩溃 / 4 个 issue**，同期非致命 1424 次。按 `FATAL,ANR` 口径取页面维度，iOS 那张表只有一行。

⛔ **「表里只有一行」与「iOS 很健康」在版面上长得一模一样。** 故 `{{ERROR_TYPES}}` 参数化，iOS 传 `'NON_FATAL'`，并在表头标注口径。

## D5 — 已知的不确定项

⚠️ iOS 页面值里有 UIKit 内部窗口：`UITrackingElementWindowController`（实测进了 top5，68 事件 / 14 安装）、`_UICursorAccessoryViewController` 等，合计约 11.7%。它们**不是业务页面**。

在与 iOS 客户端确认埋点取的是 `topViewController` 还是 `keyWindow.rootViewController` 之前，⛔ **不要把这几个当业务页面写进结论**。本 change 照实渲染、不做过滤——过滤名单是猜测，照实渲染至少是事实。
