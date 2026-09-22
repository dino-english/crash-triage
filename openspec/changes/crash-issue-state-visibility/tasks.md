## 1. 取数

- [x] 1.1 `fetch-issue-states.py` 增 `--extra-ids <文件>`：逐行 id，**只查缓存里没有的**
      → verify：传一个已在缓存里的 id，MCP 调用次数不增加
- [x] 1.2 增 `--emit-map <文件>`：输出 `{id: state}`（缓存态 + 本次补查），⛔ 不改 stdout 既有契约
      → verify：`crash-weekly.sh` 那个不带新参数的调用点行为逐字节不变
- [x] 1.3 ⛔ 事实层为空时**不得**早退出：`--extra-ids` 仍要跑
      → verify：空 STATE 目录 + 1 个 extra id，map 里有该 id

## 2. 日报渲染（两个定义点，F35）

- [x] 2.1 `ISSUE_STATES_JSON` 默认 `{}` 在 `life_tag` 之前赋值（⛔ 第 7 项「先用后定」）
- [x] 2.2 `issue_state_cell()` 实现 D2 的四态
- [x] 2.3 `issues_table`（markdown）：「状态」→「生命周期」，新增「开关」列
- [x] 2.4 `xml_issues`（DocxXML）：同上，**且链接列规格 8 → 9**
      → verify：产出的 `<a href>` 仍指向 `issue_url_prefix + 32 位 id`
- [x] 2.5 状态同步后重建 `ISSUE_STATES_JSON`（缓存 + emit-map）

## 3. 台账

- [x] 3.1 `render-ledger.sh` 认 MUTED → `🔕已静音`，与 CLOSED 分支对称（带 commit 时括注）
      → verify：造一条 MUTED + 有 fix commit 的输入，不渲染成「已修待验」

## 4. 验收

- [x] 4.1 `bash bin/check-scripts.sh` 十项全过
- [x] 4.2 函数级夹具：`issue_state_cell` 四态各一条 + 「其他值原样透传」一条，
      跑在 `bin/test/harness.sh` 生产 shell 设置下
- [x] 4.3 ⛔ **双向测试**：摘掉 `xml_issues` 里的开关列调用 → 夹具必须变红；还原 → 恢复绿
- [x] 4.4 `CRASH_REPORT_NO_DELIVER=1 bash bin/crash-daily.sh` 整跑 rc=0（2026-09-22 12:13→12:20）。
      ⛔ 不肉眼扫：先从 BigQuery 算出期望清单再逐行机器比对，**10 行 10 中 0 不符 0 多出**——
      `✅已关闭` 4（`fb6588bb` 9次/6台 · `227fc097` 10次/4台 · `ffb557a4` · `d85cbe82`）·
      `🔕已静音` 1（`579db247`）· `开启` 5。**零个「？未取到」**。
      状态同步日志：`32 条（CLOSED 20 · MUTED 1 · OPEN 16） · 补查 5 条`——⇒ 补查路径真的在起作用：
      `e8a9ce84` 事实层文件缺失（断言另有报告），照样渲染出 `开启`。
      ⚠️ 同轮 `MCP 对照（OPEN FATAL · 全版本）：iOS 1 类 1 次 · Android 4 类 16 次`，
      与手工调 `crashlytics_get_report` 的结果逐字吻合——**控制台只看得到 16/51 次事件**。
- [x] 4.4b DocxXML 路径独立核：表头 8 列正确；24 条 issue 链接**末段全是 32 位 hex，0 条坏链接**
      （链接列规格 8→9 若改漏，这里会全部指向「最新」列）；开关列取值与 markdown 逐行一致
- [~] 4.5 列宽实发验证：**判定为非阻塞**。本 change 不改卡片（卡片上没有 issue 明细表），
      文档表格从 7 列变 8 列——而 8 列并非新形态（周报版本对照表已是 10 列，长期在用）。
      ⚠️ 仍留一条部署日动作：首个生产跑批后扫一眼飞书文档里这张表有没有被挤压。
