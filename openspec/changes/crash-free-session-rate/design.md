## Context

动机见 [proposal.md](proposal.md)。这里记 2026-08-22 的实测结论——它们决定了方案形态。

**三条实测（Android，近 7 天）**：

| 测项 | 结果 |
|---|---|
| `firebase_session_id` 覆盖率 | FATAL 105/105、ANR 87/93、NON_FATAL 1020/1020 —— 近 100% |
| `session_id` JOIN 命中 | 62 崩溃事件中 52 条在 sessions 表中找到对应会话 = **83.9%** |
| `installation_uuid` ↔ `instance_id` | **0 行匹配** |

**用户标识不同源，不是格式问题**：

```
crashlytics.installation_uuid   B7207A8BD14B3E463FF610FEB60F77C5…   64 字符 十六进制大写
sessions.instance_id            dG2Kzp0MRX-Ycd2VVBGfQb              22 字符 base64url
```

前者是 Crashlytics 自己的安装标识，后者是 Firebase Installation ID。**两个 ID 体系，无映射关系。**

**样本量**：近 7 天 Android 总会话 8498、总安装 4846、崩溃会话 61 → crash-free 会话率约 **99.28%**。

## Goals / Non-Goals

**Goals:**

- 给出一个能与外部对话的稳定性指标。
- 让它的**局限同样可见**——只有会话口径、且是下界估计。

**Non-Goals**（proposal 已列，此处只加设计级边界）：

- **不试图用其他字段拼出用户口径**（如用 `device.model + os_version` 做模糊匹配）。那会造出一个来源不明、精度未知的数字，比没有更危险。

## Decisions

### D1：不 JOIN —— 分子分母各表独立聚合

**选择**：

```
分子 = crashlytics 侧 COUNT(DISTINCT firebase_session_id)  WHERE error_type='FATAL' AND 版本过滤
分母 = sessions     侧 COUNT(DISTINCT session_id)          WHERE 版本过滤
```

两表都有 `application.display_version`，各自过滤即可，**不需要 JOIN**。

**否决 JOIN 方案**：JOIN 会把命中率的 83.9% 直接变成误差——未命中的 10 个崩溃会话会从分子里消失，crash-free **被高估**。而高估是最坏的方向：报告说「99.4% 干净」，实际更低。

不 JOIN 则那 10 个会话照常计入分子，代价是分子可能包含分母里没有的会话，**失真方向变成低估**——保守，可接受，且必须标注（见 D3）。

**附带好处**：不 JOIN 意味着不需要跨表扫描，查询成本与现有崩溃 SQL 同量级。

### D2：口径限定 FATAL，与行业定义对齐

ANR 与 NON_FATAL 不计入。Firebase 的 crash-free 就是这么定义的，混入会让这个指标失去它唯一的存在理由——对外可比。

ANR 有自己的率（change `crash-error-type-coverage`），NON_FATAL 给绝对数。**三者并列呈现，各自口径清楚。**

### D3：把「只有一半」写在报告上

这是本 change 最重要的一条，也是最容易被省略的。

Firebase 控制台首屏、App Store Connect、Play Console 给的都是 **crash-free 用户率**。我们只能给**会话率**。两者数值不同——用户率通常更低（一个用户在任意一个会话崩过就算作非 crash-free）。

**做 crash-free 本是为了对齐外部，结果只对齐了一半。** 不说清楚，就会有人拿 99.28% 去对照控制台的用户率数字，得出「我们比控制台显示的好」的错误结论。

报告上必须写两句：
1. 本值为**会话**口径，与控制台首屏的用户口径不同，不可直接对照；
2. 本值为**下界估计**（D1 的失真方向），真实值不低于所示数字。

**否决「先上线，标注后补」**：一个看起来可比而实际不可比的数字，比没有这个数字更糟。标注与数字同时上线，或者都不上线。

### D4：阈值取 99.5%，标为业界常见健康线

红线 `CRASH_FREE_RED=99.0`、黄线 `CRASH_FREE_YELLOW=99.5`（**方向与其他指标相反：低于阈值才是坏**，`traffic_light()` 的调用需注意参数方向）。

实测 Android 99.28% 落在黄档、iOS 接近 100%。

⚠️ `traffic_light()` 现有语义是「大于红线 → red」。crash-free 是越大越好，**直接套用会把 100% 判成红档**。实施时要么传入 `100 − 值` 反转，要么给该函数加方向参数——**这是本 change 最容易出的一个错，且它不会报错，只会安静地把最健康的版本标红**。

### D5：crash-free **不进摘要行**（实施中决定，可证明冗余）

摘要行不加 crash-free。**理由是可以证明的**，不是版面取舍：

事件数 **≥** 崩溃会话数（同一会话可崩多次），分母相同，故

```
崩溃会话率 ≤ 事件率（= 现有崩溃率）
```

于是 **crash-free 落红档（崩溃会话率 > 1%）时，崩溃率必然已经落红档**。
加进摘要行只会对同一批崩溃事件报两次警。

反方向不成立（崩溃率红而 crash-free 绿）是有意义的信息——它说明「崩溃集中在少数会话里」——
但那属于表格里两行并读的判断，不是告警。

### D6：`verdict_line` 必须按颜色分类，不能按箭头（实施中发现的既有缺陷）

结论行原先按**箭头方向**归类（`↑`→变差、`↓`→变好），等价于假设**所有指标都越小越好**。
crash-free 是 `higher_better`，实测被判反：`✅ 变好 Crash-free 会话 -5.37pp ↓`（99.66% → 94.29%）。

`delta_cell` 本就把「**箭头跟数值方向、颜色跟好坏**」分开编码了，是 `verdict_line` 在匹配前
把颜色标签 `sed` 掉、只剩箭头可看。改按颜色分类即可。

⚠️ **顺带修掉一个既有缺陷**：`会话数` 是 `neutral`（`delta_cell` 刻意不上色）却照出箭头，
于是「会话数 -1179 ↓」也被归进「✅ 变好」。改判定依据后它不再进任何一栏——
这是修正不是回归（neutral 本就不该判好坏），但属于本 change 范围外的顺带修复。

## Risks / Trade-offs

| 风险 | 缓解 |
|---|---|
| **阈值方向套反，把 100% 判成红档** | D4：反转值或加方向参数；用例必须覆盖「100% → green」与「98% → red」两端（`crash-perf-functional-core` 的 `traffic_light` 用例可一并加） |
| **有人拿会话率对照控制台的用户率** | D3：两句标注与数字同时上线，缺一不可 |
| **crash-free 被当成取代旧崩溃率** | spec 已要求两者并存；旧指标的历史序列不能断 |
| **分子含分母外的会话导致率略低** | D1 已选择这个方向（保守）；D3 标注为下界估计 |
| **iOS 侧未实测** | 本 change 的实测数据全部来自 Android。iOS FATAL 近 14 天仅 4 条，样本极小，`session_id` 覆盖率与命中率**未验证**——列为 tasks 的独立一项 |

**接受的取舍**：本 change **不能回答「我们的 crash-free 用户率是否达到商店门槛」**。它只能回答「多少会话是干净的、趋势如何、哪个版本更差」。前者需要两个数据源共用用户标识，属于客户端埋点范畴。

## Migration Plan

无迁移。新增字段进 `metrics-history.jsonl`，旧行缺该键属正常。

**回滚**：`git revert`。

## Open Questions

无。用户标识不同源已由实测确证，不是待验证项。
