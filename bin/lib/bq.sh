#!/usr/bin/env bash
# bq 查询唯一通道（findings F1/F5 收口，change crash-perf-functional-core）。
#
# 为什么必须收口到一处：等价性验收靠 CRASH_REPORT_BQ_CACHE 冻结数据，而缓存只包得住
# bqq——任何绕过它的直连都在验收的「冻结面」上开洞。F1 实测：L2 十处直连让三层 diff
# 永远不为空（sessions 2325→2326、p95 578→651，纯数据漂移淹没真实回归）；F5 实测：
# 缺口没有护栏时，每个照着旧写法新增的取数函数都在扩大它（9 处 → 10 处）。
# 收口后由 check-scripts.sh 的「bq 直连收口 lint」保证不再出现新直连。
#
# ⚠️ 本文件**不是核心层**：它调 bq、读 ${STATE}，属外壳层，放 bin/lib/ 而非 bin/lib/core/。
# ⚠️ 依赖 run_with_timeout（bin/lib.sh），**必须在 lib.sh 之后 source**。
#    缺依赖立即失败不退化——bqq 是取数唯一通道，退化实现会静默丢掉超时与缓存。
#    ⚠️ 例外：crash-daily.sh 在 lib.sh 缺失时定义的退化桩（直接执行、无超时）能通过
#    下面的 declare -F 检查——该回落是既有容错，收紧它属行为变更，另行决策。
#
# 使用（三个取数进程各自 source、各自 init——函数不跨进程，见 CLAUDE.md 跨进程边界）：
#   . "$ROOT/bin/lib.sh"
#   . "$ROOT/bin/lib/bq.sh" || exit 1
#   bq_init                            # 之后才可调 bqq；可先预设 BQ_TIMEOUT/BQ_ERRLOG/BQ_SQLTMP 覆盖默认
#   trap 'rm -f "$BQ_SQLTMP"' EXIT     # 临时文件清理由调用方挂——在这里挂会静默覆盖调用方已有的 EXIT trap

declare -F run_with_timeout >/dev/null || {
  echo "❌ bin/lib/bq.sh 依赖 run_with_timeout，请先 source bin/lib.sh" >&2
  exit 1
}

bq_init() { # 初始化 bqq 的全局；调用方预设过的变量一律不覆盖
  BQ_TIMEOUT="${BQ_TIMEOUT:-180}"   # 单条查询上限；正常查询 3s 内返回，180s 已是极宽松
  if [ -z "${BQ_ERRLOG:-}" ]; then
    mkdir -p "$STATE/logs"
    BQ_ERRLOG="$STATE/logs/bq-stderr-${TS}.log"
  fi
  BQ_SQLTMP="${BQ_SQLTMP:-$STATE/.bq-sql-$$.sql}"
  # 查询缓存（**仅供等价性验收，生产默认关闭**）。
  # 起因：三层 diff 的验收方式在活数据上不成立——滚动窗口锚在跑批时刻，
  # 实测两次跑批相隔 6 分钟，sessions 就从 1108 变成 1107、非致命从 76 变 78。
  # 数据一直在动，diff 永远不为空，重构的真实回归就被淹没在漂移里。
  #
  # 打开 CRASH_REPORT_BQ_CACHE=<目录> 后，每条查询按「格式 + SQL 文本」的哈希缓存结果：
  # 首轮落盘、后续复用。于是验证跑批**完全复用同一批数据**，任何差异都只可能来自代码。
  #
  # ⛔ 生产绝不开启：缓存会让报告呈现陈旧数据而毫无察觉。
  BQ_CACHE="${CRASH_REPORT_BQ_CACHE:-}"
  if [ -n "$BQ_CACHE" ]; then
    mkdir -p "$BQ_CACHE"
    echo "  🧊 bq 查询缓存已开启（${BQ_CACHE}）——仅供等价性验收，生产禁用"
  fi
  return 0
}

# 传输层审计事件 bq.call（archived change crash-perf-execution-audit-log findings F2）：
# 取数已全部收口到 bqq，在这一个咽喉埋点即可覆盖三个取数进程（L1 / L2 / fetch-snapshot-bq），
# 含包装函数层拿不到的信息：缓存命中与否、行数、pid（区分父子进程）。
# 与 L1 包装函数的语义层 query 事件**类型不同**，各记各的，不构成重复计数。
# audit 未定义（lib.sh 未加载）或未接入（无 AUDIT_FILE）都静默跳过；绝不影响主链路。
_bqq_audit() { # $1=format $2=SQL文本 $3=cache标记 $4=行数 $5=秒 $6=rc
  { declare -F audit >/dev/null && audit bq.call "" "$(jq -cn --arg f "$1" \
      --arg sha "$(printf '%s|%s' "$1" "$2" | shasum -a 256 | cut -c1-12)" \
      --arg h "$(printf '%s' "$2" | tr '\n\t' '  ' | cut -c1-80)" \
      --arg cache "$3" --argjson lines "$4" --argjson secs "$5" --argjson rc "$6" --argjson pid "$$" \
      '{format:$f,sql_sha:$sha,sql_head:$h,cache:$cache,lines:$lines,secs:$secs,rc:$rc,pid:$pid}')"; } 2>/dev/null || true
}

bqq() { # $1=csv|json  $2=SQL文本 → stdout；超时返回 124，失败返回 bq 退出码
  local rc=0 ck="" _t0=$SECONDS
  if [ -n "$BQ_CACHE" ]; then
    ck="$BQ_CACHE/$(printf '%s|%s' "$1" "$2" | shasum -a 256 | cut -c1-32)"
    [ -s "$ck" ] && { cat "$ck"; _bqq_audit "$1" "$2" hit 0 0 0; return 0; }
  fi
  printf '%s\n' "$2" > "$BQ_SQLTMP"
  local out
  # ⛔ 不要用「_bqq_raw() { bqq "$@"; } + 重定义 bqq」那种包装做缓存：
  #    bash 在**调用时**解析函数名，_bqq_raw 会调到新的 bqq 上 → 无限递归。
  #    实测第一条查询就挂死，整跑卡在「选表」。读写都放同一个函数里。
  out="$(run_with_timeout "$BQ_TIMEOUT" \
    bash -c 'exec bq query --use_legacy_sql=false --format="$1" < "$2"' \
    _ "$1" "$BQ_SQLTMP" 2>>"$BQ_ERRLOG")" || rc=$?
  if [ "$rc" -eq 124 ]; then
    echo "  ⏱️ bq 查询超时 ${BQ_TIMEOUT}s，按缺数降级（详见 $(basename "${BQ_ERRLOG}")）" >&2
  fi
  # 只缓存成功的查询——把失败/超时的空结果缓存下来等于把故障固化
  [ -n "$ck" ] && [ "$rc" -eq 0 ] && printf '%s\n' "$out" > "$ck"
  _bqq_audit "$1" "$2" "$([ -n "$BQ_CACHE" ] && echo miss || echo off)" \
    "$(printf '%s' "$out" | grep -c . || true)" "$((SECONDS - _t0))" "$rc"
  printf '%s\n' "$out"
  return "$rc"
}

# ── 前后台归一化表达式（change crash-fg-bg-split / crash-issue-drilldown）─────────
# ⛔ **全仓唯一定义**。两份 SQL（crash-error-types / crash-issue-drilldown）都用 {{FG_NORM}}
#    占位符引用它——把 CASE 表达式抄进第二个文件就是失效模式 F1「同一目的两份实现」，
#    而 check-scripts 第 4 项只检测同名 bash 函数，SQL 里的重复它一个都抓不到。
# 取值优先级：process_state（Crashlytics 一等字段，双端同名同枚举）→ 自埋 app_foreground 回落。
# ⚠️ 两端 app_foreground 取值不同，方向经交叉验证（2026-08-24，7d）：
#    iOS   BACKGROUND↔"0"=1068 · FOREGROUND↔"1"=14   Android FOREGROUND↔"true"=162 · BACKGROUND↔"false"=11
# ⚠️ 放 bin/lib/bq.sh 而非 core：core 要求 env -i 可调用且不依赖外层，这是取数层的 SQL 片段。
SQL_FG_NORM="COALESCE(NULLIF(process_state, 'UNKNOWN_PROCESS_STATE'), CASE LOWER(IFNULL((SELECT value FROM UNNEST(custom_keys) WHERE key = 'app_foreground' LIMIT 1), '')) WHEN 'true' THEN 'FOREGROUND' WHEN '1' THEN 'FOREGROUND' WHEN 'false' THEN 'BACKGROUND' WHEN '0' THEN 'BACKGROUND' ELSE NULL END)"
