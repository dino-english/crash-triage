## 1. 基线取证（改之前先留证据）

- [x] 1.1 快照 `$STATE/issues/` 全部文件到 `$STATE/backup/fact-cache-before-<日期>/`，
      并记录每条的 `last_synced` / `events_count_last_seen` / `events` 长度一览
      → 验：一览表条目数 = 文件数，且与 2026-09-08 基线（25 个文件 / 声称 55 / 实存 6）可对照
- [x] 1.2 记录当前三种 `last_synced` 口径各占多少条（真 UTC / 本地标 Z / 缺失）
      → 验：三类之和 = 文件数

## 2. 共享函数（`bin/lib/factcache.sh`）

- [x] 2.1 新建 `bin/lib/factcache.sh`，函数签名接受 issues 目录、issue id、计数、窗口天数、时刻
      → 验：`grep -n '\$STATE\|\$ROOT' bin/lib/factcache.sh` 无输出
- [x] 2.2 `latest_event` 取 max 的语义原样搬入（⛔ 不得在搬运中改行为）
      → 验：`bin/test/fn-factcache.sh` 中「旧值更新时不倒退」用例通过
- [x] 2.3 `bin/fetch-snapshot-bq.sh` 改为 source 该函数，删除本地实现
      → 验：`CRASH_REPORT_BQ_CACHE` 冻结数据下跑 L2，`issues/*.json` 与改前逐字节 diff 为空
      （⚠️ 排除 `last_synced` 一行——它必然变）
      **2026-09-08 实测（eqv-check 协议）**：旧代码 `7ed66ef` 单独 worktree + 新代码各跑一轮
      `CRASH_REPORT_SKIP_ANALYSIS=1`（跳过分析层，正好绕开「冻结缓存冻不住模型」那个坑），
      共享 45 条冻结缓存；`diff -r OLD NEW --exclude=run.log` **严格为空**——
      比对面 70 个文件（中间 15 · 投递 9 · 基准 46，其中事实层 31）。
      ⚠️ `last_synced` 由 `normalize.sh` 归一成 `<ISO8601>`，无需手工排除。
      ⚠️ 首轮旧代码失败是 worktree 里 `REPOS_ROOT` 自动探测落空（环境非代码），
      显式 export 后重跑通过——该失败还真发了一张 ERR trap 告警卡到开发机私聊，
      侧证告警链路是通的。
- [x] 2.4 新增 `bin/test/fn-factcache.sh` 并挂进 `check-scripts.sh` 第 8 项
      → 验：`bash bin/check-scripts.sh` 输出里出现该夹具名且通过

## 3. 模型路径改为被回写（`bin/fetch-snapshot.sh`）

- [x] 3.1 重试循环之后、落盘校验之前，按 `snapshot.json` 逐 issue 调用共享函数回写观测字段
      → 验：`CRASH_REPORT_SKIP_ANALYSIS=` 不设、跑一次 L1，全部 issue 的 `last_synced` 差值 < 1 分钟
- [x] 3.2 `FACT_CACHE_POLICY` 删去「判定二」整段，改为「观测字段由调用方回写，不要写」
      → 验：`grep -c 'last_synced' bin/fetch-snapshot.sh` 只剩回写代码里的引用，prompt 段为 0
- [x] 3.3 回写失败（`jq` 非零）必须计入现有隔离/告警路径
      → 验：故意放一个非法 JSON 进 `issues/`，跑一轮，日志出现隔离提示且计数 +1
      **2026-09-08 以密封夹具验**（`bin/test/fn-fetch-snapshot-shell.sh`，用脚本自带的
      `AGENT_CMD` 钩子把模型换成桩，零模型调用）：坏文件 → 回写「写入失败 1 条」+ 隔离到
      `backup/corrupt-issues-*` + 从 `issues/` 移除；⛔ 双向测试通过——把回写打回 stderr、
      或让缺文件补建，夹具各自变红 3 条。
- [x] 3.4 `bash bin/check-scripts.sh` 通过（⚠️ 第 7 项：新函数的 source 必须早于首次调用）

## 4. 断言（`bin/test/assert-fact-cache.sh`）

- [x] 4.1 `last_synced` 改判时刻差值（容差 30 分钟），不再比日期前缀
- [x] 4.2 **双向测试**（夹具直跑，`CRASH_REPORT_STATE_DIR` 指临时目录）：
      真 UTC 本轮 → ✅ · 真 UTC 上一轮 → ❌ · 本地时间标 Z → ❌
      → 验：三条断言的退出码分别是 0 / 1 / 1。⛔ 第三条是本 change 的核心回归——
      改前它在 L1 场景**会误过**
- [x] 4.3 新增内容覆盖率输出行（非 gating），格式含「声称 N / 实存 M」
      → 验：当前生产数据下输出「声称 55 / 实存 6」量级的数字，且退出码不因它改变

## 5. 跑批验证

- [x] 5.1 `CRASH_REPORT_NO_DELIVER=1 bash bin/crash-daily.sh` 整跑（⚠️ 5 分钟以上，别设短超时）
      **2026-09-08 开发机实测**：rc=0 · 8 个 issue 的 last_synced 全为同一真 UTC 时刻 06:09:21Z ·
      未来时刻 0 条 · 模型日志自述「五个观测字段原样未动」· 增量抓取仍生效（3e827b74 80→83 条）
      → 验：全部 issue 的 `last_synced` 是真 UTC 且属本轮；卡片无「事实层缓存未刷新」告警
- [x] 5.2 ⚠️ L2 需在**周一之外**验：`CRASH_REPORT_NO_DELIVER=1` 且**先备份 `last-snapshot.json`**
      （L2 的基线提升在 NO_DELIVER 闸门之前）
      → 验：shell 写 → 模型跑 → 断言 三步后 `last_synced` 仍是 shell 写的那一个时刻
      **2026-09-08 开发机实测**：rc=0 · bq 路径「记录: 更新 8 条」· 回写行「8 条」可见 ·
      8 个 issue 同一真 UTC 时刻 `06:27:53Z` · 断言通过（周报无 🟡 事实层提示）·
      台账渲染正常 · 四个基线文件已 diff 后还原
- [ ] 5.3 生产首个跑批日按 `.claude/skills/morning-verify/` 四项核验
      → 验：调度层 / 健康层 / 审计层三项通过，且事实层告警消失
- [ ] 5.4 记录本 change 落地后的首个覆盖率数字，写进 `findings.md`
      → 验：有数字。⛔ 覆盖率不达标**不算本 change 失败**——它是 Non-goal，另起 change 修
