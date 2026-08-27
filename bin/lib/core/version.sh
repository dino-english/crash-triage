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

# ── 性能段分域选版（change crash-data-completeness B 组，design D3/D4）──
# 起因：性能批量表比 crashlytics/sessions 滞后约 2 天，新版在性能表里长期零行——
# 2026-08-27 实测 1.5.5 自 08-26 出现至今，两端性能表都是 0 行，性能那两列一直空着。
#
# ⛔ 这**不是**把「让新版本被看见」推翻：1.5.5 在崩溃段与放量段照常出现（那是真数据，
#    且「新版发出去有没有崩」正是发版当天最该看的一行）。只是在它**本来就没有数据可看**的
#    性能维度上，再补一列有数据的旧版进来。
# ⛔ 判据只看「性能数据有没有」，**MUST NOT 掺任何会话量门槛**（Non-goal，见 crash-daily.sh
#    perf_versions_avail 处的完整理由）。
# ⚠️ 回溯上限（design D4）：无上限会在导出停摆一周时翻到早已没人用的远古版本，显示一个
#    看不出异常的版本比显示空列更糟。上限 = want + back 个候选，之后不再往下翻。
pick_versions_perf() { # $1=候选版本(一行一个) $2=性能表有数据的版本 $3=要几个(默认2) $4=额外回溯上限(默认2)
  local want="${3:-2}" back="${4:-2}" n=0 seen=0 v out="" cands
  cands="$(printf '%s\n' "$1" | grep -v '^$' | sort -rV -u || true)"
  while IFS= read -r v; do
    if [ -z "$v" ]; then continue; fi
    seen=$((seen + 1))
    if [ "$seen" -gt "$((want + back))" ]; then break; fi
    if printf '%s\n' "$2" | grep -qx -- "$v"; then
      out="${out}${v}
"
      n=$((n + 1))
      if [ "$n" -ge "$want" ]; then break; fi
    fi
  done <<< "$cands"
  printf '%s' "$out"
  return 0
}
