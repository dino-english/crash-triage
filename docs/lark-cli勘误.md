# lark-cli 实测勘误

> 拆分自 CLAUDE.md（crash-triage@2377dad）。lark-cli 行为与文档不符的实测记录。

## 勘误清单（2026-08-19 spike，2026-08-20 补三条）

- **`--profile crash-triage` 不存在**：`lark-cli profile list` 只列出 appId `cli_aaf7b44ddeb8de14`，`crash-triage` 是未生效的历史 alias。用 `--profile cli_aaf7b44ddeb8de14`，或不传（它是唯一激活的 profile）。
- **`docs +fetch` 取正文的 jq 路径是 `.data.document.content`**，不是 `.content`（后者恒为 `null`）。
- ⛔ **`.data.document.content` 的值是 DocxXML 文本，不是块结构 JSON**（2026-08-20 实测，一次踩三处）。所有 scope（`outline` / `section` / `keyword`）都一样。想拿 block id 必须**解析 XML 标签**，在 JSON 里 `jq` 找 `type=="table"` / 遍历 `.. | objects` 永远落空：
  - 标题：`grep -oE '<h[1-6] id="[^"]*">标题文本<'`
  - 表格：`grep -oE '<table id="[^"]*"'`
  - `sync_ledger()` 的标题与表格定位都因此失效过：标题那处取「第一个带 id 的对象」还会**命中正文里提到同名文字的引用块**（台账开头那段说明就写着「Issue 现状表」），导致误判「标题不存在」而退回 bootstrap，把四段结构重复 append 了两遍。同名标题有多个时取**最后一个**（旧结构在上、本流水线建的新结构在下）。
- **`--content @绝对路径` 被拒**（"must be a relative path within the current directory"）：改用 stdin（`cat f | lark-cli ... --content -`）或先 `cd` 到文件目录用 `@./file`。
- **拆 `deliver.sh` 函数体复用时会覆盖同名变量**：`head -n <case 行> deliver.sh > /tmp/f.sh && . /tmp/f.sh` 这招能单独调 `sync_ledger()` / `publish_doc()`，但它顶部的 `ROOT=` / `STATE=` 会覆盖调用方的赋值（2026-08-20 实测 `$ROOT` 被清空，`md2docx.py` 路径变成 `//bin/...`）。source 之后再赋值，或直接写绝对路径。
