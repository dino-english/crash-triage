## 0. 拍板（未完成前不动 bin/）

- [x] 0.1 用户拍板 design Q1–Q5，结论与日期写回 design「Open Questions」
- [x] 0.2 Q5 的两个缺陷：用户 2026-10-11 指示一并修复
  - 「入选」列串值：`main_versions` 只取前 3 列（latest-versions.sql 09-17 起为 5 列），夹具 fn-version-alignment.sh ④ 用真实 5 列形状；旧代码 5 失败 / 新代码全过
  - docs 提交误判修复：`scan-fix-commits.sh` 跳过 docs / test(s) / ci / style 类型（chore 刻意保留），夹具 fn-fix-scan.sh ⑨⑩；旧代码 2 失败 / 新代码全过

## 1. 回测分档阈值（只读，生产历史）

- [x] 1.1 取生产 `runs/*/L1/latest/` 近 14 天的 issue 表 + `fixmap.json`，按 D1 规则离线算每天 🚨 / ⏳ / 👀 条数（脚本放 scratchpad，不入库）
- [x] 1.2 对比 `TIER_NEW_MIN` ∈ {1,2,3}、`TIER_LONG_MIN` ∈ {3,5,8} 的分布；把表与选定值记入本文件，回 design 改 Q2
  - 2026-10-11 生产 09-26~10-11 共 16 轮：修了仍在且近期有事件 0–3/天；未修 ≥2 台 1–5/天、≥3 台 1–3/天、≥5 台 0–2/天、≥8 台 0–2/天 ⇒ 选 2 / 5（🚨 约 1–4/天）。⚠️ 近似：含性能兜底列版本、无当日生命周期基准
- [ ] 1.3 抽 3 天人工复核（⚠️ 未做：只核了 10-11 一天，85c581ed / 8bc4b97e 等逐条与生产 fixmap 对过）：🚨 里每条是否真该开发动手、👀 里有没有漏掉该动手的

## 2. 取数

- [x] 2.1 平台整体慢帧 / 冻结 3d 值：`perf-screens` 同文件加平台级输出或新 SQL（`AVG(screen_info.*_ratio)`，3d 完整日窗口，`app_display_version IN ({{VERSIONS}})`）；⛔ 不与 1d 字段混存
- [x] 2.2 新增 `bin/sql/perf-startup-by-os.sql`：`_app_start` 按系统版本分桶输出 `n / p50 / p95 / slow_gt_red`；桶 n < 20 时 P95 置 null
- [ ] 2.3 2.1 / 2.2 在生产项目 dry-run 扫描量与实跑耗时，记入本文件（⚠️ 未做：只实跑过，耗时数秒级，未取 dry-run 字节数）
- [x] 2.4 iOS `_app_start` 的 `os_version` 分布实测，定 iOS 分桶（双端分别验，覆盖率写入本文件）
  - 2026-10-11 iOS 1.8.2（10-05~07）：26 1130 / 27 103 / 18 192 / 17 67 / 16 22 / 15 12 次——按主版本分桶即可，无需另定档
- [x] 2.5 下钻只在亮红时调用；SQL 走 `q_render` / `bqq`（等价性缓存可覆盖）

## 3. 核心纯函数 `bin/lib/core/tier.sh`

- [x] 3.1 `tier_of_issue`（jq）：输入 issue 行（台数、生命周期、开关态）+ fixmap 条目 + 阈值，输出 `urgent|release|watch` 与「为什么」短句；优先级 🚨 > ⏳ > 👀
- [x] 3.2 `light_per_platform`：每个数字独立判灯，复用 `traffic_light()` 与 crash-free 坏方向判定
- [x] 3.3 `priorities_validate`（jq）：D2 校验；输出合规条目或回落原因
- [x] 3.4 夹具（`bin/test/harness.sh` 生产 shell 设置下）用 2026-10-11 生产数据作期望：`85c581ed`→🚨（修了仍在 + 7 天 2 台）；`62f88f39` `4d05f9e7`→ 非 🚨（7 天报告版本集内 0 台）；`8bc4b97e`→⏳ 第一；`3c8c9ac8` `a086ba79` `af63b03d`→👀；`release_check != ok`→ 不进 🚨①与 ⏳
- [x] 3.5 夹具：iOS 慢帧 45.1%（最差页）不陪 Android 标红；`priorities.json` 含快照外 id → 剔除；非法 JSON → 回落
- [x] 3.6 双向测试：每条新检查「违规样本变红 + 全量代码不误报」
  - 两个数据缺陷的新夹具对旧代码跑过（变红）；core-tier 断言含负向用例

## 4. L1 卡片（`crash-daily.sh`）

- [x] 4.1 `grep -n` 数清 `build_card_table` / 摘要行 / `ROW_DEFS*` 全部调用点（口径文档 :391-434 的 6 处），列入本文件后再改
- [x] 4.2 新卡片构建：header 随最高档；🚨 色底块 + 按钮；⏳ 首条色块 + 其余进面板（markdown 表格）；👀 面板（含原「影响集中 / 系统版本最差 / 归因」三行，改 markdown 表格）；健康度面板（D4）；下钻图（D5）
- [x] 4.3 删除旧单表与 🔴/🟡 摘要行渲染；⛔ 文档侧 `ROW_DEFS_DOC` 路径不受影响
- [x] 4.4 全角括号 / `·` 先条件赋值再拼接（⛔ `${var:+（...）}`）
- [ ] 4.5 首轮注记（⚠️ 未做：判灯口径变更的首周注记尚未实现）「慢帧 / 冻结判灯改为平台整体值（原为最差页）」，带截止日期常量，一周后自动不出

## 5. L1 文档

- [x] 5.1 「一、今日要点」三档（DocxXML callout 红 / 橙 / 灰；md2docx 上色规则）
- [x] 5.2 issue 明细加「分档」列；四条明细渲染路径（md / DocxXML / 台账现状表 / 时间线，F14b）只动前两条
- [x] 5.3 口径注解挪位不删（本 change 实际未挪动任何既有注解，只在首屏新增「今日要点」；待 8.4 读回时复核）：改前后 `grep -c` 每条注解关键句，数目一致

## 6. L2（`fetch-snapshot.sh` / `crash-weekly.sh`）

- [x] 6.1 full prompt 增加 `priorities.json` 契约（字段、枚举、只写快照内 id）；⛔ 不进成功判据（`fetch-snapshot.sh:320-323` 与 `crash-weekly.sh` 两端一致）
- [x] 6.2 卡片重排为 W2 版式：🚨 来自校验后的 P0/P1；🔧 修复进度（四态计数 + 修了仍在面板）；本周变化一行计数 + 面板；健康度带 WoW；下钻图
- [x] 6.3 commit 只取 subject 首行
- [x] 6.4 文档首屏「本周必修」+ 修复进度；分析层原样追加，⛔ 不改标题层级；跑 `split-fix-list.py` 确认修复清单仍被分组
- [x] 6.5 Q4：P95 趋势图改主力版本 + 样本闸门（拍板后）
- [x] 6.6 `priorities.json` 三种情况：合规 / 缺失 / 编造 id
  - 编造 id 与合规：L2 整跑 + AGENT_CMD 桩（混入快照外 id → 「已剔除 1 条」）；缺失：SKIP_ANALYSIS 整跑走规则回落；非法 JSON / 短 id / 非法优先级：core-tier.sh 断言。⚠️ 未用 HOME 替换（整跑需要真实 HOME 的 bq / lark 凭证）

## 7. 文档同步

- [x] 7.1 `docs/CLAUDE-架构与数据口径.md`：「卡片的能力边界」补 column_set 色底 / 折叠面板 / markdown 表格 / table 不进面板；「卡片：单表」「摘要行」标注被本 change 取代，**保留踩坑记录**
- [x] 7.2 `.claude/skills/crash-report-design/SKILL.md` 模块清单同步三档结构

## 8. 验证（⛔ 全部完成前不提交、不提议部署）

- [x] 8.1 `bash bin/check-scripts.sh` 十项全绿
- [x] 8.2 L1 整跑 `CRASH_REPORT_NO_DELIVER=1`（超时 ≥10 分钟；⛔ 跑批期间不改 `bin/**`）
- [x] 8.3 L2 整跑前**备份四个基线文件 + LEDGER.md**（L2 的 DRY_RUN / NO_DELIVER 会提升基线），再 NO_DELIVER 整跑
- [x] 8.4 实发私聊：L1 / L2 卡片各一张（先填占位符 URL），`messages-mget` 读回核组件；文档 `docs +fetch` 读回核三档 callout 与「分档」列
- [x] 8.5 用户在客户端核：深色模式（色底块、图表、参考线）、手机宽度（色底块 + 按钮、markdown 表格）、面板内链接可点
  - ✅ 面板内链接可点、深色模式、手机宽度（用户 2026-10-11 确认）
- [x] 8.6 生产只读影子跑：生产 `/tmp` 用生产输入跑新代码，与当天线上产物逐项对照（🚨/⏳/👀 归属、健康度数字、下钻结论），差异逐条解释
- [x] 8.7 以上全部通过后，列出仍未验证项（如有）交用户拍板，再提议部署（走 `deploy-prod` skill）

## 9. 验证记录（2026-10-11）

- 开发机：check-scripts 十项全绿；core-tier 109 断言；L1 DRY_RUN ×3、NO_DELIVER ×1；L2 NO_DELIVER（桩模型路径 ×4、规则回落 ×1）全部 rc=0，L2 跑前后五个基线文件 + ledger 目录均从备份还原
- 卡片实发私聊（ou_）并 `messages-mget` 读回：日报 / 周报各多版，组件齐全；面板内 markdown 表格链接由用户在客户端点击确认可点
- 生产影子跑（/tmp 隔离，STATE 副本 local.env 改指私聊，NO_DELIVER）：L1 / L2 rc=0
  - **真实模型遵守 priorities.json 契约**：6 条全部合规、0 条被剔除（P0 1 / P1 4 / P2 1）
  - 性能数字与当日 08:30 线上产物逐格一致（同一完整日窗口）；崩溃数字差异来自 7d 滚动窗口相差 10 小时
  - 生命周期在生产基准下正确（af63b03d = 长期 → 👀；开发机基准陈旧时被判新增）
  - Q5 两缺陷在生产数据上验证：「入选」列正常；d0dcb015 改挂真实修复提交 `fix(media): 定向规避 Android 16 IJK 音频策略崩溃`
  - iOS 1.9.0 列消失：近 24h 0 会话（与本 change 无关，版本解析未改）
- 文档：用影子跑产物以 bot 新建两份临时文档（不进共享文件夹、不碰索引页 / 台账）并 `docs +fetch` 读回：三档 callout、分档列、本周必修、入选列均在，控制台链接 25 / 32 个；callout 底色读回不可见

## 10. 上线后监控发现的缺陷（2026-10-12 morning-verify）

- [x] 10.1 性能退化误报：上一版 1.8.1 日会话 30 被当基准 → 加会话门槛 `cmp_prev_ver_of`；夹具 `fn-perf-regress-gate.sh`（当日生产数值；旧逻辑 3 失败 / 新逻辑 6 全过；⚠️ 初版夹具因 h_run 子 shell 吞全局变量是假绿，已改 `_probe`）
- [x] 10.2 生产 /tmp 影子跑（当日真实数据）：🚨 3 → 1（只剩 85c581ed），下钻「对比上一版」不再出现，rc=0
