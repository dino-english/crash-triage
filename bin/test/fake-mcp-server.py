#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""假 MCP server（stdio JSON-RPC），供 fn-fetch-events-mcp.sh 密封测试用。

⛔ 只给夹具用，不参与生产链路。
用环境变量控制行为，让那些**真实环境里难以按需复现**的分支可以被测到：
  FAKE_429_TIMES=N   前 N 次 tools/call 返回 429（验退避）
  FAKE_MODE=empty    返回空列表（验「取不到就不落盘」）
  FAKE_MODE=garbage  返回不是列表的 YAML（验形状校验）
  FAKE_EVENT_IDS     逗号分隔的 eventId，默认 "e1,e2"
"""
import json
import os
import sys

STATE = {"calls": 0}


def yaml_events(ids):
    # 照抄真实返回的形状：YAML 字面块标量，不是 JSON（实测 2026-09-18）
    out = []
    for eid in ids:
        out.append(
            "- eventId: |\n    '%s'\n"
            "  eventTime: |\n    '2026-09-17T07:24:09Z'\n"
            "  device: |\n    manufacturer: OnePlus\n    model: OnePlus8Pro\n" % eid
        )
    return "".join(out)


def respond(obj):
    sys.stdout.write(json.dumps(obj) + "\n")
    sys.stdout.flush()


def main():
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            msg = json.loads(line)
        except ValueError:
            continue
        method = msg.get("method")
        if method == "initialize":
            respond({"jsonrpc": "2.0", "id": msg.get("id"), "result": {"protocolVersion": "2024-11-05"}})
        elif method == "notifications/initialized":
            continue
        elif method == "tools/call":
            STATE["calls"] += 1
            fail_times = int(os.environ.get("FAKE_429_TIMES", "0") or 0)
            if STATE["calls"] <= fail_times:
                respond({"jsonrpc": "2.0", "id": msg.get("id"),
                         "result": {"isError": True,
                                    "content": [{"type": "text",
                                                 "text": "429 RESOURCE_EXHAUSTED: quota exceeded"}]}})
                continue
            mode = os.environ.get("FAKE_MODE", "")
            if mode == "empty":
                text = ""
            elif mode == "garbage":
                text = "notalist: true\n"
            else:
                ids = (os.environ.get("FAKE_EVENT_IDS") or "e1,e2").split(",")
                text = yaml_events([i for i in ids if i])
            respond({"jsonrpc": "2.0", "id": msg.get("id"),
                     "result": {"content": [{"type": "text", "text": text}]}})
        else:
            respond({"jsonrpc": "2.0", "id": msg.get("id"), "result": {}})
    return 0


if __name__ == "__main__":
    sys.exit(main())
