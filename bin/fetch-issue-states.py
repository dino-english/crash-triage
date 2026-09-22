#!/usr/bin/env python3
"""把每个事实层 issue 的 OPEN/CLOSED 状态取回来，写进缓存文件。

⛔ 为什么必须单独取：反扫（scan-fix-commits.sh）的输入是事实层缓存，而缓存
「一次抓取永久保留、不清理」——关闭的 issue 永远留在里面。2026-09-11 实测：
24 条缓存里 14 条已 CLOSED，其中 6 条被报成「已修待验」（失效模式 R4）。

⚠️ topIssues 只返回 OPEN（同日实测），但它按影响面截 top-N，**OPEN 但排不进
前 N 的 issue 拿不到**——所以不能靠它反推状态，必须逐个 get_issue。

⛔ 不经模型：直接 spawn MCP server 说 JSON-RPC。状态是确定性事实，
交给模型只会多一层不可信的转述（见记忆 measure-before-inferring）。

`--extra-ids <文件>`（change crash-issue-state-visibility）：日报明细表要标开关状态，
而它渲染的 issue 未必都在事实层里——事实层由 L2 周报写入，周中新出现的 issue 一条没有。
该文件每行 `<平台>\t<32位id>`，⚠️ 平台必须是 `ios` / `android`（⛔ 不是 L1 内部用的
`ios` / `and`，两套平台键见失效模式 F43），只查缓存里没有的 id。
⛔ **不给它们建事实层文件**：`.source` 字段由创建者写死、`assert-fact-cache.sh` 的断言
建立在「记录由 L2 抓取路径创建」之上，桩记录会污染两者。补查结果只经 `--emit-map` 出。

`--emit-map <文件>`：写出 `{id: state}`（缓存态 + 本次补查）。⛔ 不传就一个字节都不写，
`crash-weekly.sh` 那个不带新参数的调用点行为逐字节不变。
"""
import json, pathlib, subprocess, sys, re, time

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
        """⚠️ 带退避重试：这个 API **会瞬时报错**（2026-09-11 实测 24 条里 3 条失败，
        单独重试全部成功）。记忆 raw-mcp-call 记过「429 很常见，30s/60s 退避两轮即过」。
        ⛔ 不重试的代价是静默少报——无 state 的记录按保守规则不计入「已修待验」。"""
        for delay in (0, 10, 30):
            if delay:
                time.sleep(delay)
            self.n += 1
            self._send({"jsonrpc": "2.0", "id": self.n, "method": "tools/call", "params": {
                "name": "crashlytics_get_issue",
                "arguments": {"appId": app_id, "issueId": issue_id}}})
            txt = json.dumps(self._recv(self.n), ensure_ascii=False)
            m = re.search(r"state:\s*\|?\s*\\n?\s*([A-Z]+)", txt) or re.search(r'"state"\s*:\s*"([A-Z]+)"', txt)
            if m:
                return m.group(1)
        return None

    def close(self):
        self.p.terminate()


def parse_args(argv):
    """⚠️ 旗标必须在 mcp 命令之前解析完：`cmd = 剩余参数` 这个既有契约不能破
    （`crash-weekly.sh` / `crash-daily.sh` 都靠它传自定义 mcp 命令）。"""
    extra_ids = emit_map = None
    rest = []
    i = 0
    while i < len(argv):
        if argv[i] == "--extra-ids" and i + 1 < len(argv):
            extra_ids = argv[i + 1]; i += 2
        elif argv[i] == "--emit-map" and i + 1 < len(argv):
            emit_map = argv[i + 1]; i += 2
        else:
            rest.append(argv[i]); i += 1
    return extra_ids, emit_map, rest


def read_extra(path):
    """→ [(app_id, issue_id)]，⛔ 平台认不出就跳过：拿错 appId 查会白等三轮退避。"""
    out = []
    try:
        for line in pathlib.Path(path).read_text().splitlines():
            plat, _, iid = line.strip().partition("\t")
            if iid and plat in APPS:
                out.append((plat, iid))
    except Exception:
        pass
    return out


def main():
    if len(sys.argv) < 2:
        print("用法：fetch-issue-states.py <STATE目录> [--extra-ids 文件] [--emit-map 文件] [mcp命令...]",
              file=sys.stderr)
        return 2
    extra_path, emit_path, rest = parse_args(sys.argv[2:])
    issues = pathlib.Path(sys.argv[1]) / "issues"
    cmd = rest or ["npx", "-y", "firebase-tools@latest", "mcp", "--only", "crashlytics"]
    files = sorted(issues.glob("*.json"))
    extra = read_extra(extra_path) if extra_path else []
    # ⛔ 事实层为空时**不得**早退出：`--extra-ids` 的补查与事实层无关，
    #    周中新出现的 issue 正是「事实层里没有」的那一批。
    if not files and not extra:
        print("  事实层为空，跳过状态同步", file=sys.stderr)
        if emit_path:
            pathlib.Path(emit_path).write_text("{}\n")
        return 0
    mcp = MCP(cmd)
    state_map = {}
    ok = failed = 0
    failed_ids = []
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
            failed_ids.append((rec.get("id") or f.stem)[:8])
            continue
        rec["state"] = st
        rec["state_synced"] = __import__("datetime").datetime.now(__import__("datetime").timezone.utc) \
            .strftime("%Y-%m-%dT%H:%M:%SZ")
        f.write_text(json.dumps(rec, ensure_ascii=False, indent=2) + "\n")
        state_map[rec.get("id") or f.stem] = st
        counts[st] = counts.get(st, 0) + 1
        ok += 1
    # 补查：只查事实层里没有的 id。⚠️ 已在 state_map 里的一个都不重查——
    # 每次重查都是一趟网络往返，而缓存那一轮刚刚取过。
    extra_ok = 0
    for plat, iid in extra:
        if iid in state_map:
            continue
        st = mcp.state(APPS[plat], iid)
        if not st:
            failed += 1
            failed_ids.append(iid[:8])
            continue
        state_map[iid] = st
        counts[st] = counts.get(st, 0) + 1
        extra_ok += 1
    mcp.close()
    if emit_path:
        pathlib.Path(emit_path).write_text(json.dumps(state_map, ensure_ascii=False) + "\n")
    summary = " · ".join(f"{k} {v}" for k, v in sorted(counts.items()))
    # ⚠️ 失败必须报出**是哪几条**：只给个数没法诊断，而「无 state → 不计入」是静默少报。
    tail = f" · ⚠️ 失败 {failed} 条（{', '.join(failed_ids)}）" if failed else ""
    extra_note = f" · 补查 {extra_ok} 条" if extra else ""
    print(f"  issue 状态同步：{ok} 条（{summary}）{extra_note}{tail}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
