#!/usr/bin/env python3
"""把周报「修复清单」章节按平台分组，其余章节原样保留。

为什么做后处理而不是改 prompt：清单内容是分析层（模型）的产出，
改 prompt 既不确定（模型未必照办）也会让每次跑批结果漂移。排版是确定性的
呈现问题，交给脚本——**只重排顺序、加平台小标题，一个字不改条目内容**。

平台判定：条目里出现 `iOS` 或 `Android` 关键词（首个出现的为准）。
两者都出现或都不出现的进「通用 / 跨端」组，不强行归类——
误分类比不分类更糟，读者会按错误的归属分派任务。
"""
import re
import sys

HEADING_RE = re.compile(r'^##\s')
FIX_HEADING_RE = re.compile(r'^##\s*[^\n]*修复清单')
ITEM_RE = re.compile(r'^[-*]\s')


def platform_of(line: str) -> str:
    """返回 'ios' / 'android' / 'common'。以首个出现的平台词为准。"""
    i_ios = line.find('iOS')
    i_and = line.find('Android')
    if i_ios >= 0 and i_and >= 0:
        return 'common'          # 同时提到两端：跨端条目，不拆
    if i_ios >= 0:
        return 'ios'
    if i_and >= 0:
        return 'android'
    return 'common'


def regroup(lines):
    """就地重排「修复清单」章节；返回新的行列表。"""
    out = []
    i = 0
    n = len(lines)
    while i < n:
        line = lines[i]
        if not FIX_HEADING_RE.match(line):
            out.append(line)
            i += 1
            continue

        # 命中修复清单标题：收集到下一个 ## 之前的所有行
        out.append(line)
        i += 1
        body = []
        while i < n and not HEADING_RE.match(lines[i]):
            body.append(lines[i])
            i += 1

        # 拆成「条目」与「非条目」（前言、空行等原样保留在最前）
        preamble, items = [], []
        cur = None
        for b in body:
            if ITEM_RE.match(b):
                cur = [b]
                items.append(cur)
            elif cur is not None and b.strip():
                cur.append(b)          # 条目的续行（缩进说明）
            elif cur is not None:
                cur.append(b)
            else:
                preamble.append(b)

        if not items:
            out.extend(body)
            continue

        groups = {'ios': [], 'android': [], 'common': []}
        for it in items:
            groups[platform_of(it[0])].append(it)

        out.extend(preamble)
        for key, title in (('ios', '### iOS'),
                           ('android', '### Android'),
                           ('common', '### 通用 / 跨端')):
            if not groups[key]:
                continue
            out.append(title)
            out.append('')
            for it in groups[key]:
                out.extend(x.rstrip('\n') for x in it)
            out.append('')
    return out


def main():
    if len(sys.argv) < 2:
        print('usage: split-fix-list.py <weekly.md> [-o out.md]', file=sys.stderr)
        return 2
    src = sys.argv[1]
    dst = sys.argv[3] if len(sys.argv) > 3 and sys.argv[2] == '-o' else src
    with open(src, encoding='utf-8') as f:
        lines = [l.rstrip('\n') for l in f]
    new = regroup(lines)
    with open(dst, 'w', encoding='utf-8') as f:
        f.write('\n'.join(new).rstrip() + '\n')
    return 0


if __name__ == '__main__':
    sys.exit(main())
