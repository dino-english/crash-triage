#!/usr/bin/env bash
# 三层产物清单（change crash-perf-functional-core，design D7）。
#
# 此前这些路径散落在十几处重定向里，本文件是**契约的第一次显式登记**：
# 每一层各自回答一个问题，三层都 diff 才叫等价。
#
#   中间产物  取数层是否等价（$TMP 下的逐版本 JSON / CSV）
#   投递产物  渲染层是否等价（$PUBLISH_DIR 全部）
#   基准文件  状态写入是否等价、有无意外改写（$STATE 顶层 + issues/ + ledger/）
#
# ⚠️ 中间层是关键：它是数据层与渲染层的天然分界。
#    中间层为空而投递层有差异 → 渲染代码问题；中间层就有差异 → 数据漂移。
#
# 被 source 使用，不直接执行。
STATE="${CRASH_REPORT_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/crash-triage}"

# 基准文件：丢失/损坏后果严重且静默（last-snapshot.json 丢 → 下周所有 issue 报成新增；
# docs.json 丢 → 新建一整套重复飞书文档）。重构不该碰它们，而「不该碰」需要被验证。
artifacts_baseline_files() {
  cat <<'EOF'
health-daily.json
health.json
metrics-history.jsonl
perf-history.jsonl
daily-snapshot.json
last-snapshot.json
issue-seen.json
docs.json
folders.json
report-index.jsonl
EOF
}
# 目录形态的基准：事实层缓存与台账本地源。
# ⚠️ issues/ 极易漏：CLAUDE.md 写它「永久保留不参与清理」，读起来像与跑批无关，
#    实则每次跑批都写；不还原则第二次跑批缓存已热，两次走不同代码分支。
artifacts_baseline_dirs() {
  cat <<'EOF'
issues
ledger
EOF
}

# 某次跑批的中间产物目录（即 TMP）。$1=L1|L2，取最近一次。
artifacts_run_dir() {
  ls -td "$STATE/runs"/*/"${1:?L1 或 L2}"/* 2>/dev/null | head -1
}
