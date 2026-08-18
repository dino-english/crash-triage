#!/usr/bin/env python3
"""Markdown → DocxXML（飞书云文档富文本）。

为什么需要它：飞书 markdown 导入不支持颜色和高亮框，要配色只能走 DocxXML。
台账 / 索引 / 周报的正文都是 markdown，逐个手写 XML 生成器代价太大，
所以做一个通用转换器：结构（标题/表格/列表/引用）照搬，颜色按规则上色。

用法: md2docx.py <input.md> [--title T] [--head-bg C] [--zebra C] [--warn "文字"]
"""
import sys, re, html, argparse

BASIC = {'red', 'orange', 'yellow', 'green', 'blue', 'purple', 'gray'}
# 状态词 → 颜色。台账里状态是判断结论，扫一眼就该分得清死活。
# 只吃「表情 + 紧跟的一个词」，不吞整句：吞多了会把后面的状态词包进来形成嵌套 span，
# 结构就烂了（2026-08-18 实测：图例行被套了三层）。
RULES = [
    (r'🔴\s?[^\s<]*', 'red'), (r'⚠️\s?[^\s<]*', 'orange'), (r'✅\s?[^\s<]*', 'green'),
    (r'📦\s?[^\s<]*', 'blue'), (r'🛠️\s?[^\s<]*', 'orange'), (r'⬇️\s?[^\s<]*', 'green'),
    (r'🆕\s?[^\s<]*', 'purple'), (r'📈\s?[^\s<]*', 'red'),
]

def esc(t):
    return html.escape(t, quote=False)

def inline(t):
    """行内标记：粗体、行内代码、链接。顺序要紧——先转义再插标签。"""
    t = esc(t)
    t = re.sub(r'\[([^\]]+)\]\(([^)]+)\)', lambda m: f'<a href="{m.group(2)}">{m.group(1)}</a>', t)
    t = re.sub(r'\*\*([^*]+)\*\*', r'<b>\1</b>', t)
    t = re.sub(r'`([^`]+)`', r'<code>\1</code>', t)
    return t

def colorize(t):
    """给状态词上色。只处理标签之外的文本段，避免把标签内容再包一层。"""
    parts = re.split(r'(<[^>]+>)', t)
    for i, seg in enumerate(parts):
        if seg.startswith('<'):
            continue
        for pat, color in RULES:
            seg = re.sub(pat, lambda m: f'<span text-color="{color}">{m.group(0)}</span>', seg)
        parts[i] = seg
    return ''.join(parts)

def split_row(line):
    return [c.strip() for c in line.strip().strip('|').split('|')]

def convert(md, head_bg, zebra):
    out, lines, i = [], md.split('\n'), 0
    while i < len(lines):
        ln = lines[i]
        s = ln.strip()
        if not s:
            i += 1; continue
        # 表格
        if s.startswith('|') and i + 1 < len(lines) and re.match(r'^\|[\s:\-|]+\|$', lines[i + 1].strip()):
            heads = split_row(s); i += 2
            out.append('<table>')
            out.append('<thead><tr>' + ''.join(
                f'<th background-color="{head_bg}">{inline(h)}</th>' for h in heads) + '</tr></thead>')
            out.append('<tbody>')
            n = 0
            while i < len(lines) and lines[i].strip().startswith('|'):
                cells = split_row(lines[i]); n += 1
                bg = f' background-color="{zebra}"' if n % 2 == 0 else ''
                cells += [''] * (len(heads) - len(cells))
                out.append('<tr>' + ''.join(
                    f'<td{bg}>{colorize(inline(c))}</td>' for c in cells[:len(heads)]) + '</tr>')
                i += 1
            out += ['</tbody>', '</table>']
            continue
        # 标题
        m = re.match(r'^(#{1,4})\s+(.*)$', s)
        if m:
            lvl = min(len(m.group(1)), 4)
            out.append(f'<h{lvl}>{inline(m.group(2))}</h{lvl}>')
            i += 1; continue
        # 引用块 → 高亮框（连续的 > 合成一个）
        if s.startswith('>'):
            buf = []
            while i < len(lines) and lines[i].strip().startswith('>'):
                buf.append(lines[i].strip().lstrip('>').strip()); i += 1
            body = [x for x in buf if x]
            joined = ' '.join(body)
            emoji, bg, border = '💡', 'light-yellow', 'yellow'
            if '⚠️' in joined or '请勿' in joined:
                emoji, bg, border = '⚠️', 'light-red', 'red'
            out.append(f'<callout emoji="{emoji}" background-color="{bg}" border-color="{border}">')
            # 逐行一个 <p>：原样保留换行，挤成一段会读不动
            for x in body:
                out.append(f'  <p>{colorize(inline(x))}</p>')
            out.append('</callout>')
            continue
        # 列表
        if re.match(r'^[-*]\s+', s):
            out.append('<ul>')
            while i < len(lines) and re.match(r'^\s*[-*]\s+', lines[i]):
                out.append('<li>' + colorize(inline(re.sub(r'^\s*[-*]\s+', '', lines[i]))) + '</li>')
                i += 1
            out.append('</ul>'); continue
        if s == '---':
            out.append('<hr/>'); i += 1; continue
        out.append(f'<p>{colorize(inline(s))}</p>')
        i += 1
    return '\n'.join(out)

if __name__ == '__main__':
    ap = argparse.ArgumentParser()
    ap.add_argument('input'); ap.add_argument('--title', default='')
    ap.add_argument('--head-bg', default='light-blue'); ap.add_argument('--zebra', default='light-gray')
    ap.add_argument('--warn', default='')
    a = ap.parse_args()
    body = open(a.input, encoding='utf-8').read()
    parts = []
    if a.title:
        parts.append(f'<title>{esc(a.title)}</title>')
    if a.warn:
        parts.append('<callout emoji="⚠️" background-color="light-red" border-color="red">')
        parts.append(f'  <p><b>{esc(a.warn)}</b></p>')
        parts.append('</callout>')
    parts.append(convert(body, a.head_bg, a.zebra))
    print('\n'.join(parts))
