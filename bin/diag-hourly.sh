#!/usr/bin/env bash
# shellcheck disable=SC2034  # AUDIT_FILE / ALERT_* / BQ_MAX_ROWS / LK 由 source 进来的 lib.sh、common.sh、bq.sh、lark.sh 读取
# L0 每小时技术诊断告警（change crash-tech-diagnostics）：app_diagnostic 接口类签名激增 → 飞书卡片。
# 两个数据源（design 决策 8）：GA4 与 PostHog Logs 两边原样取、行带 src、各记各的覆盖；
# 判定前按「平台 × 版本 × 天」二选一（core diag_pick，取设备多的一边，不相加）；断数按来源各判各的（core diag_missing）。
#
# 每次运行判定「上一个完整 MYT 小时」，并复判再往前一小时（晚到事件：hh:05 实测只到完整数据的一半，2026-11-27）：
#   取数（该小时所在 UTC 日：GA4 那张表 + PostHog 同一 UTC 日，整天重取、按来源按小时 upsert 进本地聚合；
#         复判的小时在前一个 UTC 日时（判定 MYT 08 点那次）把那天也重取一次）
#   → 基线不足先回填 → 签名级激增判定（本小时 + 复判上一小时）→ 去重 → 命中则取分布、发卡
#  （复判新命中的签名另发一张「复判补报」卡）→ 写去重状态。
#
# 运行数据只在 $STATE/diag/（spec：L0 ⛔ 不碰 L1 / L2 的文档、索引页、台账与基准文件）：
#   hourly.jsonl    小时聚合（diag-hourly.sql 的行，保留 DIAG_KEEP_DAYS 天）
#   coverage.json   GA4 一侧：各 UTC 日取自哪张表、何时取的（判定「历史是否完整」，见 core diag_need_dates）
#   coverage-posthog.json  PostHog 一侧：各 UTC 日何时取的（src 记 "posthog"，按 intraday 同一规则判完整）
#   alerted.json    去重状态 {签名: {sent, first, last}}
#   hits.jsonl      每次激增 / 数据缺失的记录（首周观察项 2026-12-04 汇总用）
#   last-eval.json  最近一次判定的全部签名；last-card.json 最近一次渲染的卡片
#
# ⛔ 投递目标 CRASH_REPORT_DIAG_ALERT_CHAT_ID **只从 $STATE/local.env 读**：先清掉环境里的同名变量。
#    未设置 → 照常计算、跳过投递并写日志，⛔ 不回落到日报群（spec「告警投递目标由机器决定」）。
#    L0 自己出错时的失败告警也只发这个目标（alert.sh --to），且只在「上一次成功 → 这一次失败」时发一次。
set -euo pipefail
unset PYTHONPATH   # Hermes 注入的 3.12 包树让 bq 导入即崩（同 L1 / L2）

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export CRASH_REPORT_ROOT="${CRASH_REPORT_ROOT:-$(dirname "$SELF_DIR")}"
ROOT="$CRASH_REPORT_ROOT"
STATE="${CRASH_REPORT_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/crash-triage}"
if [ -f "$STATE/path.env" ]; then
  # shellcheck disable=SC1091
  . "$STATE/path.env"
else
  PATH="/opt/homebrew/bin:/opt/homebrew/share/google-cloud-sdk/bin:/usr/local/bin:$HOME/.npm-global/bin:/usr/bin:/bin:/usr/sbin:/sbin"
fi
unset CRASH_REPORT_DIAG_ALERT_CHAT_ID
# shellcheck disable=SC1091
[ -f "$STATE/local.env" ] && . "$STATE/local.env"
DIAG_TO="${CRASH_REPORT_DIAG_ALERT_CHAT_ID:-}"
export PATH

TS="$(date +%Y%m%d-%H%M%S)"
RUN_ID="$TS"
DIAG_DIR="$STATE/diag"
mkdir -p "$DIAG_DIR" "$STATE/logs" "$STATE/audit"
LOG="$STATE/logs/diag-$TS.log"
AUDIT_FILE="$STATE/audit/diag-$RUN_ID.events.jsonl"
SQL_DIR="${SQL_DIR:-$ROOT/bin/sql}"
HOURLY="$DIAG_DIR/hourly.jsonl"
COVERAGE="$DIAG_DIR/coverage.json"
COVERAGE_PH="$DIAG_DIR/coverage-posthog.json"
DIAG_STATE_FILE="$DIAG_DIR/alerted.json"   # ⛔ 不能叫 ALERTED：common.sh 的 ALERTED=0 是告警去重标志，会把路径盖成「0」
HITS="$DIAG_DIR/hits.jsonl"
LOCK="$DIAG_DIR/.lock"

# ── 阈值（回测定稿，design 决策 3）─────────────────────────────
DIAG_MIN="${CRASH_REPORT_DIAG_MIN:-10}"        # 签名级受影响设备下限
DIAG_MULT="${CRASH_REPORT_DIAG_MULT:-4}"       # 对前 7 天同小时均值的倍数
DIAG_WINDOW=21600                              # 同一签名 6 小时内只发一次（秒）
DIAG_KEEP_DAYS=15                              # 本地小时聚合保留天数（基线只要 7 天，多留一周排障）
# 单条查询计费上限（BQ_MAX_BYTES，bqq 透传 --maximum_bytes_billed）：超了 BigQuery 拒绝执行、不计费。
# 实测单张日表 0.7～4.3 GB（2026-11 量级）；回填一次最多 8 张。
DIAG_MAX_BYTES_ONE=10000000000                 # 10 GB：当天一张表 / 分布查询
DIAG_MAX_BYTES_BACKFILL=40000000000            # 40 GB：回填 7 天
# ⛔ bq query 默认只返回 100 行且不报错；小时聚合一天上百行、回填 7 天上千行
BQ_MAX_ROWS=1000000

exec > >(tee -a "$LOG") 2>&1
echo "=== L0 技术诊断告警 ${TS} ==="

# ── 失败处理（同 L1 / L2 的 common.sh 约定）───────────────────
# ⚠️ ALERT_FLAG **不在开头清**：每小时跑一次，持续故障时每小时一张失败卡是轰炸。
#    标记留到下一次成功才删 → 只在「上一次成功 → 这一次失败」时发一次。
ALERT_FLAG="$DIAG_DIR/.alerted-failure"
ALERT_SOURCE="diag"
ALERT_RUN_ID="$RUN_ID"
HEALTH_FILE="$STATE/health-diag.json"
ALERT_TO="$DIAG_TO"
# shellcheck disable=SC1091
. "$ROOT/bin/lib/common.sh"
# shellcheck disable=SC1091
. "$ROOT/bin/lib.sh"
# shellcheck disable=SC1091
. "$ROOT/bin/lib/bq.sh" || exit 1
# shellcheck disable=SC1091
. "$ROOT/bin/lib/query.sh"
# shellcheck disable=SC1091
. "$ROOT/bin/lib/posthog.sh"
# shellcheck disable=SC1091
. "$ROOT/bin/lib/core/diag.sh" || { echo "❌ 核心层缺失：bin/lib/core/diag.sh" >&2; exit 1; }
set -o errtrace
trap 'on_err' ERR
bq_init
_lock_mine=0
# ⛔ 完成哨兵：bash 3.2 下 set -u 失败进 EXIT trap 时 $? 已是 0（CLAUDE.md），只能靠哨兵判成败
trap 'rm -f "$BQ_SQLTMP" "$DIAG_DIR/.rows.$$.json" "$DIAG_DIR/.phv.$$.json" "$DIAG_DIR/.ph.$$.json" "$DIAG_DIR/.ph.$$.json.r" "$HOURLY.tmp.$$" "$COVERAGE.tmp.$$" "$COVERAGE_PH.tmp.$$" "$DIAG_STATE_FILE.tmp.$$"; [ "$_lock_mine" = 1 ] && rm -rf "$LOCK"; [ "${RUN_COMPLETED:-0}" = 1 ] || exit 1' EXIT
audit run.start "" "$(jq -cn --arg to "${DIAG_TO:+set}" '{to:$to}')"

# ── 并发锁：上一轮还在跑（bq 慢）就让位，下一小时整天重取会补上 ──────────
step "加锁"
if mkdir "$LOCK" 2>/dev/null; then
  _lock_mine=1; echo "$$" > "$LOCK/pid"
else
  _owner="$(cat "$LOCK/pid" 2>/dev/null || true)"
  # ⚠️ 锁超过 50 分钟视为残留（审查建议）：只看 kill -0 会被 PID 复用骗过，L0 从此每轮「跳过」、静默停摆
  if [ -n "$_owner" ] && kill -0 "$_owner" 2>/dev/null && [ -z "$(find "$LOCK" -maxdepth 0 -mmin +50 2>/dev/null)" ]; then
    echo "  上一轮（pid ${_owner}）仍在运行，本轮跳过"
    audit run.end "加锁" '{"ok":true,"skipped":"locked"}'
    RUN_COMPLETED=1; exit 0
  fi
  echo "  清理残留锁（pid ${_owner:-?} 已不在）"
  rm -rf "$LOCK"; mkdir "$LOCK"; _lock_mine=1; echo "$$" > "$LOCK/pid"
fi

# ── 判定哪个小时 ─────────────────────────────────────────────
# CRASH_REPORT_DIAG_HOUR 只供回放测试（投递目标仍只由 local.env 决定）。
# 「当前时刻」= 该小时结束的时刻：去重窗口按小时计，回放与实跑判定一致。
HOUR="${CRASH_REPORT_DIAG_HOUR:-$(TZ=Asia/Kuala_Lumpur date -v-1H '+%Y-%m-%d %H')}"
case "$HOUR" in
  ([0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]\ [0-9][0-9]) ;;
  (*) fail "小时格式不对：${HOUR}（应为 YYYY-MM-DD HH，MYT）" ;;
esac
H_EPOCH="$(TZ=Asia/Kuala_Lumpur date -j -f '%Y-%m-%d %H:%M:%S' "$HOUR:00:00" +%s)"
NOW=$((H_EPOCH + 3600))
utc_day() { date -u -r "$1" +%Y%m%d; }
H_DAY="$(utc_day "$H_EPOCH")"
# 复判的小时（上一小时）：它的数据在上一轮 hh:05 只到了一部分，这一轮整天重取后更完整
P_EPOCH=$((H_EPOCH - 3600))
P_HOUR="$(TZ=Asia/Kuala_Lumpur date -r "$P_EPOCH" '+%Y-%m-%d %H')"
P_DAY="$(utc_day "$P_EPOCH")"
echo "  判定小时 ${HOUR}:00 MYT（UTC 日 ${H_DAY}）· 阈值 ≥${DIAG_MIN} 台且 ≥${DIAG_MULT}× · 投递目标 ${DIAG_TO:-未设置}"

# ── 取数：按 UTC 日整天重取，upsert 进本地聚合 ─────────────────
# $1=计费上限 $2..=UTC 日期 YYYYMMDD
fetch_days() {
  local max="$1"; shift
  local d ids="" sufs="" tables rows _rc=0 srcs="{}"
  for d in "$@"; do ids="${ids:+$ids,}'events_$d','events_intraday_$d'"; done
  # ⚠️ `$( )` 内先 `trap - ERR`：否则 bqq 失败时子 shell 里的 on_err 抢先发一张泛化失败卡，
  #    下面 fail 的具体原因就被告警去重压掉了（审查 G6）
  tables="$(trap - ERR; BQ_MAX_BYTES="$DIAG_MAX_BYTES_ONE" BQ_MAX_ROWS=1000 bqq csv "$(q_render diag-tables.sql TABLE_IDS="$ids")")" || _rc=$?
  [ "$_rc" -eq 0 ] || fail "查 GA4 表元数据失败（rc=${_rc}）"
  for d in "$@"; do
    local suf
    suf="$(diag_pick_suffix "$tables" "$d")"
    [ -n "$suf" ] || fail "GA4 表不存在：events_$d 与 events_intraday_$d 都没有"
    sufs="${sufs:+$sufs,}'$suf'"
    case "$suf" in (intraday_*) srcs="$(jq -c --arg d "$d" '.[$d] = "intraday"' <<<"$srcs")" ;;
                   (*)          srcs="$(jq -c --arg d "$d" '.[$d] = "daily"' <<<"$srcs")" ;; esac
  done
  echo "  取数：${sufs}"
  rows="$(trap - ERR; BQ_MAX_BYTES="$max" bqq json "$(q_render diag-hourly.sql SUFFIXES="$sufs" DIAG_API_PRED="$SQL_DIAG_API_PRED")")" || _rc=$?
  [ "$_rc" -eq 0 ] || fail "取小时聚合失败（rc=${_rc}，表 ${sufs}）"
  # bq 的 json 输出把数字给成字符串；空结果是 [] 或空串
  # ⚠️ 行数据走文件（--slurpfile），不作 --argjson 参数：回填 7 天上千行，作参数会撞 ARG_MAX
  local rowsf="$DIAG_DIR/.rows.$$.json"
  printf '%s' "${rows:-[]}" | jq -c '[ .[] | .devices |= tonumber | .users |= tonumber | .events |= tonumber ]' \
    | jq -c 'map(. + {src: "ga4"})' > "$rowsf" || fail "小时聚合结果不是合法 JSON"
  upsert_hourly ga4 "$rowsf" "$@"
  write_coverage "$COVERAGE" "$srcs"
  local nrows; nrows="$(jq length "$rowsf")"
  rm -f "$rowsf"
  audit fetch "取数" "$(jq -cn --arg s "$sufs" --argjson n "$nrows" '{suffixes:$s,rows:$n}')"
  echo "  写入 ${nrows} 行（GA4）"
}

# PostHog 一侧：$@=UTC 日期 YYYYMMDD。一条 HogQL 查最早到最晚那一天（不计费），只把列出的日 upsert 进本地。
fetch_days_ph() {
  local d lo hi srcs="{}" v="$DIAG_DIR/.phv.$$.json" f="$DIAG_DIR/.ph.$$.json"
  lo="$(printf '%s\n' "$@" | sort | head -1)"; hi="$(printf '%s\n' "$@" | sort | tail -1)"
  jq -n --arg a "$(date -u -j -f '%Y%m%d %H%M%S' "$lo 000000" '+%Y-%m-%d %H:%M:%S')" \
        --arg b "$(date -u -j -v+1d -f '%Y%m%d %H%M%S' "$hi 000000" '+%Y-%m-%d %H:%M:%S')" '{t0: $a, t1: $b}' > "$v"
  ph_query diag-hourly.hogql "$v" "$f" || fail "取 PostHog 小时聚合失败（UTC ${lo} ～ ${hi}）"
  jq -c 'map(. + {src: "posthog"})' < "$f" > "$f.r" && mv "$f.r" "$f" || fail "PostHog 小时聚合结果不是合法 JSON"
  for d in "$@"; do srcs="$(jq -c --arg d "$d" '.[$d] = "posthog"' <<<"$srcs")"; done
  upsert_hourly posthog "$f" "$@"
  write_coverage "$COVERAGE_PH" "$srcs"
  local nrows; nrows="$(jq length "$f")"
  rm -f "$v" "$f"
  audit fetch "取数" "$(jq -cn --arg s "posthog ${lo}-${hi}" --argjson n "$nrows" '{suffixes:$s,rows:$n}')"
  echo "  写入 ${nrows} 行（PostHog，UTC ${lo} ～ ${hi}）"
}

# upsert_hourly <ga4|posthog> <行文件> <UTC 日…>：该来源在这些 UTC 日对应的 MYT 小时整段替换
#（UTC D 日 = MYT D 08 时 ～ D+1 07 时）；⛔ 只换同一来源的行，另一来源原样保留；超过保留期的丢掉。
# 新行里不在这些 UTC 日的（PostHog 按最早～最晚整段查，中间可能夹着不用补的日）丢掉，不覆盖已有的。
# 保留期按**判定小时**往回算，不按真实当前时间：回放旧小时（CRASH_REPORT_DIAG_HOUR）时基线不被删掉
upsert_hourly() {
  local src="$1" rowsf="$2"; shift 2
  local keep_from; keep_from="$(TZ=Asia/Kuala_Lumpur date -r $((H_EPOCH - DIAG_KEEP_DAYS * 86400)) '+%Y-%m-%d %H')"
  local tmp="$HOURLY.tmp.$$"
  { [ -s "$HOURLY" ] && cat "$HOURLY"; true; } | jq -c --argjson days "$(printf '%s\n' "$@" | jq -R . | jq -sc .)" \
      --slurpfile new "$rowsf" --arg keep "$keep_from" --arg src "$src" -s '
    def utcday: (.h + ":00" | strptime("%Y-%m-%d %H:%M") | mktime - 8 * 3600 | strftime("%Y%m%d"));
    def listed: (utcday as $u | $days | index($u)) != null;
    ([ .[] | select(((.src // "ga4") != $src) or (listed | not)) ] + [ $new[0][] | select(listed) ])
    | map(select(.h >= $keep)) | sort_by(.h) | .[]' > "$tmp" || fail "写本地小时聚合失败"
  mv "$tmp" "$HOURLY"
}

# write_coverage <覆盖文件> <{UTC 日: src}>：记下这些日取自哪里、何时取的
write_coverage() {
  local fetched_at; fetched_at="$(date +%s)"
  jq -c --argjson s "$2" --argjson at "$fetched_at" \
     'reduce ($s | to_entries[]) as $e (.; .[$e.key] = {src: $e.value, at: $at})' \
     <<<"$( [ -s "$1" ] && cat "$1" || echo '{}' )" > "$1.tmp.$$" || fail "写 $(basename "$1") 失败"
  mv "$1.tmp.$$" "$1"
}

step "取当前小时所在 UTC 日"
fetch_days "$DIAG_MAX_BYTES_ONE" "$H_DAY"
if [ "$P_DAY" != "$H_DAY" ]; then
  # 判定 MYT 08 点那次（09:05 运行）：复判的 07 点在前一个 UTC 日，那天上次是 08:05 取的、缺晚到事件 → 再取一次
  #（每天一次，多扫一张日表）
  fetch_days "$DIAG_MAX_BYTES_ONE" "$P_DAY"
  fetch_days_ph "$P_DAY" "$H_DAY"
else
  fetch_days_ph "$H_DAY"
fi

step "基线完整性"
# 前 7 天同一小时分别落在哪个 UTC 日（MYT 与 UTC 差整 8 小时，同一小时的 UTC 日就是往前推 k 天）；
# 复判的小时也要 7 天基线：它跨 UTC 日时多出一天，⛔ 漏了会把那天当基线 0、把复判判松
_need_days="$(for k in 1 2 3 4 5 6 7; do utc_day $((H_EPOCH - k * 86400)); utc_day $((P_EPOCH - k * 86400)); done | sort -u | jq -R . | jq -sc .)"
_missing="$(diag_need_dates "$( [ -s "$COVERAGE" ] && cat "$COVERAGE" || true )" "$_need_days")"
_missing_ph="$(diag_need_dates "$( [ -s "$COVERAGE_PH" ] && cat "$COVERAGE_PH" || true )" "$_need_days")"
if [ -n "$_missing" ]; then
  echo "  本地基线（GA4）缺 UTC 日：${_missing} → 回填（⛔ 不当作基线为 0）"
  # shellcheck disable=SC2086
  fetch_days "$DIAG_MAX_BYTES_BACKFILL" $_missing
fi
if [ -n "$_missing_ph" ]; then
  echo "  本地基线（PostHog）缺 UTC 日：${_missing_ph} → 回填（⛔ 不当作基线为 0）"
  # shellcheck disable=SC2086
  fetch_days_ph $_missing_ph
fi
if [ -n "$_missing$_missing_ph" ]; then
  _still="$(diag_need_dates "$(cat "$COVERAGE")" "$_need_days") $(diag_need_dates "$(cat "$COVERAGE_PH")" "$_need_days")"
  [ -z "${_still// /}" ] || fail "回填后基线仍不完整：${_still}"
else
  echo "  前 7 天同小时基线完整（GA4 与 PostHog）"
fi

step "判定"
# win_raw <小时>：该小时、前一小时与前 7 天同小时的本地行，两边原样（断数判定用）；经 diag_pick 二选一后用于激增判定
win_raw() {
  jq -c --arg h "$1" -s '
    def ep: (. + ":00" | strptime("%Y-%m-%d %H:%M") | mktime);
    ($h | ep) as $t
    | [ .[] | (.h | ep) as $x
            | select(($t - $x) >= 0 and ($t - $x) <= 7 * 86400 and ((($t - $x) % 86400 == 0) or ($t - $x) == 3600)) ]' "$HOURLY"
}
_win_raw="$(win_raw "$HOUR")"
_win="$(diag_pick h <<<"$_win_raw")"
_cur="$(jq -c --arg h "$HOUR" '[ .[] | select(.h == $h) ]' <<<"$_win")"
_ev="$(diag_evaluate "$_cur" "$_win" "$HOUR" "$DIAG_MIN" "$DIAG_MULT")"
# 「数据缺失」按来源各判各的（design 决策 8，core diag_missing）：⛔ 两边合起来判，GA4 导出中断会被 PostHog 的行盖住；
# 判据要求前 7 天同小时**每天**都有行——量小的一边（刚放量的 PostHog、用户迁走后的 GA4）夜里两小时为 0 是常态，不能报。
_miss_src="$(diag_missing "$_win_raw" "$HOUR")"
_miss=ok; _miss_label=""
if [ -n "$_miss_src" ]; then
  _miss=missing
  _miss_label="$(printf '%s' "$_miss_src" | sed -e 's/posthog/PostHog/' -e 's/ga4/GA4/' -e 's/ /、/g')"
fi
printf '%s\n' "$_ev" > "$DIAG_DIR/last-eval.json"   # 本小时全部签名的判定（排障 / 回填验收用）
# 判定时刻的计数留档（审查 G3）：hh:05 判的是「当时进表的量」，晚到事件可能让它低于事后完整值。
# 达到下限一半以上的签名逐小时追加，首周（2026-12-04）汇总时与次日完整数据对比，量出晚到的影响再决定要不要复判。
jq -c --arg h "$HOUR" --arg run "$RUN_ID" --argjson half "$((DIAG_MIN / 2))" \
   '.[] | select(.devices >= $half) | {run:$run, h:$h, sig, devices, baseline, verdict}' <<<"$_ev" >> "$DIAG_DIR/evals.jsonl"
# 复判上一小时：同一套判定与去重。⚠️ 先于本小时做 plan——同一签名两小时都激增时，本小时的 first 才能沿用上一小时；
# 两小时都待发的签名只进本小时那张卡（卡上写「从 上一小时 起持续」），复判卡只收上一小时独有的。
_pwin="$(win_raw "$P_HOUR" | diag_pick h)"
_pev="$(diag_evaluate "$(jq -c --arg h "$P_HOUR" '[ .[] | select(.h == $h) ]' <<<"$_pwin")" "$_pwin" "$P_HOUR" "$DIAG_MIN" "$DIAG_MULT")"
jq -c --arg h "$P_HOUR" --arg run "$RUN_ID" --argjson half "$((DIAG_MIN / 2))" \
   '.[] | select(.devices >= $half) | {run:$run, h:$h, sig, devices, baseline, verdict, recheck:true}' <<<"$_pev" >> "$DIAG_DIR/evals.jsonl"
_state="$( [ -s "$DIAG_STATE_FILE" ] && cat "$DIAG_STATE_FILE" || echo '{}' )"
# ⚠️ 复判的去重按「被复判那一小时结束的时刻」（= H_EPOCH，也就是它实时判定时的「当前时刻」）算，不按 NOW：
#    实时那轮被 6 小时去重压下的签名，晚一小时可能刚出窗口——⛔ 不能借复判补发（审查 2026-11-27 #2）。
#    实时那轮发过的 sent = H_EPOCH，差 0 → 不发；没发出去的（投递失败、复判一侧失败）sent 为空 → 照发。
_pplan="$(diag_plan "$_state" "$_pev" "$P_HOUR" "$H_EPOCH" "$DIAG_WINDOW")"
_plan="$(diag_plan "$(jq -c .state <<<"$_pplan")" "$_ev" "$HOUR" "$NOW" "$DIAG_WINDOW")"
_send="$(jq -c .send <<<"$_plan")"
# 复判卡只收本小时不待发的签名
_psend="$(jq -c --argjson m "$_send" '[ .send[] | select(.sig as $k | ($m | map(.sig) | index($k)) == null) ]' <<<"$_pplan")"
_n_spike="$(jq '[.[] | select(.verdict == "spike")] | length' <<<"$_ev")"
_n_send="$(jq length <<<"$_send")"
_n_psend="$(jq length <<<"$_psend")"
echo "  签名 $(jq length <<<"$_ev") 个 · 激增 ${_n_spike} 个 · 待发 ${_n_send} 个 · 数据 ${_miss}"
jq -r '.[] | select(.verdict == "spike") | "    🚨 \(.sig)：\(.devices) 台 vs 基线 \(.baseline)"' <<<"$_ev"
echo "  复判 ${P_HOUR}:00：激增 $(jq '[.[] | select(.verdict == "spike")] | length' <<<"$_pev") 个 · 补报 ${_n_psend} 个"
jq -r '.[] | "    🔁 \(.sig)：\(.devices) 台 vs 基线 \(.baseline)"' <<<"$_psend"
_miss_send=skip
if [ "$_miss" = missing ]; then
  _miss_send="$(diag_dedupe "$_state" "__data_missing__" "$NOW" "$DIAG_WINDOW")"
  echo "  ⚠️ 数据缺失：${HOUR}:00 与前一小时 ${_miss_label} 一侧无任何接口类数据（去重判定：${_miss_send}）"
fi
# 命中记录（不论投不投递都记）：首周观察项要的是「判定命中了什么」
jq -c --arg h "$HOUR" --arg run "$RUN_ID" --arg miss "$_miss" --argjson send "$_send" \
   '[ .[] | select(.verdict == "spike") | {run:$run, h:$h, sig, devices, users, baseline,
      sent: ((.sig as $k | $send | map(.sig) | index($k)) != null)} ]
    + (if $miss == "missing" then [{run:$run, h:$h, sig:"__data_missing__"}] else [] end) | .[]' \
   <<<"$_ev" >> "$HITS"
# 复判命中另记一行（recheck:true）：实时已命中的签名也会再记一次，汇总时按 recheck 区分，sent 只算这次补报的
jq -c --arg h "$P_HOUR" --arg run "$RUN_ID" --argjson send "$_psend" \
   '.[] | select(.verdict == "spike") | {run:$run, h:$h, sig, devices, users, baseline, recheck:true,
      sent: ((.sig as $k | $send | map(.sig) | index($k)) != null)}' <<<"$_pev" >> "$HITS"

_new_state="$(jq -c .state <<<"$_plan")"
if [ "$_miss" = missing ]; then
  _new_state="$(jq -c --arg h "$HOUR" '.["__data_missing__"] = ((.["__data_missing__"] // {}) + {last: $h})' <<<"$_new_state")"
fi

# attach_breakdown <小时> <小时起 epoch> <待发 JSON>：取该小时这批签名的分布，结果放进全局 _bd_out（带 geo / cfg）。
# ⚠️ 不写成 $( ) 返回：里面的 fail 在子 shell 里退出，外层赋值失败会再触发 on_err 叠一张泛化失败卡（F72）
attach_breakdown() {
  local hour="$1" t0="$2" send="$3" keys suf bd _rc=0
  # ⚠️ 签名来自数据：用 jq 的 @json 生成双引号字面量（\" \\ \uXXXX 都是 BigQuery 认的转义），不手拼引号
  keys="$(jq -r '[ .[].sig | @json ] | join(",")' <<<"$send")"
  suf="$(jq -r --arg d "$(utc_day "$t0")" 'if .[$d].src == "daily" then $d else "intraday_" + $d end' "$COVERAGE")"
  bd="$(trap - ERR; BQ_MAX_BYTES="$DIAG_MAX_BYTES_ONE" bqq json "$(q_render diag-breakdown.sql SUFFIXES="'$suf'" HOUR="$hour" SIG_KEYS="$keys")")" || _rc=$?
  [ "$_rc" -eq 0 ] || fail "取分布失败（rc=${_rc}，${hour}:00）"
  # PostHog 一侧同一小时同一批签名（签名来自数据，⛔ 只走 values 占位，不拼进查询文本）
  jq -n --arg a "$(date -u -r "$t0" '+%Y-%m-%d %H:%M:%S')" --arg b "$(date -u -r $((t0 + 3600)) '+%Y-%m-%d %H:%M:%S')" \
        --argjson s "$(jq -c '[.[].sig]' <<<"$send")" '{t0: $a, t1: $b, sigs: $s}' > "$DIAG_DIR/.phv.$$.json"
  ph_query diag-breakdown.hogql "$DIAG_DIR/.phv.$$.json" "$DIAG_DIR/.ph.$$.json" || fail "取 PostHog 分布失败（${hour}:00）"
  # 两边合并：affected 是各来源各自的受影响设备数，按签名两边相加（每个版本只在一边，不重复）
  bd="$(jq -c --argjson g "${bd:-[]}" '
    ([ $g[] | . + {src: "ga4"} ] + [ .[] | . + {src: "posthog"} ])
    | map(.devices |= tonumber | .affected |= tonumber)
    | (group_by(.sig) | map({key: .[0].sig, value: (group_by(.src) | map(.[0].affected) | add)}) | from_entries) as $aff
    | map(.affected = $aff[.sig] | del(.src))' "$DIAG_DIR/.ph.$$.json")"
  rm -f "$DIAG_DIR/.phv.$$.json" "$DIAG_DIR/.ph.$$.json"
  _bd_out="$(jq -c --argjson bd "${bd:-[]}" '
    ($bd | map(.devices |= tonumber | .affected |= tonumber)) as $b
    | map(. as $x | . + {geo: [ $b[] | select(.dim == "geo" and .sig == $x.sig) ],
                         cfg: [ $b[] | select(.dim == "cfg" and .sig == $x.sig) ]})' <<<"$send")"
}

# deliver_card <卡片 JSON> <幂等键种子>：发一张卡，message_id 放进全局 _mid；失败 fail（同 attach_breakdown，不走 $( )）
deliver_card() {
  local key _resp _rc=0
  key="diag-$(printf '%s' "$2" | shasum -a 256 | cut -c1-32)"
  _resp="$(trap - ERR; lk im +messages-send "${_recip[@]}" --msg-type interactive --content "$1" \
             --idempotency-key "$key" --as "$LARK_AS" --format json)" || _rc=$?
  # ⛔ 只看退出码会打假 ✅（F57）：以回包里有 message_id 为准
  _mid="$(printf '%s' "$_resp" | jq -r '.. | .message_id? // empty' 2>/dev/null | head -1 || true)"
  [ "$_rc" -eq 0 ] && [ -n "$_mid" ] || fail "告警卡片发送失败（rc=${_rc}，回包无 message_id）：$(printf '%s' "$_resp" | head -c 300)"
  echo "  📣 已发送到 ${DIAG_TO}（message_id=${_mid}）"
}

save_state() {
  printf '%s\n' "$_new_state" > "$DIAG_STATE_FILE.tmp.$$" && mv "$DIAG_STATE_FILE.tmp.$$" "$DIAG_STATE_FILE"
}

_card=""; _pcard=""
render_main() {
  _card="$(diag_card "$_send" "$HOUR" "$( [ "$_miss_send" = send ] && printf '%s' "$_miss_label" || echo ok )" "$DIAG_MIN" "$DIAG_MULT")"
  printf '%s\n' "$_card" > "$DIAG_DIR/last-card.json"
}
render_recheck() {
  _pcard="$(diag_card "$_psend" "$P_HOUR" ok "$DIAG_MIN" "$DIAG_MULT" recheck)"
  printf '%s\n' "$_pcard" > "$DIAG_DIR/last-card-recheck.json"
}
_has_main=0
if [ "$_n_send" -gt 0 ] || [ "$_miss_send" = send ]; then _has_main=1; fi
if [ "$_has_main" = 1 ] || [ "$_n_psend" -gt 0 ]; then
  if [ -z "$DIAG_TO" ]; then
    # 没有投递目标就不取分布：卡片发不出去，白扫一张表（~3 GB）
    step "投递"
    _written=""
    if [ "$_has_main" = 1 ]; then render_main; _written="last-card.json"; fi
    if [ "$_n_psend" -gt 0 ]; then
      render_recheck
      if [ -n "$_written" ]; then _written="${_written} 与 last-card-recheck.json"; else _written="last-card-recheck.json"; fi
    fi
    echo "  ⏭️ 未设置 CRASH_REPORT_DIAG_ALERT_CHAT_ID（\$STATE/local.env），跳过分布查询与投递；卡片已写 $DIAG_DIR/ 下的 ${_written}"
    audit deliver.skip "投递" '{"reason":"CRASH_REPORT_DIAG_ALERT_CHAT_ID 未设置"}'
  else
    LARK_AS="${CRASH_REPORT_LARK_AS:-bot}"
    LARK_PROFILE="${CRASH_REPORT_LARK_PROFILE:-crash-triage}"
    [ -n "${HERMES_HOME:-}${OPENCLAW_HOME:-}" ] && LARK_PROFILE=""
    LK=(lark-cli); [ -n "$LARK_PROFILE" ] && LK=(lark-cli --profile "$LARK_PROFILE")
    # shellcheck disable=SC1091
    . "$ROOT/bin/lib/lark.sh"
    case "$DIAG_TO" in (ou_*) _recip=(--user-id "$DIAG_TO") ;; (*) _recip=(--chat-id "$DIAG_TO") ;; esac
    # ⚠️ 先取分布、发本小时卡并落盘去重状态，再做复判卡：复判一侧（分布查询 / 发送）失败时，
    #    实时卡已经发出、不会在下一小时重发（审查 2026-11-27 #1）。复判失败照样非零退出、发失败卡（spec「检查失败不冒充平稳」），
    #    代价是那一小时独有的补报签名不再有第三次判定——失败卡会让维护者知道。
    if [ "$_has_main" = 1 ]; then
      if [ "$_n_send" -gt 0 ]; then step "取分布"; attach_breakdown "$HOUR" "$H_EPOCH" "$_send"; _send="$_bd_out"; fi
      step "投递"
      render_main
      # 幂等键 = 小时 + 待发签名集合：同一小时重跑不会重复发
      deliver_card "$_card" "$(printf '%s|%s|%s' "$HOUR" "$(jq -c '[.[].sig]' <<<"$_send")" "$_miss_send")"
      _new_state="$(diag_mark_sent "$_new_state" "$(jq -c '[.[].sig]' <<<"$_send")" "$NOW")"
      if [ "$_miss_send" = send ]; then
        _new_state="$(diag_mark_sent "$_new_state" '["__data_missing__"]' "$NOW")"
      fi
      save_state
      audit deliver "投递" "$(jq -cn --arg mid "$_mid" --argjson n "$_n_send" --arg miss "$_miss_send" '{message_id:$mid,sigs:$n,missing:$miss}')"
    fi
    if [ "$_n_psend" -gt 0 ]; then
      step "取分布（复判 ${P_HOUR}:00）"
      attach_breakdown "$P_HOUR" "$P_EPOCH" "$_psend"; _psend="$_bd_out"
      step "投递（复判补报）"
      render_recheck
      # 幂等键 = 复判 + 小时 + 待发签名集合：同一小时重跑不会重复发
      deliver_card "$_pcard" "recheck|${P_HOUR}|$(jq -c '[.[].sig]' <<<"$_psend")"
      _new_state="$(diag_mark_sent "$_new_state" "$(jq -c '[.[].sig]' <<<"$_psend")" "$NOW")"
      save_state
      audit deliver "投递" "$(jq -cn --arg mid "$_mid" --argjson n "$_n_psend" '{message_id:$mid,sigs:$n,recheck:true}')"
    fi
  fi
fi

step "写状态"
save_state
# 数据缺失 = 检查失败（spec「检查失败不冒充平稳」：数据未更新 → 非零退出并留下失败记录）。
# 「数据缺失」卡已经发过（或因未配置目标 / 6 小时去重没发），⛔ 不再叠一张泛化失败卡：先置告警标记再 fail，
# fail 只写 health（ok:false）与审计、非零退出；标记留到下一次成功才删，与其它失败同一套「只报一次」。
if [ "$_miss" = missing ]; then
  : > "$ALERT_FLAG"
  fail "数据缺失：${HOUR}:00 与前一小时 ${_miss_label} 一侧没有任何接口类诊断数据（前 7 天同小时每天都有）——上报或导出可能中断"
fi
jq -n --arg t "$TS" --arg h "$HOUR" --argjson sp "$_n_spike" --argjson se "$_n_send" --argjson re "$_n_psend" --arg miss "$_miss" \
  '{last_run:$t, run_id:$t, ok:true, hour:$h, spikes:$sp, sent:$se, recheck_sent:$re, data:$miss}' > "$HEALTH_FILE"
rm -f "$ALERT_FLAG"
audit run.end "写状态" "$(jq -cn --argjson sp "$_n_spike" --argjson se "$_n_send" --argjson re "$_n_psend" '{ok:true,spikes:$sp,sent:$se,recheck_sent:$re}')"
echo "=== 完成 ==="
RUN_COMPLETED=1
