#!/usr/bin/env bash
# lark-cli 限流重试（F68）与固定文档覆盖失败不换键（F69），2026-11-02 生产事故。
#
# 事故：日报卡片撞 429（`retryable: true`）直接判失败，紧接着的告警卡也没发出去；
# 补投时索引页覆盖失败，publish_doc 新建一份并把 docs.json 的 index 键切了过去，
# 群里钉着的索引页从此不再更新——人手改回 docs.json、删孤儿才收拾干净。
set -uo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SELF_DIR/../.." && pwd)"
# shellcheck disable=SC1091
. "$SELF_DIR/harness.sh"
# 整文件 source：h_load 只抽函数，抽不到顶层的 LK_RETRY_DELAYS（下面覆盖成 0 秒）
# shellcheck disable=SC1091
. "$ROOT/bin/lib/lark.sh"
# json_only 在 deliver.sh 里是单行函数，h_extract 抽不了——照抄（429 重试留痕会混在 JSON 前面，直通版测不出解析）
json_only() { sed -n '/^[[:space:]]*{/,$p'; }
h_load "$ROOT/bin/deliver.sh" _lark_write_ok overwrite_doc is_fixed_resource_key publish_doc || { h_summary; exit 1; }

# ⚠️ 桩都跑在 $( ) 子 shell 里，计数与入参只能落文件
TMPD="$(mktemp -d)"
FAKE="$TMPD/fake-lark"
# 假 lark-cli：依次吐出 $TMPD/resp.N（N 从 1 起），每份第一行是退出码、其余是 stderr 内容；
# 没有对应文件时成功并在 stdout 输出 {"ok":true}。
cat > "$FAKE" <<'SH'
#!/usr/bin/env bash
d="$(dirname "$0")"; n=$(( $(cat "$d/calls" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$d/calls"
if [ -f "$d/resp.$n" ]; then rc="$(head -1 "$d/resp.$n")"; tail -n +2 "$d/resp.$n" >&2; exit "$rc"; fi
echo '{"ok":true,"data":{"result":"success"}}'
SH
chmod +x "$FAKE"
LK=("$FAKE")
LK_RETRY_DELAYS="0 0"
# lk 返回非零是它的语义，裸 h_run 会把 `return` 本身记成 ERR——包一层条件位，
# 仍能抓到 lk **内部**（含 $( ) 子 shell）的 ERR，退出码落文件
lk_rc() { local r=0; lk "$@" || r=$?; printf '%s' "$r" > "$TMPD/rc"; }
# ⚠️ publish_doc 的失败路径用 deliver.sh 的**真实**设置跑（set -euo pipefail，无 errtrace / ERR trap）：
#    overwrite_doc 里 `if ! _owout="$(… lk …)"` 是 deliver.sh 18 处调用点的既有写法，
#    errtrace 下子 shell 里的失败会记 ERR，但 deliver.sh 没装 ERR trap，生产不受影响
p_run() { ( set -euo pipefail; "$@" ); }
reset_fake() { rm -f "$TMPD"/resp.* "$TMPD/calls"; }
calls() { cat "$TMPD/calls" 2>/dev/null || echo 0; }
# lark-cli 的真实形态：pretty JSON 走 stderr（2026-11-02 生产日志原文）
R429='{
  "ok": false,
  "identity": "bot",
  "error": {
    "type": "api",
    "subtype": "rate_limit",
    "code": 429,
    "message": "TAT endpoint rate limited (HTTP 429)",
    "retryable": true
  }
}'
RGONE='{"ok":false,"identity":"bot","error":{"type":"api","subtype":"unknown","code":3380003,"message":"Document page has been deleted."}}'
RMISS='{"ok":false,"identity":"bot","error":{"type":"api","subtype":"unknown","code":3380002,"message":"Invalid document_id or document not found."}}'
RPERM='{"ok":false,"identity":"bot","error":{"type":"api","subtype":"permission","code":1770032,"message":"forbidden"}}'

echo "── lk：只在 429 时重试 ──"
reset_fake; printf '1\n%s\n' "$R429" > "$TMPD/resp.1"; printf '1\n%s\n' "$R429" > "$TMPD/resp.2"
out="$(h_run lk_rc im +messages-send 2>/dev/null)"; rc="$(cat "$TMPD/rc")"
h_assert_eq "0" "$rc" "429 两次后第三次成功 → rc=0"
h_assert_eq "3" "$(calls)" "共调用 3 次（两次重试）"
h_assert_contains "$out" '"ok":true' "成功那次的 stdout 原样透出"

reset_fake; for i in 1 2 3; do printf '1\n%s\n' "$R429" > "$TMPD/resp.$i"; done
err="$( { h_run lk_rc im +messages-send >/dev/null; } 2>&1)"; rc="$(cat "$TMPD/rc")"
h_assert_eq "1" "$rc" "429 持续 → 重试用完后返回 lark-cli 的退出码"
h_assert_eq "3" "$(calls)" "⛔ 重试有上限：1 次 + 2 次重试"
h_assert_contains "$err" "TAT endpoint rate limited" "最后一次的错误 JSON 回写到 stderr（调用方日志里看得见原因）"
h_assert_contains "$err" "飞书限流（429）" "重试过程留痕"

reset_fake; printf '1\n%s\n' "${R429//\"code\": 429/\"code\":429}" > "$TMPD/resp.1"
h_run lk_rc im +messages-send >/dev/null 2>&1
h_assert_eq "2" "$(calls)" "紧凑 JSON（\"code\":429）同样识别"

reset_fake; printf '1\n%s\n' "$RMISS" > "$TMPD/resp.1"
h_run lk_rc docs +update >/dev/null 2>&1; rc="$(cat "$TMPD/rc")"
h_assert_eq "1" "$rc" "非 429 失败原样返回"
h_assert_eq "1" "$(calls)" "⛔ 非 429 不重试（5xx 等可能已生效，重试会写出重复）"

reset_fake; printf '1\n%s\n' '{"ok":false,"error":{"code":4290,"message":"x"}}' > "$TMPD/resp.1"
h_run lk_rc docs +update >/dev/null 2>&1
h_assert_eq "1" "$(calls)" "⛔ 4290 之类以 429 开头的业务码不算限流"

reset_fake
h_assert_silent lk im +messages-send
h_assert_eq "1" "$(calls)" "一次成功只调一次"

echo "── publish_doc：固定文档覆盖失败不换键 ──"
SPY="$TMPD/spy"
DRY_RUN=0; LARK_AS=bot; DOC_URL_BASE=""
IDX="https://example.invalid/docx/INDEX_PINNED"
fail() { echo "FAIL: $*" >&2; exit 1; }
doc_get() { [ "$1" = index ] && printf '%s' "$IDX" || printf ''; }
doc_put() { printf 'put %s %s\n' "$1" "$2" >> "$SPY"; }
create_xml_doc() { printf 'create\n' >> "$SPY"; printf 'https://example.invalid/docx/NEW'; }
import_doc() { printf 'import\n' >> "$SPY"; printf 'https://example.invalid/docx/NEW'; }
note_new() { :; }
SRC="$TMPD/index.xml"; printf '<p>x</p>' > "$SRC"

for case in "429 用完:$R429" "无权限:$RPERM"; do
  reset_fake; : > "$SPY"
  for i in 1 2 3; do printf '1\n%s\n' "${case#*:}" > "$TMPD/resp.$i"; done
  u="$(p_run publish_doc "$SRC" "索引" "" "ROOT" index xml "$SRC" 2>/dev/null)"
  h_assert_eq "$IDX" "$u" "固定文档 ${case%%:*} → 仍返回群里钉着的那份"
  h_assert_eq "" "$(cat "$SPY")" "⛔ 固定文档 ${case%%:*} → 不新建、不改 docs.json"
done

reset_fake; : > "$SPY"
# F41：rc=0 但 result=failed
LK=(bash -c 'echo "{\"ok\":true,\"data\":{\"result\":\"failed\"}}"' _)
u="$(p_run publish_doc "$SRC" "索引" "" "ROOT" index xml "$SRC" 2>/dev/null)"
h_assert_eq "$IDX" "$u" "固定文档 F41（ok:true 但没写进去）→ 保留原文档"
h_assert_eq "" "$(cat "$SPY")" "⛔ F41 同样不换键"
LK=("$FAKE")

for case in "已删除:$RGONE" "不存在:$RMISS"; do
  reset_fake; : > "$SPY"
  printf '1\n%s\n' "${case#*:}" > "$TMPD/resp.1"
  u="$(p_run publish_doc "$SRC" "索引" "" "ROOT" index xml "$SRC" 2>/dev/null)"
  h_assert_eq "https://example.invalid/docx/NEW" "$u" "固定文档${case%%:*} → 重建"
  h_assert_contains "$(cat "$SPY")" "put index https://example.invalid/docx/NEW" "固定文档${case%%:*} → docs.json 换到新文档"
done

reset_fake; : > "$SPY"
doc_get() { [ "$1" = daily-2026-11-02 ] && printf 'https://example.invalid/docx/TODAY' || printf ''; }
printf '1\n%s\n' "$RPERM" > "$TMPD/resp.1"
u="$(p_run publish_doc "$SRC" "日报" "" "DAILY" daily-2026-11-02 xml "$SRC" 2>/dev/null)"
h_assert_eq "https://example.invalid/docx/NEW" "$u" "按日期的文档覆盖失败 → 照旧重建（只影响当天那份）"
h_assert_contains "$(cat "$SPY")" "put daily-2026-11-02" "按日期的文档 → 键换到新建那份"

reset_fake; : > "$SPY"
doc_get() { [ "$1" = index ] && printf '%s' "$IDX" || printf ''; }
u="$(h_run publish_doc "$SRC" "索引" "" "ROOT" index xml "$SRC" 2>/dev/null)"
h_assert_eq "$IDX" "$u" "覆盖成功 → 返回原 URL"
h_assert_eq "" "$(cat "$SPY")" "覆盖成功 → 不新建、不改键"

reset_fake; printf '1\n%s\n' "$RPERM" > "$TMPD/resp.1"
err="$( { p_run publish_doc "$SRC" "索引" "" "ROOT" index xml "$SRC" >/dev/null; } 2>&1)"
h_assert_contains "$err" "forbidden" "失败日志带 lark-cli 原文（11-02 那次只剩一句「覆盖失败」）"

rm -rf "$TMPD"
h_summary
