#!/usr/bin/env bash
# 核心层（Functional Core）——数值与时间格式化
#
# ⛔ 本层是**纯函数**：给定相同入参产出相同结果。不读写文件、不发起网络或数据查询、
#    不读取当前时刻、**不引用任何脚本全局变量**。所有输入经位置参数传入，输出经 stdout 返回。
#    判定标准是「是否读取了参数之外的状态」，而非是否 fork 了进程——
#    把一个 epoch 格式化成日期字符串是纯的，取「现在几点」不是。
#
# 因为不依赖全局，本层**加载顺序任意**，且可在空环境中直接调用（这正是「可测」的操作性定义）。
# `bin/check-scripts.sh` 有一条 grep lint 守着这条边界：出现 bq / lark-cli / $STATE / $ROOT 即失败。
# bash 没有编译器，这是依赖规则在这门语言里唯一能落地的强制形式。

int()  { [ -n "$1" ] && printf '%.0f' "$1" || echo ""; }
pct()  { [ -n "$1" ] && awk -v v="$1" 'BEGIN{printf (v==int(v)?"%.0f":"%.1f"), v}' || echo ""; }
rate_pct() { [ -n "$1" ] && [ -n "$2" ] && [ "$2" != "0" ] \
  && awk -v e="$1" -v s="$2" 'BEGIN{printf "%.2f", e/s*100}' || echo ""; }
_fmt() { if [ -n "${2:-}" ]; then TZ="$2" date -r "$1" '+%m-%d %H:%M' 2>/dev/null
         else date -r "$1" '+%m-%d %H:%M' 2>/dev/null; fi; }
_until_epoch() { local s="${1:-}"; s="${s% UTC}"
  [ -n "$s" ] && [ "$s" != "—" ] || return 0
  TZ=UTC date -j -f '%Y-%m-%d %H:%M' "$s" '+%s' 2>/dev/null || true; }

# ⚠️ 以下两个原本读全局 RUN_EPOCH（跑批时刻）与 TZ_LABEL，现改为**首二参传入**。
#    「依赖当前时刻」是纯函数的破口：能通过预设全局跑通的测试，掩盖的正是
#    「这函数依赖看不见的状态」这个缺陷本身。基准时刻由调用方在跑批启动时取一次。
# 卡片用：08-15 17:22 → 08-16 14:59 (+08) · 08-15 09:22 → 08-16 06:59 UTC
win_compact() { # $1=基准epoch $2=时区标签 $3=窗口天数 $4=止点文本
  local se ue; se=$(( $1 - ${3:-0} * 86400 )); ue="$(_until_epoch "${4:-}")"
  [ -n "$ue" ] || { printf '%s → —' "$(_fmt "$se")"; return 0; }
  printf '%s → %s (%s) · %s → %s UTC' "$(_fmt "$se")" "$(_fmt "$ue")" \
    "${2%00}" "$(_fmt "$se" UTC)" "$(_fmt "$ue" UTC)"
}
# 文档用：每个时刻都写两个时区
win_full() { # $1=基准epoch $2=时区标签 $3=窗口天数 $4=止点文本
  local se ue; se=$(( $1 - ${3:-0} * 86400 )); ue="$(_until_epoch "${4:-}")"
  [ -n "$ue" ] || { printf '%s UTC / %s %s → —' "$(_fmt "$se" UTC)" "$(_fmt "$se")" "$2"; return 0; }
  printf '%s UTC / %s %s → %s UTC / %s %s' \
    "$(_fmt "$se" UTC)" "$(_fmt "$se")" "$2" \
    "$(_fmt "$ue" UTC)" "$(_fmt "$ue")" "$2"
}

# ── 完整日窗口（change crash-data-completeness，design D1/D2）──────────
# 起因：性能表每天只灌到 06:59 UTC，**最后一个日历日恒为 7 小时的残日**
#（2026-08-27 实测 iOS perf：08-25 有 24 小时 44420 行，08-26 只有 7 小时 3988 行）。
# 窗口锚在跑批时刻时，这半天既掺进滚动窗口，又被 DoD 当成「今日」去和完整天比——
# ⚠️ 那半天固定是 00:00–07:00 UTC（= 东亚上午），是**系统性构成偏差不是随机噪声**。
#
# ⛔ 判据只用「表里存在 D+1 的事件 ⇒ D 已灌完」，**不查 INFORMATION_SCHEMA.PARTITIONS**：
#    perf 表按**摄取时间**分区（`bq ls` 显示 DAY 无 field），partition_id 与事件日不是一回事——
#    2026-08-27 实测 perf IOS 根本没有 20260826 分区，按事件日却有 3988 行 08-26 数据。
#    且本判据只吃现成的 DATA_UNTIL（既有 table_max() 的结果），**不额外查 BigQuery**。
_day_epoch() { # $1=YYYY-MM-DD → epoch（当日 12:00 UTC，只为做整日加减，不表达时刻）
  [ -n "${1:-}" ] || return 0
  TZ=UTC date -j -f '%Y-%m-%d %H:%M:%S' "$1 12:00:00" '+%s' 2>/dev/null || true
}
day_shift() { # $1=YYYY-MM-DD $2=整日偏移（-2 / 1）→ YYYY-MM-DD；入参空或不可解析 → 空
  local e; e="$(_day_epoch "${1:-}")"
  [ -n "$e" ] || { echo ""; return 0; }
  TZ=UTC date -r "$(( e + ${2:-0} * 86400 ))" '+%Y-%m-%d' 2>/dev/null || true
}
# 最后一个完整日 = DATE(DATA_UNTIL) − 1。DATA_UNTIL 为空 / 「—」时返回空，
# ⚠️ 调用方据此跳过性能取数，走**既有**缺数三态第 2 态（不新增态、不改判据顺序）。
last_complete_day() { # $1=DATA_UNTIL 文本（"2026-08-26 06:59 UTC"）→ YYYY-MM-DD 或空
  local e; e="$(_until_epoch "${1:-}")"
  [ -n "$e" ] || { echo ""; return 0; }
  TZ=UTC date -r "$(( e - 86400 ))" '+%Y-%m-%d' 2>/dev/null || true
}
# 完整日窗口标注（design D2）：窗口 + 滞后 + **上游进度三者都要给**。
# ⛔ 只给窗口会丢掉上游进度——读者无法判断明天会不会好转，也看不出导出是不是卡住了
#    （实测有过回填到 145h 的情况）。`crash-perf-data-staleness-guard` 要求「各段截止时间戳
#    分别如实标注」，本函数是在它之上再加窗口，不替代它。
win_days() { # $1=起日 $2=止日(LCD) $3=基准epoch $4=DATA_UNTIL 文本 → 标注串
  local rd le lag nxt
  [ -n "${1:-}" ] && [ -n "${2:-}" ] || { printf -- '—'; return 0; }
  rd="$(TZ=UTC date -r "$3" '+%Y-%m-%d' 2>/dev/null || true)"
  le="$(_day_epoch "$2")"
  lag=""
  [ -n "$rd" ] && [ -n "$le" ] && lag=$(( ( $(_day_epoch "$rd") - le ) / 86400 ))
  nxt="${4:0:10}"; [ -n "$nxt" ] && [ "$nxt" != "—" ] || nxt="$(day_shift "$2" 1)"
  printf '%s ~ %s（完整日）' "$1" "${2:5}"
  [ -n "$lag" ] && printf ' · 滞后 %s 天' "$lag"
  [ -n "$nxt" ] && printf ' · %s 起未合并' "${nxt:5}"
  return 0
}

# 页面名短名（卡片专用，change crash-data-completeness B 组的列宽代价）。
# ⚠️ 起因：卡片从每端 2 列变 3 列后实发验证被截断——CardKit 表格总宽固定，7 列时
#    「PaywallThemeCoursePopupViewController 54.2%（26 次）」这种单元格必然放不下。
# ⛔ 只在卡片上短，**完整页面名留在文档**（CLAUDE.md：长文案把列宽撑爆截断，短文案给卡片）。
# 先砍平台惯例后缀：ViewController / Controller / Activity / Fragment 每个名字里都有，零区分度。
screen_brief() { # $1=页面名 $2=最大长度（默认 12）→ 短名
  local s="${1:-}" n="${2:-12}"
  [ -n "$s" ] || { echo ""; return 0; }
  s="${s%ViewController}"; s="${s%Controller}"; s="${s%Activity}"; s="${s%Fragment}"
  [ -n "$s" ] || s="$1"
  if [ "${#s}" -gt "$n" ]; then s="${s:0:$n}…"; fi
  printf '%s' "$s"
}
