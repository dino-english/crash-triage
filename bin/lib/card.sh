#!/usr/bin/env bash
# 卡片产物的公共处理（2026-09-07）。
#
# ⚠️ 单独成文件而不是并进 lib/common.sh：deliver.sh 不 source common.sh
#    （后者要求调用方先设好 $ROOT/$STATE/$TS 与四个告警变量），而本函数三个入口都要用。
#    本文件**零全局依赖**，任意顺序 source 均可。

# 把未回填的链接占位符降级为纯文本。
# ⛔ 起因：`[完整报告](__REPORT_URL__)` 会被飞书渲染成 `http://__report_url__` 死链。
#    两条路径都会踩到——① 文档发布失败时卡片照发（deliver.sh 的回填带 `[ -n "$URL" ]` 条件）；
#    ② 人手工单发 publish/ 里的卡片去验列宽（有记录的做法）。
# ⚠️ **只作用于副本，绝不改 card.json 原件**：占位符必须留在原件里，
#    「重跑 deliver.sh 补投」靠 doc_get 回填它们；产出时抹掉就永远填不上了。
strip_unfilled_links() { # $1=卡片 json（就地改写）；降级时在 stderr 提示
  [ -s "$1" ] || return 0
  python3 - "$1" <<'STRIPPY' || true
import re, sys, pathlib
p = pathlib.Path(sys.argv[1]); t = p.read_text()
n = re.sub(r'\[([^\]]*)\]\(__[A-Z_]+_URL__\)', r'\1（链接未生成）', t)
if n != t:
    p.write_text(n)
    sys.stderr.write("  ⚠️ 卡片有未回填的链接占位符，已降级为纯文本（文档可能发布失败）\n")
STRIPPY
  return 0
}

# 产出可安全外发的预览件。⛔ 原件不动。
write_card_preview() { # $1=card.json 路径 → 同目录下 card-preview.json
  [ -s "$1" ] || return 0
  local pv; pv="$(dirname "$1")/card-preview.json"
  cp "$1" "$pv" 2>/dev/null || return 0
  strip_unfilled_links "$pv" 2>/dev/null
  return 0
}

# ── 版本注记（change crash-version-notes）────────────────────────────
# 回答「这个数字为什么跳变」——当原因不在数据里而在代码/口径变更里时。
# 人手维护 `notes/version-notes.tsv`（`平台<TAB>版本<TAB>一句话`），脚本**只读永不覆写**。
#
# ⚠️ **版本集由调用方传入，函数不读全局**：L1 用最新 N 版、L2 用会话量 top2 主力版本，
#    两者常常不同，同一条注记只出现在命中的那一份里——**这是设计如此不是缺陷**（design D3）。
#    参数化是为了让「用哪个版本集」这个决定留在调用点、看得见。
# ⛔ 只出摘要区，不进表格单元格（design D2）：进表格会同时踩中「列宽只有真发一张才验得出」
#    与「卡片列集合有 build_card_table / md_table 两个定义点」（F35）。
# ⚠️ 放 lib/card.sh 而不是写在某个入口脚本里：**函数不跨进程**，L1/L2 是两个独立进程，
#    写在 crash-daily.sh 里 L2 永远看不见（本 change 一度就是这么漏的）。
version_notes_md() { # $1=iOS 版本集（空白分隔） $2=Android 版本集 → markdown 列表，无命中输出空串
    local file="${CRASH_REPORT_NOTES_FILE:-$ROOT/notes/version-notes.tsv}"
    local max="${CRASH_REPORT_NOTES_MAX:-3}"
    [ -f "$file" ] || return 0
    local plat ver text pname hits=0 total=0 out=""
    # ⚠️ 先数总命中再截断：截断了不说条数，读者不知道还有没被显示的
    while IFS=$'\t' read -r plat ver text; do
        case "$plat" in ''|'#'*) continue;; esac
        [ -n "$ver" ] && [ -n "$text" ] || continue
        case "$plat" in
            ios) printf '%s\n' $1 | grep -qxF "$ver" || continue; pname="iOS";;
            and) printf '%s\n' $2 | grep -qxF "$ver" || continue; pname="Android";;
            *) continue;;
        esac
        total=$((total + 1))
        [ "$hits" -ge "$max" ] && continue
        hits=$((hits + 1))
        out="${out}- ⚠️ **${pname} ${ver}**：${text}\n"
    done < "$file"
    [ "$total" -gt 0 ] || return 0
    # 全角括号不参与变量拼接（⛔ 禁 ${var:+（...）}：bash 把全角字节并进变量名）
    local more=""
    [ "$total" -gt "$hits" ] && more="- 另有 $((total - hits)) 条注记未显示\n"
    printf '%b%b' "$out" "$more"
}
