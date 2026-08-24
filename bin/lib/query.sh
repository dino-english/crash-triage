#!/usr/bin/env bash
# SQL 模板渲染（外壳层，与 bq.sh / csv.sh 平级）——**全仓唯一的占位符替换入口**。
#
# 为什么只收口「替换」而不收口整个包装函数：L1 与 L2 对同一份 SQL 的**调用约定确实不同**
# （L1 多走 `bqq json` + jq 取字段，L2 走 `bqq csv` + cut/awk），那是刻意的差异不是重复。
# 真正重复的是 8 份 SQL × 两条链路的 sed 替换链——2026-08-24 加 `{{FG_NORM}}` 时就得改两处，
# 漏一处的表现是 BigQuery 语法错（响，但要等到跑批才响）。
#
# ⛔ **不要加「多传占位符」检测**（2026-08-24 试过，当轮就给使用方发了误报告警卡，失效模式 F30）：
#    `qc()` / `q()` 是**通用包装**——一个函数喂多份 SQL，固定传一整套占位符，
#    某份 SQL 用不到其中几个是**设计如此**。把它当异常会对正常路径持续报警。
#    真正要守的是**漏传**（下方缺项检查），那才会让 SQL 带着 {{...}} 去执行。
#
# ⛔ **窗口天数必须由调用方显式传**，本层不设默认值：L1 用 CRASH_DAYS(7)/PERF_DAYS(3)、
#    L2 用 WEEK_DAYS(7)。共享层一旦有默认值，某条链路漏传时会**静默用错窗口**——
#    那种错不报错、数字看着也合理，是这个仓库最怕的一类。

# 渲染 SQL 文本到 stdout。用法：q_render <sql文件名> KEY=VALUE ...
#   q_render crash-rate.sql TABLE="$t" SESSIONS_TABLE="$s" DAYS=7 VERSIONS='"1.5.4"'
q_render() {
  local name="$1" f="${SQL_DIR:?SQL_DIR 未设置}/$1"; shift
  [ -f "$f" ] || { echo "❌ SQL 模板不存在：$f" >&2; return 1; }
  local out kv k v
  out="$(cat "$f")" || return 1
  for kv in "$@"; do
    k="${kv%%=*}"; v="${kv#*=}"
    # ⚠️ 用 python 做字面替换而不是 sed：值里出现 sed 的分隔符（|）或 & 都会静默改写结果，
    #    而维度表达式与归一化 CASE 语句都是自由文本，迟早会撞上。
    out="$(K="$k" V="$v" python3 -c '
import os, sys
sys.stdout.write(sys.stdin.read().replace("{{" + os.environ["K"] + "}}", os.environ["V"]))
' <<<"$out")" || return 1
  done
  # ⛔ 未替换的占位符必须**当场失败**，不能喂给 BigQuery 让它报语法错——
  #    语法错的信息里没有「哪个占位符漏了」，而这正是「加了新占位符只改了一条链路」
  #    （失效模式 F1）最常见的落地方式。
  # ⛔ `|| true` 不可省：**`grep -o` 无匹配时返回 1**，而「无匹配」正是成功路径
  #    （没有漏传的占位符）。`set -e` + `pipefail` 下这个赋值状态为 1 → ERR trap →
  #    **每次成功渲染都发一张告警卡**（2026-08-24 实测，alert_once 才让它只发了一张）。
  #    与失效模式 F21（`grep -c … || echo 0` 得到两个 0）是同一类：⚠️ grep 的退出码
  #    表达的是「有没有匹配」，不是「有没有出错」。
  local left
  left="$(printf '%s' "$out" | grep -o '{{[A-Z_]*}}' | sort -u | tr '\n' ' ' || true)"
  if [ -n "$left" ]; then
    echo "❌ ${name} 存在未替换的占位符：${left}（调用方漏传）" >&2
    return 1
  fi
  printf '%s\n' "$out"
}
