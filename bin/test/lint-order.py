#!/usr/bin/env python3
"""顶层「先用后定」检测。

bash 顺序执行，声明与使用隔着几百行时没有任何工具在守。2026-08-24 一天内同类错误四次
（DD_TOP_N / dd_fetch / WOW_CUT / …），⚠️ 表现各不相同且**全都不报错或报错被吞**：
  · 常量先用后定 → `unbound variable`，退出码曾被 EXIT trap 吞成 0（F24）
  · 函数先用后定 → `command not found`，被 `|| true` 吞掉 → 空产物 + rc=0

判定范围：
  ⚠️ 只看**顶层**引用——函数体内互相引用与定义顺序无关（合法，运行时才解析）。
  ⚠️ 跳过 ${VAR:-x} / ${VAR:+x} / ${VAR:?x}：那是「显式允许未设置」，不是先用后定。
  ⚠️ 跳过 trap/alias 单引号体：它们的执行时机与所在行无关。
"""
import re, sys, pathlib

ASSIGN = re.compile(r'^([A-Z][A-Z0-9_]*)=')
FUNC_S = re.compile(r'^([a-z_][a-z0-9_]*)\(\)\s*\{\s*$')
FUNC_1 = re.compile(r'^([a-z_][a-z0-9_]*)\(\)\s*\{.*\}\s*$')      # 单行函数
VAR_USE = re.compile(r'\$\{([A-Z][A-Z0-9_]*)\}|\$([A-Z][A-Z0-9_]*)')
VAR_DEF = re.compile(r'\$\{[A-Z][A-Z0-9_]*[:-]')                   # ${V:-x} 形式，整体跳过

def func_ranges(lines):
    """返回顶层函数体行号区间 [(start,end)]，函数以列 0 的 `}` 收尾（本仓库风格）。"""
    out, i, n = [], 0, len(lines)
    while i < n:
        s = lines[i]
        if FUNC_1.match(s):
            out.append((i + 1, i + 1)); i += 1; continue
        if FUNC_S.match(s):
            j = i + 1
            while j < n and lines[j] != '}':
                j += 1
            out.append((i + 1, j + 1)); i = j + 1; continue
        i += 1
    return out

bad = 0
for f in sorted(pathlib.Path(sys.argv[1]).rglob('*.sh')):
    if f.name == 'check-scripts.sh':
        continue
    lines = f.read_text(encoding='utf-8').splitlines()
    ranges = func_ranges(lines)
    in_func = lambda n: any(a <= n <= b for a, b in ranges)
    defined, used = {}, {}
    for n, raw in enumerate(lines, 1):
        if raw.lstrip().startswith('#'):
            continue
        if in_func(n):
            # 函数体里只登记「定义」不登记「引用」
            continue
        m = ASSIGN.match(raw)
        if m:
            defined.setdefault(m.group(1), n)
        if "trap '" in raw or 'trap "' in raw:
            continue
        body = VAR_DEF.sub('', raw)                    # 剥掉 ${V:-x} 这类
        for a, b in VAR_USE.findall(body):
            used.setdefault(a or b, n)
        for name in re.findall(r'(?:^|[;&|]\s*|\$\(\s*|\bthen\s+|\belse\s+|\bdo\s+)([a-z_][a-z0-9_]{2,})\s', raw):
            used.setdefault(name, n)
    # 函数定义行（顶层）
    for a, b in ranges:
        m = FUNC_S.match(lines[a - 1]) or FUNC_1.match(lines[a - 1])
        if m:
            defined.setdefault(m.group(1), a)
    for name, dl in defined.items():
        ul = used.get(name)
        if ul is not None and ul < dl:
            print(f'❌ {f.name}:{ul} 顶层引用 `{name}`，但它定义在 :{dl}（先用后定）')
            bad = 1
sys.exit(bad)
