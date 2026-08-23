#!/usr/bin/env bash
# 核心层（Functional Core）——缓存策略判定（change crash-perf-functional-core，design D10）
#
# ⛔ 本层是**纯函数**：给定相同入参产出相同结果。不读写文件、不发起网络或数据查询、
#    不读取当前时刻、**不引用任何脚本全局变量**。所有输入经位置参数（或 stdin）传入，
#    输出经 stdout 返回。
#
# 分层依据：缓存的 *policy*（该不该重取、该不该淘汰）是纯判定，进核心层；
# *mechanism*（读写文件）是副作用，留外壳层。这与仓库已有的一次同向决策一致——
# `fetch-snapshot-bq.sh` 的「事实层缓存判定在 shell 里做，不在 prompt 里」把 policy
# 从模型手里收回；再从 IO 循环收进核心层是同一方向的下一步，理由相同：**判定要能被断言**。

# 事实层**抓取**判定（从 fetch-snapshot-bq.sh 的 while 循环上移）。
#
# ⚠️ 只回答「要不要发起抓取」这**一个**问题。观测字段（计数 / latest_event / last_synced /
#    window_days）的刷新是**另一个判定，每轮无条件执行**，不归本函数管。
#    两者曾被挤在一个 if/else 里，导致「跳过抓取」连带跳过记录更新：`latest_event` 冻结在
#    历史峰值那天、`last_synced` 冻结让正在被修好的 issue 看起来像「数据停更」。
#    已由 change crash-fact-cache-freshness 于 2026-08-22 拆开修复。
#
# ⚠️ 本次计数 **小于** 上次是正常的，不是异常：滚动窗口内的 COUNT(*) 老事件出窗即下降，
#    **不是单调量**。下降只意味着没有新事件 → 跳过抓取是**正确的**。
cache_verdict() { # $1=强制重抓(1/0) $2=文件是否存在(1/0) $3=上次计数 $4=本次计数 → new|append|skip
  if [ "$1" = "1" ] || [ "$2" != "1" ]; then printf 'new'; return 0; fi
  if [ "$4" -gt "$3" ] 2>/dev/null; then printf 'append'; else printf 'skip'; fi
}

# docs.json 的日期键保留谓词（从 deliver.sh 的 doc_prune 上移，jq 表达式一字未改）。
# JSON 自 stdin 进、结果自 stdout 出——不碰文件，读写由外壳层负责。
#
# ⛔ **先 test 再 capture**：capture 不匹配时返回**空**而不是 null，`// "9999"` 兜不住，
#    整个 entry 会被 select 判假而丢弃——`index` / `ledger` 这类无日期后缀的固定键会被误删。
#    2026-08-18 实测踩过：两个固定文档键被删，下次运行重建了两份新飞书文档。
#    这是全仓库最该有断言的一处纯判定，代价是重建整套文档。
doc_keep_predicate() { # $1=cutoff（YYYY-MM-DD）
  jq --arg cut "$1" \
    'with_entries(select(
       if (.key | test("-[0-9]{4}-[0-9]{2}-[0-9]{2}$"))
       then (.key | capture("-(?<d>[0-9]{4}-[0-9]{2}-[0-9]{2})$").d) >= $cut
       else true end))'
}
