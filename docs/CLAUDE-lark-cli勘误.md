# lark-cli 实测勘误

> 拆分自 CLAUDE.md（crash-triage@2377dad）。lark-cli 行为与文档不符的实测记录。

## 勘误清单（2026-08-19 spike，2026-08-20 补三条）

- ⛔ **已订正（2026-09-28）：「不传 profile 即可，它是唯一激活的 profile」是过期结论，照做会静默用错应用。**
  原文写的是「`--profile crash-triage` 不存在……用 `--profile cli_aaf7b44ddeb8de14`，或不传（它是唯一激活的 profile）」。
  2026-09-28 在两台机器上实测，**结论相反且与上下文有关**：

  | | `lark-cli profile list` |
  | --- | --- |
  | 开发机 | `cli_aad59f453275de18`（**active / effective**）· `crash-triage` → `cli_aaf7b44ddeb8de14`（inactive） |
  | 生产机（普通 ssh） | `[]`（无命名 profile） |

  也就是说开发机上**生效的是另一个应用**（`cli_aad59f…`），不传 profile 就是用它。
  ⚠️ 两个应用看到的文档权限互不相通：用默认 profile 建的文档，`crash-triage` 那个 bot **写不进去**，
  而失败形态正是 F57 —— `block_replace` 返回 `ok:true` / rc=0 / `result:"failed"`，
  报文是 `No permission to operate on this document`。2026-09-28 部署时连踩两次才定位到。
  ⛔ **判据不是「能不能读」**：那次 bot 能读（`docs +fetch` 正常、指纹比对也跑通了），只是不能写。

  **怎么做才对**：跟着 `deliver.sh` 走，⛔ 不要自己猜。它的逻辑是
  `LARK_PROFILE=crash-triage`，且 **hermes / openclaw 上下文下清空**
  （那里用 Agent 工作区配置 `~/.lark-cli/hermes/config.json`，传命名 profile 会报 `not found`）。
  手工排查时若要复现生产行为，用 `--profile crash-triage`；
  ⚠️ 生产机普通 ssh 下 `profile list` 是空的，但 cron 跑在 hermes 上下文里、走的是另一份配置——
  **「我 ssh 上去看到的」不等于「cron 跑的时候用的」**。
- **`docs +fetch` 取正文的 jq 路径是 `.data.document.content`**，不是 `.content`（后者恒为 `null`）。
- ⛔ **`.data.document.content` 的值是 DocxXML 文本，不是块结构 JSON**（2026-08-20 实测，一次踩三处）。所有 scope（`outline` / `section` / `keyword`）都一样。想拿 block id 必须**解析 XML 标签**，在 JSON 里 `jq` 找 `type=="table"` / 遍历 `.. | objects` 永远落空：
  - 标题：`grep -oE '<h[1-6] id="[^"]*">标题文本<'`
  - 表格：`grep -oE '<table id="[^"]*"'`
  - `sync_ledger()` 的标题与表格定位都因此失效过：标题那处取「第一个带 id 的对象」还会**命中正文里提到同名文字的引用块**（台账开头那段说明就写着「Issue 现状表」），导致误判「标题不存在」而退回 bootstrap，把四段结构重复 append 了两遍。同名标题有多个时取**最后一个**（旧结构在上、本流水线建的新结构在下）。
- **`--content @绝对路径` 被拒**（"must be a relative path within the current directory"）：改用 stdin（`cat f | lark-cli ... --content -`）或先 `cd` 到文件目录用 `@./file`。
- **拆 `deliver.sh` 函数体复用时会覆盖同名变量**：`head -n <case 行> deliver.sh > /tmp/f.sh && . /tmp/f.sh` 这招能单独调 `sync_ledger()` / `publish_doc()`，但它顶部的 `ROOT=` / `STATE=` 会覆盖调用方的赋值（2026-08-20 实测 `$ROOT` 被清空，`md2docx.py` 路径变成 `//bin/...`）。source 之后再赋值，或直接写绝对路径。
