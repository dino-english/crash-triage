#!/usr/bin/env bash
# 提交前自检。两项：
#  1. bash 语法
#  2. $VAR 紧跟多字节字符 —— bash 3.2（macOS 自带）会把多字节的首字节并进变量名，
#     报 "VAR?: unbound variable"。2026-08-18 一天内连踩五次，做成检查项。
#     用 python 做匹配：BSD grep -E 不支持 \x 转义，写正则会误报一片。
set -uo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
rc=0
for f in "$SELF_DIR"/*.sh; do
  [ "$(basename "$f")" = "check-scripts.sh" ] && continue
  bash -n "$f" || { echo "❌ 语法: $(basename "$f")"; rc=1; }
done
python3 - "$SELF_DIR" <<'PY' || rc=1
import sys, re, pathlib
bad = 0
pat = re.compile(r'\$([A-Za-z_][A-Za-z0-9_]*)(?=[^\x00-\x7F])')
for f in sorted(pathlib.Path(sys.argv[1]).glob('*.sh')):
    if f.name == 'check-scripts.sh':
        continue
    for n, line in enumerate(f.read_text(encoding='utf-8').splitlines(), 1):
        for m in pat.finditer(line):
            print(f'❌ {f.name}:{n} 变量紧邻多字节字符，需写成 ${{{m.group(1)}}}：{line.strip()[:70]}')
            bad = 1
sys.exit(bad)
PY
python3 -c "import ast; ast.parse(open('$SELF_DIR/md2docx.py').read())" 2>/dev/null || { echo "❌ md2docx.py 语法"; rc=1; }
[ $rc -eq 0 ] && echo "✅ 全部通过"
exit $rc
