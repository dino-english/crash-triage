#!/usr/bin/env bash
# 事实层观测字段的落盘（change crash-fact-cache-deterministic-records，design D1/D2）。
#
# 为什么是共享函数：这段逻辑此前有两份实现——确定性 shell（fetch-snapshot-bq.sh）一份、
# 模型执行的自然语言 prompt（fetch-snapshot.sh 的 FACT_CACHE_POLICY）一份。
# 后者实测 25 轮里只有 5 轮真正落盘，且写出的 last_synced 三种口径并存
# （真 UTC / 本地时间标 Z，快 8 小时）。**措辞一致 ≠ 行为一致**——把它收成一份 bash 实现，
# 跨执行模型的重复就物理消失了（crash-perf-functional-core design D10 登记的缺口）。
#
# ⛔ 不放 bin/lib/core/：本函数要落盘到 issues 目录，核心层的依赖方向 lint（check-scripts
#    第 3 项）会因 `$STATE` 类引用而拦下。**路径一律走参数**，函数体内不出现 $STATE 与 $ROOT 这两个变量。
# ⚠️ 函数不跨进程：fetch-snapshot-bq.sh 与 fetch-snapshot.sh 是两个独立子进程，各自 source。

# 写入/刷新一条事实层记录的观测字段。
#
# ⛔ 时刻由**调用方**用 `date -u` 产生并传入（$9），不在函数内取——同一轮跑批的所有记录
#    必须共享同一个时刻，否则「是不是本轮」的断言会在一轮内部产生漂移。
# ⛔ 更新分支**不碰 .source**：该字段区分「只有聚合事实」（bigquery）与「有完整事件数组」
#    （模型路径），由创建者写死；更新时改写会把来源标签抹掉——events 数组还在，标签却说没有。
# ⚠️ latest_event 取 max(已存, 本次)：窗口内的 MAX(event_timestamp) 非单调，最新那条出窗后
#    剩余事件的 MAX 会比上一轮更早。直接覆盖会把「冻结」换成更糟的「倒退」。
#
# 退出码：0 已写入 · 1 写入失败 · 3 文件不存在且未获准新建（调用方据此计数，见 D7）
fc_record() { # $1=issues目录 $2=32位id $3=平台 $4=标题 $5=事件数 $6=用户数 $7=最近事件 $8=窗口天数 $9=本轮时刻 ${10}=新建时的 source（空串=不新建）
  local dir="$1" id="$2" plat="$3" title="$4" events="$5" users="$6" latest="$7" wd="$8" now="$9" src="${10:-}"
  local f="$dir/$id.json" tmp
  if [ ! -f "$f" ]; then
    # ⛔ 默认不新建。模型路径下「文件不存在」意味着这一轮它连事件都没抓——此时补一条
    #    带真实计数的记录，会让**下一轮**的抓取判定把它当成已缓存而跳过（cache_verdict
    #    只看计数不看 events 数组），事件明细就永远补不回来了。宁可留空让下轮全量重抓。
    [ -n "$src" ] || return 3
    jq -n --arg id "$id" --arg p "$plat" --arg t "$title" --arg l "$latest" \
          --argjson e "$events" --argjson u "$users" --argjson w "$wd" \
          --arg ts "$now" --arg s "$src" \
      '{id:$id, platform:$p, title:$t, events_count_last_seen:$e, users_last_seen:$u,
        latest_event:(if $l == "" then null else $l end),
        window_days:$w, source:$s, last_synced:$ts}' > "$f" || return 1
    return 0
  fi
  tmp="$(mktemp)" || return 1
  # ⚠️ 空的 latest 不参与比较：模型路径的快照里没有该字段，传空串时必须保留已存值。
  if jq --argjson e "$events" --argjson u "$users" --arg l "$latest" \
        --argjson w "$wd" --arg ts "$now" \
       '.events_count_last_seen=$e | .users_last_seen=$u
        | .latest_event=(if $l != "" and ((.latest_event // "") < $l) then $l else .latest_event end)
        | .window_days=$w | .last_synced=$ts' \
       "$f" > "$tmp"; then
    mv "$tmp" "$f" || { rm -f "$tmp"; return 1; }
  else
    rm -f "$tmp"; return 1
  fi
  return 0
}

# ── 「抓得到 / 抓不到」的判定（change crash-fact-cache-events-backfill，findings F-1）──
# 事实层的欠账记录分两类：**还没抓**（事件仍在窗口内）与**抓不到**（事件已滑出窗口，
# `list_events` 查不到任何东西）。⛔ 混在一个数里会让收敛判据永远不达标，
# 更糟的是按 id 排序的节流会被「抓不到」的记录**永久占位**——
# 2026-09-10 生产实测：15 条欠账里 13 条已出窗，而按 id 排序的前三名全是它们。

# 窗口起点（UTC 日期）。⚠️ macOS 与 Linux 的 date 参数不同，两种都试。
fc_cutoff_date() { # $1=窗口天数 → YYYY-MM-DD
  date -u -v-"$1"d +%Y-%m-%d 2>/dev/null && return 0
  date -u -d "$1 days ago" +%Y-%m-%d 2>/dev/null && return 0
  printf ''
}

# 某条记录的事件是否已全部滑出窗口（= 抓不到）。
# ⚠️ `latest_event` 缺失时判为**可补**：没有证据说明它陈旧，宁可花一个名额去试，
#    也不要把一条可能补得上的记录永久排除在候选之外。
fc_unfetchable() { # $1=事实层文件 $2=窗口起点(YYYY-MM-DD) → rc 0=抓不到
  local le
  le="$(jq -r '(.latest_event // "") | .[0:10]' "$1" 2>/dev/null || printf '')"
  [ -n "$le" ] || return 1
  [ -n "$2" ] || return 1
  if [[ "$le" < "$2" ]]; then return 0; fi
  return 1
}
