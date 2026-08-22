#!/usr/bin/env bash
# 核心层（Functional Core）——阈值判定与增量渲染
#
# ⛔ 本层是**纯函数**：给定相同入参产出相同结果。不读写文件、不发起网络或数据查询、
#    不读取当前时刻、**不引用任何脚本全局变量**。所有输入经位置参数传入，输出经 stdout 返回。
#    判定标准是「是否读取了参数之外的状态」，而非是否 fork 了进程——
#    把一个 epoch 格式化成日期字符串是纯的，取「现在几点」不是。
#
# 因为不依赖全局，本层**加载顺序任意**，且可在空环境中直接调用（这正是「可测」的操作性定义）。
# `bin/check-scripts.sh` 有一条 grep lint 守着这条边界：出现 bq / lark-cli / $STATE / $ROOT 即失败。
# bash 没有编译器，这是依赖规则在这门语言里唯一能落地的强制形式。

traffic_light() {
  local v="$1" red="$2" yellow="$3"
  [ -n "$v" ] && [ "$v" != "无法计算" ] || { echo ""; return; }
  awk -v v="$v" -v r="$red" -v y="$yellow" 'BEGIN{ if(v>r) print "red"; else if(v>y) print "yellow"; else print "green" }'
}
cell_color() { # $1=判定值 $2=红 $3=黄 $4=单元格内容
  local t; t="$(traffic_light "$1" "$2" "$3")"
  case "$t" in
    red)    printf '<font color=red>%s</font>' "$4";;
    yellow) printf '<font color=orange>%s</font>' "$4";;
    *)      printf '%s' "$4";;
  esac
}
delta_cell() { # $1=最新版值 $2=上一版值 $3=单位(pp|ms|n) $4=方向(lower_better|higher_better|neutral)
  local unit="${3:-n}" dir="${4:-lower_better}" txt worse arrow
  { [ -n "$1" ] && [ -n "$2" ] && [ "$1" != "无法计算" ] && [ "$2" != "无法计算" ]; } || { printf '—'; return 0; }
  txt="$(awk -v c="$1" -v o="$2" -v u="$unit" 'BEGIN{
    d=c-o; sign=(d>0)?"+":"";
    if(u=="ms")      printf "%s%dms", sign, d;
    else if(u=="pp") printf "%s%.2fpp", sign, d;
    else             printf "%s%g", sign, d;
  }')"
  # neutral：只给方向不判好坏（放量进度这类指标，红绿会暗示「新版会话少 = 出问题了」，并不成立）
  worse="$(awk -v c="$1" -v o="$2" -v dir="$dir" 'BEGIN{
    d=c-o;
    if(d==0 || dir=="neutral"){print "flat"}
    else if(dir=="higher_better"){ print (d>0)?"better":"worse" }
    else { print (d>0)?"worse":"better" }
  }')"
  # 箭头跟**数值方向**（涨=↑），颜色跟**好坏**（红=变差）——两者分开表达；
  # 合并会让「会话数 -51」这类「越大越好」的指标渲染成「-51 ↑」，读起来自相矛盾。
  arrow="$(awk -v c="$1" -v o="$2" 'BEGIN{ d=c-o; print (d>0)?"↑":(d<0)?"↓":"" }')"
  [ -n "$arrow" ] && txt="$txt $arrow"
  case "$worse" in
    worse)  printf '<font color=red>%s</font>' "$txt";;
    better) printf '<font color=green>%s</font>' "$txt";;
    *)      printf '%s' "$txt";;
  esac
}

# ⚠️ 原本读全局 RUN_EPOCH，现改为首参传入（理由同 format.sh 的 win_*）。
stale_days() { # $1=基准epoch $2=表 MAX 时间戳文本 $3=窗口天数 → 停更天数（未停更/无法解析 → 空）
  local e
  e="$(_until_epoch "$2")"
  [ -n "$e" ] || { echo ""; return 0; }
  [ "$e" -lt "$(( $1 - $3 * 86400 ))" ] || { echo ""; return 0; }
  echo "$(( ($1 - e) / 86400 ))"
}
