#!/usr/bin/env bash
# 纯函数断言运行器（change crash-perf-functional-core，design D4）。
#
# 自建而非依赖 bats：bats 要 brew install 或 vendoring，而生产机（无人值守 Mac mini）
# 不该为开发期工具多一项装机依赖。本 change 需要的全部能力就是
# 「比较两个字符串、不等就非零退出」——30 行够了，bash 3.2 兼容，零外部依赖。
#
# 用例文件写成普通 bash（core-*.sh），将来要迁 bats 是机械转换。
set -uo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CORE_DIR="$SELF_DIR/../lib/core"

PASS=0; FAIL=0
assert_eq() { # $1=期望 $2=实际 $3=用例名
  if [ "$1" = "$2" ]; then PASS=$((PASS+1))
  else FAIL=$((FAIL+1)); printf '  ❌ %s\n     期望 [%s]\n     实际 [%s]\n' "$3" "$1" "$2"; fi
}

# 核心层必须能在空环境加载——这是「可测」的操作性定义，也顺带验证了它不依赖全局。
for f in "$CORE_DIR"/*.sh; do
  # shellcheck disable=SC1090
  . "$f" || { echo "❌ 无法加载 $f" >&2; exit 1; }
done

for t in "$SELF_DIR"/core-*.sh; do
  [ -e "$t" ] || continue
  # shellcheck disable=SC1090
  . "$t"
done

printf '\n  纯函数断言：%d 通过' "$PASS"
[ "$FAIL" -gt 0 ] && { printf '，%d 失败\n' "$FAIL"; exit 1; }
printf '，0 失败 ✅\n'; exit 0
