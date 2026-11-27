#!/usr/bin/env bash
# 外壳层：PostHog HogQL 取数（change crash-tech-diagnostics「PostHog 双源」；L0 / L1 / L2 / 回填共用）。
#
# 为什么有这一层：App 从 **iOS 2.1.2、Android 2.1.1** 起把技术诊断 `app_diagnostic` 改发 PostHog Logs，
# Firebase / GA4 停发（iOS 提交 2be0e62c2「将技术诊断迁移至 PostHog 官方 Logs」，2026-11-19；
# Android 见 daily-machine-hermes-ops docs/CLAUDE-客服机器人.md「PostHog Logs」）。只查 GA4 的话，
# iOS 的诊断随用户升级归零（2026-11-26 实测：iOS 2.1.2 GA4 设备 1382 台、诊断 0 条），读者会读成「无报错」。
#
# ⚠️ 函数不跨进程：L0、L1、L2、bin/diag-backfill.sh 各自 source。依赖 q_render（bin/lib/query.sh）。
# ⚠️ 凭据：CRASH_REPORT_POSTHOG_API_KEY（PostHog 只读 Personal API Key，项目 423878），只放 $STATE/local.env，
#    写成普通赋值、⛔ 不 export：ph_query 都在主进程里调，export 了会进 claude -p / MCP / lark-cli 等所有子进程的环境。
#    ⛔ 不进命令行参数（ps 看得见）：经 `curl -K -` 从 stdin 传请求头；⛔ 不进日志、不进审计。
# ⛔ 失败只返回非零、不调 fail（同 bin/lib/diag.sh）：L1 / L2 要降级成「取数失败」，L0 由调用方 fail。

PH_HOST="https://us.posthog.com"
PH_PROJECT=423878
# ⛔ PostHog 查询接口：不写 LIMIT 只回 100 行（hasMore:true）；LIMIT 写得再大也**悄悄截到 50000 行**，
#    且此时 hasMore 是 null（2026-11-27 实测）。模板一律写 LIMIT 50000，回满 50000 行就当作被截断、判失败。
PH_MAX_ROWS=50000

# ⛔ 没有「版本分界」常量：哪个版本取哪边由数据决定（core diag_pick，按平台 × 版本 × 天取设备多的一边）。
#    初版按版本号划分界（iOS ≥ 2.1.2、Android ≥ 2.1.1 取 PostHog），11-27 审查推翻：还没合入迁移的开发分支
#   （Android 2.2.0）照样发 GA4，按版本号会把它判给 PostHog，两边都看不到（design 决策 8）。

# 接口类签名谓词的 HogQL 写法。⛔ 与 bin/lib/bq.sh 的 SQL_DIAG_API_PRED 是**同一口径的两种方言**，改一处必须改另一处
#（check-scripts 抓不到 SQL 文本里的重复，失效模式 F1）：只用 api_result，code 非空且非 2xx。
# shellcheck disable=SC2034  # 由 q_render 渲染 HogQL 模板时读取
PH_DIAG_API_PRED="did = 'api_result' AND code != '' AND NOT match(code, '^http_2\\\\d\\\\d\$')"

# diag_ph_note → 一句话说明数据来源（日报 / 周报说明文字共用，不手写第二份）
diag_ph_note() {
  printf '%s' "GA4 与 PostHog Logs（只算 env=production；App 从 iOS 2.1.2、Android 2.1.1 起改发 PostHog）两处取，同一版本同一天只取设备数多的一边、不相加"
}

# ph_query <HogQL 模板名> <values JSON 文件> <输出文件> → 0 成功（输出文件 = 行对象 JSON 数组，键 = 列名）/ 非零失败
#   模板里的 {{X}} 由 q_render 换（只放代码常量），{name} 是 HogQL 占位，值来自 values 文件——
#   ⛔ 来自数据的值（签名等）只能走 values，不拼进查询文本。
#   CRASH_REPORT_BQ_CACHE 非空时同 bqq：按请求内容缓存回包，冻结数据做等价性验收（⛔ 生产禁用）。
ph_query() {
  local tpl="$1" vals="$2" out="$3" key="${CRASH_REPORT_POSTHOG_API_KEY:-}"
  local q body resp code rc=0 n ck=""
  _ph_audit() { if declare -F audit >/dev/null; then audit ph.call "" "$(jq -cn --arg t "$tpl" --arg ok "$1" --arg why "${2:-}" --argjson n "${3:-null}" '{template:$t, ok:($ok == "1"), why:$why, rows:$n}')"; fi; }
  [ -n "$key" ] || { echo "  ⚠️ PostHog：未配置 CRASH_REPORT_POSTHOG_API_KEY（\$STATE/local.env）" >&2; _ph_audit 0 no_key; return 1; }
  # ⛔ 可能失败的命令替换一律 `"$(trap - ERR; …)"`：errtrace 下子 shell 继承 ERR trap，失败时先发一张假故障卡（F72）
  q="$(trap - ERR; q_render "$tpl" PH_DIAG_API_PRED="$PH_DIAG_API_PRED")" || return 1
  body="$(mktemp "${TMPDIR:-/tmp}/ph-body.XXXXXX")"; resp="$(mktemp "${TMPDIR:-/tmp}/ph-resp.XXXXXX")"
  jq -n --arg q "$q" --slurpfile v "$vals" \
     '{query: {kind: "HogQLQuery", query: $q, values: $v[0]}, refresh: "force_blocking"}' > "$body" \
    || { echo "  ⚠️ PostHog：values 不是合法 JSON（${vals}）" >&2; rm -f "$body" "$resp"; return 1; }
  if [ -n "${CRASH_REPORT_BQ_CACHE:-}" ]; then
    ck="$CRASH_REPORT_BQ_CACHE/ph-$(shasum -a 256 < "$body" | cut -c1-32).json"
  fi
  if [ -n "$ck" ] && [ -s "$ck" ]; then
    cp "$ck" "$resp"; code=200
  else
    code="$(trap - ERR; printf 'header = "Authorization: Bearer %s"\n' "$key" \
            | curl -sS --max-time 180 -K - -o "$resp" -w '%{http_code}' -X POST \
                   "$PH_HOST/api/projects/$PH_PROJECT/query/" -H 'Content-Type: application/json' --data-binary @"$body")" || rc=$?
    if [ "$rc" -ne 0 ]; then
      echo "  ⚠️ PostHog：请求失败（curl rc=${rc}，模板 ${tpl}）" >&2; rm -f "$body" "$resp"; _ph_audit 0 "curl_rc_${rc}"; return 1
    fi
  fi
  rm -f "$body"
  # 错误回包形如 {"type":"validation_error","detail":"…"}；成功回包 error 为 null、results 为数组
  if [ "$code" != 200 ] || ! jq -e '(.results | type) == "array" and (.error == null)' "$resp" >/dev/null 2>&1; then
    echo "  ⚠️ PostHog：查询失败（HTTP ${code}，模板 ${tpl}）：$(trap - ERR; jq -r '.detail // .error // empty' "$resp" 2>/dev/null | head -c 200 || true)" >&2
    rm -f "$resp"; _ph_audit 0 "http_${code}"; return 1
  fi
  n="$(jq '.results | length' "$resp")"   # 上面已校验 results 是数组，这里不会失败
  if [ "$n" -ge "$PH_MAX_ROWS" ] || [ "$(jq -r '.hasMore // false' "$resp")" = true ]; then
    echo "  ⚠️ PostHog：结果 ${n} 行到了上限（${PH_MAX_ROWS}），可能被截断（模板 ${tpl}）" >&2
    rm -f "$resp"; _ph_audit 0 truncated "$n"; return 1
  fi
  [ -z "$ck" ] || [ -s "$ck" ] || cp "$resp" "$ck"
  jq -c '.columns as $c | [ .results[] | [$c, .] | transpose | map({(.[0]): .[1]}) | add ]' "$resp" > "$out" \
    || { echo "  ⚠️ PostHog：回包转换失败（模板 ${tpl}）" >&2; rm -f "$resp"; return 1; }
  rm -f "$resp"
  _ph_audit 1 "" "$n"   # audit 来自 bin/lib.sh；只 source 了本文件的夹具里没有它，_ph_audit 自己判
  return 0
}
