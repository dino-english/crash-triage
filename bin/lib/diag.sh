#!/usr/bin/env bash
# 外壳层：技术诊断**日聚合**的取数与本地存储（change crash-tech-diagnostics；L1 日报 / L2 周报 / 回填共用）。
#
# ⚠️ 函数不跨进程：L1、L2、bin/diag-backfill.sh 各自 source。
# ⚠️ 依赖：${STATE}、bqq（bin/lib/bq.sh，须已 bq_init）、q_render（bin/lib/query.sh）、
#    SQL_DIAG_API_PRED（bq.sh）、core/diag.sh（diag_pick_suffix / diag_need_days / diag_pick / diag_day_gaps）。
#    PostHog 一侧（ph_query）由本文件自己 source bin/lib/posthog.sh。
# ⚠️ 两个数据源（design 决策 8）：App 从 iOS 2.1.2、Android 2.1.1 起改发 PostHog Logs，没合入迁移的分支仍发 GA4。
#    **存的时候两边原样存**（行带 src："ga4" / "posthog"；src 字段出现之前写入的行按 ga4 算），各取各的、各记各的覆盖，
#    整段替换时只换同一来源的行——补一边不会把另一边那几天抹掉，也不用为了补 PostHog 重扫 GA4。
#    **读的时候二选一**（diag_daily_rows 经 core diag_pick：每个平台 × 版本 × 天取设备多的一边）。
# ⛔ 可能失败的命令替换一律写成 `"$(trap - ERR; …)"`：errtrace 下 `$( )` 子 shell 继承 ERR trap，
#    外层的 `||` / `if` 都接不住——不清就会在「只降级」的路径上发一张假故障卡（tasks 8.5 审查 S1，bash 3.2 实测）。
# ⛔ 本文件的函数**失败只返回非零、不调 fail**：日报 / 周报里这一节取不到要降级成「取数失败」写进产物，
#    不能让整份报告因此失败，也不能冒充「平稳」（spec「检查失败不冒充平稳」）。
#
# 本地数据（$STATE/diag/，与 L0 的小时聚合同目录、不同文件）：
#   daily.jsonl                   diag-daily.sql / diag-daily.hogql 的行 {d, kind, plat, ver, s1, s2, devices, users, events, src}
#   daily-coverage.json           GA4 一侧 {<MYT 日>: <取数 epoch 秒>}——判定某日是否已完整取过（core diag_need_days）
#   daily-coverage-posthog.json   PostHog 一侧，格式同上

# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/posthog.sh"

DIAG_DAILY_FILE="$STATE/diag/daily.jsonl"
DIAG_DAILY_COV="$STATE/diag/daily-coverage.json"
DIAG_DAILY_COV_PH="$STATE/diag/daily-coverage-posthog.json"
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
  diag_daily_store "$f" "$from" "$to" ga4 || { rm -f "$f"; return 1; }
  rm -f "$f"
  echo "  （表 ${sufs}）"
}

# diag_daily_fetch_ph <起日> <止日> → 0 成功（写入本地）/ 非零失败（原因打到 stderr）：PostHog 一侧，同 diag_daily_fetch
#   一条 HogQL 查完整段（MYT [起日 0 点, 止日次日 0 点)）。PostHog 查询不计费，BQ_DRY_RUN=1 时直接跳过。
diag_daily_fetch_ph() {
  local from="$1" to="$2" t0 t1
  if [ -n "${BQ_DRY_RUN:-}" ]; then
    echo "  🔎 dry-run ${from} ～ ${to}：PostHog 查询不计费，跳过估算"; return 0
  fi
  t0="$(date -u -r "$(_diag_myt_epoch "$from")" '+%Y-%m-%d %H:%M:%S')"
  t1="$(date -u -r $(( $(_diag_myt_epoch "$to") + 86400 )) '+%Y-%m-%d %H:%M:%S')"
  local v="$STATE/diag/.phv.$$.json" f="$STATE/diag/.fetch-ph.$$.json"
  mkdir -p "$STATE/diag"
  jq -n --arg a "$t0" --arg b "$t1" '{t0: $a, t1: $b}' > "$v"
  ph_query diag-daily.hogql "$v" "$f" || { rm -f "$v" "$f"; echo "  ⚠️ 技术诊断：PostHog 日聚合查询失败（${from} ～ ${to}）" >&2; return 1; }
  rm -f "$v"
  diag_daily_store "$f" "$from" "$to" posthog || { rm -f "$f"; return 1; }
  rm -f "$f"
}

# diag_daily_store <结果文件（行 JSON 数组）> <起日> <止日> <ga4|posthog> → 0 / 非零：
#   把该来源 [起, 止] 的行（打上 src，⛔ 不在这里二选一）整段替换进 daily.jsonl，并在该来源的覆盖文件记取数时刻
#   ⛔ 行数据一律走文件（--slurpfile），不走 --argjson：37 天约 2 万行 / 3 MB，作参数传会撞 macOS 1 MB 的
#      ARG_MAX（2026-11-26 回填实测：查询已计费 48 GB，写本地时报「Argument list too long」）。
diag_daily_store() {
  local src="$1" from="$2" to="$3" kind="$4" norm="$STATE/diag/.norm.$$.json" lock="$STATE/diag/.daily.lock" i=0
  # 写锁（审查 G5）：L2（周一 05:30，带模型分析，耗时长）、L1（08:30）、手工回填可能同时读-改-写，
  # 最后写的一方会把另一方那几天整段盖掉，coverage 却记着「已完整」。等最多 120 秒；超过 10 分钟的锁视为残留。
  mkdir -p "$STATE/diag"
  until mkdir "$lock" 2>/dev/null; do
    if [ -n "$(find "$lock" -maxdepth 0 -mmin +10 2>/dev/null)" ]; then rmdir "$lock" 2>/dev/null || true; continue; fi
    i=$((i + 1)); [ "$i" -le 120 ] || { echo "  ⚠️ 技术诊断：等 daily.jsonl 写锁超时（120 秒）" >&2; return 1; }
    sleep 1
  done
  _diag_store_locked "$src" "$from" "$to" "$norm" "$kind"; local rc=$?
  rmdir "$lock" 2>/dev/null || true
  return "$rc"
}
_diag_store_locked() {
  local src="$1" from="$2" to="$3" norm="$4" kind="$5" cov
  case "$kind" in (ga4) cov="$DIAG_DAILY_COV" ;; (posthog) cov="$DIAG_DAILY_COV_PH" ;;
                  (*) echo "  ⚠️ 技术诊断：未知数据源 ${kind}" >&2; return 1 ;; esac
  jq -c --arg k "$kind" '[ .[] | .devices |= tonumber | .users |= tonumber | .events |= tonumber | . + {src: $k} ]' "$src" > "$norm" \
    || { echo "  ⚠️ 技术诊断：日聚合结果不是合法 JSON" >&2; rm -f "$norm"; return 1; }
  local now keep tmp; now="$(date +%s)"; keep="$(_diag_day_add "$to" "-${DIAG_DAILY_KEEP_DAYS}")"
  tmp="$DIAG_DAILY_FILE.tmp.$$"
  { [ -s "$DIAG_DAILY_FILE" ] && cat "$DIAG_DAILY_FILE"; true; } \
    | jq -c -s --slurpfile new "$norm" --arg from "$from" --arg to "$to" --arg keep "$keep" --arg src "$kind" '
        ([ .[] | select(.d < $from or .d > $to or ((.src // "ga4") != $src)) ] + $new[0])
        | map(select(.d >= $keep)) | sort_by(.d) | .[]' > "$tmp" \
    || { echo "  ⚠️ 技术诊断：写 daily.jsonl 失败" >&2; rm -f "$norm" "$tmp"; return 1; }
  mv "$tmp" "$DIAG_DAILY_FILE"
  # 区间内每一天都记取数时刻（某天 0 行也算取过——全天没有一条接口失败不可能，真出现就是数据问题，由产物里的 0 暴露）
  jq -c --arg from "$from" --arg to "$to" --argjson at "$now" '
      ($from | strptime("%Y-%m-%d") | mktime) as $a | ($to | strptime("%Y-%m-%d") | mktime) as $b
      | reduce range($a; $b + 1; 86400) as $t (.; .[($t | strftime("%Y-%m-%d"))] = $at)' \
    <<<"$( [ -s "$cov" ] && cat "$cov" || echo '{}' )" > "$cov.tmp.$$" \
    || { echo "  ⚠️ 技术诊断：写 $(basename "$cov") 失败" >&2; rm -f "$norm"; return 1; }
  mv "$cov.tmp.$$" "$cov"
  echo "  技术诊断日聚合 ${from} ～ ${to}（$([ "$kind" = ga4 ] && echo GA4 || echo PostHog)）：$(jq length "$norm") 行"
  rm -f "$norm"
}

# diag_daily_ensure <日> <回看天数> <回填计费上限字节> → 0 / 非零
#   当日总是重取（同日重跑覆盖）；回看窗口里没取完整的日一次补齐（从最早缺的一天到最晚缺的一天，一条查询）。
#   GA4、PostHog 两边各自判缺、各自补（上线后 PostHog 一侧首次补满回看窗口，GA4 一侧不受影响、不重扫）。
#   ⛔ 任一边失败都返回非零——不能把缺的历史当成基线 0，也不能拿一半的数据冒充全量。
diag_daily_ensure() {
  local day="$1" n="$2" max="$3" need days i src cov
  # 单日 = 两张 UTC 表；11-22 / 11-23 各约 4.3 GB，上限留到 25 GB（审查 G1：10 GB 只剩 16% 余量）
  diag_daily_fetch "$day" "$day" 25000000000 || return 1
  diag_daily_fetch_ph "$day" "$day" || return 1
  days="$(for ((i = n; i >= 1; i--)); do _diag_day_add "$day" "-$i"; done | jq -R . | jq -sc .)"
  for src in ga4 posthog; do
    if [ "$src" = ga4 ]; then cov="$DIAG_DAILY_COV"; else cov="$DIAG_DAILY_COV_PH"; fi
    need="$(trap - ERR; diag_need_days "$( [ -s "$cov" ] && cat "$cov" || true )" "$days")" || return 1
    [ -n "$need" ] || continue
    echo "  技术诊断：本地日聚合（$([ "$src" = ga4 ] && echo GA4 || echo PostHog)）缺 $(printf '%s' "$need" | wc -w | tr -d ' ') 天 → 回填"
    # shellcheck disable=SC2086
    if [ "$src" = ga4 ]; then
      diag_daily_fetch "$(printf '%s\n' $need | head -1)" "$(printf '%s\n' $need | tail -1)" "$max" || return 1
    else
      diag_daily_fetch_ph "$(printf '%s\n' $need | head -1)" "$(printf '%s\n' $need | tail -1)" || return 1
    fi
  done
}

# diag_daily_rows <起日> <止日> [raw] → stdout：本地 daily.jsonl 里区间内的行（JSON 数组），
#   默认经 core diag_pick 二选一（每个平台 × 版本 × 天只留一个来源）；第三参数 raw = 两边原样（断数检测用）。
#   ⚠️ 结果可达数 MB：调用方直接管道给核心层函数的 stdin，⛔ 不要先装进变量再作参数传
diag_daily_rows() {
  if [ -s "$DIAG_DAILY_FILE" ]; then
    if [ "${3:-}" = raw ]; then
      jq -c -s --arg a "$1" --arg b "$2" '[ .[] | select(.d >= $a and .d <= $b) ]' "$DIAG_DAILY_FILE"
    else
      jq -c -s --arg a "$1" --arg b "$2" '[ .[] | select(.d >= $a and .d <= $b) ]' "$DIAG_DAILY_FILE" | diag_pick d
    fi
  else
    echo '[]'
  fi
}

# diag_daily_gaps <起日> <止日> → stdout：区间内断数的「来源@日」（空格分隔，空串 = 没有），见 core diag_day_gaps。
#   L1 / L2 取数成功后调：有断数就把这一节降级成「取数失败」——0 行的那天会被记成「取过」，不在这里拦就再也不重取。
diag_daily_gaps() {
  local days
  days="$(i=0; d="$1"; while [ "$d" \< "$2" ] || [ "$d" = "$2" ]; do printf '%s\n' "$d"; d="$(_diag_day_add "$d" +1)"; i=$((i + 1)); [ "$i" -le 400 ] || break; done | jq -R . | jq -sc .)"
  diag_daily_rows "$(_diag_day_add "$1" -7)" "$2" raw | diag_day_gaps "$days"
}
