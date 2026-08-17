# Explore Notes — crash-perf-card-table-v2（CardKit v2 原生 table + 单元格红绿灯）

> 本文件由 explorer 需求结晶产出，供 propose 阶段（架构师）作为唯一需求依据。
> 现状基准：`bin/crash-daily.sh`（与 `scripts/crash-report/crash-daily.sh` 逐字节一致，diff 实测 IDENTICAL）+ `state/publish/card.json`（v1 卡片，4143 字节，无 table 组件）。
> 需求定性：**纯展示层重构**，不动任何 SQL / 数据计算 / 接口路径。后端数据管道（DoD/WoW、受影响安装数、阈值常量、慢帧口径、sparkline）已在 `crash-perf-daily-monitoring-enhancement` 落地，本次直接复用。
> 文档取证：全部结论均来自飞书官方文档（open.feishu.cn 纯 Markdown 版 `.md` 端点）+ GitHub 参考实现源码，见各节证据链接。

---

## 1. 五项技术验证结论

### V1｜CardKit v2 `table` 组件确切 schema + 单元格级样式结论（红绿灯前提）

**证据**：官方《表格组件》JSON 2.0 文档
`https://open.feishu.cn/document/feishu-cards/card-json-v2-components/content-components/table`（Lark 国际版镜像同路径，`.md` 后缀可直读）

**完整 schema（官方 Demo 节选，字段以官方字段说明表为准）：**

```json
{
  "schema": "2.0",
  "body": {
    "elements": [
      {
        "tag": "table",
        "element_id": "custom_id",
        "margin": "0px 0px 0px 0px",
        "page_size": 5,                 // 每页最大行数，[1,10] 整数，默认 5
        "row_height": "low",            // low | middle | high | auto | [32,124]px
        "freeze_first_column": false,
        "header_style": {               // 仅作用于表头
          "text_align": "left",
          "text_size": "normal",
          "background_style": "none",   // grey | none
          "text_color": "grey",         // default | grey
          "bold": true,
          "lines": 1
        },
        "columns": [
          { "name": "metric", "display_name": "指标", "data_type": "text", "width": "auto" },
          { "name": "ios", "display_name": "iOS", "data_type": "lark_md", "width": "auto" }
        ],
        "rows": [
          { "metric": "崩溃率", "ios": "<font color=red>1.44%</font>" }
        ]
      }
    ]
  }
}
```

**字段要点：**

| 层级 | 字段 | 说明 |
|---|---|---|
| table | `columns`（必填） | 列定义数组；列 key `name` 必填，行数据按 `"name": VALUE` 填格 |
| table | `rows`（必填） | 行对象数组，键名必须与 `columns[].name` 一致（错误码 200915 即此校验） |
| table | `header_style` | 表头样式：`text_align` / `text_size`(normal\|heading) / `background_style`(grey\|none) / `text_color`(default\|grey) / `bold` / `lines` |
| column | `data_type` | `text`(默认) \| `lark_md` \| `options` \| `number` \| `persons` \| `date` \| `markdown`；`number` 可配 `format{precision,symbol,separator}`，`date` 可配 `date_format` |
| column | `width` | `auto` \| [80,600]px \| [1,100]%；`horizontal_align`/`vertical_align` 列级对齐 |
| column | `display_name` | 表头展示名；为空则不展示列名 |

**单元格级样式——核心结论（§3 红绿灯前提）：**

1. **`table` 组件没有任何「单元格级」样式属性**。`text_color` / `background_style` 只存在于 `header_style`，且只作用于表头一行；`columns` 只有对齐/宽度/数据格式，没有 per-cell 颜色。
2. **单元格文字颜色可行**：`data_type: "lark_md"` 的单元格支持 lark_md 语法（官方文档明确「支持部分 markdown 格式的文本，详情参考普通文本-lark_md 支持的 Markdown 语法」），其中**彩色文本语法 `<font color=red>红色</font>` 官方明确支持**（v1/v2 普通文本文档的语法表均有此行）。v2 富文本（markdown）组件同样支持 `<font color=red>…</font>` 且支持嵌套（v2 更新说明的 HTML 语法清单）。→ 红绿灯 = 在 lark_md 单元格里对数值包 `<font color=red|orange|green>`。
3. **单元格「背景色」不可做**：官方无单元格背景属性。近似替代为标签形态：`data_type: "options"` 单元格（`[{"text":"超阈值","color":"red"}]` 彩色 pill）或 lark_md 内 `<text_tag color='red'>超阈值</text_tag>`（色 chip）。注意 options 标签文本过长会显示不全（官方注意事项），不适用于数值行。
4. 颜色枚举（`<font color>` / options / text_tag 通用）：`blue / wathet / turquoise / green / yellow / orange / red / carmine / violet / purple / indigo / grey`（text_tag 另有 neutral、lime）。文档《颜色枚举值》：`https://open.feishu.cn/document/feishu-cards/enumerations-for-fields-related-to-color`
5. **渲染验证缺口**：`<font color>` 是 lark_md 语法层面官方支持，但官方表格文档的 lark_md 示例只给了链接。**表格单元格内实际渲染建议 implement 阶段先发一张带色测试卡实投验证**（DRY RUN `jq empty` 只能验 JSON 合法性，验不了渲染）——见 §5 风险 R1。

**参考开源实现佐证**：`https://github.com/chapaofan/Hermes-feishu-to-table`（feishu.py `_build_table_card`）——columns 全 `data_type:"text"` + `header_style{bold:true}`，**只实现了表头加粗，未做单元格级颜色**（与任务描述一致），从侧面印证「单元格颜色必须走 lark_md/options 内容层，没有样式属性可用」。注意其 README 示例在 v2 卡片里仍写 `config:{"wide_screen_mode":true}`，与官方 v2 config 文档冲突（v2 无此字段且未知属性报错），**不可照抄**。

### V2｜CardKit v2 限制核实（5 table / 50 列）

**证据**：同表格文档「注意事项」+「列」字段说明 + v2 结构文档。

| 限制 | 官方原文 | 本次用量 | 余量 |
|---|---|---|---|
| 单卡最多 table 组件数 | 「单张卡片最多支持放置五个表格组件」（多语言则单语言 5 个） | 2 | ✅ 3 余 |
| 单表最多列数 | 「最多支持添加 50 列，超出 50 列的内容不展示」 | 3（指标/iOS/Android） | ✅ 47 余 |
| 单卡最多元素/组件数（v2） | 「一张卡片最多支持 200 个元素（如 tag 为 plain_text 的文本元素）或组件」 | < 30 | ✅ |
| 表格嵌套 | 「表格组件不可被内嵌在其它组件内，只可放在卡片根节点下」 | 2 表放 `body.elements` 根 | ⚠️ 见 V4 |
| 消息体上限 | im/v1 创建消息：「卡片消息、富文本消息请求体最大不能超过 30 KB」 | 现 4.1KB，加表后预计 < 10KB | ✅ |

另：`page_size` 默认 5 —— 我们的表行数可能 >5（性能表约 6–8 行），**须显式 `page_size: 10` 或接受分页**（展示细节，propose 定）。

### V3｜投递链路兼容（im_v1_message_create 能否投 schema 2.0；v1 元素在 v2 下可用性）

**证据**：官方《发送消息》`https://open.feishu.cn/document/server-docs/im-v1/message/create` + 本机 lark-mcp 工具 schema（`mcp__lark_mcp__im_v1_message_create`）。

1. **接口本身不感知 schema 版本**：`POST /open-apis/im/v1/messages`，`msg_type:"interactive"`，`content` = 卡片 JSON 序列化字符串。`schema:"2.0"` 是卡片 JSON 内部声明，同一接口原样投递。官方错误码表里 200861（`cards of schema V2 no longer support this capability; unsupported tag`）与 11310（`element exceeds the limit`）都针对 v2 卡片，证明该接口就是 v2 卡片的投递通道。→ **投递链路兼容，无需改接口/改投递方式**。
2. **30KB 上限**：官方「卡片消息、富文本消息请求体最大不能超过 30 KB」，与任务给定一致；现卡 4.1KB，迁移后远低于上限。
3. **v1 元素在 v2 的可用性**（详见 V4 迁移清单）：
   - `header{template:red/blue}` → **v2 保留**（v2 结构文档 header.template 枚举同 v1：blue/red/grey/…）。
   - `markdown` → **v2 保留**（tag 仍 `markdown`，且 v2 富文本支持标准 Markdown + 更多 HTML，`<font color>` 嵌套可用）。
   - `hr` → **v2 保留**（组件页在 v2 下叫「分割线 divider」，tag 仍为 `hr`）。
   - `column_set` → **v2 保留**（分栏容器；v2 容器可内嵌除 form/table 外所有组件）。
   - `note`（备注）→ **v2 已废弃**（见 V4），必须改写。
   - `config.wide_screen_mode` → **v2 无此字段**，必须改 `width_mode`。

### V4｜v1 → v2 迁移范围（保留 / 改写清单）

**证据**：《卡片 JSON 2.0 版本更新说明》`https://open.feishu.cn/document/uAjLw4CM/ukzMukzMukzM/feishu-cards/card-json-v2-breaking-changes-release-notes` + 《卡片 JSON 2.0 结构》`https://open.feishu.cn/document/feishu-cards/card-json-v2-structure`。

**全局结构迁移（必做）：**
- 顶部加 `"schema": "2.0"`（v2 必须显式声明，默认 1.0）。
- `elements` 移到 `body.elements` 下（v2 新增 body 层；不再支持顶层 `i18n_elements`）。
- `config.wide_screen_mode:true` → **删除**，改用 `config.width_mode:"fill"`（fill=撑满聊天窗口宽度；v2 默认宽 600px）。**v2 校验更严：传入不支持的属性将报错**（1.0 忽略、2.0 报错）——迁移必须全量清理 v1 专有字段，残留一个就整卡 230099。

**当前卡各元素的迁移结论：**

| 当前元素（card.json） | v2 结论 | 动作 |
|---|---|---|
| `config.wide_screen_mode` | v2 无 | 改 `width_mode:"fill"` 或省略 |
| `header.template`（red/blue） | 保留 | 原样 |
| `markdown`（顶部摘要 / 板块标题 `<font color>` / 放量 / 详情链接） | 保留 | 原样（v2 markdown 支持 `<font color>` 嵌套） |
| `hr` | 保留 | 原样（v2 文档页名 divider，tag 仍 hr） |
| `column_set` bisect（iOS\|Android 两栏 markdown） | 保留组件，**但内容需重构** | 两个性能/崩溃 table 不能放 column_set 内（table 只可在卡片根），**表格直接放 body.elements 根，column_set 不再承载表格内容** |
| `note`（底部口径注释） | **v2 废弃** | 官方替代方案：普通文本组件配置 `text_size:"notation"` + `text_color:"grey"`（= `div` 组件，12px 灰字）——恰好同时满足需求 10「口径说明字号调小、颜色变浅」 |
| `plain_text`（note 内） | 保留（div.text.tag） | 随 note 改写为 div |
| markdown 差异化跳转 `$urlVal` | v2 废弃语法 | 本卡未用，无影响 |

**客户端版本门槛（迁移的硬约束）**：v2 结构要求客户端 ≥ 7.20；低于 7.20 的客户端「卡片标题可正常显示，但内容将展示兜底的升级提示文案」。→ 收卡成员客户端版本需确认（见 OPEN QUESTIONS Q3）。

### V5｜深色风格结论（「保留深色卡片风格」实际指什么）

**证据**：《卡片 JSON 2.0 结构》config 段 + 普通文本组件 text_color 字段说明。

1. **CardKit 没有 `config.theme` / 深色主题开关**。深色观感 = **跟随客户端主题自动生效**：`text_color:"default"` 在浅色主题下为黑色、深色主题下为白色；header `template` 色、table header `background_style:"grey"` 等均由客户端主题适配。
2. v2 唯一与主题相关的显式能力是 `config.style.color`：可为自定义颜色名分别配 `light_mode` / `dark_mode` 的 RGBA 值，供组件引用。**我们不需要**。
3. **结论**：现 card.json 本就没有任何显式深色配置（无 `theme`、无写死的浅色专属色），「深色卡片风格」实际 = 保持使用主题自适应色（header template + default 文本色 + `<font color>` 枚举色），**不要引入写死的浅色/深色专属 RGBA**。迁移后深色模式外观自动保持。表格 header 用 `background_style:"grey"`、正文单元格用 default/lark_md 枚举色，深浅主题都可读。

---

## 2. 卡片新结构建议 schema（性能 table + 崩溃 table 草案）

> 草案供 propose 阶段采纳/调整；结构事实（哪些字段存在）以 V1 官方 schema 为准。

```
┌───────────────────────────────────────────────┐
│ header: 📊 08-16 崩溃 & 性能  (template=red|blue) │
├───────────────────────────────────────────────┤
│ [markdown] 顶部摘要：仅展示触发阈值(红/黄)的指标行 │  ← 需求7
│ [markdown] 💥 崩溃（font red）                  │
│ [table#1]  崩溃表  行=指标  列=指标|iOS|Android  │  ← 需求2/3/4/6
│ [markdown] ⚡ 性能（font blue）                  │
│ [table#2]  性能表  行=指标  列=指标|iOS|Android  │
│ [markdown] 🚀 放量（font green）+ 版本会话段落    │  ← 保留三层结构
│ [hr]                                           │
│ [div] 底部口径注释（notation 字号 / grey 色）     │  ← 需求5/10，替代废弃的 note
│ [markdown] 📄 [详情](__DETAIL_URL__)            │  ← 保留
└───────────────────────────────────────────────┘
```

**崩溃表（table#1，建议 `page_size:10`）**：

```json
{
  "tag": "table",
  "page_size": 10,
  "row_height": "low",
  "header_style": { "text_align": "left", "text_size": "normal", "background_style": "grey", "text_color": "default", "bold": true, "lines": 1 },
  "columns": [
    { "name": "metric", "display_name": "指标", "data_type": "text", "width": "auto", "horizontal_align": "left" },
    { "name": "ios", "display_name": "iOS", "data_type": "lark_md", "width": "auto", "horizontal_align": "left" },
    { "name": "android", "display_name": "Android", "data_type": "lark_md", "width": "auto", "horizontal_align": "left" }
  ],
  "rows": [
    { "metric": "崩溃次数", "ios": "3 类 4 次", "android": "<font color=red>8 类 60 次 ↑</font>" },
    { "metric": "崩溃率", "ios": "0.27% (4/1487)", "android": "<font color=red>1.44% (60/4154)</font>" },
    { "metric": "受影响安装", "ios": "4", "android": "55" },
    { "metric": "环比 DoD", "ios": "<font color=green>-0.05pp ↓</font>", "android": "<font color=red>+0.12pp ↑</font>" },
    { "metric": "环比 WoW", "ios": "", "android": "<font color=orange>+0.80pp ↑</font>" }
  ]
}
```

**性能表（table#2，建议 `page_size:10`）**：行 = 启动 P50 / 启动 P95 / 慢帧最差页 / 冻结率 / 接口错误率，各平台列同样 lark_md + 红绿灯着色；DoD/WoW 可作为每指标的相邻行（同格内两行或独立行，propose 定版式）。

**红绿灯单元格着色草案（§3 落地方式）：**

| 档位 | 判定（读脚本常量） | 单元格写法 |
|---|---|---|
| 🔴 红（超阈值） | `值 > RED` | `<font color=red>1.44% ↑ +0.12pp</font>` |
| 🟡 黄（临近） | `RED ≥ 值 > YELLOW` | `<font color=orange>0.6%</font>`（浅色主题下 orange 对比度优于 yellow，propose 可换 `yellow`） |
| 🟢 正常 | `值 ≤ YELLOW` | 裸值（default 主题自适应色），不包 font |
| WoW 无基准 | 基准为空 | 整字段隐藏（需求 4，不显示「WoW 无基准」） |

- 需求 4 格式 `数值 ↑/↓ 变化量`：数值与变化量同格、整体包一个颜色（如 `<font color=red>1.44% ↑ +0.12pp</font>`）；箭头/变化量沿用脚本 `_dod_wow()` 现有产出（已含 ± 号与 ↑/↓）。
- 可选增强（propose 定）：在 lark_md 单元格追加 `<text_tag color='red'>超阈值</text_tag>` 状态芯片——非必需，且占横向空间。
- 需求 9 样本提示：`⚠️ 样本量小` 可并入该平台单元格尾部（`IOS_SAMPLE_NOTE`/`AND_SAMPLE_NOTE` 已有）。

---

## 3. 需求 11 点与脚本现状核对（后端已落地，直接复用）

| # | 需求点 | 脚本/数据现状（bin/crash-daily.sh 实测） | 本 change 动作 |
|---|---|---|---|
| 1 | 表格改 CardKit v2 原生 table | 现无 table，Markdown 表格问题不存在于现卡（现卡用 markdown 段落） | 新增 2 个 v2 table 组件（V1 可行） |
| 2 | 性能/崩溃各一独立 table，行=指标、列=iOS/Android | — | 2 table × 3 列（V2 余量充足） |
| 3 | 单元格红绿灯 | `traffic_light()` + 红/黄常量已存在（L52-62）；告警走 `red_line` | lark_md 单元格 `<font color>` 着色（V1） |
| 4 | 核心指标 DoD+WoW，`数值 ↑/↓ 变化量`；WoW 无基准隐藏字段 | `_dod_wow()`（L200-208）已产出 DoD/WoW 字符串（含 ±pp/±ms、↑/↓、DoD 对比日期标注）；当前字符串直接拼「WoW 无基准」 | 展示层按基准存在性裁剪 WoW 字段；格式重组 |
| 5 | 表格内不重复日期说明，底部统一一次 | `_dod_wow` 的 `$5` 标注（对比 X vs Y）现在每个单元格都拼 | 单元格去标注，底部 note 统一写一次 |
| 6 | 崩溃率旁保留受影响安装数 | `IOS_AFFECTED`/`AND_AFFECTED` 已有（crash-rate.sql `COUNT(DISTINCT installation_uuid)`） | 表内「受影响安装」行保留 |
| 7 | 顶部摘要只显示异常指标 | `ALERTS` + `add_alert`/`red_line` 已判定；现卡片顶部 5 行全量 🔴 | 摘要 markdown 改为仅渲染命中阈值的行 |
| 8 | 阈值红档：崩溃>1% / 慢帧>50% / 接口错误率>1% | `CRASH_RATE_RED=1.0` ✅、`SLOW_FRAME_RED=50` ✅、**`NET_ERR_RED=0` ⚠️ 与需求「>1%」不一致**（注释：红>0，首版沿用现行为） | 单元格着色读取常量；**冲突见 Q1** |
| 9 | 会话数<30 追「⚠️样本量小」 | `SAMPLE_SESSION_MIN=30` + `IOS_SAMPLE_NOTE`/`AND_SAMPLE_NOTE` 已有 | 并入单元格/平台列 |
| 10 | 底部保留慢帧口径；口径字号小、色浅、分隔线区隔 | `NOTE_MD` 已有慢帧定义 + 三表截止时间戳；现用 note 组件 | note→div（notation 灰字）+ hr 分隔（V4） |
| 11 | 保留：深色风格/三层结构/时间戳/详情链接 | header template + markdown 段落 + `__DETAIL_URL__` 占位 | 全部保留（V5：深色=主题自适应，无显式配置可保） |

---

## 4. 方案对比（实现路径）

| 方案 | 做法 | 范围 | 风险 | 工作量 |
|---|---|---|---|---|
| **A（推荐）** | 整卡迁 v2：schema 2.0 + body.elements + 2 个 table 替换两处 column_set 分栏 + note→div；其余 markdown/hr/header 保留 | 只动 `CARD_JSON` 组装段（L695-717 及 md 拼装函数），数据管道零改动 | v2 严格校验需一次改干净；客户端 ≥7.20 要求 | 中（单文件重构） |
| B | 只加 table 组件，其余保持 v1 结构（不加 schema 2.0） | 最小 | **不可行**：table 是 v2 组件，v1 卡片 JSON 无 table 标签，会解析失败 | — |
| C | 表格内容仍用 markdown 段落 + 字体色（不迁 v2） | 小 | 不满足需求 1/2（requester 点名原生 table），表格化诉求落空 | 小 |

推荐 **A**：table 组件只存在于 v2 结构，迁移 v2 是需求的硬前提；v1 元素中只有 note 需改写，迁移面可控。B 是伪选项（table 必须 v2），C 不满足需求。

---

## 5. 风险与 unknowns（propose/implement 注意，非待答问题）

1. **R1｜表格单元格 `<font color>` 渲染待实投验证**：文档层确认 lark_md 语法支持彩色文本，但无表格场景官方示例。建议 implement 验收第一步：DRY RUN 生成含红绿灯表格的 card.json → 实投一条测试消息 → 确认单元格着色与整体布局后再切正式。DRY RUN 的 `jq empty` 只验 JSON 合法性。
2. **R2｜v2 严格校验**：`wide_screen_mode`、顶层 `elements`、note 等任一 v1 残留 → 整卡报 230099/200861。迁移须全量清理；建议用官方错误码表做验收清单。
3. **R3｜客户端 ≥7.20**：低版本客户端仅显示标题 + 升级提示（内容不展示）。见 Q3。
4. **R4｜双副本同步**：`bin/crash-daily.sh` ↔ `scripts/crash-report/crash-daily.sh` 须同步改（现 diff IDENTICAL，验收复测）。
5. **R5｜page_size 默认 5**：性能表约 6–8 行会分页；需显式 `page_size:10`（行数不超 10 则不出现分页）。
6. **R6｜黄档阈值未拍板**：现 YELLOW 常量注释「待对齐」，但需求 3 要展示🟡——着色即隐含采纳当前值，见 Q2。
7. **R7｜30KB / 200 元素上限**：本卡远低于两者，但加表后建议保留 DRY RUN 打字节数习惯。
8. **R8｜options 标签长文本截断**：官方注意事项；数值不放进 options 单元格（用 lark_md），仅可选状态芯片用 text_tag。

---

## 6. 已核实的官方文档清单（证据索引）

| 主题 | 链接 |
|---|---|
| v2 表格组件 | https://open.feishu.cn/document/feishu-cards/card-json-v2-components/content-components/table |
| v2 整体结构（config/header/body） | https://open.feishu.cn/document/feishu-cards/card-json-v2-structure |
| v2 不兼容变更 & 废弃组件 | https://open.feishu.cn/document/uAjLw4CM/ukzMukzMukzM/feishu-cards/card-json-v2-breaking-changes-release-notes |
| v2 组件概述（hr=divider、column_set、note 缺失） | https://open.feishu.cn/document/feishu-cards/card-json-v2-components/component-json-v2-overview |
| 普通文本/lark_md 语法（含 `<font color>`）v2 | https://open.feishu.cn/document/feishu-cards/card-json-v2-components/content-components/plain-text |
| 富文本 markdown v2 | https://open.feishu.cn/document/feishu-cards/card-json-v2-components/content-components/rich-text |
| 颜色枚举值 | https://open.feishu.cn/document/feishu-cards/enumerations-for-fields-related-to-color |
| 发送消息 im/v1（interactive + 30KB + 错误码） | https://open.feishu.cn/document/server-docs/im-v1/message/create |
| 参考实现（仅 header_style 加粗） | https://github.com/chapaofan/Hermes-feishu-to-table |

---

## OPEN QUESTIONS

> **已拍板（2026-08-16，requester 回复「按照你推荐的来」）**：Q1=a、Q2=a、Q3=a。
> - **Q1** 接口错误率红档 = 按需求改 **1%**（`NET_ERR_RED` 0→1.0；iOS 0.6% 红→黄、Android 2.2% 仍红）。属阈值常量调整，随本 change 一并落地。
> - **Q2** 黄档 = 直接采用脚本现值着色（崩溃 0.5 / 慢帧 30 / 冻结 0.5 / P95 1500 / 错误率 0.5），注释保留「待对齐」，后续团队对齐后仅微调常量、不重走流程。
> - **Q3** = 直接迁 v2（客户端 ≥7.20 门槛接受，低版本仅降级显示、不影响他人）。

**Q1｜接口错误率红档阈值冲突**：需求 8 文案「接口错误率>1%（红档）」，但脚本常量 `NET_ERR_RED=0`（注释：红>0，首版沿用现行为）。本 change 是纯展示层、不改数据计算——单元格红档着色以哪个为准？(a) 沿用 `NET_ERR_RED=0`（与现告警行为一致）；(b) 按需求改 1%（需另动脚本常量，超出纯展示范围，或另开 change）。影响：接口错误率单元格的红灯判定与既有告警是否一致。

**Q2｜黄档阈值采纳**：需求 3 要求🟡「临近」档展示，但脚本 YELLOW 常量（崩溃 0.5 / 慢帧 30 / 冻结 0.5 / P95 1500 / 错误率 0.5）注释均为「待对齐」。单元格🟡着色是否直接采用脚本现值？(a) 直接采用（着色即隐含确认，注释保留待对齐）；(b) 本轮不渲染🟡，只有红/正常两态，等黄档拍板。

**Q3｜v2 客户端版本门槛**：v2 卡片要求飞书客户端 ≥ 7.20，低版本只显示标题 + 升级提示（内容不展示）。收卡成员（群）客户端是否都 ≥ 7.20？若有成员低于该版本，是否接受其降级显示，还是暂缓 v2 迁移（保留 v1 卡片）？影响：整卡迁移的放行条件。
