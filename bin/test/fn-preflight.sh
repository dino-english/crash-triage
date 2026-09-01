ROOT="${CRASH_REPORT_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}"
. "$ROOT/bin/test/harness.sh"
h_load "$ROOT/bin/fetch-snapshot.sh" _endpoint_port _port_listening preflight_model_endpoint
MODEL_PROXY_LABEL="com.nonexistent.test"; MODEL_PROXY_WAIT=2
FH="$(mktemp -d)"; mkdir -p "$FH/.claude"

printf '%s' '{"env":{}}' > "$FH/.claude/settings.json"
out="$(HOME="$FH" h_run preflight_model_endpoint 2>&1)"; rc=$?
h_assert_eq "0" "$rc" "未配置端点 → rc=0"
h_assert_eq "" "$out" "未配置端点 → 零输出（⛔ 不得在每台机器每轮刷噪声）"

printf '%s' '{"env":{"ANTHROPIC_BASE_URL":"https://api.anthropic.com"}}' > "$FH/.claude/settings.json"
out="$(HOME="$FH" h_run preflight_model_endpoint 2>&1)"; rc=$?
h_assert_eq "0" "$rc" "远端端点 → rc=0"
h_assert_eq "" "$out" "远端端点 → 零输出"

printf '%s' '{"env":{"ANTHROPIC_BASE_URL":"http://127.0.0.1:65533"}}' > "$FH/.claude/settings.json"
out="$(HOME="$FH" h_run preflight_model_endpoint 2>&1)"; rc=$?
h_assert_eq "0" "$rc" "端点不通且拉不起来 → 仍 rc=0（⛔ 预检不得成为整跑失败原因）"
h_assert_contains "$out" "无人监听" "端点不通 → 播报"
h_assert_contains "$out" "照常调用模型" "拉起失败 → 明说继续，不假装成功"
h_summary
