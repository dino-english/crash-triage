#!/usr/bin/env bash
# 投递失败必须浮出水面（2026-09-11 事故）。
#
# 事故形态：deliver.sh 的 fail() 多数发生在 `$( )` 命令替换里，`exit 1` 只结束子 shell，
# 外层照常跑完 exit 0；crash-daily.sh 又用 `|| echo` 吞掉退出码、health 写死 ok:true。
# 结果：群里收到「投递失败」告警卡，而跑批与 Hermes 双双记「成功」。
set -uo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SELF_DIR/../.." && pwd)"
# shellcheck disable=SC1091
. "$SELF_DIR/harness.sh"

echo "── deliver.sh：子 shell 里的 fail 必须让整脚本非零退出 ──"
# 行为测试：把 fail 抽出来真跑一次，验它确实落了标记（⚠️ fail 里有 exit，放子 shell 里调）
h_load "$ROOT/bin/deliver.sh" fail || { h_summary; exit 1; }
TMPM="$(mktemp -d)/mark"
( DELIVER_FAIL_MARK="$TMPM" ROOT="/nonexistent" CURRENT_STEP="投递" RUN_ID="test" \
  fail "模拟导入失败" ) >/dev/null 2>&1 || true
if [ -e "$TMPM" ]; then echo "  ✅ fail 在子 shell 里也落下了标记"; H_PASS=$((H_PASS+1))
else echo "  ❌ fail 没落标记——外层将无从得知失败"; H_FAIL=$((H_FAIL+1)); fi
rm -rf "$(dirname "$TMPM")"

# 余下断言的是源码事实：deliver.sh 整体需要真实 lark-cli 才跑得起来，收尾分支只能静态钉。
for pat in ': > "$DELIVER_FAIL_MARK"' 'rm -f "$DELIVER_FAIL_MARK"' 'RUN_COMPLETED=1; exit 1'; do
  if grep -qF "$pat" "$ROOT/bin/deliver.sh"; then
    echo "  ✅ 存在：$pat"; H_PASS=$((H_PASS+1))
  else
    echo "  ❌ 缺失：$pat"; H_FAIL=$((H_FAIL+1))
  fi
done

echo "── crash-daily.sh：不得吞掉 deliver 的退出码 ──"
if grep -qF 'deliver.sh" "$PUBLISH_DIR/manifest.json" || echo' "$ROOT/bin/crash-daily.sh"; then
  echo "  ❌ ⛔ `|| echo` 又回来了：退出码会被吞掉（F17 同类）"; H_FAIL=$((H_FAIL+1))
else
  echo "  ✅ 未用 || echo 吞码"; H_PASS=$((H_PASS+1))
fi
if grep -qF 'ok:true,data_until' "$ROOT/bin/crash-daily.sh"; then
  echo "  ❌ ⛔ health 的 ok 又被写死成 true"; H_FAIL=$((H_FAIL+1))
else
  echo "  ✅ health 的 ok 由 DELIVER_RC 决定，未写死"; H_PASS=$((H_PASS+1))
fi
for pat in 'DELIVER_RC=$?' 'exit "$DELIVER_RC"'; do
  if grep -qF "$pat" "$ROOT/bin/crash-daily.sh"; then
    echo "  ✅ 存在：$pat"; H_PASS=$((H_PASS+1))
  else
    echo "  ❌ 缺失：$pat"; H_FAIL=$((H_FAIL+1))
  fi
done

h_summary
