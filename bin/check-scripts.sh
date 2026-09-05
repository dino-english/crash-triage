#!/usr/bin/env bash
# 提交前自检。⚠️ **九项**（CLAUDE.md 若仍写「七项」以本文件为准）：
#  1. bash 语法（递归扫 bin/**/*.sh）
#  2. $VAR 紧跟多字节字符 —— bash 3.2（macOS 自带）会把多字节的首字节并进变量名，
#     报 "VAR?: unbound variable"。2026-08-18 一天内连踩五次，做成检查项。
#     用 python 做匹配：BSD grep -E 不支持 \x 转义，写正则会误报一片。
#  3. 依赖方向（核心层不得出现取数 / 投递 / 模型 / 状态目录）
#  4. 同名函数跨文件重复定义
#  5. bq query 直连收口（只允许 bin/lib/bq.sh）
#  6. printf 格式串里的字面 %（F22：只在运行时炸，bash -n 查不出）
#  7. 顶层「先用后定」（F24 同源：常量/函数定义晚于使用，报错常被 EXIT trap 吞成 0）
#  8. 纯函数断言（bin/test/run.sh）+ 函数级回归（fn-regression.sh，生产 shell 设置下）
#  9. ShellCheck（可选依赖，未安装则跳过，不影响退出码）
#
# ⚠️ 每加一项都要**双向测试**：①塞违规样本确认真的变红 ②在**当前全量代码**上确认不误报。
#    只做①不够——2026-08-24 加的「多传占位符」检查对正常设计也报，当轮就给使用方
#    发了误报告警卡（失效模式 F30）。⛔ 检查本身也不得走会触发 ERR trap 的路径。
#    一个不会红的检查项危险，一个乱红的检查项更危险——它会训练人忽略告警。
set -uo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
rc=0
# ⚠️ **必须递归**：早先只扫 "$SELF_DIR"/*.sh，于是 bin/lib/ 与 bin/test/ 下的新代码
# 完全不受任何检查——包括下面那条多字节变量 lint。实测第一个放进 bin/test/ 的脚本
# 就带着 `$SCRIPT（` 这种写法通过了自检，运行时才炸。
while IFS= read -r f; do
  [ "$(basename "$f")" = "check-scripts.sh" ] && continue
  bash -n "$f" || { echo "❌ 语法: ${f#"$SELF_DIR"/}"; rc=1; }
done < <(find "$SELF_DIR" -name '*.sh' -type f | sort)
python3 - "$SELF_DIR" <<'PY' || rc=1
import sys, re, pathlib
bad = 0
pat = re.compile(r'\$([A-Za-z_][A-Za-z0-9_]*)(?=[^\x00-\x7F])')
for f in sorted(pathlib.Path(sys.argv[1]).rglob('*.sh')):
    if f.name == 'check-scripts.sh':
        continue
    for n, line in enumerate(f.read_text(encoding='utf-8').splitlines(), 1):
        for m in pat.finditer(line):
            rel = f.relative_to(pathlib.Path(sys.argv[1]))
            print(f'❌ {rel}:{n} 变量紧邻多字节字符，需写成 ${{{m.group(1)}}}：{line.strip()[:70]}')
            bad = 1
sys.exit(bad)
PY
python3 -c "import ast; ast.parse(open('$SELF_DIR/md2docx.py').read())" 2>/dev/null || { echo "❌ md2docx.py 语法"; rc=1; }

# ── 3. 依赖方向 lint（change crash-perf-functional-core，design D5）───────────
# bash 没有编译器，这是「内层不知道外层」这条依赖规则在这门语言里**唯一能落地的强制形式**。
# 核心层出现取数 / 投递 / 模型调用 / 网络，或引用运行目录、状态目录变量，即失败。
# 跳过整行注释；行内注释的假阳性是刻意接受的代价——**假阴性（核心层偷读 $STATE）才是真风险**。
if [ -d "$SELF_DIR/lib/core" ]; then
  hits="$(grep -nE '^[^#]*(\bbq\b|lark-cli|claude |curl |firebase|\$STATE|\$ROOT|\$\{STATE|\$\{ROOT)' \
            "$SELF_DIR"/lib/core/*.sh 2>/dev/null || true)"
  if [ -n "$hits" ]; then
    echo "❌ 核心层出现外层依赖（应为纯函数，见 bin/lib/core/*.sh 顶部说明）："
    printf '%s\n' "$hits" | sed 's|^'"$SELF_DIR"'/|   |'
    rc=1
  fi
fi

# ── 4. 重复定义检测 ──────────────────────────────────────────────
# 同名函数出现在两个及以上文件即失败。豁免清单以**数据形式**集中在下面，
# 每项带一行理由——散落的 if 判断会让清单悄悄长大而无人察觉。
#   fail:deliver.sh      独立进程，不写 health 文件（投递失败不改变生成脚本的健康状态），语义不同
#   fail:crash-daily.sh  common.sh 缺失时的回落分支
#   fail:crash-weekly.sh 同上
#   say:install.sh       装机链路，与流水线运行时无关，本次未合并（不是「不该合并」）
#   say:update.sh        同上
#
# ⛔ **本项只比对生产文件，排除 bin/test/**（2026-09-05）。理由是结构性的，不是图省事：
#    本项的判据是「共享函数应收口到 bin/lib/」，而夹具里的函数**本来就不该被收口**——
#    它们是桩与局部助手（`json_only(){ cat; }` 注释明写「夹具里退化为直通」、
#    `note_new` 是副作用记录器、`mk`/`probe`/`ok`/`bad` 是各夹具自己的打印助手）。
#    把 bin/test/ 一并比对的结果是**这一项长期常红 6 条**，而常红等于没有：
#    2026-09-05 一天三次部署，每次都看见同一条 ❌，新旧无从分辨。
#    ⚠️ 一个不会红的检查项危险，一个乱红的检查项更危险——它会训练人忽略告警（本文件开头原话）。
# ⚠️ 代价要说清：夹具**照抄**生产函数（而非 h_load 抽取）这种情况本项不再报。
#    但本项只比名字不比函数体，本来也分辨不了「桩」与「照抄」——那属于测试质量，
#    另有 bin/test/harness.sh 的 h_load 约定负责，不该由重名检查兼职。
# ⚠️ 递归扫描的其余各项（语法 / 多字节 lint / 先用后定 …）**仍然覆盖 bin/test/**，此处只改本项。
dup="$(
  { for f in $(find "$SELF_DIR" -name '*.sh' -type f -not -path '*/test/*' | sort); do
      grep -oE '^[a-zA-Z_][a-zA-Z0-9_]*\(\)' "$f" | tr -d '()' | sed "s|\$|	${f#"$SELF_DIR"/}|"
    done; } | grep -vE '^(fail	(deliver|crash-daily|crash-weekly)\.sh|say	(install|update)\.sh)$' \
  | awk -F'\t' '{n[$1]=n[$1]" "$2; c[$1]++} END{for(k in c) if(c[k]>1) print "   " k ": " n[k]}' | sort
)"
if [ -n "$dup" ]; then
  echo "❌ 同名函数在多个文件中重复定义（共享函数应收口到 bin/lib/）："
  printf '%s\n' "$dup"
  rc=1
fi

# ── 5. bq 直连收口 lint（findings F1/F5 的护栏）──────────────────
# `bq query` 只允许出现在 bin/lib/bq.sh（bqq，全仓唯一取数通道）。直连会绕过
# CRASH_REPORT_BQ_CACHE，在等价性验收的「冻结面」上开洞——F5 实测：没有这条 lint，
# 每个照着旧写法新增的取数函数都在扩大缺口（9 处 → 10 处）。豁免清单（带理由）：
#   install.sh  装机自检探活，跑在 STATE 尚未建立时，且探活本就不该吃缓存
bq_direct="$(
  find "$SELF_DIR" -name '*.sh' -type f | sort | while IFS= read -r f; do
    rel="${f#"$SELF_DIR"/}"
    # 模式带前导 (：bash 3.2 在 $( ) 里会把 case 模式的裸 ) 当成命令替换终点，当场语法炸
    case "$rel" in (lib/bq.sh|install.sh|check-scripts.sh) continue;; esac
    grep -nE '^[^#]*\bbq query\b' "$f" | sed "s|^|   ${rel}:|" || true
  done
)"
if [ -n "$bq_direct" ]; then
  echo "❌ bq query 直连（应走 bin/lib/bq.sh 的 bqq，否则绕过等价性验收缓存）："
  printf '%s\n' "$bq_direct"
  rc=1
fi

# ── 6. printf 格式串里的字面 % ───────────────────────────────────
# 中文报告文案里百分比极常见（「覆盖 96.6%」「Android 0%」），写进 printf 的**格式串**
# 会被当成格式符，报 invalid format character——⚠️ **只在运行时炸**，且触发 ERR trap 发告警。
# `bash -n` 查不出（格式串语法合法），2026-08-24 实测让一次整跑在取数 5 分钟后作废（F22）。
# 修法：含字面 % 的文案走 `printf '%s\n' "…"`，不放进格式串。
python3 - "$SELF_DIR" <<'PY' || rc=1
import sys, re, pathlib
bad = 0
# 合法的转换说明符与 %%，其余的 % 视为字面量
ok = re.compile(r'%%|%[-+ #0-9.*]*[diouxXeEfgGaAcsbq]')
for f in sorted(pathlib.Path(sys.argv[1]).rglob('*.sh')):
    if f.name == 'check-scripts.sh':
        continue
    for n, line in enumerate(f.read_text(encoding='utf-8').splitlines(), 1):
        for m in re.finditer(r"printf\s+'([^']*)'", line):
            if '%' in ok.sub('', m.group(1)):
                rel = f.relative_to(pathlib.Path(sys.argv[1]))
                print(f'❌ {rel}:{n} printf 格式串含字面 %，改用 printf \'%s\\n\' "…"：{line.strip()[:70]}')
                bad = 1
sys.exit(bad)
PY

# ── 7. 顶层「先用后定」────────────────────────────────────────────
# bash 顺序执行，声明与使用隔着几百行时没有任何工具在守。2026-08-24 一天内同类错误四次
# （DD_TOP_N / dd_fetch / WOW_CUT / awk 列序），⚠️ **全都不报错或报错被吞**：
#   · 常量先用后定 → unbound variable，退出码曾被 EXIT trap 吞成 0（失效模式 F24）
#   · 函数先用后定 → command not found，被 `|| true` 吞掉 → 空产物 + rc=0
# 只看顶层引用（函数体内前向引用合法），跳过 ${VAR:-默认} 与 trap 体。
if [ -f "$SELF_DIR/test/lint-order.py" ]; then
  python3 "$SELF_DIR/test/lint-order.py" "$SELF_DIR" || rc=1
fi

# ── 8. 纯函数断言 ────────────────────────────────────────────────
if [ -x "$SELF_DIR/test/run.sh" ]; then
  bash "$SELF_DIR/test/run.sh" || rc=1
fi
# 函数级回归：跑在**生产 shell 设置**下（set -euo pipefail + errtrace + ERR trap）。
# ⛔ 与上面的纯函数断言不是一回事：那些验「输入→输出」，这些验「过程中有没有踩 ERR trap」。
#    2026-08-24 实测：`grep -o` 无匹配返回 1，普通夹具测出 rc=0 一切正常，
#    生产里每次成功渲染都触发一次 ERR trap → 发告警卡（失效模式 F31）。
#    详见 docs/CLAUDE-测试盲区.md。
if [ -x "$SELF_DIR/test/fn-regression.sh" ]; then
  bash "$SELF_DIR/test/fn-regression.sh" || rc=1
fi

# ── 9. ShellCheck（可选依赖）─────────────────────────────────────
# 生产机是无人值守的 Mac mini，不该为开发期工具多一项装机步骤。
# 未安装 → 跳过并提示，**不影响退出码**；已安装 → 计入。
if command -v shellcheck >/dev/null 2>&1; then
  sc="$(find "$SELF_DIR" -name '*.sh' -type f -print0 | xargs -0 shellcheck -S warning 2>&1 || true)"
  if [ -n "$sc" ]; then
    echo "⚠️ ShellCheck 报告（首 20 行）："; printf '%s\n' "$sc" | head -20
    SC_COUNT="$(printf '%s\n' "$sc" | grep -cE '^In .* line [0-9]+:' || true)"
    echo "   共 ${SC_COUNT} 处。首次接入若数量大，先记录再分批清理，不阻塞本轮（见 change findings）"
  fi
else
  echo "ℹ️ 未安装 shellcheck，跳过静态检查（可选依赖，不影响退出码）"
fi
[ $rc -eq 0 ] && echo "✅ 全部通过"
exit $rc
