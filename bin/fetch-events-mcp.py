#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""事实层事件明细的确定性抓取（change crash-fact-cache-model-free-events）。

⛔ 为什么不让模型抓：`crashlytics_list_events` 的结果一超限就不下发给模型——
   它只收到 2KB 预览和一个磁盘路径，事件数据**从未进入其上下文**。要拿到就得解析
   那个文件，而解析需要解释器，解释器被 --allowedTools 正确禁掉了（失效模式 F52）。
   2026-09-18 实测：6 个待抓 issue，模型写进 issues/ 的文件数是 0；
   而它会写出 `{"data":"__EVENT_0__"}` 这种占位条目冒充成功。

用法（id 清单走 stdin，一行一条 "<32位id>\\t<ios|android>\\t<线上计数>"）：
  fetch-events-mcp.py --issues-dir DIR --ios-app ID --android-app ID --days N [--page-size 50] [--force]

退出码：0 = 全部处理完（含「无事可做」）· 1 = 有 issue 抓取失败
⛔ 失败必须非零退出：调用方据此判定，与仓库既有的「退出码是唯一失败信号」一致。
"""
import argparse
import json
import os
import signal
import subprocess
import sys
import time
from datetime import datetime, timedelta

try:
    import yaml
except ImportError:  # pragma: no cover - setup.sh 已设闸，这里只是给手工调用的人一句人话
    sys.stderr.write("❌ 缺少 PyYAML：python3 -m pip install --user pyyaml\n")
    sys.exit(1)

# ⚠️ 429 很常见、不是故障（memory raw-mcp-call，2026-08-23 实测）：两轮退避即过。
# ⚠️ 允许环境变量覆盖**只为夹具**：真等 30+60 秒会让密封测试变成 90 秒起步，
#    没人会去跑它，那条分支就又回到「只过代码审查」的状态。⛔ 生产不设这个变量。
def _backoff_from_env():
    raw = os.environ.get("CRASH_REPORT_MCP_BACKOFF", "")
    if not raw:
        return (30, 60)
    out = []
    for part in raw.split(","):
        part = part.strip()
        if part:
            try:
                out.append(float(part))
            except ValueError:
                pass
    return tuple(out) if out else (30, 60)


BACKOFF_SECONDS = _backoff_from_env()


class McpSession(object):
    """一次握手、多次调用。⛔ 不要每个 issue 起一个 server：npx 冷启动是秒级的。"""

    def __init__(self, command):
        self.proc = subprocess.Popen(
            command,
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            text=True,
            bufsize=1,
        )
        self._next_id = 0
        self._send({
            "jsonrpc": "2.0", "id": self._new_id(), "method": "initialize",
            "params": {
                "protocolVersion": "2024-11-05", "capabilities": {},
                "clientInfo": {"name": "crash-triage-fact-layer", "version": "1"},
            },
        })
        self._read(self._next_id)
        self._send({"jsonrpc": "2.0", "method": "notifications/initialized", "params": {}})

    def _new_id(self):
        self._next_id += 1
        return self._next_id

    def _send(self, obj):
        self.proc.stdin.write(json.dumps(obj) + "\n")
        self.proc.stdin.flush()

    def _read(self, want):
        # ⚠️ server 会穿插 notification，按 id 认领自己的那条。
        while True:
            line = self.proc.stdout.readline()
            if not line:
                return None
            try:
                msg = json.loads(line)
            except ValueError:
                continue
            if msg.get("id") == want:
                return msg

    def call(self, name, arguments):
        call_id = self._new_id()
        self._send({
            "jsonrpc": "2.0", "id": call_id, "method": "tools/call",
            "params": {"name": name, "arguments": arguments},
        })
        return self._read(call_id)

    def close(self):
        try:
            self.proc.stdin.close()
        except Exception:
            pass
        self.proc.kill()


def result_text(msg):
    """取回 content 里的文本块；⛔ isError 时原样返回文本供调用方判 429。"""
    if not msg or "result" not in msg:
        return None, True
    result = msg["result"]
    parts = []
    for item in result.get("content") or []:
        if isinstance(item, dict) and item.get("type") == "text":
            parts.append(item.get("text") or "")
    return "".join(parts), bool(result.get("isError"))


def clean_scalars(event):
    """把 YAML 字面块标量还原成干净值。

    ⛔ MCP 返回的每个字段都是 `key: |` 块标量，解析出来带**引号和尾换行**：
       `eventId` → "\'2264847276362233513\'\n"。而事实层里既有的记录（模型路径写的）
       是干净的 "2242955368866323656"。两种形状混在一起会让去重整个失效——
       ⚠️ 2026-09-18 夹具实测：重抓同一个 issue，2 条变 3 条，每轮都会再复制一遍。
    ⚠️ 只动顶层字符串标量：`device` / `threads` 这类多行文本块要原样保留
       （fc_compact 的注释写着 threads 不要假设能拆）。
    """
    if not isinstance(event, dict):
        return event
    out = {}
    for key, value in event.items():
        if isinstance(value, str) and "\n" not in value.strip():
            v = value.strip()
            if len(v) >= 2 and v[0] == v[-1] and v[0] in ("'", '"'):
                v = v[1:-1]
            out[key] = v
        else:
            out[key] = value
    return out


def real_events(events):
    """真事件 = eventId 非空。⛔ 判据必须与 bin/lib/factcache.sh 的 fc_real_events 一致。"""
    out = []
    for e in events or []:
        if isinstance(e, dict) and str(e.get("eventId") or "").strip():
            out.append(e)
    return out


def load_record(path):
    if not os.path.exists(path) or os.path.getsize(path) == 0:
        return None
    try:
        with open(path, "r") as fh:
            return json.load(fh)
    except (ValueError, IOError):
        # ⛔ 非法 JSON 不当成「没有文件」：那会让下面按全量抓取后覆盖写，
        #    把一个坏文件悄悄换成新文件、丢掉它原有的事件。交给调用方的断言去报。
        return "CORRUPT"


def fetch_events(session, app_id, issue_id, start_iso, end_iso, page_size):
    """返回 (事件列表, 错误说明)。⚠️ 参数是 camelCase 且 issueId 必须嵌在 filter 里——
    实测平铺会被拒：`Must specify 'filter.issueId' or 'filter.issueVariantId'`。"""
    args = {
        "appId": app_id,
        "filter": {
            "issueId": issue_id,
            "intervalStartTime": start_iso,
            "intervalEndTime": end_iso,
        },
        "pageSize": page_size,
    }
    attempt = 0
    while True:
        text, is_error = result_text(session.call("crashlytics_list_events", args))
        if text is None:
            return None, "MCP 无响应"
        if is_error:
            if "429" in text or "RESOURCE_EXHAUSTED" in text or "quota" in text.lower():
                if attempt < len(BACKOFF_SECONDS):
                    time.sleep(BACKOFF_SECONDS[attempt])
                    attempt += 1
                    continue
                return None, "429 退避两轮后仍失败"
            return None, text.strip().splitlines()[0][:120] if text.strip() else "未知错误"
        try:
            parsed = yaml.safe_load(text)
        except yaml.YAMLError as exc:
            return None, "YAML 解析失败：%s" % str(exc)[:100]
        if parsed is None:
            return [], None
        if not isinstance(parsed, list):
            return None, "返回不是列表（拿到 %s）" % type(parsed).__name__
        return [clean_scalars(e) for e in parsed], None


def merge(existing, fetched):
    """已有事件原样保留、只 append 新增。⛔ 不改写既有记录（fc_compact 压过的也不复原）。"""
    seen = set()
    merged = []
    for e in existing:
        merged.append(e)
        seen.add(str(e.get("eventId")))
    added = 0
    for e in real_events(fetched):
        if str(e.get("eventId")) in seen:
            continue
        merged.append(e)
        seen.add(str(e.get("eventId")))
        added += 1
    return merged, added


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--issues-dir", required=True)
    ap.add_argument("--ios-app", required=True)
    ap.add_argument("--android-app", required=True)
    ap.add_argument("--days", type=int, required=True)
    ap.add_argument("--page-size", type=int, default=50)
    ap.add_argument("--force", action="store_true")
    ap.add_argument("--mcp-command", default="npx -y firebase-tools@latest mcp --only crashlytics")
    # ⛔ 看门狗：MCP 挂起过就会把整轮跑批拖死（stdout.readline 无限等）。
    # ⚠️ 本脚本不 source bin/lib.sh（副作用太大），所以超时自带，不用 run_with_timeout。
    ap.add_argument("--timeout", type=int, default=600)
    args = ap.parse_args()

    def _timeout(signum, frame):
        raise RuntimeError("MCP 取数超时（%ds）" % args.timeout)
    signal.signal(signal.SIGALRM, _timeout)
    signal.alarm(args.timeout)

    tasks = []
    for line in sys.stdin:
        parts = line.rstrip("\n").split("\t")
        if len(parts) < 2 or not parts[0]:
            continue
        online = 0
        if len(parts) > 2:
            try:
                online = int(parts[2])
            except ValueError:
                online = 0
        tasks.append((parts[0], parts[1], online))

    if not tasks:
        print("  事实层（确定性）：无待抓 issue")
        return 0

    # ⚠️ 显式区间是硬要求：不传就是 API 默认的 7 天窗，欠账记录的事件多半在 7 天之外，
    #    会空手而归、看起来像「抓不到」，其实是没去要（归档 change events-backfill 的 F-0）。
    now = datetime.utcnow()
    end_iso = now.strftime("%Y-%m-%dT%H:%M:%SZ")
    start_iso = (now - timedelta(days=args.days)).strftime("%Y-%m-%dT%H:%M:%SZ")

    try:
        session = McpSession(args.mcp_command.split())
    except (OSError, RuntimeError) as exc:
        # ⛔ 起不来就非零退出，不能静默当作「无事可做」——那正是本 change 要消灭的降级。
        print("  ⚠️ 事实层（确定性）：MCP server 启动失败：%s" % str(exc)[:120])
        return 1
    n_skip = n_full = n_append = n_fail = 0
    added_total = 0
    failures = []
    try:
        for issue_id, platform, online in tasks:
            path = os.path.join(args.issues_dir, issue_id + ".json")
            record = load_record(path)
            if record == "CORRUPT":
                n_fail += 1
                failures.append("%s 文件非法 JSON，跳过（不覆盖）" % issue_id[:8])
                continue
            existing = real_events((record or {}).get("events"))
            if not args.force and record is not None and online <= len(existing):
                n_skip += 1
                continue
            app_id = args.ios_app if platform.startswith("ios") else args.android_app
            fetched, err = fetch_events(session, app_id, issue_id, start_iso, end_iso, args.page_size)
            if err is not None:
                n_fail += 1
                failures.append("%s %s" % (issue_id[:8], err))
                continue
            merged, added = merge(existing, fetched)
            # ⛔ 一条真事件都没有就**不落盘**：宁可留空让下一轮重抓，也不写出
            #    条数正确、内容中空的记录——那种记录会让抓取判定从此永久判命中跳过（F52）。
            if not merged:
                n_fail += 1
                failures.append("%s 未取到任何事件，不落盘（下轮重抓）" % issue_id[:8])
                continue
            out = record if isinstance(record, dict) else {"id": issue_id, "platform": platform}
            out["events"] = merged
            tmp = path + ".tmp"
            with open(tmp, "w") as fh:
                json.dump(out, fh, ensure_ascii=False)
            os.replace(tmp, path)
            added_total += added
            if record is None:
                n_full += 1
            else:
                n_append += 1
    except RuntimeError as exc:          # 看门狗
        print("  ⚠️ 事实层（确定性）：%s" % exc)
        n_fail += 1
    finally:
        signal.alarm(0)
        session.close()

    print("  事实层（确定性）：跳过 %d · 全量 %d · 增量 %d · 失败 %d · 新增事件 %d 条"
          % (n_skip, n_full, n_append, n_fail, added_total))
    for line in failures:
        print("    ⚠️ %s" % line)
    return 1 if n_fail else 0


if __name__ == "__main__":
    sys.exit(main())
