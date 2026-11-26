#!/usr/bin/env bash
# .claude/hooks/guard.py 的双向测试：每条规则的违规样本必须被拦（退出码 2），相邻的正常写法必须放行（0）。
# 只喂 JSON、不执行任何样本命令；R1 / R2 用一个改了进程名的 sleep 冒充「正在跑的跑批」。
ROOT="${CRASH_REPORT_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}"
. "$ROOT/bin/test/harness.sh"
G="$ROOT/.claude/hooks/guard.py"
[ -f "$G" ] || { echo "❌ 缺 $G"; exit 1; }

hook() { # $1=工具名 $2=tool_input JSON → 退出码
  local rc=0
  jq -cn --arg t "$1" --argjson i "$2" '{tool_name:$t, tool_input:$i}' \
    | CLAUDE_PROJECT_DIR="$ROOT" /usr/bin/python3 "$G" >/dev/null 2>&1 || rc=$?
  echo "$rc"
}
bash_in() { jq -cn --arg c "$1" --argjson t "${2:-null}" --argjson b "${3:-false}" '{command:$c, timeout:$t, run_in_background:$b}'; }
block() { h_assert_eq 2 "$(hook Bash "$(bash_in "$@")")" "拦：$1"; }
allow() { h_assert_eq 0 "$(hook Bash "$(bash_in "$@")")" "放：$1"; }

echo "── R5 循环里 pgrep -f ──"
block 'until ! pgrep -f "bin/crash-daily.sh" >/dev/null; do sleep 5; done'
allow 'pgrep -fl "crash-daily|crash-weekly" || echo 无跑批进程'
allow 'until grep -q 完成 run.log; do sleep 5; done'

echo "── R4 日报机手工跑 L1 / L2 ──"
block "ssh dino911s-mac-mini 'cd ~/gitWorkspace/crash-triage && bash bin/crash-daily.sh'"
block "ssh -o BatchMode=yes dino911s-mac-mini 'bash ~/.hermes/scripts/crash-weekly.sh'"
block "ssh dino911s-mac-mini 'export PATH=/opt/homebrew/bin; hermes cron run 72f0850e6688'"
allow "ssh dino911s-mac-mini 'CRASH_REPORT_STATE_DIR=/tmp/shadow CRASH_REPORT_NO_DELIVER=1 bash bin/crash-daily.sh'"
allow "ssh dino911s-mac-mini 'cd ~/gitWorkspace/crash-triage && bash bin/update.sh'"
allow "ssh dino911s-mac-mini 'grep -n diag bin/crash-daily.sh; env -i HOME=\$HOME /bin/bash ~/.hermes/scripts/diag-hourly.sh'"

echo "── R3 整跑设短超时 ──"
block 'CRASH_REPORT_NO_DELIVER=1 bash bin/crash-daily.sh' null false
block 'CRASH_REPORT_DRY_RUN=1 bash bin/crash-weekly.sh' 120000 false
block 'timeout 300 bash bin/crash-daily.sh > run.log 2>&1' 600000 false
block 'BASELINE_BQ_CACHE=/x bash bin/test/baseline.sh L1 /tmp/out' 300000 false
allow 'CRASH_REPORT_NO_DELIVER=1 bash bin/crash-daily.sh' 600000 false
allow 'CRASH_REPORT_NO_DELIVER=1 bash bin/crash-daily.sh' null true
allow 'timeout 1500 bash bin/crash-daily.sh > run.log 2>&1' 600000 false
allow 'timeout 60 git fetch --quiet origin' null false
allow 'bash -n bin/crash-daily.sh bin/crash-weekly.sh && echo syntax-ok'
allow 'grep -n "DIAG_" bin/crash-daily.sh | head'
allow 'shellcheck -S warning bin/crash-daily.sh'
allow 'bash bin/check-scripts.sh > /tmp/cs.out 2>&1' 600000

echo "── R1 / R2：用 ps 桩（CLAUDE_GUARD_PS）冒充「此刻在跑什么」，不受机器上真实进程影响 ──"
PSF="$(mktemp)"; trap 'rm -f "$PSF"' EXIT
export CLAUDE_GUARD_PS="$PSF"
# 只是「提到」路径的进程：工具外壳的 zsh / bash -c、ssh、grep —— ⛔ 不算跑批（2026-11-26 试跑时的误报）
cat > "$PSF" <<PS
101 /bin/zsh -c source snap.sh && bash bin/crash-daily.sh > run.log
102 ssh -o BatchMode=yes dino911s-mac-mini cd ~/gitWorkspace/crash-triage && bash bin/diag-hourly.sh
103 grep -n diag bin/crash-daily.sh
104 bash -c bash bin/crash-weekly.sh
105 bash /private/tmp/scratch/wt-head/bin/crash-daily.sh
PS
h_assert_eq 0 "$(hook Write "$(jq -cn '{file_path:"bin/test/fn-new.sh"}')")" "放：只有「提到路径」的进程 / worktree 里的跑批时，写 bin/test/ 新文件"
allow "kill 101"
# 真正在跑的本仓跑批
cat > "$PSF" <<PS
4242 bash bin/crash-daily.sh
4343 /bin/bash $ROOT/bin/test/baseline.sh L1 /tmp/out
PS
h_assert_eq 2 "$(hook Edit "$(jq -cn --arg p "$ROOT/bin/lib/diag.sh" '{file_path:$p}')")" "拦：跑批期间 Edit bin/lib/diag.sh"
h_assert_eq 2 "$(hook Write "$(jq -cn '{file_path:"bin/sql/new.sql"}')")" "拦：跑批期间 Write bin/sql/new.sql（相对路径）"
block "sed -i '' 's/a/b/' bin/crash-daily.sh"
h_assert_eq 0 "$(hook Edit "$(jq -cn --arg p "$ROOT/docs/CLAUDE-部署与运维.md" '{file_path:$p}')")" "放：跑批期间改 docs/"
h_assert_eq 0 "$(hook Edit "$(jq -cn --arg p "$ROOT/openspec/changes/x/tasks.md" '{file_path:$p}')")" "放：跑批期间改 openspec/"
block "kill 4242"
block "kill -TERM 4343"
block 'pkill -f bin/crash-daily.sh'
allow "kill -9 4242"
allow 'pkill -9 -f bin/crash-daily.sh'
allow "kill -0 4242"
: > "$PSF"
h_assert_eq 0 "$(hook Edit "$(jq -cn --arg p "$ROOT/bin/lib/diag.sh" '{file_path:$p}')")" "放：跑批结束后 Edit bin/"
allow "sed -i '' 's/a/b/' bin/crash-daily.sh"
unset CLAUDE_GUARD_PS

echo "── heredoc 正文不算命令 ──"
allow "$(printf '%s\n' "python3 - <<'PY'" 'print("bash bin/crash-daily.sh 是整跑")' 'PY')"
allow "$(printf '%s\n' "cat > /tmp/x.sh <<'EOF'" 'until ! pgrep -f foo; do sleep 1; done' 'EOF')"
block "$(printf '%s\n' "cat > /tmp/x.sh <<'EOF'" 'echo hi' 'EOF' 'bash bin/crash-daily.sh')"

echo "── 钩子自身出错一律放行 ──"
rc=0; printf 'not json' | /usr/bin/python3 "$G" >/dev/null 2>&1 || rc=$?
h_assert_eq 0 "$rc" "放：输入不是 JSON"
h_summary
