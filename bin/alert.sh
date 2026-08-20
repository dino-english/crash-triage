#!/usr/bin/env bash
# 流水线故障告警：把失败发到群里，而不是死在日志里没人看见。
#
# 为什么要有它：整条链路的失败都是「安静」的——脚本 exit 1、health.json 写个 ok:false、
# 然后什么都不发生。群里没消息时，看的人无法区分「今天很好」和「昨晚挂了」。
# 监控系统最忌讳的就是这种沉默。
#
# 用法：
#   alert.sh --source daily --step "查询崩溃数据" --message "bq 不可用" \
#            [--severity error|warn] [--run-id X] [--log /path] [--rc 1] [--hint "建议动作"]
#
# 设计约束：**告警自身失败绝不能影响主流程**——所有错误吞掉，恒退出 0。
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export CRASH_REPORT_ROOT="${CRASH_REPORT_ROOT:-$(dirname "$SELF_DIR")}"
STATE="${CRASH_REPORT_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/crash-triage}"
# if/elif 不是两条 && ：并列写法下旧的 config.env 会盖掉 path.env，迁移后那份是陈旧的
if [ -f "$STATE/path.env" ]; then . "$STATE/path.env" 2>/dev/null
elif [ -f "$STATE/config.env" ]; then . "$STATE/config.env" 2>/dev/null   # 旧名，兼容一轮
fi
# 告警器不能和被监控对象共享故障源：PATH 配错正是最常见的失败原因之一，
# 而 path.env 恰好就是 PATH 的来源。找不到 lark-cli 就补上常见安装位置再试
# （2026-08-18 实测：伪造坏 PATH 触发告警，告警自己也发不出去）。
if ! command -v lark-cli >/dev/null 2>&1; then
  PATH="$PATH:$HOME/.npm-global/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
fi
export PATH

SOURCE="未知"; STEP=""; MESSAGE=""; SEVERITY="error"; RUN_ID=""; LOGF=""; RC=""; HINT=""
while [ $# -gt 0 ]; do
  case "$1" in
    --source) SOURCE="$2"; shift 2;;
    --step) STEP="$2"; shift 2;;
    --message) MESSAGE="$2"; shift 2;;
    --severity) SEVERITY="$2"; shift 2;;
    --run-id) RUN_ID="$2"; shift 2;;
    --log) LOGF="$2"; shift 2;;
    --rc) RC="$2"; shift 2;;
    --hint) HINT="$2"; shift 2;;
    *) shift;;
  esac
done

CHAT_ID="${CRASH_REPORT_ALERT_CHAT_ID:-${CRASH_REPORT_CHAT_ID:-}}"
[ -n "$CHAT_ID" ] || { echo "alert: 未设置 CRASH_REPORT_ALERT_CHAT_ID / CRASH_REPORT_CHAT_ID，跳过" >&2; exit 0; }
LARK_AS="${CRASH_REPORT_LARK_AS:-bot}"
CACHE_NS="${CRASH_REPORT_LARK_PROFILE:-crash-triage}"
LARK_PROFILE="$CACHE_NS"
# hermes/openclaw 上下文下 lark-cli 走 Agent 工作区配置，没有命名 profile（见 deliver.sh 注释）
[ -n "${HERMES_HOME:-}${OPENCLAW_HOME:-}" ] && LARK_PROFILE=""
LK=(lark-cli); [ -n "$LARK_PROFILE" ] && LK=(lark-cli --profile "$LARK_PROFILE")

case "$SOURCE" in
  daily)   SRC_NAME="L1 日报";;
  weekly)  SRC_NAME="L2 周报";;
  deliver) SRC_NAME="投递";;
  agent)   SRC_NAME="Agent 取数";;
  *)       SRC_NAME="$SOURCE";;
esac
if [ "$SEVERITY" = warn ]; then
  TONE=orange; EMOJI="⚠️"; TITLE="降级运行"; HDR=orange
else
  TONE=red;    EMOJI="🚨"; TITLE="执行失败"; HDR=red
fi

# 错误摘要截断：卡片不该塞整份日志，够定位就行
SUMMARY="$(printf '%s' "$MESSAGE" | head -c 600)"
[ -n "$LOGF" ] && [ -s "$LOGF" ] && TAIL="$(tail -6 "$LOGF" 2>/dev/null | head -c 800)" || TAIL=""

# 默认建议：多数故障的共性是「数据没产出」还是「产出了没投递」——这决定要不要补投
if [ -z "$HINT" ]; then
  case "$SOURCE" in
    deliver) HINT="数据已落盘，重跑 bin/deliver.sh 即可补投（幂等键保证不会重复发卡片）";;
    *)       HINT="查看日志定位后重跑对应脚本；数据源问题通常次日自行恢复";;
  esac
fi

# 父目录链接：故障时最常问的是「文档到底产出了没」，给个直达入口比让人翻云空间强
FOLDER_URL="$( [ -s "$STATE/docs.json" ] && jq -r --arg k "${CACHE_NS}|folder-root-url" '.[$k] // empty' "$STATE/docs.json" 2>/dev/null || true )"

ROWS="$(jq -cn --arg s "$SRC_NAME" --arg st "${STEP:-—}" --arg rc "${RC:-—}" \
  --arg rid "${RUN_ID:-—}" --arg t "$(date '+%Y-%m-%d %H:%M:%S')" \
  '[{k:"环节",v:$s},{k:"步骤",v:$st},{k:"退出码",v:$rc},{k:"运行 ID",v:$rid},{k:"时间",v:$t}]')"

CARD="$(jq -n \
  --arg hdr "$HDR" --arg title "$EMOJI 崩溃 & 性能流水线 · $TITLE" \
  --arg lead "**$SRC_NAME $TITLE**${STEP:+ · $STEP}" \
  --arg sum "$SUMMARY" --arg tail "$TAIL" --arg hint "$HINT" \
  --arg logf "${LOGF:-—}" --arg tone "$TONE" --arg folder "$FOLDER_URL" \
  --argjson rows "$ROWS" \
  '{schema:"2.0", config:{width_mode:"fill"},
    header:{template:$hdr,title:{tag:"plain_text",content:$title}},
    body:{elements:([
      {tag:"markdown",content:("<font color=" + $tone + ">" + $lead + "</font>")},
      {tag:"hr"},
      {tag:"table",page_size:6,row_height:"low",
       header_style:{text_align:"left",text_size:"normal",background_style:"grey",text_color:"default",bold:true,lines:1},
       columns:[{name:"k",display_name:"项",data_type:"text",width:"auto",horizontal_align:"left"},
                {name:"v",display_name:"值",data_type:"lark_md",width:"auto",horizontal_align:"left"}],
       rows:$rows},
      {tag:"markdown",content:("**错误**\n```\n" + $sum + "\n```")}]
      + (if $tail != "" then [{tag:"markdown",content:("**日志尾部**\n```\n" + $tail + "\n```")}] else [] end)
      + [{tag:"markdown",content:("💡 " + $hint)},
         {tag:"div",text:{tag:"plain_text",content:("日志：" + $logf),text_size:"notation",text_color:"grey"}}])}}')"

TMP="$(mktemp)"; printf '%s' "$CARD" > "$TMP"
case "$CHAT_ID" in ou_*) RECIP=(--user-id "$CHAT_ID");; *) RECIP=(--chat-id "$CHAT_ID");; esac
# 幂等键 = run_id + 环节 + 步骤：同一次运行里同一处反复失败不会刷屏
KEY="$(printf 'alert-%s-%s-%s' "${RUN_ID:-none}" "$SOURCE" "${STEP:-x}" | tr -c 'A-Za-z0-9-' '-' | head -c 50)"
if "${LK[@]}" im +messages-send "${RECIP[@]}" --msg-type interactive \
     --content "$(cat "$TMP")" --idempotency-key "$KEY" --as "$LARK_AS" --format json >/dev/null 2>&1; then
  echo "  📣 已发送告警到 $CHAT_ID"
else
  echo "  ⚠️ 告警发送失败（不影响主流程）" >&2
fi
rm -f "$TMP"
exit 0
