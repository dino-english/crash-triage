#!/usr/bin/env python3
"""回测评估：读 bt.sql 的 CSV，按阈值网格统计激增命中（签名级 = 各平台相加）。
用法：bt_eval.py <bt.csv> <out_dir>
小时级：基线 = 前 7 天同一小时均值（缺行按 0），基线 <1 按 1；同签名 6 小时去重。
日级：基线 = 前 7 天均值；同签名 1 天内只算一次（日粒度天然如此）。
"""
import csv, sys, json, collections, datetime as dt, statistics, os

src, out = sys.argv[1], sys.argv[2]
os.makedirs(out, exist_ok=True)
H = collections.defaultdict(lambda: collections.defaultdict(int))   # (kind,sig) -> hour -> devices
D = collections.defaultdict(lambda: collections.defaultdict(int))   # (kind,sig) -> day -> devices
with open(src) as f:
    for r in csv.DictReader(f):
        k = (r['kind'], r['s1'] + ' × ' + r['s2'])
        (H if r['g'] == 'h' else D)[k][r['bucket']] += int(r['devices'])

START, END = dt.date(2026, 10, 27), dt.date(2026, 11, 25)      # 30 天回测窗口
days = [(START + dt.timedelta(i)) for i in range((END - START).days + 1)]
MUST = [("2026-11-23 17", "/app/v2/onboarding-journey/bootstrap", "http_409"),
        ("2026-11-16", "/app/v1/learning-plan/home", "http_500")]

def base(series, keys, how):
    vals = [series.get(x, 0) for x in keys]
    return {'mean': statistics.mean, 'median': statistics.median, 'max': max}[how](vals)

def run_hourly(kind, mn, mult, how='mean', dedupe_h=6):
    hits = []
    for (kd, sig), s in H.items():
        if kd != kind:
            continue
        last = None
        for d in days:
            for hh in range(24):
                t = dt.datetime(d.year, d.month, d.day, hh)
                key = t.strftime('%Y-%m-%d %H')
                dev = s.get(key, 0)
                if dev < mn:
                    continue
                b = base(s, [(t - dt.timedelta(days=i)).strftime('%Y-%m-%d %H') for i in range(1, 8)], how)
                if dev >= max(b, 1) * mult:
                    if last is None or (t - last) >= dt.timedelta(hours=dedupe_h):
                        hits.append((key, sig, dev, round(b, 1)))
                        last = t
    return sorted(hits)

def run_daily(kind, mn, mult, how='mean'):
    hits = []
    for (kd, sig), s in D.items():
        if kd != kind:
            continue
        for d in days:
            key = d.isoformat()
            dev = s.get(key, 0)
            if dev < mn:
                continue
            b = base(s, [(d - dt.timedelta(days=i)).isoformat() for i in range(1, 8)], how)
            if dev >= max(b, 1) * mult:
                hits.append((key, sig, dev, round(b, 1)))
    return sorted(hits)

def must_ok(hits, gran):
    res = []
    for when, tgt, code in MUST:
        sig = tgt + ' × ' + code
        if gran == 'h':
            ok = any(h[1] == sig and h[0] == when for h in hits) if len(when) == 13 else any(h[1] == sig and h[0].startswith(when) for h in hits)
        else:
            ok = any(h[1] == sig and h[0] == when[:10] for h in hits)
        res.append(ok)
    return res

summary = {}
for kind in ('apiA', 'apiB'):
    for how in ('mean', 'median'):
        for mn, mult in [(10, 4), (10, 3), (10, 5), (15, 4), (20, 4), (10, 6)]:
            hits = run_hourly(kind, mn, mult, how)
            k = f'h|{kind}|{how}|{mn}|{mult}'
            summary[k] = {'hits': len(hits), 'per_day': round(len(hits) / len(days), 2),
                          'sigs': len({h[1] for h in hits}), 'must': must_ok(hits, 'h')}
            with open(f'{out}/{k.replace("|", "_")}.tsv', 'w') as w:
                for h in hits:
                    w.write('\t'.join(map(str, h)) + '\n')
    for kind2 in ([kind, 'flow'] if kind == 'apiB' else [kind]):
        for mn, mult in [(10, 3), (20, 3), (20, 4), (30, 3), (50, 3), (30, 2)]:
            hits = run_daily(kind2, mn, mult)
            k = f'd|{kind2}|mean|{mn}|{mult}'
            summary[k] = {'hits': len(hits), 'per_week': round(len(hits) / len(days) * 7, 2),
                          'sigs': len({h[1] for h in hits}), 'must': must_ok(hits, 'd')}
            with open(f'{out}/{k.replace("|", "_")}.tsv', 'w') as w:
                for h in hits:
                    w.write('\t'.join(map(str, h)) + '\n')
json.dump(summary, open(f'{out}/summary.json', 'w'), ensure_ascii=False, indent=1)
for k, v in summary.items():
    print(k, v)
