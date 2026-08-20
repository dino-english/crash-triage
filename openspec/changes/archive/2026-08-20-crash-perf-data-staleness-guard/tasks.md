## 1. 脚本改造（crash-daily.sh）

- [x] 1.1 版本放量段切 REALTIME 表：`SESS_IOS`/`SESS_AND` 指向 `firebase_sessions.*_REALTIME`，`adoption_section` 与 `topver` 加「REALTIME 表缺失则回退批量表并标注」逻辑
- [x] 1.2 放量段陈旧告警：`adoption_section` 查完若 0 行，输出「⚠️ 数据未同步，最新截至 XX」而非空表（XX = sessions 表 MAX(event_timestamp)）
- [x] 1.3 性能段陈旧告警：`perf_section` 三个子查询（traces/screens/network）任一且整体 0 行时，输出「⚠️ 数据未同步，最新截至 XX」而非空表
- [x] 1.4 性能窗口放宽：新增 `PERF_DAYS`（默认 3），`perf_section` 与 `extract` 的性能查询改用 `PERF_DAYS`，放量保持 `DAYS`
- [x] 1.5 分表截止时间戳：新增 `ADOPTION_UNTIL`（sessions 表 MAX），`DATA_UNTIL` 保持性能表语义，崩溃沿用 `CRASH_UNTIL`；报告头与卡片如实展示各段截止
- [x] 1.6 卡片/报告文案：窗口说明改为「性能近 3 天 · 放量近 N 天 · 崩溃近 7 天」，截止时间戳分列

## 2. SQL 确认

- [x] 2.1 确认 `sessions-by-version.sql` 已参数化（`{{TABLE}}`/`{{DAYS}}`），无需改动；实测 REALTIME 表四字段（version/session_id/instance_id/event_timestamp）可查

## 3. 验证

- [x] 3.1 `CRASH_REPORT_DRY_RUN=1` 跑 L1，核对：放量表有数据、性能表有数据、各段截止时间戳正确、窗口 3 天
- [x] 3.2 人为模拟「表存在但停更」场景（临时把某表名指到停更的批量表），确认输出「⚠️ 数据未同步」告警而非空表
- [x] 3.3 数值与 Firebase/BigQuery 抽查 2-3 项，核对放量会话数（对照 REALTIME 表直查）

## 4. 回填与收尾

- [x] 4.1 回填 `dino-crash-perf-report` skill「已知坑」：新增「sessions 批量表可能停更，REALTIME 表才是活源；性能表每日批量同步滞后约 2 天，窗口须 ≥3 天」
- [x] 4.2 `openspec validate --strict` 通过，卡片文案无乱码
