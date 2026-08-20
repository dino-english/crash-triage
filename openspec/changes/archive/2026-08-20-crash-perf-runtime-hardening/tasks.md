## 1. 路径自解析

- [x] 1.1 `crash-daily.sh` / `crash-weekly.sh` / `setup.sh` 运行根改 `BASH_SOURCE` 自解析，删除 `$HOME/crash-triage` 默认值
- [x] 1.2 `REPOS_ROOT` 自动探测同级工作区，探测不到才回落 `$ROOT/repos`
- [x] 1.3 两个 plist 改 `__ROOT__` / `__STATE__` 占位符模板；`setup.sh` 生成到 `$STATE/`
- [x] 1.4 清理注释与文档里的 `gitWorkspace` / `$HOME/crash-triage` 字样（该目录在本机并不存在，照着排查会走空）
- [x] 1.5 三种布局实测验证（仓库内 / 老式独立目录 / 显式环境变量）

## 2. 代码与状态分离

- [x] 2.1 引入 `STATE`（`CRASH_REPORT_STATE_DIR`，默认 XDG）
- [x] 2.2 logs / 报告 / 快照 / 历史 / publish / audit / config.env 全部迁到 `$STATE`
- [x] 2.3 `weekly-index.jsonl` 移入 `reports/` 并纳入 git（不可再生）
- [x] 2.4 `.gitignore` 重写（仓库不再产生运行时文件）
- [x] 2.5 实测确认跑完一轮后 `git status` 无新增运行时文件

## 3. 删除双副本

- [x] 3.1 `git rm -r scripts/crash-report`（19 文件）
- [x] 3.2 删除 `setup.sh` 的自装 cp 逻辑
- [x] 3.3 更新 INSTALL.md §4 / §7.3 与 CLAUDE.md 的相关章节

## 4. 确定性投递

- [x] 4.1 manifest 增加 `day` / `run_id`（日报与周报）
- [x] 4.2 新增 `bin/deliver.sh`：导入文档 → 回填占位符 → 发卡片，`--idempotency-key` 用 `run_id`
- [x] 4.3 陈旧 manifest 闸门（`day` ≠ 今天则拒投）
- [x] 4.4 周报 `send=false` 时整段跳过；归档追加在卡片发出之后
- [x] 4.5 生成脚本末尾串行调用 deliver，失败只告警不改退出码；`CRASH_REPORT_NO_DELIVER=1` 可跳过
- [x] 4.6 dry-run 验证全部分支（日报 / 周报 send=true / send=false / 陈旧闸门 / dry-run 不落盘）
- [x] 4.7a 云文档目录结构（父目录 + L1/L2 子目录），按名字幂等查找、token 缓存
- [x] 4.7b 索引与台账改原地覆盖（`DOC_*_ID` 设了才生效，未设则沿用新建并打印 URL）
- [x] 4.7c 日报周报统一归档到 `reports/report-index.jsonl`，索引页渲染两张表，兼容旧 `weekly-index.jsonl`
- [x] 4.7 **真实投递验证**（会真的建文档发卡片）：先用私聊 `ou_xxx` 跑一轮，确认 `drive +import` 返回的 URL 字段名与递归提取一致 — 2026-08-20 实证：L1/L2 多轮真实投递到 `ou_edd20a8dbfcc5e3ee279a225aec044d0`，`publish_doc()` 均正确取到 URL（如 `docx/KdK8dlqXuoOkQdxxz1sjszLspnc`），覆盖新建与原地覆盖两条路径
- [x] 4.8 `crash-perf-execution-audit-log` 归档时删除 T1「投递幂等台账 / card_sent 闸门 / 同日补投」条目（已被 `--idempotency-key` 取代） — 2026-08-20 结项：`crash-perf-execution-audit-log` 32 项一项未实施，从未落地过 T1，无内容可删。本条的实质诉求「幂等靠 `--idempotency-key` 而非台账」已在 `deliver.sh:291` 实现并写入 CLAUDE.md；若将来重启审计日志 change，需以此为前提重写其 T1
