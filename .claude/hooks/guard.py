#!/usr/bin/env python3
"""PreToolUse 钩子：把 CLAUDE.md 里只靠文字约束的几条 ⛔ 硬规则变成机制（主会话和子 agent 都经过这里）。

退出码 2 = 拦下，stderr 的说明回给模型；其他情况（含钩子自己出错）一律放行——钩子坏了不能把正常工作堵死。
每条规则都对应一次真实事故或 CLAUDE.md 的一条 ⛔，出处写在规则旁边。改规则后跑 bin/test/fn-claude-guard.sh（双向测试）。

  R1 跑批期间改 bin/**          CLAUDE.md「跑批期间不得改 bin/**」：bash 按字节偏移边读边执行，改动让运行中的进程错位
  R2 用默认信号终止跑批          CLAUDE.md「终止跑批用 kill -9」：TERM 会被 ERR trap 捕获，发一张假故障告警卡
  R3 整跑设短超时                CLAUDE.md「整跑要 5 分钟以上，别设短超时」：被信号杀掉同样触发 ERR trap 发假告警
  R4 在日报机上跑测试            维护者规则（2026-11-27）：测试在本地机做，确认无误后才上生产；生产机只做只读查询。
                                 拦：在日报机上执行 bin/ 下的 crash-daily / crash-weekly / diag-hourly（⛔ 带 /tmp 影子副本也拦）、
                                 hermes cron run、往 ~/.hermes/scripts/ 写文件。放：update.sh、生产包装首跑、只读命令。
  R5 循环里用 pgrep -f 等进程    pgrep -f 匹配到这条命令自己，循环永不结束（2026-11-26 本仓实测踩到）
"""

from __future__ import annotations  # 钩子用系统 python3（macOS 自带 3.9）跑

import json
import os
import re
import subprocess
import sys

# 「执行」整跑脚本（⛔ 不是提到路径：grep / cat / bash -n / shellcheck 这些只读命令不算）
FULL_RUN = re.compile(
    r"(?:^|[\s;&|(])(?:bash|sh|exec)\s+(?!-n\b)(?:-[a-zA-Z]+\s+)*\S*bin/(?:crash-daily|crash-weekly|test/baseline)\.sh\b"
    r"|(?:^|[\s;&|(])\./bin/(?:crash-daily|crash-weekly)\.sh\b"
)
MINI = re.compile(r"\bssh\b[^\n]*\b(?:dino911s-mac-mini|100\.114\.17\.23)\b")
PROD_RUN = re.compile(
    r"(?:^|[\s;&|('\"])(?:bash|sh|exec)\s+\S*(?:bin/|\.hermes/scripts/)(?:crash-daily|crash-weekly)\.sh\b"
    r"|(?:^|[\s;&|('\"])(?:bash|sh|exec)\s+\S*bin/diag-hourly\.sh\b"
    r"|\bhermes\s+cron\s+run\b"
)
# 往生产调度脚本目录写文件（2026-11-27 实例：在日报机写临时探针脚本 + 建一次性 cron 任务做测试）
HERMES_SCRIPT_WRITE = re.compile(r"(?:>>?|\btee\b(?:\s+-a)?|\bcp\b[^\n;&|]*|\bmv\b[^\n;&|]*)\s*\S*\.hermes/scripts/")
LOOP = re.compile(r"\b(?:until|while)\b")
PGREP_F = re.compile(r"\bpgrep\b[^\n|;&]*\s-[a-zA-Z]*f")
KILL = re.compile(r"\b(kill|pkill|killall)\b([^\n;&|]*)")
# -9 / KILL 放行；-0 只检查进程在不在、不发信号，也放行
SIG9 = re.compile(r"(?:^|\s)-(?:9|0|KILL|SIGKILL|s\s+(?:9|0|KILL|SIGKILL))\b")
# 只认「紧挨着整跑命令」的那个 timeout（`timeout 60 git fetch; bash bin/crash-daily.sh` 里的 60 与整跑无关）
TIMEOUT_N = re.compile(
    r"\btimeout\s+(?:-\S+\s+)*(\d+)([smh]?)\s+(?:env\s+)?(?:[A-Za-z_]+=\S*\s+)*(?<![.\w])(?:bash|sh|exec)\s+(?:-[a-zA-Z]+\s+)*\S*bin/(?:crash-daily|crash-weekly|test/baseline)\.sh"
)
BIN_WRITE = re.compile(
    r"(?:\bsed\s+-i\b|\bperl\s+-[a-zA-Z]*i\b|\btee\b|>>?)\s*[^\n;&|]*?(?:^|[\s'\"/])bin/\S+"
)


def repo_root() -> str:
    return os.environ.get("CLAUDE_PROJECT_DIR") or os.getcwd()


def _ps(args: list[str]) -> str:
    """ps 的输出。测试用 CLAUDE_GUARD_PS 指向一个「pid<空格>command」的文件代替真 ps（夹具不受机器上此刻在跑什么影响）。"""
    fake = os.environ.get("CLAUDE_GUARD_PS")
    if fake:
        try:
            return open(fake).read()
        except Exception:
            return ""
    try:
        return subprocess.run(["ps"] + args, capture_output=True, text=True, timeout=5).stdout
    except Exception:
        return ""


SCRIPT = re.compile(r"^(?:\./)?(?:\S*/)?bin/(?:crash-daily|crash-weekly|diag-hourly|deliver|test/baseline)\.sh$")


def is_batch_cmd(cmd: str) -> bool:
    """是不是「正在执行」本仓的跑批脚本：argv[0] 是 bash / sh，紧跟的第一个非选项参数就是跑批脚本。
    ⛔ 只是命令行里**提到**路径的进程不算：zsh / bash -c 包装（工具外壳）、ssh、grep……
    （2026-11-26 试跑实测：本机 zsh 包装和 ssh 到日报机的命令曾被误当成跑批，拦了往 bin/test/ 写新文件）。"""
    toks = cmd.split()
    if not toks or os.path.basename(toks[0]) not in ("bash", "sh"):
        return False
    rest = [t for t in toks[1:] if not t.startswith("-")]
    if any(t == "-c" for t in toks[1:3]):
        return False
    if not rest or not SCRIPT.search(rest[0]):
        return False
    path = rest[0]
    return not path.startswith("/") or path.startswith(repo_root() + "/")  # 绝对路径要在本仓里（worktree / scratchpad 不算）


def running_batches() -> list[str]:
    """本机正在跑的、属于**本仓**的跑批进程。"""
    hits = []
    for line in _ps(["-axo", "pid=,command="]).splitlines():
        pid, _, cmd = line.strip().partition(" ")
        if pid != str(os.getpid()) and is_batch_cmd(cmd.strip()):
            hits.append(f"{pid} {cmd.strip()[:120]}")
    return hits


def pid_is_batch(pid: str) -> bool:
    for line in _ps(["-axo", "pid=,command="]).splitlines():
        p, _, cmd = line.strip().partition(" ")
        if p == pid:
            return is_batch_cmd(cmd.strip())
    return False


HEREDOC = re.compile(r"<<-?\s*(['\"]?)([A-Za-z_][A-Za-z0-9_]*)\1")


def strip_heredocs(cmd: str) -> str:
    """去掉 heredoc 正文：那是写进文件或喂给解释器的内容，不是要执行的命令参数。
    （历史 625 条命令回放：误报全来自 heredoc 正文——python 代码里的正则字符串、写进文件的脚本。）"""
    out, end = [], None
    for line in cmd.splitlines():
        if end is not None:
            if line.strip() == end:
                end = None
            continue
        out.append(line)
        m = HEREDOC.search(line)
        if m:
            end = m.group(2)
    return "\n".join(out)


def check_bash(cmd: str, tin: dict) -> str | None:
    cmd = strip_heredocs(cmd)
    # R5
    if LOOP.search(cmd) and PGREP_F.search(cmd):
        return ("R5：不要在 until/while 循环里用 pgrep -f 等进程——它会匹配到这条命令自己，循环永不结束。"
                "等指定进程用 kill -0 <PID>；等后台任务用完成通知。")
    # R4（先于 R2 / R3：远端命令里的 kill / timeout 是另一台机器的事）
    if MINI.search(cmd) and (PROD_RUN.search(cmd) or HERMES_SCRIPT_WRITE.search(cmd)):
        return ("R4：⛔ 不在日报机上做测试（维护者规则：测试在本地机做，确认无误后才上生产；生产机只做只读查询）。"
                "带 /tmp 影子副本也不行——2026-11-27 影子跑在生产 ~/.claude 写了空令牌文件、挂住 MCP 进程，又在生产建临时 cron 做探针。"
                "做法：把生产 STATE 只读复制到本机 scratchpad，在本机用 CRASH_REPORT_STATE_DIR=<副本> + NO_DELIVER 跑"
                "（.claude/skills/crash-report-debug/「用生产数据在本机验证」）。部署用 update.sh / 生产包装首跑不受影响。")
    if MINI.search(cmd):
        return None
    # R2
    for m in KILL.finditer(cmd):
        verb, args = m.group(1), m.group(2)
        if SIG9.search(" " + args):
            continue
        if verb in ("pkill", "killall") and re.search(r"crash-daily|crash-weekly|diag-hourly|deliver\.sh|baseline\.sh", args):
            return ("R2：终止跑批要用 -9（pkill -9 -f …）——默认 TERM 会被 ERR trap 捕获，发一张假故障告警卡（CLAUDE.md）。")
        if verb == "kill":
            for pid in re.findall(r"(?<![\w-])(\d{2,7})\b", args):
                if pid_is_batch(pid):
                    return (f"R2：pid {pid} 是跑批进程，终止要用 kill -9——默认 TERM 会被 ERR trap 捕获，发假故障告警卡（CLAUDE.md）。")
    # R3：前台整跑 L1 / L2（含 baseline.sh）
    if FULL_RUN.search(cmd):
        for n, unit in TIMEOUT_N.findall(cmd):
            secs = int(n) * {"": 1, "s": 1, "m": 60, "h": 3600}[unit]
            if secs < 900:
                return (f"R3：整跑 L1 / L2 要 5 分钟以上，`timeout {n}{unit}` 太短——被杀会触发 ERR trap 发假故障告警（CLAUDE.md）。"
                        "外层 timeout 给到 ≥ 900 秒，或放后台跑。")
        if not tin.get("run_in_background"):
            t = tin.get("timeout")
            if t is None or int(t) < 600000:
                return ("R3：前台整跑 L1 / L2 要 5 分钟以上，Bash 工具超时不足 600000 ms 会在中途杀掉进程、触发 ERR trap 发假故障告警（CLAUDE.md）。"
                        "设 timeout: 600000，或 run_in_background: true。")
    # R1（Bash 写 bin/）
    if BIN_WRITE.search(cmd):
        hits = running_batches()
        if hits:
            return ("R1：有跑批正在用本仓 bin/（" + "；".join(hits[:2]) + "），此刻不得改 bin/**——bash 边读边执行，"
                    "改动会让运行中的进程从错位处继续读（CLAUDE.md）。等它结束，或先 kill -9 它。")
    return None


def check_edit(path: str) -> str | None:
    root = repo_root()
    rel = os.path.relpath(os.path.abspath(path), root) if path else ""
    if not rel.startswith("bin" + os.sep):
        return None
    hits = running_batches()
    if hits:
        return ("R1：有跑批正在用本仓 bin/（" + "；".join(hits[:2]) + f"），此刻不得改 {rel}——bash 边读边执行，"
                "改动会让运行中的进程从错位处继续读（CLAUDE.md）。等它结束，或先 kill -9 它。")
    return None


def main() -> int:
    try:
        data = json.load(sys.stdin)
    except Exception:
        return 0
    tool, tin = data.get("tool_name", ""), data.get("tool_input") or {}
    try:
        if tool == "Bash":
            msg = check_bash(tin.get("command", ""), tin)
        elif tool in ("Edit", "Write", "MultiEdit", "NotebookEdit"):
            msg = check_edit(tin.get("file_path") or tin.get("notebook_path") or "")
        else:
            msg = None
    except Exception:
        return 0  # 钩子自身的错误不挡正常工作
    if msg:
        sys.stderr.write(msg + "\n")
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main())
