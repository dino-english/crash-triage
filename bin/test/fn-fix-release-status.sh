#!/usr/bin/env bash
# fix-release-status.sh 整脚本（change crash-fix-release-status）：用 PATH 里的假 bq 喂数据，零真实查询。
#
# 钉住两件事：
#   ① 成功路径：四态写回 mapped，原时间规则结果留在 status_time，release_check=ok
#   ② ⛔ 失败路径（design D6）：退出码 2、**文件照写**、原状态保留、逐条 release_check=unavailable——
#      不得静默退回两态，也不得因为一端失败把另一端也丢掉
set -uo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SELF_DIR/../.." && pwd)"
# shellcheck disable=SC1091
. "$SELF_DIR/harness.sh"

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin" "$T/state"
A=8bc4b97e887ce32a7fada8b4fd2abc29   # Android，未发版
B=8b297547000011112222333344445555   # Android，已发版、旧包仍崩
I=09ee5ad371c6c16acf0388f898f1839f   # iOS，未发版
jq -n --arg a "$A" --arg b "$B" --arg i "$I" '{scanned_at:"x",window_days:90,platform_unavailable:[],ambiguous:[],mapped:{
  ($a):{platform:"android",commit:"952c4e2e",subject:"s",status:"修了仍在",commit_epoch:1791183447,release_ref:null,fixed_in_version:null},
  ($b):{platform:"android",commit:"96738df6",subject:"s",status:"修了仍在",commit_epoch:1790581208,release_ref:"V1.8.2",fixed_in_version:"1.8.2"},
  ($i):{platform:"ios",commit:"5b0dec2f",subject:"s",status:"已修待验",commit_epoch:1791182515,release_ref:null,fixed_in_version:null}}}' > "$T/in.json"

# 假 bq：按 SQL 里的表名回对应平台的数据；FAKE_BQ_FAIL 命中的平台返回非零
cat > "$T/bin/bq" <<EOF
#!/usr/bin/env bash
sql="\$(cat)"
case "\$sql" in
  *_ANDROID_REALTIME*) p=android ;;
  *) p=ios ;;
esac
case ",\${FAKE_BQ_FAIL:-}," in *",\$p,"*) echo "boom" >&2; exit 1 ;; esac
if [ "\$p" = android ]; then
  printf '%s' '[{"kind":"ev","issue_id":"$A","build":"182010","version":"1.8.2","first_seen":"1759224000","perf_on":"0","events":"1"},
                {"kind":"ev","issue_id":"$B","build":"181001","version":"1.8.1","first_seen":"1758547560","perf_on":"0","events":"2"}]'
else
  printf '%s' '[{"kind":"rel","issue_id":"","build":"1.7.1.2","version":"1.7.1","first_seen":"1757941500","perf_on":"2790","events":"0"}]'
fi
EOF
chmod +x "$T/bin/bq"

run() { PATH="$T/bin:$PATH" CRASH_REPORT_ROOT="$ROOT" CRASH_REPORT_STATE_DIR="$T/state" \
          bash "$ROOT/bin/fix-release-status.sh" "$T/in.json" "$T/out.json" 2>"$T/err"; }
get() { jq -r --arg id "$1" ".mapped[\$id] | $2" "$T/out.json"; }

echo "── ① 成功路径 ──"
run; rc=$?
h_assert_eq "0" "$rc" "两端都判了 → rc=0"
h_assert_eq "已修未发版" "$(get "$A" .status)" "8bc4b97e：修复未上线、崩溃在旧包"
h_assert_eq "修了仍在"   "$(get "$A" .status_time)" "原时间规则结果保留在 status_time，供对照"
h_assert_eq "已发版待验|2" "$(get "$B" '"\(.status)|\(.old_build_events)"')" "8b297547：已发版，旧包仍崩 2"
h_assert_eq "已修未发版" "$(get "$I" .status)" "iOS：上架包都早于提交 → 未发版"
h_assert_eq "ok|ok|ok" "$(jq -r '[.mapped[].release_check] | join("|")' "$T/out.json")" "逐条 release_check=ok"
h_assert_eq "[]" "$(jq -c .release_unavailable "$T/out.json")" "无不可得平台"

echo "── ② ⛔ 一端取数失败（android）──"
rm -f "$T/out.json"; FAKE_BQ_FAIL=android run; rc=$?
h_assert_eq "2" "$rc" "有一端失败 → rc=2（调用方据此标注，不中断）"
h_assert_eq "true" "$([ -s "$T/out.json" ] && echo true || echo false)" "⛔ 文件照写——不能因为失败就没有产物"
h_assert_eq "修了仍在|unavailable" "$(get "$A" '"\(.status)|\(.release_check)"')" "失败端保留时间规则结果并标 unavailable"
h_assert_eq "null" "$(get "$A" .old_build_events)" "⛔ 失败端不得出现四态字段（否则会被当成判过）"
h_assert_eq "已修未发版|ok" "$(get "$I" '"\(.status)|\(.release_check)"')" "⛔ 另一端（iOS）照常判定，不被连累"
h_assert_contains "$(cat "$T/err")" "发版判定取数失败（android" "失败要说出来"

echo "── ③ 两端都失败 + 仓库未同步 ──"
rm -f "$T/out.json"; FAKE_BQ_FAIL=ios,android CRASH_REPORT_REPOS_SYNCED=0 run; rc=$?
h_assert_eq "2" "$rc" "rc=2"
h_assert_eq "unavailable|unavailable|unavailable" "$(jq -r '[.mapped[].release_check] | join("|")' "$T/out.json")" "全部标 unavailable"
h_assert_eq "false" "$(jq -r .repos_synced "$T/out.json")" "repos_synced=false 透传给呈现层（design D5）"

h_summary
