#!/usr/bin/env bash
# 产物自检：对 $STATE/publish/ 下的**产物本身**断言不变量，⛔ 与「本轮改了什么」无关。
#
# 为什么需要它（2026-09-02 立）：仓库原有 check-scripts.sh 查代码、fn-*.sh 查函数，
# **没有任何东西查产物**。于是产物正确性一直靠人临时想到什么就 grep 什么——想不到就漏。
# 同一天连漏三次，全是同一种失效：**验的是「我改的那处生效了吗」，不是「这份产物对不对」**。
#   ① 链接数只数总数 → Android 四段全是 0 没发现（F43）
#   ② 卡片只验列宽没验可点性 → 白发一次（F42）
#   ③ 占位符只替换了自以为有的那个 → 日报卡片另有三个，用户点到死链
# 这三条现在都是下面的机械断言。
#
# 用法：bash bin/test/assert-artifacts.sh [publish 目录]（缺省取 $STATE/publish）
set -uo pipefail
ROOT="${CRASH_REPORT_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}"
STATE="${CRASH_REPORT_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/crash-triage}"
PUB="${1:-$STATE/publish}"
PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); printf '  ✅ %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  ❌ %s\n' "$1"; [ -n "${2:-}" ] && printf '     %s\n' "$2"; }
skip() { printf '  ⏭  %s（产物不存在，跳过）\n' "$1"; }

IOS_APP="1:465344775452:ios:610bc2f8ea0750fff466d9"
AND_APP="1:465344775452:android:2c546b57b0176325f466d9"

# ── ① 文档：**每个「id 单元格」都必须是链接**，且 app id 与所在段平台一致 ──
# ⚠️ 判据精确到单元格，⛔ 不是「这段有行就该有链接」——机型 / 系统版本 / 页面 / 归因
#    这些维度表有很多行却根本没有 issue id，粗判据会把它们全判成失败（初版就是这么错的）。
# 判据：`<td …>abcdef12</td>` 这种「内容恰为 8 位 hex」的单元格，必须被 <a href=控制台> 包裹。
check_doc_links() { # $1=xml 文件
  local f="$1"; [ -s "$f" ] || { skip "$(basename "$f") 的 id 单元格链接"; return 0; }
  local out; out="$(IOS_APP="$IOS_APP" AND_APP="$AND_APP" python3 - "$f" <<'PY2'
import re,sys,os
t=open(sys.argv[1]).read(); ios,and_=os.environ["IOS_APP"],os.environ["AND_APP"]
bad=[]
for m in re.finditer(r"<h[23][^>]*>(.*?)</h[23]>(.*?)(?=<h[23]|\Z)", t, re.S):
    title=re.sub("<[^>]*>","",m.group(1)).strip()[:40]; body=m.group(2)
    # ⛔ 三种坏形态都要抓，⚠️ 只查「有没有 <a>」会漏掉最隐蔽的那种：
    #    ① 裸 id 单元格（根本没做链接）
    #    ② <a href="<32位id>">——前缀解析失败时 href 变成裸 id，点了 404
    #       （2026-09-02 实测：issue_url_prefix 不认 `and` 时 Android 段全是这个形态）
    # ⚠️ **只看每行第一个单元格**：三份产物的 issue 表都把 id 放首列，而「修复提交」列里的
    #    commit hash 同样是 8 位 hex——不限定首列会把它当成 issue id 误报
    #    （2026-09-02 实测：index.xml 的 29a20dc5 是 commit 不是 issue）。
    naked=[]; broken=[]
    for row in re.findall(r"<tr>(.*?)</tr>", body, re.S):
        cells=re.findall(r"<td[^>]*>(.*?)</td>", row, re.S)
        if not cells: continue
        c0=cells[0]
        if re.fullmatch(r"[0-9a-f]{8}", c0.strip()): naked.append(c0.strip())
        else:
            mm=re.match(r'\s*<a href="([^"]*)">[0-9a-f]{8}</a>\s*$', c0)
            if mm and not mm.group(1).startswith(("http://","https://")): broken.append(mm.group(1))
    if naked:  bad.append(f"{title}: {len(naked)} 个 id 单元格没有链接（{naked[0]} …）")
    if broken: bad.append(f"{title}: {len(broken)} 个 id 链接的 href 不是 URL（{broken[0][:34]} …）")
    low=title.lower()
    want = ios if low.startswith("ios") else (and_ if low.startswith("android") else None)
    if want:
        wrong=[u for u in re.findall(r'<a href="([^"]*console\.firebase[^"]*)"', body) if want not in u]
        if wrong: bad.append(f"{title}: {len(wrong)} 个链接的 app id 与平台不符")
print("\n".join(bad))
PY2
)"
  [ -z "$out" ] && ok "$(basename "$f")：id 单元格全部是链接，且 app id 与平台一致" \
                || bad "$(basename "$f")：id 单元格链接不达标" "$out"
}

# ── ② 卡片：无残留占位符 ───────────────────────────────
# ⚠️ **只对已投递的卡片有意义**：未投递的 card.json 本来就带占位符，
#    deliver.sh 是在建完文档拿到真 URL 之后才回填的。默认跳过，传 CHECK_PLACEHOLDERS=1 才查。
check_card_placeholders() { # $1=card.json
  local f="$1"; [ -s "$f" ] || { skip "卡片占位符"; return 0; }
  [ "${CHECK_PLACEHOLDERS:-0}" = 1 ] || { skip "卡片占位符（未投递产物本就带占位符）"; return 0; }
  local left; left="$(grep -oE '__[A-Z_]+__' "$f" | sort -u | tr '\n' ' ')"
  [ -z "$left" ] && ok "卡片无残留占位符" || bad "卡片仍有未回填的占位符" "$left"
}

# ── ③ 卡片：表格单元格不得含链接（实测 CardKit 表格不渲染，写进去是字面 markdown）──
check_card_table_no_link() { # $1=card.json
  local f="$1"; [ -s "$f" ] || { skip "卡片表格无链接"; return 0; }
  local n; n="$(jq -r '[..|objects|select(has("rows"))|.rows[]?|..|strings|select(test("\\]\\(http"))]|length' "$f" 2>/dev/null || echo 0)"
  [ "${n:-0}" = 0 ] && ok "卡片表格单元格无链接" || bad "卡片表格里有 $n 处 markdown 链接（实测不渲染，会显示字面文本并撑宽）"
}

# ── ④ 卡片：列名不得叫 ios/android（CardKit 平台变体键，只有真发一张才炸）──
check_card_colnames() { # $1=card.json
  local f="$1"; [ -s "$f" ] || { skip "卡片列名"; return 0; }
  local n; n="$(jq -r '[..|objects|select(has("columns"))|.columns[]?|.name|select(.=="ios" or .=="android" or .=="pc" or .=="harmony")]|length' "$f" 2>/dev/null || echo 0)"
  [ "${n:-0}" = 0 ] && ok "卡片列名未使用 CardKit 平台变体键" || bad "卡片有 $n 个列名撞上平台变体键（ios/android/pc/harmony）"
}

echo "── 产物自检（${PUB}）──"
check_doc_links "$PUB/docs/daily.xml"
check_doc_links "$PUB/docs/index.xml"
check_card_placeholders "$PUB/card.json"
check_card_table_no_link "$PUB/card.json"
check_card_colnames "$PUB/card.json"
printf '── 产物自检：%s 通过，%s 失败\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
