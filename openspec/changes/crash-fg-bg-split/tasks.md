## 1. SQL

- [x] 1.1 `crash-error-types.sql` 增三类事件各自的 `_fg` / `_bg` / `_unknown` 共 9 列
- [x] 1.2 WHERE 由 `('ANR','NON_FATAL')` 放宽为含 `FATAL`，实测既有四列**逐字节不变**（Android `53,42,95,53`／iOS `0,0,995,112`）
- [x] 1.3 归一化表达式收口为 `SQL_FG_NORM`（`bin/lib/bq.sh`），两份 SQL 用 `{{FG_NORM}}` 引用
- [x] 1.4 调用方（L1 `qc` / L2 `ver_etypes`）补占位符替换。**负向验证**：未替换时 SQL 直接语法报错，不静默出坏数

## 2. 取值方向（搞反就全错）

- [x] 2.1 交叉验证（7d）：iOS `BACKGROUND↔"0"`=1068 · `FOREGROUND↔"1"`=14；Android `FOREGROUND↔"true"`=162 · `BACKGROUND↔"false"`=11
- [x] 2.2 回落有效性实测：Android 未知 **21 → 1**（95% 恢复）

## 3. 渲染

- [x] 3.1 九个字段落进 `m-<key>.json` 的 `errtype`
- [x] 3.2 摘要行，阈值 `FGBG_MIN_EVENTS=20` / `FGBG_BG_NOTE_PCT=80`，⛔ 不参与红黄绿判定
- [x] 3.3 ⛔ **取事件最多的版本不是最新版**（F20：首版写 `$IOS_V1`，1.5.4 仅 14 条低于阈值，整行渲染不出来）
- [x] 3.4 ⛔ 未知为 `0` 时不渲染「（未知 0）」；全角括号**先条件赋值再拼接**（F19：`${var:+（…）}` 绕过了 lint）

## 4. 验收

- [x] 4.1 函数级 3 用例（正向 / 未知=3 / 后台占比 50% 不出行）
- [x] 4.2 L1 整跑 rc=0，产物：`ℹ️ iOS 1.5.3 非致命 980 次中 966 次在后台（98.6%），用户无感；前台仅 14 次`
- [x] 4.3 `check-scripts.sh` rc=0
