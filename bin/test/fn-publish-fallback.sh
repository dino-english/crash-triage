#!/usr/bin/env bash
# publish_doc 的回退文件（2026-09-11 生产事故）。
#
# 事故：XML 建档被拒后，回退把**同一个 .xml** 喂给 drive +import，
# lark-cli 报 `unsupported file extension: xml`，两层全挂，当天日报没有文档。
# 注释里写着「失败回退 markdown 导入」，但 markdown 文件从没被传进 publish_doc。
set -uo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SELF_DIR/../.." && pwd)"
# shellcheck disable=SC1091
. "$SELF_DIR/harness.sh"
h_load "$ROOT/bin/deliver.sh" publish_doc || { h_summary; exit 1; }

echo "── publish_doc：XML 失败时回退到 markdown ──"
# 桩：记录 import_doc 实际拿到的文件名；create_xml_doc 一律失败
# ⚠️ publish_doc 跑在 $( ) 子 shell 里，桩里的变量赋值**传不回来**——必须落文件。
SPY="$(mktemp)"
create_xml_doc() { return 1; }
import_doc() { printf '%s' "$1" > "$SPY"; printf 'https://example.invalid/docx/FALLBACK'; }
overwrite_doc() { return 1; }
doc_get() { printf ''; }
doc_put() { :; }
is_fixed_resource_key() { return 1; }
note_new() { :; }

u="$(publish_doc /tmp/report.xml "标题" "" "FOLDER" "daily-2026-09-11" xml /tmp/report.md)"
h_assert_eq "/tmp/report.md" "$(cat "$SPY")" "⛔ 回退必须导入 markdown，不是那个被拒的 .xml"
h_assert_eq "https://example.invalid/docx/FALLBACK" "$u" "回退后仍返回 URL（链路不断）"

# ⚠️ 不传第 7 参时退回旧行为（$1），保证其余调用点不受影响
: > "$SPY"
u="$(publish_doc /tmp/only.md "标题" "" "FOLDER" "k" markdown)"
h_assert_eq "/tmp/only.md" "$(cat "$SPY")" "未传回退文件时用 \$1（markdown 调用点不受影响）"

# XML 成功时不该走导入
: > "$SPY"
create_xml_doc() { printf 'https://example.invalid/docx/XMLOK'; }
u="$(publish_doc /tmp/report.xml "标题" "" "FOLDER" "k" xml /tmp/report.md)"
h_assert_eq "" "$(cat "$SPY")" "⛔ XML 成功时不得再导入一份（否则每天两份文档）"
h_assert_eq "https://example.invalid/docx/XMLOK" "$u" "XML 成功返回 XML 的 URL"

rm -f "$SPY"
h_summary
