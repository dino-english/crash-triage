#!/usr/bin/env bash
# 双向测试：模型端点预检 + ConnectionRefused 分类分支
ROOT="${CRASH_REPORT_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}"
. "$ROOT/bin/test/harness.sh"

# ── A. _endpoint_port：三种配置 ───────────────────────────
h_load "$ROOT/bin/fetch-snapshot.sh" _endpoint_port

FAKE_HOME="$(mktemp -d)"; mkdir -p "$FAKE_HOME/.claude"

_case() { printf '%s' "$2" > "$FAKE_HOME/.claude/settings.json"; HOME="$FAKE_HOME" _endpoint_port; }

out="$(_case x '{"env":{"ANTHROPIC_BASE_URL":"http://127.0.0.1:15721"}}')"
h_assert_eq "15721" "$out" "本机端点 → 解析出端口"

out="$(_case x '{"env":{"ANTHROPIC_BASE_URL":"https://api.anthropic.com"}}')"
h_assert_eq "" "$out" "远端端点 → 空（⛔ 不去猜远端可达性）"

out="$(_case x '{"env":{}}')"
h_assert_eq "" "$out" "未配置 → 空"

rm -f "$FAKE_HOME/.claude/settings.json"
out="$(HOME="$FAKE_HOME" _endpoint_port)"
h_assert_eq "" "$out" "配置文件不存在 → 空且不报错"

out="$(_case x 'this-is-not-json{{{')"
h_assert_eq "" "$out" "配置损坏 → 空且不报错"

# ── B. 分类分支：ConnectionRefused 走新支，有码走旧支 ────────
classify() { # $1=日志文本 → "reason|hint"
  local _atxt="$1" _alog="/tmp/agent" TRIAGE_RC=1
  local ANALYSIS_SKIP_REASON="" ANALYSIS_FIX_HINT="" _acode
  _acode="$(printf '%s' "$_atxt" | grep -oE 'API Error: [0-9]{3}' | grep -oE '[0-9]{3}' | tail -1 || true)"
  if printf '%s' "$_atxt" | grep -q 'ConnectionRefused\|Connection refused'; then
    ANALYSIS_SKIP_REASON="模型端点连接被拒（本机代理未运行）"
    ANALYSIS_FIX_HINT="检查 ANTHROPIC_BASE_URL 指向的本机代理是否在监听"
  else
  case "${_acode:-}" in
    (429) ANALYSIS_SKIP_REASON="模型额度耗尽（API 429）"; ANALYSIS_FIX_HINT="额度恢复后重跑" ;;
    (529) ANALYSIS_SKIP_REASON="模型服务端过载（API 529）"; ANALYSIS_FIX_HINT="稍后重跑" ;;
    (5??) ANALYSIS_SKIP_REASON="模型服务端错误（API ${_acode}）"; ANALYSIS_FIX_HINT="稍后重跑" ;;
    (4??) ANALYSIS_SKIP_REASON="模型请求被拒（API ${_acode}）"; ANALYSIS_FIX_HINT="看日志定位" ;;
    (*)   ANALYSIS_SKIP_REASON="模型不可用（退出码 ${TRIAGE_RC:-?}）"; ANALYSIS_FIX_HINT="未能识别" ;;
  esac
  fi
  printf '%s|%s' "$ANALYSIS_SKIP_REASON" "$ANALYSIS_FIX_HINT"
}

REAL='API Error: Connection refused — a firewall or proxy may be blocking it (ConnectionRefused)'
out="$(h_run classify "$REAL")"
h_assert_contains "$out" "本机代理未运行" "正样本：08-31 真实日志原文 → 新分支"
h_assert_contains "$out" "ANTHROPIC_BASE_URL" "正样本：补救建议指向端点，不是额度"

out="$(h_run classify 'API Error: 529 Overloaded')"
h_assert_contains "$out" "529" "负样本：529 仍走旧分支（⛔ 不得被新分支吃掉）"

out="$(h_run classify 'API Error: 429 rate limit')"
h_assert_contains "$out" "额度耗尽" "负样本：429 仍走旧分支"

out="$(h_run classify 'some unrelated failure with no code')"
h_assert_contains "$out" "未能识别" "负样本：无码无 refused → 仍落兜底分支"

out="$(h_run classify '')"
h_assert_contains "$out" "未能识别" "负样本：空日志 → 兜底分支，不误判"

h_summary
