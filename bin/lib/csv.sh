#!/usr/bin/env bash
# CSV 解析（外壳层，与 bq.sh 平级）——**全仓唯一的 bq CSV 解析入口**。
#
# ⛔ 不要对 bq 的 CSV 输出用 `awk -F,` / `cut -d,`：含逗号的字段 bq 会加引号，裸切会切成两列。
#    实测 2026-08-24：Apple 机型标识符自带逗号（`iPad7,11` / `iPhone14,3` 是官方格式），
#    原始行 `"Apple iPad7,11",1,1,0,,1.0` 被切成 机型=`"Apple iPad7`、事件=`11"`——
#    **1 个事件渲染成 11**，集中度整列丢失，退出码 0、无任何告警。
#    同类风险字段还有 perf-network 的 `event_name`（是 URL）。
#
# ⚠️ 本文件放 bin/lib/ 不放 bin/lib/core/：core 要求「env -i 空环境可调用」，
#    而这里依赖 python3 在 PATH 中，不满足该判据（check-scripts 第 3 项查的是另一件事，
#    它不会拦下来——这是判据本身的要求，不是 lint 的要求）。
#
# 为什么转 TSV 而不是直接在 awk 里解析引号：BigQuery 这些列都是标识符或数字，**不含制表符**，
# 而逗号确定会出现。转成 TSV 后调用方 `awk -F'\t'` 的字段号与原来完全一致，改造只动分隔符。

# stdin CSV → stdout TSV。字段内的制表符替换为空格（防御性，实测未出现过）。
csv2tsv() {
  python3 -c '
import csv, sys
for r in csv.reader(sys.stdin):
    sys.stdout.write("\t".join(f.replace("\t", " ") for f in r) + "\n")
'
}

# 取文件首行第 N 列（1 起始）。文件不存在或为空 → 空串。
csv_field1() { # $1=文件 $2=列号
  [ -s "$1" ] || { printf ''; return 0; }
  csv2tsv < "$1" | awk -F'\t' -v c="$2" 'NR==1{printf "%s", $c}'
}

# ── 刻意**不**走本文件的位置（不是漏网，别顺手改）────────────────────────
# 判据：字段本身不可能含逗号，改造只会增加出错面。
#   crash-daily.sh  `grep '^_app_start,' | cut -d, -f3/-f4`  —— 首列是 Firebase trace 名（标识符）
#   crash-daily.sh  allver_crashfree 的 `cut -d, -f2/-f4`     —— crash-rate.sql 输出整行皆数字
#   crash-daily.sh  hours_peak / hours_cluster 的 `awk -F,`   —— crash-hours.sql 输出为时间桶与计数
#   crash-daily.sh  sum_impact_rows / blame_csv 下游的 `awk -F,` —— 消费的是**本仓库自己**生成并加引号的
#                    中间 CSV，且其字段（平台/版本/数字）不含逗号；真正的解析在 md_csv_table / xml_csv_table
#                    的 Python csv.reader 里完成
