#!/usr/bin/env bash
# 投递器：读 manifest.json，用 lark-cli 把文档与卡片投到飞书。
#
# 为什么不是 agent：这条链路每一步都是确定性 API 调用——建文档 → 拿 URL → 回填占位符 → 发卡片，
# 没有一处需要判断力。交给 LLM 换来的是不可复现、可能改写卡片数字、以及重复投递
# （2026-08-17 实测：脚本成功但 agent 中途崩，文档建了卡片没发，系统完全不自知）。
# 重复投递这一项由 lark-cli 的 --idempotency-key 原生根治，不需要额外的投递台账。
#
# 用法：deliver.sh [manifest.json]         默认 $STATE/publish/manifest.json
#      CRASH_REPORT_DRY_RUN=1 只打印不投递
set -euo pipefail
unset PYTHONPATH

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export CRASH_REPORT_ROOT="${CRASH_REPORT_ROOT:-$(dirname "$SELF_DIR")}"
ROOT="$CRASH_REPORT_ROOT"
# 核心层（纯函数）。本脚本是独立进程，必须自己加载——不能指望调用方 export 函数。
# 只加载用得到的 cache：缺失则直接失败不退化，退化版本会静默产出错误判定
# （抓取判定退化 → 事实层停更；保留谓词退化 → 误删固定文档键、重建整套飞书文档）。
# shellcheck disable=SC1091
. "$ROOT/bin/lib/core/cache.sh" || { echo "❌ 核心层缺失：bin/lib/core/cache.sh" >&2; exit 1; }
STATE="${CRASH_REPORT_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/crash-triage}"
# PATH 来源，见 crash-daily.sh 同处注释。
# else 兜底是随改名一起补的：本脚本原本只有 if、没有 else，文件缺失时就直接吃 cron 的最小 env，
# 而 lark-cli 装在 npm 全局目录里——PATH 一缺，投递整条链路挂掉且报错指向 lark-cli 而非 PATH。
if [ -f "$STATE/path.env" ]; then
  # shellcheck disable=SC1091
  . "$STATE/path.env"
else
  PATH="/opt/homebrew/bin:/usr/local/bin:$HOME/.npm-global/bin:/usr/bin:/bin:/usr/sbin:/sbin"
fi
# 机器本地配置，见 crash-daily.sh 同处注释。deliver.sh 是投递的唯一出口，这里再 source 一次，
# 是为了拦住「拿别处产出的 manifest 在本机补投」——那份 manifest 里的 chat_id 可能是正式群。
[ -f "$STATE/local.env" ] && . "$STATE/local.env"   # shellcheck disable=SC1091
# 必须 export：alert.sh / deliver.sh 是**子进程**，local.env 里的普通赋值它们看不见。
# 2026-08-20 实测：只靠 local.env 的机器，失败告警被 alert.sh 当成「未设置 CHAT_ID」静默跳过。
# （生产机因 wrapper 里已 export、普通赋值保留 export 属性而侥幸没中招。）
export CRASH_REPORT_CHAT_ID
export PATH

# 身份钉死 bot：user 身份的 refresh token 会过期（需人工重登），无人值守跑必挂；
# bot 身份不过期。且 bot 导入的文档会自动给 CLI 用户授 full_access，人照样能管。
LARK_AS="${CRASH_REPORT_LARK_AS:-bot}"
# 主力应用（壹帏管家 cli_aaf7b44ddeb8de14）。两个概念必须分开，合在一起会出大问题：
#   CACHE_NS   —— docs.json / folders.json 的键前缀，**任何环境下都必须一致**，
#                 否则 hermes 跑的时候认不出已建文档，会重新建一整套
#   LARK_PROFILE —— 传给 lark-cli 的 --profile。hermes/openclaw 上下文下 lark-cli
#                 改用 Agent 工作区配置（~/.lark-cli/hermes/config.json），那里没有命名
#                 profile，传了直接报 `profile "crash-triage" not found`（2026-08-18 实测）
CACHE_NS="${CRASH_REPORT_LARK_PROFILE:-crash-triage}"
LARK_PROFILE="$CACHE_NS"
[ -n "${HERMES_HOME:-}${OPENCLAW_HOME:-}" ] && LARK_PROFILE=""
LK=(lark-cli); [ -n "$LARK_PROFILE" ] && LK=(lark-cli --profile "$LARK_PROFILE")
MANIFEST="${1:-$STATE/publish/manifest.json}"
DRY_RUN="${CRASH_REPORT_DRY_RUN:-0}"
TODAY="$(date +%Y-%m-%d)"

fail() {
  echo "❌ $*" >&2
  # 投递失败必须发出去：数据已落盘但群里没消息，是最容易被当成「今天没问题」的故障形态
  [ -x "$ROOT/bin/alert.sh" ] && "$ROOT/bin/alert.sh" --source deliver --severity error \
    --step "${CURRENT_STEP:-投递}" --message "$*" --rc 1 --run-id "${RUN_ID:-}" >/dev/null 2>&1 || true
  exit 1
}
# lark-cli 会在 JSON 前打进度行（"Uploading media for import: ..."），直接喂 jq 会解析失败——
# 于是「已经成功」被读成「失败」，重跑又建一份文档。截取第一个 { 之后的内容再解析。
# （这条坑 INSTALL.md §9 早有登记：drive +delete 同样如此。）
json_only() { sed -n '/^[[:space:]]*{/,$p'; }
# 本轮新建的固定资源（文件夹 / 尚未钉住的文档）：收尾时打印成可直接粘贴的表格。
# 这些是部署实例独有的事实，不回填到 CLAUDE.md 的「部署实例」表里，换机器就只能翻群找入口。
# 用文件不用变量：记录点都在 $(...) 命令替换里，子 shell 的赋值传不回父进程。
NEW_RESOURCES="$(mktemp)"
# ⛔ EXIT trap 用**完成哨兵**判定成败，⚠️ 不能靠 `$?`——bash 3.2 在 `set -u` 未定义变量
#    这条致命路径上，**进 trap 时 `$?` 已经是 0**（实测；普通命令失败时才是 1）。
#    而 unbound variable 恰是本仓库最常见的失败模式（多字节首字节被并进变量名）。
#    不修则三重静默：退出码 0 + ERR trap 不触发（shell 错误不是命令失败）+ health
#    停在上一轮的 ok:true——cron 看到成功、无告警、群里却收不到报告（2026-08-24 实测）。
#    ⚠️ 任何提前 `exit 0` 的合法路径都必须先置 RUN_COMPLETED=1。
trap 'rm -f "$NEW_RESOURCES"; [ "${RUN_COMPLETED:-0}" = 1 ] || exit 1' EXIT
note_new() { printf '| %s | `%s` |\n' "$1" "$2" >> "$NEW_RESOURCES"; }
[ -s "$MANIFEST" ] || fail "投递清单不存在：$MANIFEST"
jq empty "$MANIFEST" 2>/dev/null || fail "投递清单不是合法 JSON：$MANIFEST"

m() { jq -r --arg p "$1" '(getpath($p | split(".")) // "") | tostring' "$MANIFEST"; }
TYPE="$(m type)"; DAY="$(m day)"; RUN_ID="$(m run_id)"; CHAT_ID="$(m chat_id)"
[ -n "$CHAT_ID" ] || fail "清单缺 chat_id"

# 本机配置压过清单：local.env 里的 CRASH_REPORT_CHAT_ID 决定这台机器往哪投，
# 而不是清单里记着的那个目标。开发机据此把测试卡片留在私聊，正式群只由生产机投。
# 生产机上两者本就相同，这段等于没执行；不一致才打印，静默改目标比误发还难查。
if [ -n "${CRASH_REPORT_CHAT_ID:-}" ] && [ "$CRASH_REPORT_CHAT_ID" != "$CHAT_ID" ]; then
  echo "  ⚠️ 本机 local.env 覆盖投递目标：清单 ${CHAT_ID} → 实投 ${CRASH_REPORT_CHAT_ID}"
  CHAT_ID="$CRASH_REPORT_CHAT_ID"
fi

# 正式投递 = 投到群（oc_）。投私聊（ou_）是开发机自测，**不得写正式产物**：
# 两台机器的 docs.json 指向同一份索引页与同一份台账（UPQNdbz… / Ttpwdhg…），
# 开发机跑一次就会覆盖群里那份索引页、并把测试结论同步进正式台账（2026-08-20 查实）。
# 归档同理：它的语义是「已正式投递」，私聊测试不该入档。
# 日报/周报文档本身照常建——它们按 docs.json 的日期键各机器各一份，互不干扰，
# 而看到真实渲染效果正是自测的目的。
case "$CHAT_ID" in
  oc_*) IS_PROD=1 ;;
  *)    IS_PROD=0
        echo "  🧪 自测模式（投递目标 ${CHAT_ID} 非群）：跳过归档、索引页与台账同步" ;;
esac

# 陈旧清单闸门：脚本失败时不会重写 manifest，照投就会把昨天的卡片当今天发出去。
# 这类静默错误比不投更糟——宁可报错让人来看。
if [ "$DAY" != "$TODAY" ]; then
  fail "清单日期 $DAY ≠ 今天 ${TODAY}，拒绝投递（脚本可能没跑成功，manifest 是旧的）"
fi

echo "=== 投递 $TYPE · $DAY · run $RUN_ID ==="
[ "$DRY_RUN" = "1" ] && echo "（DRY RUN，只打印不执行）"

# ── 文件夹结构 ────────────────────────────────────────
# Dino 崩溃 & 性能日/周报
#   ├─ L1 日报        ← 日报文档（每天新建，都堆在这个目录里）
#   ├─ L2 周报        ← 周报文档（每周新建）
#   └─ 索引 / 台账镜像 ← 固定两份，原地覆盖，放父目录根部
#
# 按「名字」查而不是每次新建：否则每天会多出一个同名文件夹。查到就复用，查不到才建，
# 结果缓存到 $STATE/folders.json（人手动挪动或改名后删掉缓存即可重新发现）。
FOLDER_CACHE="$STATE/folders.json"
FOLDER_ROOT_NAME="${CRASH_REPORT_FOLDER:-Dino 崩溃 & 性能日/周报}"
FOLDER_DAILY_NAME="${CRASH_REPORT_FOLDER_DAILY:-L1 日报}"
FOLDER_WEEKLY_NAME="${CRASH_REPORT_FOLDER_WEEKLY:-L2 周报}"

cache_get() { [ -s "$FOLDER_CACHE" ] && jq -r --arg k "$1" '.[$k] // empty' "$FOLDER_CACHE" 2>/dev/null || true; }
cache_put() {
  local tmp; tmp="$(mktemp)"
  { [ -s "$FOLDER_CACHE" ] && cat "$FOLDER_CACHE" || echo '{}'; } \
    | jq --arg k "$1" --arg v "$2" '. + {($k):$v}' > "$tmp" && mv "$tmp" "$FOLDER_CACHE"
}
# 注意 $2 的两种"空"：调用方明确要放根目录（顶层目录）是一种，父目录解析失败是另一种。
# 后者必须整棵放弃、退回根目录，**不能**继续在根上建子目录——否则会出现一个飘在
# 云空间最外层的孤儿「L1 日报」（2026-08-18 实测造出来过，用户一眼看出"乱建"）。
ensure_folder() { # $1=文件夹名 $2=父 token（空 = 云空间根） → stdout: token
  local name="$1" parent="${2:-}" key tok out
  # 缓存键带 profile：不同应用看到的是各自的云空间，token 不通用——
  # 换 app 后复用旧 token 会得到「无权限」而不是「找不到」，更难排查。
  key="${CACHE_NS}|${2:-root}/$1"
  tok="$(cache_get "$key")"; [ -n "$tok" ] && { printf '%s' "$tok"; return 0; }
  if [ "$DRY_RUN" = "1" ]; then
    echo "  [dry-run] 确保文件夹存在：${name}（父=${parent:-根}）" >&2
    note_new "${name}（文件夹·dry-run）" "DRYRUN_FOLDER"
    printf 'DRYRUN_FOLDER'; return 0
  fi
  # 先按名字找现成的，找不到才建——否则每天多一个同名文件夹
  if [ -n "$parent" ]; then
    out="$("${LK[@]}" drive files list --folder-token "$parent" --page-size 200 --as "$LARK_AS" --format json 2>&1)" || out=''
  else
    out="$("${LK[@]}" drive files list --page-size 200 --as "$LARK_AS" --format json 2>&1)" || out=''
  fi
  tok="$(printf '%s' "$out" | json_only | jq -r --arg n "$name" \
    'first(.. | objects | select((.name? // "") == $n and (.type? // "") == "folder") | .token) // empty' 2>/dev/null || true)"
  if [ -z "$tok" ]; then
    if [ -n "$parent" ]; then
      out="$("${LK[@]}" drive +create-folder --name "$name" --folder-token "$parent" --as "$LARK_AS" --format json 2>&1)" || true
    else
      out="$("${LK[@]}" drive +create-folder --name "$name" --as "$LARK_AS" --format json 2>&1)" || true
    fi
    tok="$(printf '%s' "$out" | json_only | jq -r 'first(.. | objects | select(has("token")) | .token) // empty' 2>/dev/null || true)"
    # +create-folder 的返回体只给 url 不给 token（实测），从 URL 末段兜底取——
    # 否则首次建目录会被误判成失败而降级到根目录。
    if [ -z "$tok" ]; then
      tok="$(printf '%s' "$out" | json_only | jq -r 'first(.. | objects | select(has("url")) | .url) // empty' 2>/dev/null | sed 's|.*/||' || true)"
    fi
    if [ -z "$tok" ]; then
      # 目录只是组织方式，不是正确性——缺 scope / 建失败时降级到根目录，别因此挡住整条投递。
      # 常见原因：应用没申请 drive:drive（导入文档不需要该 scope，建文件夹需要）。
      echo "  ⚠️ 文件夹「${name}」不可用，本轮降级到根目录。原因：" >&2
      printf '%s' "$out" | json_only | jq -r '.error.message // .error.hint // "（未返回结构化错误）"' 2>/dev/null | head -2 >&2 || true
      printf ''; return 0
    fi
    echo "  📁 新建文件夹 ${name} → $tok" >&2
    note_new "${name}（文件夹）" "$tok"
  fi
  cache_put "$key" "$tok"
  printf '%s' "$tok"
}

# ── 导入本地 markdown 为飞书云文档，回显 URL ──────────────
# +import 内置轮询；窗口内没完成会返回 ready=false + ticket，这里继续用 +task_result 轮。
# 同一位置的导入必须串行（并发会撞 232140101/232140100/233523001），本脚本天然串行。
# XML 建档：颜色/高亮框只能走 DocxXML，docs +create 一次调用即可（还能直接指定父目录）
create_xml_doc() { # $1=xml 文件 $2=父目录 token（可空） → stdout: URL
  local file="$1" folder="${2:-}" out url
  [ -s "$file" ] || return 1
  if [ "$DRY_RUN" = "1" ]; then
    echo "  [dry-run] lark-cli docs +create --content @$file${folder:+ --parent-token $folder}" >&2
    printf 'https://example.invalid/docx/DRYRUN'; return 0
  fi
  if [ -n "$folder" ]; then
    out="$(cd "$(dirname "$file")" && "${LK[@]}" docs +create --content "@$(basename "$file")" --parent-token "$folder" --as "$LARK_AS" --format json 2>&1)" || true
  else
    out="$(cd "$(dirname "$file")" && "${LK[@]}" docs +create --content "@$(basename "$file")" --as "$LARK_AS" --format json 2>&1)" || true
  fi
  url="$(printf '%s' "$out" | json_only | jq -r 'first(.. | objects | select(has("url")) | .url) // empty' 2>/dev/null || true)"
  [ -n "$url" ] || { echo "  ⚠️ XML 建档失败，回退 markdown 导入：$(printf '%s' "$out" | json_only | jq -r '.error.message // "未知"' 2>/dev/null)" >&2; return 1; }
  echo "  🎨 $(basename "$file") → ${url}（彩色 XML）" >&2
  printf '%s' "$url"
}

import_doc() { # $1=本地文件 $2=文档标题 $3=目标文件夹 token（可空=根） → stdout: URL
  local file="$1" name="$2" folder="${3:-}" out ticket url tries
  [ -s "$file" ] || fail "待导入文件为空或不存在：$file"
  if [ "$DRY_RUN" = "1" ]; then
    echo "  [dry-run] lark-cli drive +import --file $file --type docx --name '${name}'${folder:+ --folder-token $folder}" >&2
    printf 'https://example.invalid/docx/DRYRUN'
    return 0
  fi
  # 用 cwd 相对路径调用：lark-cli 的若干上传类命令拒绝绝对路径
  if [ -n "$folder" ]; then
    out="$(cd "$(dirname "$file")" && "${LK[@]}" drive +import --file "$(basename "$file")" --type docx --name "$name" --folder-token "$folder" --as "$LARK_AS" --format json 2>&1)" \
      || fail "导入失败（${name}）：$out"
  else
  out="$(cd "$(dirname "$file")" && "${LK[@]}" drive +import --file "$(basename "$file")" --type docx --name "$name" --as "$LARK_AS" --format json 2>&1)" \
    || fail "导入失败（${name}）：$out"
  fi
  url="$(printf '%s' "$out" | json_only | jq -r 'first(.. | objects | select(has("url")) | .url) // empty' 2>/dev/null || true)"
  if [ -z "$url" ]; then
    ticket="$(printf '%s' "$out" | json_only | jq -r 'first(.. | objects | select(has("ticket")) | .ticket) // empty' 2>/dev/null || true)"
    [ -n "$ticket" ] || fail "导入未返回 url 也未返回 ticket（${name}）：$out"
    for tries in 1 2 3 4 5 6; do
      sleep 5
      out="$("${LK[@]}" drive +task_result --scenario import --ticket "$ticket" --as "$LARK_AS" --format json 2>&1)" || true
      url="$(printf '%s' "$out" | json_only | jq -r 'first(.. | objects | select(has("url")) | .url) // empty' 2>/dev/null || true)"
      [ -n "$url" ] && break
    done
    [ -n "$url" ] || fail "导入任务 $ticket 轮询 30s 仍未就绪（${name}）"
  fi
  echo "  📄 $name → $url" >&2
  printf '%s' "$url"
}

# ── 文档台账：建过的文档记下来，下次复用（覆盖）而不是再建一份 ─────────
# 为什么不靠环境变量：脚本建完就知道 URL，让人去 plist 里手抄一遍纯属多余，
# 而且抄之前的每一天都会多产生一份孤儿文档。环境变量仍然优先（显式配置压过自动记忆）。
DOC_STORE="$STATE/docs.json"
doc_get() { [ -s "$DOC_STORE" ] && jq -r --arg k "${CACHE_NS}|$1" '.[$k] // empty' "$DOC_STORE" 2>/dev/null || true; }
# 写入时顺手清理过期的日期键（daily-YYYY-MM-DD / weekly-...）：
# 不清理的话每天净增一个键、从不回收——量不大但属于没人管的增长。
# index / ledger 这类固定键不带日期，不受影响。
DOC_KEEP_DAYS="${CRASH_REPORT_DOC_KEEP_DAYS:-90}"
doc_put() {
  local tmp; tmp="$(mktemp)"
  { [ -s "$DOC_STORE" ] && cat "$DOC_STORE" || echo '{}'; } \
    | jq --arg k "${CACHE_NS}|$1" --arg v "$2" '. + {($k):$v}' > "$tmp" && mv "$tmp" "$DOC_STORE"
}
# 清理必须独立于 doc_put：稳态下每天都是「覆盖」而非「新建」，doc_put 根本不会被调用，
# 挂在它里面的清理等于永不执行（2026-08-18 实测踩到）。
doc_prune() {
  [ -s "$DOC_STORE" ] || return 0
  local tmp cutoff before after; tmp="$(mktemp)"
  cutoff="$(date -v-"${DOC_KEEP_DAYS}"d +%Y-%m-%d 2>/dev/null)" || return 0
  before="$(jq 'length' "$DOC_STORE" 2>/dev/null || echo 0)"
  # 谓词已上移核心层（bin/lib/core/cache.sh 的 doc_keep_predicate，jq 表达式一字未改），
  # 那里有它的断言（bin/test/core-cache.sh），包括 index / ledger 固定键必须保留这一条。
  doc_keep_predicate "$cutoff" < "$DOC_STORE" > "$tmp" 2>/dev/null && mv "$tmp" "$DOC_STORE" || return 0
  after="$(jq 'length' "$DOC_STORE" 2>/dev/null || echo 0)"
  [ "$before" -gt "$after" ] && echo "  🧹 文档台账清理：丢弃 $((before - after)) 条超过 ${DOC_KEEP_DAYS} 天的记录"
  return 0
}

# 父目录 URL：域名从刚建好的文档 URL 里取，不写死租户域名（换租户不用改代码）。
folder_url() { # $1=文件夹 token $2=同租户的任一文档 URL
  { [ -n "${1:-}" ] && [ -n "${2:-}" ]; } || { printf ''; return 0; }
  printf '%s/drive/folder/%s' "$(printf '%s' "$2" | sed -E 's|^(https?://[^/]+).*|\1|')" "$1"
}

# 固定文档原地覆盖：URL 不变，不再每天产生一份新文档 + 一堆孤儿。
# doc_id 传文档 URL（浏览器里复制的那串）最省事；传裸 token 时用 DOC_URL_BASE 拼回 URL。
DOC_URL_BASE="${CRASH_REPORT_DOC_URL_BASE:-}"
overwrite_doc() { # $1=本地文件 $2=doc_id（URL 或 token） $3=标题（仅日志） $4=格式(markdown|xml) → stdout: URL
  local file="$1" doc="$2" name="$3" fmt="${4:-markdown}" url
  [ -s "$file" ] || fail "待覆盖的本地文件为空：$file"
  case "$doc" in
    *://*) url="$doc";;
    *)     [ -n "$DOC_URL_BASE" ] || fail "doc_id 是裸 token（${doc}），请设 CRASH_REPORT_DOC_URL_BASE 或改传完整 URL"
           url="${DOC_URL_BASE%/}/$doc";;
  esac
  if [ "$DRY_RUN" = "1" ]; then
    echo "  [dry-run] lark-cli docs +update --command overwrite --doc $doc --doc-format $fmt --content @$file" >&2
    printf '%s' "$url"; return 0
  fi
  if ! (cd "$(dirname "$file")" && "${LK[@]}" docs +update --command overwrite --doc "$doc" --doc-format "$fmt" \
        --content "@$(basename "$file")" --as "$LARK_AS" --format json >/dev/null); then
    echo "  ⚠️ 覆盖失败（${name}），改为新建一份" >&2; return 1
  fi
  echo "  ♻️ $name → ${url}（原地覆盖）" >&2
  printf '%s' "$url"
}
# 有固定 doc_id 就覆盖，没有就新建；新建时把 URL 打出来，方便一次性钉成固定文档
publish_doc() { # $1=本地文件 $2=标题 $3=doc_id(可空) $4=文件夹 token(可空) $5=台账键 $6=格式 → stdout: URL
  local fixed="${3:-}" key="${5:-}" fmt="${6:-markdown}" u=""
  # 显式配置 > 自动记忆 > 新建
  [ -z "$fixed" ] && [ -n "$key" ] && fixed="$(doc_get "$key")"
  if [ -n "$fixed" ]; then
    u="$(overwrite_doc "$1" "$fixed" "$2" "$fmt" || true)"
    [ -n "$u" ] && { printf '%s' "$u"; return 0; }
    echo "  ↳ 覆盖不成（文档可能已被删），重建一份" >&2
  fi
  if [ "$fmt" = xml ]; then u="$(create_xml_doc "$1" "${4:-}" || true)"; fi
  [ -n "$u" ] || u="$(import_doc "$1" "$2" "${4:-}")"
  [ -n "$key" ] && doc_put "$key" "$u"
  note_new "$2" "$u"
  printf '%s' "$u"
}

# 发交互卡片。--idempotency-key 用 run_id：同一次运行重跑不会发出第二张卡片。
send_card() { # $1=card.json
  local card="$1"
  [ -s "$card" ] || fail "卡片文件为空：$card"
  jq empty "$card" || fail "卡片 JSON 不合法：$card"
  if [ "$DRY_RUN" = "1" ]; then
    echo "  [dry-run] "${LK[@]}" im +messages-send → ${CHAT_ID}（interactive, as=$LARK_AS, idempotency-key=${RUN_ID}）"
    return 0
  fi
  # ou_ 是人（私聊，首次部署验证用），oc_ 是群——两者走不同的 flag
  local recip
  case "$CHAT_ID" in ou_*) recip=(--user-id "$CHAT_ID");; *) recip=(--chat-id "$CHAT_ID");; esac
  "${LK[@]}" im +messages-send \
    "${recip[@]}" \
    --msg-type interactive \
    --content "$(cat "$card")" \
    --idempotency-key "${RUN_ID:0:50}" \
    --as "$LARK_AS" \
    --format json >/dev/null || fail "卡片发送失败"
  echo "  ✅ 卡片已发送（idempotency-key=${RUN_ID}）"
}

fill() { # $1=文件 $2=占位符 $3=值（值可能含 & 与 |，走 python 替换避免 sed 转义地狱）
  [ -s "$1" ] || return 0
  [ "$DRY_RUN" = "1" ] && { echo "  [dry-run] 回填 $2 → $3（$1）"; return 0; }
  python3 - "$1" "$2" "$3" <<'PY'
import sys,pathlib
p=pathlib.Path(sys.argv[1]); p.write_text(p.read_text().replace(sys.argv[2], sys.argv[3]))
PY
}

# 报告归档：日报与周报写同一份 JSONL（{type,day,url,...}），索引页据此渲染归档表。
# 追加时机固定在卡片发送成功之后——归档的语义是「已投递」，不是「已生成」。
archive_append() { # $1=文档 URL
  [ "$IS_PROD" = "1" ] || { echo "  ⏭️ 自测模式，跳过归档"; return 0; }
  local idx day
  idx="$(m archive_append.jsonl_file)"; day="$(m archive_append.day)"
  { [ -n "$idx" ] && [ -n "${1:-}" ]; } || return 0
  if [ "$DRY_RUN" = "1" ]; then echo "  [dry-run] 追加归档（$(m archive_append.type)）→ $idx"; return 0; fi
  mkdir -p "$(dirname "$idx")"
  # 按 (type,day) upsert：同一天重跑覆盖那一行，不再堆重复归档
  if [ -s "$idx" ]; then
    local tmp; tmp="$(mktemp)"
    jq -c --arg t "$(m archive_append.type)" --arg d "$day" \
      'select(.type != $t or .day != $d)' "$idx" > "$tmp" && mv "$tmp" "$idx"
  fi
  # at 记录该行是哪一次跑批的产物：按 (type,day) upsert 只留最后一次，
  # 但索引页表格里若不标时刻，同日重跑后读者无从判断看到的是几点那版（2026-08-20 Sir 反馈）。
  jq -cn --arg t "$(m archive_append.type)" --arg day "$day" --arg url "$1" \
         --arg at "$(printf '%s' "$RUN_ID" | sed -n 's/^[0-9]\{8\}-\([0-9]\{2\}\)\([0-9]\{2\}\).*/\1:\2/p')" \
         --arg vers "$(m archive_append.versions)" \
         --arg ios "$(m archive_append.ios)" --arg and "$(m archive_append.android)" \
    '{type:$t, day:$day, url:$url}
     + (if $at   != "" then {at:$at} else {} end)
     + (if $vers != "" then {versions:$vers} else {} end)
     + (if $ios  != "" then {ios:($ios|tonumber? // $ios)} else {} end)
     + (if $and  != "" then {android:($and|tonumber? // $and)} else {} end)' >> "$idx"
  echo "  🗂 已归档（$(m archive_append.type) ${day}）→ $idx"
  return 0
}

# 只重发卡片、不碰文档：排版调整后想让群里看到新卡片，但文档内容没变、不该再导一遍。
# 占位符从文档台账里取已有 URL，因此不依赖本轮是否建过文档。
CARD_ONLY="${CRASH_REPORT_CARD_ONLY:-0}"
if [ "$CARD_ONLY" = "1" ]; then
  CARD="$(m card_file)"
  FURL="$(doc_get folder-root-url)"
  case "$TYPE" in
    daily)
      fill "$CARD" "__DETAIL_URL__" "$(doc_get "daily-$DAY")"
      fill "$CARD" "__INDEX_URL__"  "$(doc_get index)"
      ;;
    weekly)
      fill "$CARD" "__REPORT_URL__" "$(doc_get "weekly-$DAY")"
      ;;
  esac
  [ -n "$FURL" ] && fill "$CARD" "__FOLDER_URL__" "$FURL"
  # 幂等键必须换新：它的作用是防「同一次运行重复发」，而这里是**刻意**重发，
  # 沿用旧 run_id 会被飞书当成重复请求直接丢掉，卡片根本到不了群里。
  RUN_ID="${RUN_ID}-resend-$(date +%H%M%S)"
  echo "  ↻ 仅重发卡片（文档未改动）"
  send_card "$CARD"
  echo "=== 投递完成 ==="
  RUN_COMPLETED=1; exit 0   # 合法提前退出，必须置哨兵
fi

# ── 台账同步（design D2/D3/D6.6/D6.7，change crash-ledger-l2-ownership，L2 独占）──────
# 现状表：block ID 定点 block_replace（1.1-1.6 spike 已验证有效，见 design.md D3）。
# 时间线：append（只增不改，历史条目永不因本函数被覆盖）。
# **硬约束：定位失效必须报错中止，绝不退化为 overwrite**（会连同时间线历史一起重写）。
# 失败通过返回非零码传给调用方；调用方（case weekly 分支）只打警告不 fail，
# 保证台账同步失败不改变 deliver.sh / crash-weekly.sh 的退出码（6.7）。
#
# **首次同步（bootstrap，6.5）**：目标文档现存的是旧版一次性台账内容（无本次新四段结构的
# 「Issue 现状表」标题），block ID 定位必然失败。这不是错误，是「尚未建立新结构」——
# 此时改用 append 把 local_full_file（本地台账全文，四段结构齐全）追加到文档末尾，
# 旧内容原样保留在其上方，由人工核实后另行清理（design D2：不使用 overwrite，任何阶段都不用）。
# 之后每一轮跑批，标题已存在，走正常的 block_replace + append 定点更新路径。
LEDGER_HEADING_TEXT="${CRASH_REPORT_LEDGER_HEADING:-Issue 现状表}"
LEDGER_NF_HEADING_TEXT="${CRASH_REPORT_LEDGER_NF_HEADING:-NON_FATAL 现状表}"

# 按标题文本定位标题块 id。⛔ 只认标题标签（h1-h6），不接受「第一个带 id 的对象」——
# keyword 检索会命中正文里**提到**同名文字的引用块（2026-08-20 实测因此误判「标题不存在」，
# 退回 bootstrap 把四段结构重复 append 了两遍）。同名标题多个时取**最后一个**：
# 旧结构（历史遗留）在上、本流水线建的新结构在下。
_ledger_heading_id() { # $1=doc $2=标题文本 → stdout: block id（找不到则空）
  local doc="$1" text="$2" outline hid
  outline="$("${LK[@]}" docs +fetch --doc "$doc" --scope outline --max-depth 6 \
              --as "$LARK_AS" --format json 2>&1)" || outline=""
  hid="$(printf '%s' "$outline" | json_only | jq -r '.data.document.content // ""' 2>/dev/null \
    | grep -oE "<h[1-6] id=\"[^\"]*\">${text}<" \
    | sed -E 's/^<h[1-6] id="([^"]*)">.*/\1/' | tail -1 || true)"
  if [ -z "$hid" ]; then
    outline="$("${LK[@]}" docs +fetch --doc "$doc" --scope keyword --keyword "$text" \
                --detail with-ids --as "$LARK_AS" --format json 2>&1)" || outline=""
    hid="$(printf '%s' "$outline" | json_only | jq -r '.data.document.content // ""' 2>/dev/null \
      | grep -oE "<h[1-6] id=\"[^\"]*\">${text}<" \
      | sed -E 's/^<h[1-6] id="([^"]*)">.*/\1/' | tail -1 || true)"
  fi
  printf '%s' "$hid"
}

# 在标题块之下定位表格并 block_replace。
# ⚠️ 不缓存表格 id：block_replace 每次都会让表格拿到新 id，跨轮必须重查（design D3 第 6 点）。
# ⚠️ section 返回的是 DocxXML 文本不是块结构 JSON——在 JSON 里找 type=="table" 永远落空。
_ledger_replace_table() { # $1=doc $2=heading_id $3=内容文件 $4=格式 $5=日志标签 → 0成功/1失败
  local doc="$1" hid="$2" f="$3" fmt="${4:-markdown}" label="$5" section tid
  section="$("${LK[@]}" docs +fetch --doc "$doc" --scope section --start-block-id "$hid" \
              --detail with-ids --as "$LARK_AS" --format json 2>&1)" || section=""
  tid="$(printf '%s' "$section" | json_only | jq -r '.data.document.content // ""' 2>/dev/null \
    | grep -oE '<table id="[^"]*"' | head -1 | sed -E 's/^<table id="([^"]*)"/\1/' || true)"
  if [ -z "$tid" ]; then
    echo "  ❌ 台账同步失败：「${label}」下定位不到表格 block，中止（不退化为 overwrite）" >&2
    return 1
  fi
  if ! (cd "$(dirname "$f")" && "${LK[@]}" docs +update --command block_replace \
        --doc "$doc" --block-id "$tid" --doc-format "$fmt" \
        --content "@$(basename "$f")" --as "$LARK_AS" --format json >/dev/null); then
    echo "  ❌ 台账同步失败：block_replace「${label}」出错（block-id=${tid}），中止（不退化为 overwrite）" >&2
    return 1
  fi
  echo "  ✅ 台账「${label}」已同步（block_replace，block-id=${tid}）" >&2
  return 0
}
sync_ledger() { # $1=doc_id  $2=FATAL现状表文件  $3=表格式(xml|markdown)
                # $4=timeline增量文件(可空)  $5=timeline格式  $6=本地台账全文(可空，仅 bootstrap)
                # $7=NON_FATAL现状表文件(可空)
  local doc="$1" table_file="$2" table_fmt="${3:-markdown}" tl_file="${4:-}" tl_fmt="${5:-markdown}" full_file="${6:-}" nf_file="${7:-}"
  [ -n "$doc" ] || { echo "  ⚠️ 台账同步跳过：未配置台账文档 ID" >&2; return 1; }
  [ -s "$table_file" ] || { echo "  ⚠️ 台账同步跳过：现状表内容为空（${table_file}）" >&2; return 1; }

  if [ "$DRY_RUN" = "1" ]; then
    echo "  [dry-run] 台账同步：定位「${LEDGER_HEADING_TEXT}」→ block_replace 现状表（找不到则 bootstrap append 全文）" >&2
    [ -s "$nf_file" ] && echo "  [dry-run] 台账同步：定位「${LEDGER_NF_HEADING_TEXT}」→ block_replace NON_FATAL 现状表" >&2
    [ -s "$tl_file" ] && echo "  [dry-run] 台账同步：append 时间线增量（$(wc -l < "$tl_file" | tr -d ' ') 行）" >&2
    return 0
  fi

  local heading_id nf_heading_id
  heading_id="$(_ledger_heading_id "$doc" "$LEDGER_HEADING_TEXT")"

  if [ -z "$heading_id" ]; then
    # ── Bootstrap：新结构标题不存在 → append 本地台账全文，旧内容保留在上方 ──
    if [ -n "$full_file" ] && [ -s "$full_file" ]; then
      echo "  ℹ️ 台账首次同步：目标文档暂无「${LEDGER_HEADING_TEXT}」标题，改用 append 建立新结构（旧内容保留，不 overwrite）" >&2
      if ! (cd "$(dirname "$full_file")" && "${LK[@]}" docs +update --command append \
            --doc "$doc" --doc-format markdown --content "@$(basename "$full_file")" \
            --as "$LARK_AS" --format json >/dev/null); then
        echo "  ❌ 台账首次同步失败：append 全文出错，中止（不退化为 overwrite）" >&2
        return 1
      fi
      echo "  ✅ 台账新结构已 append 建立；下一轮起可 block_replace 定点更新两张现状表" >&2
      return 0
    fi
    echo "  ❌ 台账同步失败：定位不到「${LEDGER_HEADING_TEXT}」标题块，且无本地全文可 bootstrap，中止（不退化为 overwrite）" >&2
    return 1
  fi

  _ledger_replace_table "$doc" "$heading_id" "$table_file" "$table_fmt" "$LEDGER_HEADING_TEXT" || return 1

  # NON_FATAL 现状表：与 FATAL **分两张表**，不加「类型」列混排——单表混排时两类交错，
  # 读者无法一眼看出「有几个致命问题」，而那是台账最主要的用途。
  # ⚠️ 标题不存在时**只警告不中止**：FATAL 表已同步成功，因一张新表让整个同步失败会连带丢掉已成功的那半。
  if [ -n "$nf_file" ] && [ -s "$nf_file" ]; then
    nf_heading_id="$(_ledger_heading_id "$doc" "$LEDGER_NF_HEADING_TEXT")"
    if [ -z "$nf_heading_id" ]; then
      echo "  ⚠️ 台账「${LEDGER_NF_HEADING_TEXT}」标题尚不存在，本轮跳过（FATAL 现状表已同步）。首次需在台账文档中加入该标题与一张占位表格。" >&2
    else
      _ledger_replace_table "$doc" "$nf_heading_id" "$nf_file" markdown "$LEDGER_NF_HEADING_TEXT" \
        || echo "  ⚠️ NON_FATAL 现状表同步失败（FATAL 现状表已同步成功，不影响主链路）" >&2
    fi
  fi

  # ── append 时间线增量（只增不改；无增量则跳过，不产生空 append）────────
  if [ -s "$tl_file" ]; then
    if (cd "$(dirname "$tl_file")" && "${LK[@]}" docs +update --command append \
          --doc "$doc" --doc-format "$tl_fmt" --content "@$(basename "$tl_file")" \
          --as "$LARK_AS" --format json >/dev/null); then
      echo "  ✅ 台账变更时间线已追加（$(wc -l < "$tl_file" | tr -d ' ') 行）" >&2
    else
      echo "  ⚠️ 台账时间线追加失败（现状表已同步成功，不影响主链路）" >&2
    fi
  fi
  return 0
}

case "$TYPE" in
  daily)
    CARD="$(m card_file)"
    DAILY_FILE="$(m create_doc.file)";  DAILY_TITLE="$(m create_doc.title)"
    INDEX_FILE="$(m index_doc.file)";   INDEX_TITLE="$(m index_doc.title)"

    F_ROOT="$(ensure_folder "$FOLDER_ROOT_NAME" "")"
    # 父目录拿不到就整棵放弃：文档落根目录，而不是在根上另造一个「L1 日报」
    F_DAILY=""
    [ -n "$F_ROOT" ] && F_DAILY="$(ensure_folder "$FOLDER_DAILY_NAME" "$F_ROOT")"
    # 日报每天新建（当天数据快照，事后要能回看）→ 全部收进 L1 目录；
    # 索引页是「当前状态」的投影，固定一份原地覆盖 → 放父目录根部。
    # 台账已移交 L2 独占产出（change crash-ledger-l2-ownership D1），L1 不再导入台账镜像文档。
    # 优先彩色 XML；失败回退 markdown 导入（保证链路不因排版功能挂掉）
    # 日报每天一份（跨天留痕），但**同一天重跑覆盖当天那份**——否则每次重试都多一份同名文档
    DAILY_XML="$(m create_doc.xml_file)"
    if [ -s "$DAILY_XML" ]; then
      URL_DAILY="$(publish_doc "$DAILY_XML" "$DAILY_TITLE" "" "$F_DAILY" "daily-$DAY" xml)"
    else
      URL_DAILY="$(publish_doc "$DAILY_FILE" "$DAILY_TITLE" "" "$F_DAILY" "daily-$DAY")"
    fi

    # 索引页里的入口 URL 必须在导入前回填——文档一旦建好就只能新建不能覆盖
    URL_INDEX=""
    if [ -n "$INDEX_FILE" ] && [ "$IS_PROD" != "1" ]; then
      echo "  ⏭️ 自测模式，跳过索引页覆盖（它是群里那份固定文档）"
    elif [ -n "$INDEX_FILE" ]; then
      fill "$INDEX_FILE" "__DAILY_URL__"  "$URL_DAILY"
      INDEX_XML="$(m index_doc.xml_file)"
      if [ -s "$INDEX_XML" ]; then
        URL_INDEX="$(publish_doc "$INDEX_XML" "$INDEX_TITLE" "$(m index_doc.doc_id)" "$F_ROOT" index xml)"
      else
        URL_INDEX="$(publish_doc "$INDEX_FILE" "$INDEX_TITLE" "$(m index_doc.doc_id)" "$F_ROOT" index)"
      fi
    fi

    FURL="$(folder_url "$F_ROOT" "$URL_DAILY")"
    [ -n "$FURL" ] && doc_put "folder-root-url" "$FURL"
    fill "$CARD" "__FOLDER_URL__" "${FURL:-$URL_DAILY}"
    fill "$CARD" "__DETAIL_URL__" "$URL_DAILY"
    fill "$CARD" "__INDEX_URL__"  "${URL_INDEX:-$URL_DAILY}"
    send_card "$CARD"
    # 归档必须在卡片发出后追加：先追加再发的话，发送失败会留下指向「已投递报告」的假记录
    archive_append "$URL_DAILY"
    ;;

  weekly)
    CARD="$(m card_file)"
    REPORT_FILE="$(m create_doc.file)"; REPORT_TITLE="$(m create_doc.title)"
    # send=false 只由 DRY RUN 产生（见 crash-weekly.sh §7）：正式跑批恒为 true，
    # 与本周有无变化无关。这里保留判断是为了手工构造 manifest 的排障场景——
    # 此时跳过卡片与文档，但**台账照常同步**：「不打扰群里」和「不记录数据」是两回事，
    # 台账的事件量趋势与处置状态即便在平稳周也会变。
    WEEKLY_QUIET=0
    if [ "$(m send)" != "true" ]; then
      echo "  send=false：跳过卡片与文档，仅同步台账"
      WEEKLY_QUIET=1
    fi
    F_ROOT="$(ensure_folder "$FOLDER_ROOT_NAME" "")"
    F_WEEKLY=""
    [ -n "$F_ROOT" ] && F_WEEKLY="$(ensure_folder "$FOLDER_WEEKLY_NAME" "$F_ROOT")"
    URL_REPORT=""
    if [ "$WEEKLY_QUIET" = "0" ]; then
      REPORT_XML="$(m create_doc.xml_file)"
      if [ -s "$REPORT_XML" ]; then
        URL_REPORT="$(publish_doc "$REPORT_XML" "$REPORT_TITLE" "" "$F_WEEKLY" "weekly-$DAY" xml)"
      elif [ -n "$REPORT_FILE" ]; then
        URL_REPORT="$(publish_doc "$REPORT_FILE" "$REPORT_TITLE" "" "$F_WEEKLY" "weekly-$DAY")"
      fi
      FURL="$(folder_url "$F_ROOT" "$URL_REPORT")"
      [ -n "$FURL" ] && doc_put "folder-root-url" "$FURL"
      fill "$CARD" "__FOLDER_URL__" "${FURL:-$URL_REPORT}"
      [ -n "$URL_REPORT" ] && fill "$CARD" "__REPORT_URL__" "$URL_REPORT"
      send_card "$CARD"

      archive_append "$URL_REPORT"
    fi

    # ── 台账同步（6.4-6.8）：只在卡片发送成功之后做，与归档同一时序理由——
    # 台账时间线的 __REPORT_URL__ 引用必须指向已投递成功的报告，失败半成品不能挂进台账（6.8）。
    # 失败只打印警告，不 fail：台账同步失败不改变本脚本的退出码（6.7），失败原因已落 stderr/日志，
    # 可用 CRASH_REPORT_LEDGER_DOC_ID 单独重跑（重跑机制：下次 crash-weekly.sh 会重新渲染并重试同步）。
    LEDGER_TABLE_FILE="$(m ledger_sync.table_file)"
    LEDGER_TIMELINE_FILE="$(m ledger_sync.timeline_file)"
    LEDGER_LOCAL_FILE="$(m ledger_sync.local_file)"
    LEDGER_NF_FILE="$(m ledger_sync.nonfatal_file)"
    # 自测闸门：非群投递默认跳过台账同步——两台机器的 docs.json 指向**同一份**台账文档，
    # 从开发机同步会把测试结论写进群里那份。
    #
    # **但这个理由只在「目标就是那份文档」时成立。** 显式指定另一份文档时风险不存在，
    # 而台账同步是整条链路里唯一无法在开发机验证的一段（block_replace 定位、
    # 时间线不被覆盖、两张现状表各自替换——这些只有真同步才验得到）。
    # 故开一个**比闸门更窄**的口子：非群投递时，仅当 CRASH_REPORT_LEDGER_DOC_ID
    # 被显式设置**且与 docs.json 里那份不同**才放行。指成生产台账照样拒绝。
    LEDGER_DOC_ID="${CRASH_REPORT_LEDGER_DOC_ID:-$(doc_get ledger)}"
    LEDGER_ALLOW=0
    if [ "$IS_PROD" = "1" ]; then
      LEDGER_ALLOW=1
    elif [ -n "${CRASH_REPORT_LEDGER_DOC_ID:-}" ]; then
      if [ "$CRASH_REPORT_LEDGER_DOC_ID" != "$(doc_get ledger)" ]; then
        LEDGER_ALLOW=1
        echo "  🧪 自测台账同步：目标是显式指定的另一份文档（非 docs.json 里那份），放行"
      else
        echo "  ⛔ 拒绝：CRASH_REPORT_LEDGER_DOC_ID 指向的正是 docs.json 里那份生产台账，自测模式下不放行"
      fi
    fi
    if [ -n "$LEDGER_TABLE_FILE" ] && [ "$LEDGER_ALLOW" != "1" ]; then
      echo "  ⏭️ 自测模式，跳过台账同步（它是群里那份固定文档，测试结论不得写入）"
      echo "     要验证同步逻辑：CRASH_REPORT_LEDGER_DOC_ID=<另建一份测试文档> 重跑 deliver.sh"
    elif [ -n "$LEDGER_TABLE_FILE" ]; then
      if [ -z "$LEDGER_DOC_ID" ]; then
        echo "  ⚠️ 台账同步跳过：未配置台账文档（CRASH_REPORT_LEDGER_DOC_ID 或 docs.json 的 ledger 键）"
      else
        # __REPORT_URL__ 占位符回填：先本地文件（含本地台账源），再飞书上传内容
        if [ -n "$URL_REPORT" ]; then
          fill "$LEDGER_TABLE_FILE" "__REPORT_URL__" "$URL_REPORT"
          [ -s "$LEDGER_TIMELINE_FILE" ] && fill "$LEDGER_TIMELINE_FILE" "__REPORT_URL__" "$URL_REPORT"
          [ -s "$LEDGER_LOCAL_FILE" ] && fill "$LEDGER_LOCAL_FILE" "__REPORT_URL__" "$URL_REPORT"
        fi
        if [ -s "$LEDGER_TIMELINE_FILE" ]; then
          sync_ledger "$LEDGER_DOC_ID" "$LEDGER_TABLE_FILE" markdown "$LEDGER_TIMELINE_FILE" markdown "$LEDGER_LOCAL_FILE" "$LEDGER_NF_FILE" \
            || echo "  ⚠️ 台账同步未完成（详见上方日志），数据已落本地 ${LEDGER_LOCAL_FILE}，下次跑批会重试"
        else
          sync_ledger "$LEDGER_DOC_ID" "$LEDGER_TABLE_FILE" markdown "" markdown "$LEDGER_LOCAL_FILE" "$LEDGER_NF_FILE" \
            || echo "  ⚠️ 台账同步未完成（详见上方日志），数据已落本地 ${LEDGER_LOCAL_FILE}，下次跑批会重试"
        fi
      fi
    fi
    ;;

  *) fail "未知的清单类型：$TYPE";;
esac
if [ -s "$NEW_RESOURCES" ]; then
  echo
  echo "⚠️ 本轮新建了固定资源，请回填到仓库 CLAUDE.md 的「部署实例：飞书侧固定资源」表："
  cat "$NEW_RESOURCES"
  echo "（索引页还要设成 DOC_INDEX_ID 才会走原地覆盖；台账走 docs.json 的 ledger 键自动记忆，无需环境变量）"
fi
doc_prune
echo "=== 投递完成 ==="
RUN_COMPLETED=1
