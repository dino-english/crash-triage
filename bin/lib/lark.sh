#!/usr/bin/env bash
# lark-cli 调用封装（F68）。deliver.sh 与 alert.sh 共用——⚠️ 函数不跨进程，两边各自 source。
# 调用方需预设 LK 数组（lark-cli [+ --profile]，见 deliver.sh 的 LARK_PROFILE 注释）。
#
# 所有 lark-cli 调用都走 lk：限流（429）时退避重试，其余失败原样返回（F68）。
# 2026-11-02 实测：日报文档与索引页都写完了，发卡片时撞上 `TAT endpoint rate limited (HTTP 429)`，
# 报文明说 `retryable: true`，脚本却直接判失败；紧接着的投递失败告警卡同样没发出去——
# 群里那天**什么都没收到**。日报机上 crash-triage 与
# Hermes 主机器人共用同一个应用的令牌配额，限流不是偶发能消灭的。
# ⚠️ 只认 429：它在令牌端 / 频控处就被拒了，业务调用没执行，重试建档、append 都不会写出重复；
#    5xx 等「可能已生效」的失败⛔不重试。卡片另有 idempotency-key 兜底。
# ⚠️ lark-cli 的错误 JSON 走 **stderr**（实测），判据看 stdout+stderr；两路原样分开回写，调用方的重定向语义不变。
LK_RETRY_DELAYS="20 60"
lk() { # $@=lark-cli 参数（不含 lark-cli 与 --profile）→ stdout/stderr/退出码同 lark-cli
  local _o _e _rc _d _ef
  _ef="$(mktemp)"
  for _d in $LK_RETRY_DELAYS ""; do
    # ⚠️ `||` 必须写在 $( ) 里面：写在外面时，errtrace 下子 shell 里的失败照样触发 ERR trap（bash 3.2 实测）
    rm -f "$_ef.rc"
    _o="$("${LK[@]}" "$@" 2>"$_ef" || echo "$?" > "$_ef.rc")"
    _rc=0; if [ -s "$_ef.rc" ]; then _rc="$(cat "$_ef.rc")"; fi
    _e="$(cat "$_ef")"
    [ "$_rc" -eq 0 ] && break
    [ -n "$_d" ] || break
    printf '%s\n%s' "$_o" "$_e" | grep -Eq '"code": *429([^0-9]|$)|"subtype": *"rate_limit"' || break
    echo "  ⏳ 飞书限流（429），${_d}s 后重试：lark-cli $1 $2" >&2
    sleep "$_d"
  done
  rm -f "$_ef" "$_ef.rc"
  if [ -n "$_o" ]; then printf '%s\n' "$_o"; fi
  if [ -n "$_e" ]; then printf '%s\n' "$_e" >&2; fi
  return "$_rc"
}
