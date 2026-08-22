#!/usr/bin/env bash
# 核心层（Functional Core）——版本清单挑选
#
# ⛔ 本层是**纯函数**：给定相同入参产出相同结果。不读写文件、不发起网络或数据查询、
#    不读取当前时刻、**不引用任何脚本全局变量**。所有输入经位置参数传入，输出经 stdout 返回。
#    判定标准是「是否读取了参数之外的状态」，而非是否 fork 了进程——
#    把一个 epoch 格式化成日期字符串是纯的，取「现在几点」不是。
#
# 因为不依赖全局，本层**加载顺序任意**，且可在空环境中直接调用（这正是「可测」的操作性定义）。
# `bin/check-scripts.sh` 有一条 grep lint 守着这条边界：出现 bq / lark-cli / $STATE / $ROOT 即失败。
# bash 没有编译器，这是依赖规则在这门语言里唯一能落地的强制形式。

pick_newest() { printf '%s\n' "$1" | grep -v '^$' | cut -d, -f1 | sort -rV -u | head -"$2" || true; }
pick_top_sessions() { printf '%s\n' "$1" | grep -v '^$' | sort -t, -k2,2 -nr | head -2 | cut -d, -f1 || true; }
ver_field() { printf '%s\n' "$1" | grep -v '^$' | awk -F, -v v="$2" -v f="$3" '$1==v{print $f; exit}' || true; }

# ⚠️ 原本读全局 MAX_VERSION_COLS，现改为第三参传入。
# 列集合 = 最新 N 版 ∪ 主力 2 版，按版本号新→旧，上限由调用方给。
union_versions() { # $1=最新版列表 $2=主力版列表 $3=列上限
  printf '%s\n%s\n' "$1" "$2" | grep -v '^$' | sort -rV -u | head -"$3" || true
}
