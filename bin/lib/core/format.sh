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
