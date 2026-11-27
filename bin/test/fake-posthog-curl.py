#!/usr/bin/env python3
"""PostHog 查询接口的 curl 桩（夹具用；change crash-tech-diagnostics「PostHog 双源」）。

夹具在 $T/bin/curl 里写一行 `exec python3 <本文件> "$@"`，放进 PATH 最前。只认 bin/lib/posthog.sh 的调用形态：
  curl -sS --max-time N -K - -o <回包文件> -w '%{http_code}' -X POST <url> -H ... --data-binary @<请求体文件>
记录（都在 $FAKE_DIR 下）：
  curl.argv     每次调用的命令行参数一行——断言 key ⛔ 不在命令行上（ps 看得见）
  curl.stdin    -K - 从 stdin 读到的配置（key 应该在这里）
  ph.bodies     每次的请求体（一行一个 JSON）——断言签名走 values、不拼进查询文本
回放：
  FAKE_PH_FAIL=1   curl 自身失败（退出 7，不写回包）
  FAKE_PH_HTTP=400 返回 HTTP 400 + {"type":"validation_error","detail":"fake bad query"}
  FAKE_PH_ROWS=N   返回 N 行单列结果（测 50000 行截断判定）
  FAKE_PH_FAIL_BREAKDOWN=1  只有分布查询（含 "affected AS"）失败，其余照常
  否则按查询文本挑夹具：含 "affected AS" → fx/ph-breakdown.json；含 "AS h," → fx/ph-hourly.json
  （按 values 的 t0 ≤ h 的 UTC 时刻 < t1 过滤）；含 "AS d," → fx/ph-daily.json（按 MYT 日落在 [t0, t1) 过滤）。
  夹具文件是行对象数组；不存在就回空结果。
"""
import datetime as dt
import json
import os
import sys

d = os.environ["FAKE_DIR"]
args = sys.argv[1:]
with open(os.path.join(d, "curl.argv"), "a") as f:
    f.write(" ".join(args) + "\n")
out = args[args.index("-o") + 1]
body_path = args[args.index("--data-binary") + 1].lstrip("@")
if "-K" in args and args[args.index("-K") + 1] == "-":
    with open(os.path.join(d, "curl.stdin"), "a") as f:
        f.write(sys.stdin.read())
body = json.load(open(body_path))
with open(os.path.join(d, "ph.bodies"), "a") as f:
    f.write(json.dumps(body, ensure_ascii=False) + "\n")

if os.environ.get("FAKE_PH_FAIL") == "1" or (
        os.environ.get("FAKE_PH_FAIL_BREAKDOWN") == "1" and "affected AS" in body["query"]["query"]):
    sys.stderr.write("curl: (7) fake connection failure\n")
    sys.exit(7)
if os.environ.get("FAKE_PH_HTTP"):
    json.dump({"type": "validation_error", "detail": "fake bad query"}, open(out, "w"))
    sys.stdout.write(os.environ["FAKE_PH_HTTP"])
    sys.exit(0)


def reply(rows):
    cols = list(rows[0].keys()) if rows else []
    json.dump({"columns": cols, "results": [[r[c] for c in cols] for r in rows], "error": None,
               "hasMore": False, "is_cached": False}, open(out, "w"), ensure_ascii=False)
    sys.stdout.write("200")
    sys.exit(0)


n = os.environ.get("FAKE_PH_ROWS")
if n:
    reply([{"x": i} for i in range(int(n))])

q, v = body["query"]["query"], body["query"].get("values", {})
t0 = dt.datetime.strptime(v["t0"], "%Y-%m-%d %H:%M:%S")
t1 = dt.datetime.strptime(v["t1"], "%Y-%m-%d %H:%M:%S")


def load(name):
    p = os.path.join(d, "fx", name)
    return json.load(open(p)) if os.path.exists(p) else []


if "affected AS" in q:
    reply([r for r in load("ph-breakdown.json") if r["sig"] in v.get("sigs", [])])
elif "AS h," in q:
    reply([r for r in load("ph-hourly.json")
           if t0 <= dt.datetime.strptime(r["h"], "%Y-%m-%d %H") - dt.timedelta(hours=8) < t1])
elif "AS d," in q:
    reply([r for r in load("ph-daily.json")
           if t0 <= dt.datetime.strptime(r["d"], "%Y-%m-%d") - dt.timedelta(hours=8) < t1])
else:
    sys.stderr.write("fake-posthog-curl: 认不出的查询\n")
    sys.exit(2)
