#!/usr/bin/env bash
# 函数级测试夹具：让被测函数跑在**与生产相同的 shell 设置**下。
#
# 为什么需要它（失效模式 F31 / docs/CLAUDE-测试盲区.md 盲区③）：
# 生产脚本头部是 `set -euo pipefail` + `set -o errtrace` + ERR trap（触发即发告警卡），
# 而随手写的夹具通常是 `bash -c 'set -uo pipefail; …'`——**少了 -e 和 ERR trap**。
# 于是「过程中某条命令返回非零」这类问题在夹具里只是个被忽略的退出码，
# 在生产里却是一张发给使用方的告警。2026-08-24 实测：`grep -o` 无匹配返回 1，
# 夹具测出 rc=0 一切正常，跑批时每次成功渲染都触发一次 ERR trap。
#
# 用法：
#   . bin/test/harness.sh
#   h_load bin/crash-weekly.sh dd_block          # 从脚本里抽一个函数进当前 shell
#   h_run dd_block "$csv" "Android" "口径" 1     # 在生产 shell 设置下跑，ERR 即失败
#   h_assert_contains "$out" '| Issue |' '下钻表头'
#   h_summary                                    # 打印统计并按失败数退出
set -uo pipefail

H_PASS=0; H_FAIL=0
H_ERR_HIT=0

# 从脚本文件里抽出一个顶层函数的源码（本仓库风格：函数以列 0 的 `}` 收尾）。
# ⚠️ 抽出来测**看不见定义顺序**（盲区①）——顺序问题走 check-scripts 第 7 项的静态检查，
#    ⛔ 不要指望这里能抓到。
h_extract() { # $1=脚本 $2=函数名
  awk -v fn="$2" '
    $0 ~ "^" fn "\\(\\) \\{" { inf=1 }
    inf { print }
    inf && $0 == "}" { exit }
  ' "$1"
}

h_load() { # $1=脚本 $2..=函数名…
  local f="$1"; shift
  local fn src
  for fn in "$@"; do
    src="$(h_extract "$f" "$fn")"
    if [ -z "$src" ]; then
      echo "❌ 夹具：在 $f 里找不到函数 $fn" >&2; H_FAIL=$((H_FAIL+1)); return 1
    fi
    # ⛔ 抽多了必须当场失败：h_extract 靠「列 0 的 `}`」定位结尾，被抽的函数若以 `; }` 收尾，
    #    它会一路吞掉后面的顶层代码并连同 eval（实测吞进 `HISTORY="$STATE/…"`，报的是
    #    `STATE: unbound variable`——错误信息与真正的原因毫无关系）。
    #    判据：函数体里不该出现**列 0 的顶层赋值**。碰巧无害时静默通过才是最坏的结果。
    if printf '%s\n' "$src" | grep -qE '^[A-Za-z_][A-Za-z0-9_]*='; then
      echo "❌ 夹具：抽取 $fn 时越过了函数结尾（$f 里它没有以列 0 的 } 收尾）" >&2
      H_FAIL=$((H_FAIL+1)); return 1
    fi
    eval "$src" || { echo "❌ 夹具：$fn 无法加载" >&2; H_FAIL=$((H_FAIL+1)); return 1; }
  done
}

# 在**生产 shell 设置**下执行，stdout 回传，ERR trap 命中即记失败。
# ⛔ 关键就是这一行的 `set -euo pipefail; set -o errtrace` + ERR trap——
#    夹具与生产的差异全在这里，少一样就等于没测那一类问题。
h_run() { # $1=函数名 $2..=参数 → stdout；ERR 命中时 H_ERR_HIT=1
  local out rc errf; errf="$(mktemp)"
  # ⚠️ 重定向必须用 { …; } 2>file 绑到整组命令上——写成单独一行的 `2>"$errf"`
  #    会被当成一条空重定向命令，stderr 根本没被捕获（本文件初版就是这么错的，
  #    表现是「检测到了却没计入失败」——检查工具自己失灵最难发现）。
  rc=0
  out="$( { set -euo pipefail
            set -o errtrace
            trap 'echo "__H_ERR__ rc=$? cmd=$BASH_COMMAND" >&2' ERR
            "$@"
          } 2>"$errf" )" || rc=$?
  if grep -q '__H_ERR__' "$errf" 2>/dev/null; then
    H_ERR_HIT=1
    echo "❌ ERR trap 在 $1 内触发（生产里这会发告警卡）：" >&2
    grep '__H_ERR__' "$errf" | head -3 >&2
    H_FAIL=$((H_FAIL+1))
  fi
  # 非 __H_ERR__ 的 stderr 原样透出，便于看真实报错
  grep -v '__H_ERR__' "$errf" >&2 2>/dev/null || true
  rm -f "$errf"
  printf '%s' "$out"
  return $rc
}

# ⛔ 「正常路径必须完全安静」——F30 的教训：只测「违规样本会红」不够，
#    新检查对正常输入乱报的代价是训练人忽略告警。
h_assert_silent() { # $1=函数名 $2..=参数
  local errf; errf="$(mktemp)"
  ( set -euo pipefail; set -o errtrace
    trap 'echo "__H_ERR__ rc=$? cmd=$BASH_COMMAND" >&2' ERR
    "$@" ) >/dev/null 2>"$errf"
  if [ -s "$errf" ]; then
    echo "❌ 正常路径不安静（stderr 非空）：$1" >&2; sed 's/^/     /' "$errf" >&2
    H_FAIL=$((H_FAIL+1)); rm -f "$errf"; return 1
  fi
  rm -f "$errf"; H_PASS=$((H_PASS+1)); echo "  ✅ 正常路径安静：$1"
}

h_assert_contains() { # $1=实际 $2=期望子串 $3=说明
  case "$1" in
    (*"$2"*) H_PASS=$((H_PASS+1)); echo "  ✅ $3";;
    (*) H_FAIL=$((H_FAIL+1)); echo "  ❌ $3：输出里没有 [$2]"; printf '%s\n' "$1" | head -3 | sed 's/^/     /';;
  esac
}

h_assert_eq() { # $1=期望 $2=实际 $3=说明
  # ⚠️ 与 h_assert_contains 的分工：凡是「文案一字未动」「必须正好是这个值」的断言必须用这个，
  #    contains 会让「多打了一句话」「少了日期」这类回归悄悄通过。
  if [ "$1" = "$2" ]; then H_PASS=$((H_PASS+1)); echo "  ✅ $3"
  else H_FAIL=$((H_FAIL+1)); echo "  ❌ $3"; echo "     期望 [$1]"; echo "     实际 [$2]"; fi
}

h_assert_absent() { # $1=实际 $2=不该出现的子串 $3=说明
  case "$1" in
    (*"$2"*) H_FAIL=$((H_FAIL+1)); echo "  ❌ $3：不该出现 [$2]";;
    (*) H_PASS=$((H_PASS+1)); echo "  ✅ $3";;
  esac
}

h_assert_rc() { # $1=期望rc $2=函数名 $3..=参数
  local want="$1"; shift
  local got=0
  ( set -uo pipefail; "$@" ) >/dev/null 2>&1 || got=$?
  if [ "$got" = "$want" ]; then H_PASS=$((H_PASS+1)); echo "  ✅ rc=${want}：$1"
  else H_FAIL=$((H_FAIL+1)); echo "  ❌ rc 期望 ${want} 实得 ${got}：$1"; fi
}

h_summary() {
  echo "  ── 夹具：${H_PASS} 通过，${H_FAIL} 失败$([ "$H_ERR_HIT" = 1 ] && echo "（含 ERR trap 命中）")"
  [ "$H_FAIL" -eq 0 ]
}
