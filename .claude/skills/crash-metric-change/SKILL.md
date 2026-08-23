---
name: crash-metric-change
description: 改 crash-triage 任何指标数字 / 阈值 / 口径前的强制校验流程——先核对口径红线再动手，防止改出静默错误的数字。用于：改崩溃率、crash-free、ANR、性能指标的算法或阈值，加新指标，改 SQL 窗口；或当用户提到 改口径、改阈值、改指标、加指标、崩溃率算法、告警阈值 时。
---

# crash-metric-change

## 核心事实（先读）

1. **改数字前必读** docs/CLAUDE-架构与数据口径.md 的「数据口径」「版本口径」「阈值与告警」三节——多数「看起来不对的数字」是刻意取舍，都有实测反例。
2. **两套口径分离存储不可混比**：滚动窗口展示值 vs 天级单日值（`*_1d`，供 DoD/WoW），混入 `metrics-history.jsonl` 会让 90 天趋势断裂。
3. ⛔ `error_type` 三类（FATAL / ANR / NON_FATAL），**不要用 `is_fatal` 过滤**——ANR 与 NON_FATAL 会整体不可见。崩溃次数/率/受影响安装保持 FATAL 口径不变。
4. **阈值常量集中在 `crash-daily.sh` 顶部**；判定统一走 `traffic_light()`。⚠️ crash-free 方向相反（越大越好）——用坏方向值判定、好方向值展示，直接套用会把 100% 静默判红。
5. ⚠️ **告警判定对象由 1 天窗小样本回退决定**（`adopt.sessions` < `SAMPLE_SESSION_MIN` 时回退到会话量最大版本）——评估「改了会不会告警」看 1 天窗，不是崩溃段的 7 天窗。

## 校验清单（动手前逐项过）

1. 这个数字在哪几条渲染路径出现？⚠️ `ROW_DEFS` 拆 CARD(6)/DOC(13)，显式 3 处 + 别名 3 处——先 `grep -n` 数清调用点，别名处改名不报错只静默拿空集合。
2. 新口径与 Firebase 控制台 / Google Play 可比吗？不可比必须在报告标注（用户率做不了、Play ANR 口径不同——见口径文档）。
3. 分母为 0 / 缺数怎么显示？「无法计算」不是 0 也不是 100%；缺数三态顺序不可颠倒。
4. 动了 SQL？占位符只替换值；perf 系与 crashlytics/sessions 系字段路径不同不可共用模板。
5. 改完跑 `check-scripts.sh`；声称零行为变更的部分走 `eqv-check` skill 的冻结缓存协议。

## 不负责什么

- 只是调试跑批 / 验产物 → `crash-report-debug` skill
- 台账同步逻辑 → docs/CLAUDE-架构与数据口径.md「台账口径」
