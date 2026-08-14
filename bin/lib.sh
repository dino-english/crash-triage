#!/usr/bin/env bash
# crash-report 共享函数。由 crash-daily.sh / crash-weekly.sh source。

# 带超时执行命令。**不依赖 coreutils 的 timeout/gtimeout**——Mac mini 上不一定装，
# 而定时任务因为缺个命令跑不起来是很蠢的失败方式。
#
# 用法：run_with_timeout <秒> <命令...>
# 返回：命令自身退出码；超时返回 124（沿用 GNU timeout 的约定）
run_with_timeout() {
  local secs="$1"; shift
  local pid waited=0 rc

  "$@" &
  pid=$!

  while kill -0 "$pid" 2>/dev/null; do
    if [ "$waited" -ge "$secs" ]; then
      echo "  ⏱️ 超时 ${secs}s，终止 pid $pid" >&2
      # 先礼后兵：TERM 给机会收尾，5 秒后 KILL。
      # 同时清理子进程——agent 会拉起 npx / MCP server，只杀父进程会留孤儿。
      pkill -TERM -P "$pid" 2>/dev/null || true
      kill -TERM "$pid" 2>/dev/null || true
      sleep 5
      pkill -KILL -P "$pid" 2>/dev/null || true
      kill -KILL "$pid" 2>/dev/null || true
      wait "$pid" 2>/dev/null || true
      return 124
    fi
    sleep 5
    waited=$((waited + 5))
  done

  wait "$pid"; rc=$?
  return $rc
}
