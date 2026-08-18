#!/usr/bin/env bash
# 一键更新：拉代码 → 重探本机路径 → 刷新 wrapper → 自检 → 打印变更摘要。
#
# 不动的东西：授权、docs.json/folders.json（台账丢了会重建重复文档）、cron 时间表。
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(dirname "$SELF_DIR")"
STATE="${CRASH_REPORT_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/crash-triage}"

say() { printf '\n\033[1m%s\033[0m\n' "$*"; }

say "更新 $ROOT"
BEFORE="$(git -C "$ROOT" rev-parse --short HEAD 2>/dev/null || echo '?')"

# 未提交改动会让 pull 失败或产生冲突——先说清楚，不擅自 stash
if [ -n "$(git -C "$ROOT" status --porcelain 2>/dev/null)" ]; then
  echo "  ⚠️ 工作区有未提交改动，先处理再更新："
  git -C "$ROOT" status --short | head -10
  exit 1
fi

git -C "$ROOT" pull --ff-only 2>&1 | tail -3
AFTER="$(git -C "$ROOT" rev-parse --short HEAD 2>/dev/null || echo '?')"

if [ "$BEFORE" = "$AFTER" ]; then
  echo "  已是最新（${AFTER}）"
else
  say "变更（$BEFORE → ${AFTER}）"
  git -C "$ROOT" log --oneline "$BEFORE..$AFTER" | head -20
  # SQL 或口径改动值得单独提醒：数字会变，别让人以为是线上出了问题
  if git -C "$ROOT" diff --name-only "$BEFORE" "$AFTER" | grep -q '^bin/sql/'; then
    echo "  ⚠️ SQL 有变更 —— 指标口径可能变化，明日数值波动先查这里"
  fi
fi

say "重探本机工具路径"
bash "$SELF_DIR/setup.sh" >/dev/null 2>&1 && echo "  ✅ config.env / mcp.json 已刷新" || echo "  ❌ setup.sh 失败"

say "刷新 hermes wrapper"
W="$HOME/.hermes/scripts"
if [ -f "$W/crash-daily.sh" ]; then
  # wrapper 里写死了 ROOT/STATE/CHAT_ID，代码目录搬过位就会指错
  grep -q "$ROOT" "$W/crash-daily.sh" && echo "  ✅ wrapper 路径正确" \
    || echo "  ⚠️ wrapper 指向的不是当前 ROOT，重跑 bin/install.sh 刷新"
else
  echo "  ⚠️ 未找到 wrapper，尚未安装定时任务（跑 bin/install.sh）"
fi

say "自检"
bash "$SELF_DIR/check-scripts.sh"

say "状态"
[ -s "$STATE/health-daily.json" ] && echo "  L1 $(jq -c '{last_run,ok}' "$STATE/health-daily.json")"
[ -s "$STATE/health.json" ] && echo "  L2 $(jq -c '{last_run,ok}' "$STATE/health.json")"
[ -s "$STATE/docs.json" ] && echo "  文档台账 $(jq 'length' "$STATE/docs.json") 条"
hermes cron list 2>/dev/null | grep -i crash | sed 's/^/  /' || echo "  （无 hermes cron 任务）"

say "更新完成"
