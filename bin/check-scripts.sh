#!/usr/bin/env bash
# 提交前自检。两项：
#  1. bash 语法
#  2. $VAR 紧跟多字节字符 —— bash 3.2（macOS 自带）会把多字节的首字节并进变量名，
#     报 "VAR?: unbound variable"。2026-08-18 一天内连踩五次，做成检查项。
#     用 python 做匹配：BSD grep -E 不支持 \x 转义，写正则会误报一片。
set -uo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
rc=0
# ⚠️ **必须递归**：早先只扫 "$SELF_DIR"/*.sh，于是 bin/lib/ 与 bin/test/ 下的新代码
# 完全不受任何检查——包括下面那条多字节变量 lint。实测第一个放进 bin/test/ 的脚本
# 就带着 `$SCRIPT（` 这种写法通过了自检，运行时才炸。
while IFS= read -r f; do
  [ "$(basename "$f")" = "check-scripts.sh" ] && continue
  bash -n "$f" || { echo "❌ 语法: ${f#"$SELF_DIR"/}"; rc=1; }
done < <(find "$SELF_DIR" -name '*.sh' -type f | sort)
python3 - "$SELF_DIR" <<'PY' || rc=1
import sys, re, pathlib
bad = 0
pat = re.compile(r'\$([A-Za-z_][A-Za-z0-9_]*)(?=[^\x00-\x7F])')
for f in sorted(pathlib.Path(sys.argv[1]).rglob('*.sh')):
    if f.name == 'check-scripts.sh':
        continue
    for n, line in enumerate(f.read_text(encoding='utf-8').splitlines(), 1):
        for m in pat.finditer(line):
            rel = f.relative_to(pathlib.Path(sys.argv[1]))
            print(f'❌ {rel}:{n} 变量紧邻多字节字符，需写成 ${{{m.group(1)}}}：{line.strip()[:70]}')
            bad = 1
sys.exit(bad)
PY
python3 -c "import ast; ast.parse(open('$SELF_DIR/md2docx.py').read())" 2>/dev/null || { echo "❌ md2docx.py 语法"; rc=1; }

# ── 3. 依赖方向 lint（change crash-perf-functional-core，design D5）───────────
# bash 没有编译器，这是「内层不知道外层」这条依赖规则在这门语言里**唯一能落地的强制形式**。
# 核心层出现取数 / 投递 / 模型调用 / 网络，或引用运行目录、状态目录变量，即失败。
# 跳过整行注释；行内注释的假阳性是刻意接受的代价——**假阴性（核心层偷读 $STATE）才是真风险**。
if [ -d "$SELF_DIR/lib/core" ]; then
  hits="$(grep -nE '^[^#]*(\bbq\b|lark-cli|claude |curl |firebase|\$STATE|\$ROOT|\$\{STATE|\$\{ROOT)' \
            "$SELF_DIR"/lib/core/*.sh 2>/dev/null || true)"
  if [ -n "$hits" ]; then
    echo "❌ 核心层出现外层依赖（应为纯函数，见 bin/lib/core/*.sh 顶部说明）："
    printf '%s\n' "$hits" | sed 's|^'"$SELF_DIR"'/|   |'
    rc=1
  fi
fi

# ── 4. 重复定义检测 ──────────────────────────────────────────────
# 同名函数出现在两个及以上文件即失败。豁免清单以**数据形式**集中在下面，
# 每项带一行理由——散落的 if 判断会让清单悄悄长大而无人察觉。
#   fail:deliver.sh      独立进程，不写 health 文件（投递失败不改变生成脚本的健康状态），语义不同
#   fail:crash-daily.sh  common.sh 缺失时的回落分支
#   fail:crash-weekly.sh 同上
#   say:install.sh       装机链路，与流水线运行时无关，本次未合并（不是「不该合并」）
#   say:update.sh        同上
dup="$(
  { for f in $(find "$SELF_DIR" -name '*.sh' -type f | sort); do
      grep -oE '^[a-zA-Z_][a-zA-Z0-9_]*\(\)' "$f" | tr -d '()' | sed "s|\$|	${f#"$SELF_DIR"/}|"
    done; } | grep -vE '^(fail	(deliver|crash-daily|crash-weekly)\.sh|say	(install|update)\.sh)$' \
  | awk -F'\t' '{n[$1]=n[$1]" "$2; c[$1]++} END{for(k in c) if(c[k]>1) print "   " k ": " n[k]}' | sort
)"
if [ -n "$dup" ]; then
  echo "❌ 同名函数在多个文件中重复定义（共享函数应收口到 bin/lib/）："
  printf '%s\n' "$dup"
  rc=1
fi

# ── 5. 纯函数断言 ────────────────────────────────────────────────
if [ -x "$SELF_DIR/test/run.sh" ]; then
  bash "$SELF_DIR/test/run.sh" || rc=1
fi

# ── 6. ShellCheck（可选依赖）─────────────────────────────────────
# 生产机是无人值守的 Mac mini，不该为开发期工具多一项装机步骤。
# 未安装 → 跳过并提示，**不影响退出码**；已安装 → 计入。
if command -v shellcheck >/dev/null 2>&1; then
  sc="$(find "$SELF_DIR" -name '*.sh' -type f -print0 | xargs -0 shellcheck -S warning 2>&1 || true)"
  if [ -n "$sc" ]; then
    echo "⚠️ ShellCheck 报告（首 20 行）："; printf '%s\n' "$sc" | head -20
    SC_COUNT="$(printf '%s\n' "$sc" | grep -cE '^In .* line [0-9]+:' || true)"
    echo "   共 ${SC_COUNT} 处。首次接入若数量大，先记录再分批清理，不阻塞本轮（见 change findings）"
  fi
else
  echo "ℹ️ 未安装 shellcheck，跳过静态检查（可选依赖，不影响退出码）"
fi
[ $rc -eq 0 ] && echo "✅ 全部通过"
exit $rc
