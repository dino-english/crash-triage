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
