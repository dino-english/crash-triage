## 1. SQL

- [x] 1.1 新增 `crash-dimensions-nodenom.sql`，列 = `dim / events / users / concentration`
- [x] 1.2 `{{ERROR_TYPES}}` 参数化（Android `'FATAL','ANR'`／iOS `'NON_FATAL'`）
- [x] 1.3 `(未知)` 用 `IFNULL(NULLIF(…,''),'(未知)')` 兜住 NULL 与空串，⛔ 不丢弃
- [x] 1.4 两份维度 SQL 头部**互相交叉引用**，写明列序不同、渲染层不可共用列号
- [x] 1.5 `bin/sql/README.md` 登记文件表与 `{{ERROR_TYPES}}` 占位符

## 2. 取数与渲染

- [x] 2.1 `qdim_nd()`（不 JOIN sessions，带 audit 事件）
- [x] 2.2 `collect_dims` 增页面维度，错误类型按端分叉
- [x] 2.3 ⛔ **不复用 `dim_csv`**：那份判 `NF>=6` 读第 5 列作率，无分母 CSV 只有 4 列，套用会**静默拿空表**。单写 `dim_nd_csv`
- [x] 2.4 markdown + XML 双路径渲染，四条标注随表出现

## 3. 验收

- [x] 3.1 函数级：真实 CSV 渲染，`(未知)` 成行
- [x] 3.2 L1 整跑 rc=0，产物含 `SplashActivity 17 | 12 | 1.4` 与 `(未知)` 行
- [x] 3.3 ⚠️ 实测印证 design D5 的担心：iOS 1.5.4 的 top 页面确实是 UIKit 内部窗口 `UITrackingElementWindowController`——**待与 iOS 端确认埋点取值对象**（未决）
