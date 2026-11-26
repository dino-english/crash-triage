#!/usr/bin/env bash
# 外壳层：技术诊断**日聚合**的取数与本地存储（change crash-tech-diagnostics；L1 日报 / L2 周报 / 回填共用）。
#
# ⚠️ 函数不跨进程：L1、L2、bin/diag-backfill.sh 各自 source。
# ⚠️ 依赖：${STATE}、bqq（bin/lib/bq.sh，须已 bq_init）、q_render（bin/lib/query.sh）、
#    SQL_DIAG_API_PRED（bq.sh）、core/diag.sh（diag_pick_suffix / diag_need_days）。
# ⛔ 可能失败的命令替换一律写成 `"$(trap - ERR; …)"`：errtrace 下 `$( )` 子 shell 继承 ERR trap，
#    外层的 `||` / `if` 都接不住——不清就会在「只降级」的路径上发一张假故障卡（tasks 8.5 审查 S1，bash 3.2 实测）。
# ⛔ 本文件的函数**失败只返回非零、不调 fail**：日报 / 周报里这一节取不到要降级成「取数失败」写进产物，
#    不能让整份报告因此失败，也不能冒充「平稳」（spec「检查失败不冒充平稳」）。
#
# 本地数据（$STATE/diag/，与 L0 的小时聚合同目录、不同文件）：
#   daily.jsonl           diag-daily.sql 的行 {d, kind, plat, ver, s1, s2, devices, users, events}
#   daily-coverage.json   {<MYT 日>: <取数 epoch 秒>}——判定某日是否已完整取过（core diag_need_days）

DIAG_DAILY_FILE="$STATE/diag/daily.jsonl"
DIAG_DAILY_COV="$STATE/diag/daily-coverage.json"
DIAG_DAILY_KEEP_DAYS=60          # 周报「前 4 周未出现」要 35 天；多留排障
# shellcheck disable=SC2034  # 由 L1 / L2 读取
DIAG_DAILY_MIN=50                # 日级激增：签名级 ≥50 台且 ≥3× 前 7 天均值（回测定稿，design 决策 3）
# shellcheck disable=SC2034  # 由 L1 读取
DIAG_DAILY_MULT=3

_diag_myt_epoch() { TZ=Asia/Kuala_Lumpur date -j -f '%Y-%m-%d %H:%M:%S' "$1 00:00:00" +%s; }
_diag_day_add() { TZ=Asia/Kuala_Lumpur date -j -v"$2"d -f '%Y-%m-%d' "$1" +%Y-%m-%d; }   # $1=日 $2=+N/-N

# diag_daily_fetch <起日> <止日> <计费上限字节> → 0 成功（写入本地）/ 非零失败（原因打到 stderr）
#   MYT 日 D 横跨 UTC D-1 与 D 两张表：区间 [起, 止] 要读 UTC 起-1 … 止 共 N+1 张，同一 UTC 日只读一张（日表优先）。
#   BQ_DRY_RUN=1 时只打印 bq 的扫描估算、不写本地。
diag_daily_fetch() {
  local from="$1" to="$2" max="$3"
  local e0 e1 e ids="" sufs="" tables rows rc=0 d suf
  e0=$(( $(_diag_myt_epoch "$from") - 86400 )); e1="$(_diag_myt_epoch "$to")"
  # MYT 0 点 = UTC 前一日 16:00，所以从 (起日 − 1 天) 的 UTC 日一直取到止日的 UTC 日
  for ((e = e0 + 43200; e <= e1 + 43200; e += 86400)); do
    d="$(date -u -r "$e" +%Y%m%d)"
    ids="${ids:+$ids,}'events_${d}','events_intraday_${d}'"
  done
  tables="$(trap - ERR; BQ_DRY_RUN='' BQ_MAX_BYTES=10000000000 BQ_MAX_ROWS=1000 bqq csv "$(q_render diag-tables.sql TABLE_IDS="$ids")")" || rc=$?
  [ "$rc" -eq 0 ] || { echo "  ⚠️ 技术诊断：查 GA4 表元数据失败（rc=${rc}）" >&2; return 1; }
  for ((e = e0 + 43200; e <= e1 + 43200; e += 86400)); do
    d="$(date -u -r "$e" +%Y%m%d)"
    suf="$(diag_pick_suffix "$tables" "$d")"
    [ -n "$suf" ] || { echo "  ⚠️ 技术诊断：GA4 表不存在（events_${d} 与 events_intraday_${d} 都没有）" >&2; return 1; }
    sufs="${sufs:+$sufs,}'${suf}'"
  done
  rows="$(trap - ERR; BQ_MAX_BYTES="$max" BQ_MAX_ROWS=1000000 bqq json \
            "$(q_render diag-daily.sql SUFFIXES="$sufs" DAY_FROM="$from" DAY_TO="$to" DIAG_API_PRED="$SQL_DIAG_API_PRED")")" || rc=$?
  if [ -n "${BQ_DRY_RUN:-}" ]; then
    # ⚠️ 只取字节数：dry-run 原始回包里带着执行账号的邮箱，不进日志
    echo "  🔎 dry-run ${from} ～ ${to}（$(printf '%s' "$sufs" | tr ',' '\n' | grep -c .) 张表）：$(printf '%s' "$rows" | jq -r '.statistics.totalBytesProcessed // "?"' 2>/dev/null || echo '?') 字节"
    return "$rc"
  fi
  [ "$rc" -eq 0 ] || { echo "  ⚠️ 技术诊断：日聚合查询失败（rc=${rc}，${from} ～ ${to}）" >&2; return 1; }
  local f="$STATE/diag/.fetch.$$.json"
  mkdir -p "$STATE/diag"
  printf '%s' "${rows:-[]}" > "$f"
  diag_daily_store "$f" "$from" "$to" || { rm -f "$f"; return 1; }
  rm -f "$f"
  echo "  （表 ${sufs}）"
}

# diag_daily_store <bq json 结果文件> <起日> <止日> → 0 / 非零：把 [起, 止] 整段替换进 daily.jsonl，并记取数时刻
#   ⛔ 行数据一律走文件（--slurpfile），不走 --argjson：37 天约 2 万行 / 3 MB，作参数传会撞 macOS 1 MB 的
#      ARG_MAX（2026-11-26 回填实测：查询已计费 48 GB，写本地时报「Argument list too long」）。
diag_daily_store() {
  local src="$1" from="$2" to="$3" norm="$STATE/diag/.norm.$$.json" lock="$STATE/diag/.daily.lock" i=0
  # 写锁（审查 G5）：L2（周一 05:30，带模型分析，耗时长）、L1（08:30）、手工回填可能同时读-改-写，
  # 最后写的一方会把另一方那几天整段盖掉，coverage 却记着「已完整」。等最多 120 秒；超过 10 分钟的锁视为残留。
  mkdir -p "$STATE/diag"
  until mkdir "$lock" 2>/dev/null; do
    if [ -n "$(find "$lock" -maxdepth 0 -mmin +10 2>/dev/null)" ]; then rmdir "$lock" 2>/dev/null || true; continue; fi
    i=$((i + 1)); [ "$i" -le 120 ] || { echo "  ⚠️ 技术诊断：等 daily.jsonl 写锁超时（120 秒）" >&2; return 1; }
    sleep 1
  done
  _diag_store_locked "$src" "$from" "$to" "$norm"; local rc=$?
  rmdir "$lock" 2>/dev/null || true
  return "$rc"
}
_diag_store_locked() {
  local src="$1" from="$2" to="$3" norm="$4"
  jq -c '[ .[] | .devices |= tonumber | .users |= tonumber | .events |= tonumber ]' "$src" > "$norm" \
    || { echo "  ⚠️ 技术诊断：日聚合结果不是合法 JSON" >&2; rm -f "$norm"; return 1; }
  local now keep tmp; now="$(date +%s)"; keep="$(_diag_day_add "$to" "-${DIAG_DAILY_KEEP_DAYS}")"
  tmp="$DIAG_DAILY_FILE.tmp.$$"
  { [ -s "$DIAG_DAILY_FILE" ] && cat "$DIAG_DAILY_FILE"; true; } \
    | jq -c -s --slurpfile new "$norm" --arg from "$from" --arg to "$to" --arg keep "$keep" '
        ([ .[] | select(.d < $from or .d > $to) ] + $new[0]) | map(select(.d >= $keep)) | sort_by(.d) | .[]' > "$tmp" \
    || { echo "  ⚠️ 技术诊断：写 daily.jsonl 失败" >&2; rm -f "$norm" "$tmp"; return 1; }
  mv "$tmp" "$DIAG_DAILY_FILE"
  # 区间内每一天都记取数时刻（某天 0 行也算取过——全天没有一条接口失败不可能，真出现就是数据问题，由产物里的 0 暴露）
  jq -c --arg from "$from" --arg to "$to" --argjson at "$now" '
      ($from | strptime("%Y-%m-%d") | mktime) as $a | ($to | strptime("%Y-%m-%d") | mktime) as $b
      | reduce range($a; $b + 1; 86400) as $t (.; .[($t | strftime("%Y-%m-%d"))] = $at)' \
    <<<"$( [ -s "$DIAG_DAILY_COV" ] && cat "$DIAG_DAILY_COV" || echo '{}' )" > "$DIAG_DAILY_COV.tmp.$$" \
    || { echo "  ⚠️ 技术诊断：写 daily-coverage.json 失败" >&2; rm -f "$norm"; return 1; }
  mv "$DIAG_DAILY_COV.tmp.$$" "$DIAG_DAILY_COV"
  echo "  技术诊断日聚合 ${from} ～ ${to}：$(jq length "$norm") 行"
  rm -f "$norm"
}

# diag_daily_ensure <日> <回看天数> <回填计费上限字节> → 0 / 非零
#   当日总是重取（同日重跑覆盖）；回看窗口里没取完整的日一次补齐（从最早缺的一天到最晚缺的一天，一条查询）。
#   ⛔ 回填失败返回非零——不能把缺的历史当成基线 0。
diag_daily_ensure() {
  local day="$1" n="$2" max="$3" need days i
  # 单日 = 两张 UTC 表；11-22 / 11-23 各约 4.3 GB，上限留到 25 GB（审查 G1：10 GB 只剩 16% 余量）
  diag_daily_fetch "$day" "$day" 25000000000 || return 1
  days="$(for ((i = n; i >= 1; i--)); do _diag_day_add "$day" "-$i"; done | jq -R . | jq -sc .)"
  need="$(diag_need_days "$( [ -s "$DIAG_DAILY_COV" ] && cat "$DIAG_DAILY_COV" || true )" "$days")"
  [ -n "$need" ] || return 0
  echo "  技术诊断：本地日聚合缺 $(printf '%s' "$need" | wc -w | tr -d ' ') 天 → 回填"
  # shellcheck disable=SC2086
  diag_daily_fetch "$(printf '%s\n' $need | head -1)" "$(printf '%s\n' $need | tail -1)" "$max" || return 1
}

# diag_daily_rows <起日> <止日> → stdout：本地 daily.jsonl 里区间内的行（JSON 数组）
#   ⚠️ 结果可达数 MB：调用方直接管道给核心层函数的 stdin，⛔ 不要先装进变量再作参数传
diag_daily_rows() {
  if [ -s "$DIAG_DAILY_FILE" ]; then
    jq -c -s --arg a "$1" --arg b "$2" '[ .[] | select(.d >= $a and .d <= $b) ]' "$DIAG_DAILY_FILE"
  else
    echo '[]'
  fi
}
