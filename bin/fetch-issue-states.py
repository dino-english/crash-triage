#!/usr/bin/env python3
"""把每个事实层 issue 的 OPEN/CLOSED 状态取回来，写进缓存文件。

⛔ 为什么必须单独取：反扫（scan-fix-commits.sh）的输入是事实层缓存，而缓存
「一次抓取永久保留、不清理」——关闭的 issue 永远留在里面。2026-09-11 实测：
24 条缓存里 14 条已 CLOSED，其中 6 条被报成「已修待验」（失效模式 R4）。

⚠️ topIssues 只返回 OPEN（同日实测），但它按影响面截 top-N，**OPEN 但排不进
前 N 的 issue 拿不到**——所以不能靠它反推状态，必须逐个 get_issue。

⛔ 不经模型：直接 spawn MCP server 说 JSON-RPC。状态是确定性事实，
交给模型只会多一层不可信的转述（见记忆 measure-before-inferring）。
"""
import json, pathlib, subprocess, sys, re

APPS = {"ios": "1:465344775452:ios:610bc2f8ea0750fff466d9",
        "android": "1:465344775452:android:2c546b57b0176325f466d9"}


class MCP:
    def __init__(self, cmd):
        self.p = subprocess.Popen(cmd, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                  stderr=subprocess.DEVNULL, text=True, bufsize=1)
        self._send({"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {
            "protocolVersion": "2024-11-05", "capabilities": {},
            "clientInfo": {"name": "fetch-issue-states", "version": "1"}}})
        self._recv(1)
        self._send({"jsonrpc": "2.0", "method": "notifications/initialized", "params": {}})
        self.n = 10

    def _send(self, o):
        self.p.stdin.write(json.dumps(o) + "\n"); self.p.stdin.flush()

    def _recv(self, i):
        while True:
            line = self.p.stdout.readline()
            if not line:
                return {}
            try:
                m = json.loads(line)
            except Exception:
                continue
            if m.get("id") == i:
                return m

    def state(self, app_id, issue_id):
        self.n += 1
        self._send({"jsonrpc": "2.0", "id": self.n, "method": "tools/call", "params": {
            "name": "crashlytics_get_issue",
            "arguments": {"appId": app_id, "issueId": issue_id}}})
        txt = json.dumps(self._recv(self.n), ensure_ascii=False)
        m = re.search(r"state:\s*\|?\s*\\n?\s*([A-Z]+)", txt) or re.search(r'"state"\s*:\s*"([A-Z]+)"', txt)
        return m.group(1) if m else None

    def close(self):
        self.p.terminate()


def main():
    if len(sys.argv) < 2:
        print("用法：fetch-issue-states.py <STATE目录> [mcp命令...]", file=sys.stderr)
        return 2
    issues = pathlib.Path(sys.argv[1]) / "issues"
    cmd = sys.argv[2:] or ["npx", "-y", "firebase-tools@latest", "mcp", "--only", "crashlytics"]
    files = sorted(issues.glob("*.json"))
    if not files:
        print("  事实层为空，跳过状态同步", file=sys.stderr)
        return 0
    mcp = MCP(cmd)
    ok = failed = 0
    counts = {}
    for f in files:
        try:
            rec = json.loads(f.read_text())
        except Exception:
            failed += 1
            continue
        st = mcp.state(APPS.get(rec.get("platform") or "android", APPS["android"]), rec.get("id") or f.stem)
        if not st:
            # ⛔ 取不到就**保持原值**：把未知写成 CLOSED 会让 issue 从台账上凭空消失
            failed += 1
            continue
        rec["state"] = st
        rec["state_synced"] = __import__("datetime").datetime.now(__import__("datetime").timezone.utc) \
            .strftime("%Y-%m-%dT%H:%M:%SZ")
        f.write_text(json.dumps(rec, ensure_ascii=False, indent=2) + "\n")
        counts[st] = counts.get(st, 0) + 1
        ok += 1
    mcp.close()
    summary = " · ".join(f"{k} {v}" for k, v in sorted(counts.items()))
    print(f"  issue 状态同步：{ok} 条（{summary}）" + (f" · ⚠️ 失败 {failed} 条" if failed else ""), file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
