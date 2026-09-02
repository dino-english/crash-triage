#!/usr/bin/env bash
# 外壳层共享函数（change crash-perf-functional-core）。
#
# ⚠️ **必须在 $ROOT / $STATE / $TS 赋值之后 source**——本文件依赖它们，
#    以及调用方预设的四个差异变量（见下）。核心层（bin/lib/core/）没有这个限制，
#    它不依赖任何全局，可任意顺序加载。
#
# 调用方需预设：
#   ALERT_SOURCE   告警来源标识（daily / weekly / …）
#   ALERT_RUN_ID   告警携带的 run id（L1 传 RUN_ID，L2 传 TS）
#   ALERT_FLAG     去重标记文件路径（各链路一个，避免互相压制）
#   HEALTH_FILE    健康状态文件路径
#
# 这四项是 crash-daily.sh 与 crash-weekly.sh 之间**仅有的**差异；
# 此前为了这三处不同，整整 5 个函数各存了一份，改一处漏一处只是时间问题
# （2026-08-21 的告警风暴修复就是在两个文件里各改了一遍）。

ALERTED=0
CURRENT_STEP="启动"

step() { CURRENT_STEP="$1"; echo "--- $1 ---"
  # 审计只记录不 gating；audit 未定义（lib.sh 未加载）或未接入（无 AUDIT_FILE）都静默跳过
  { declare -F audit >/dev/null && audit step.start "$1"; } 2>/dev/null || true; }

# 告警去重：ALERTED 只在主进程有效——命令替换 / 管道都在子 shell 里跑，
# 那里的 ALERTED=1 传不回来（2026-08-21 实测一次 grep 无匹配就在群里连发 8 张卡）。
# 故再加一道文件标记，跑批开始时由调用方清一次。
alert_once() { # $1=step $2=message $3=rc
  [ "$ALERTED" = 1 ] && return 0
  [ -e "$ALERT_FLAG" ] && return 0
  ALERTED=1; : > "$ALERT_FLAG"
  [ -x "$ROOT/bin/alert.sh" ] || return 0
  # 输出一律走 stderr：ERR trap 可能在命令替换里触发，告警文案打到 stdout 会被当成取数结果
  # captured 进变量（2026-08-21：`printf: 📣 已发送告警到 oc_…: invalid number`）。
  "$ROOT/bin/alert.sh" --source "$ALERT_SOURCE" --severity error --step "$1" \
    --message "$2" --rc "${3:-1}" --run-id "$ALERT_RUN_ID" --log "$LOG" >&2 || true
}

# 失败位置：脚本实际跑在 bash 3.2（macOS 系统 bash，`#!/usr/bin/env bash` → /bin/bash）。
# **3.2 下没有任何一种取行号的路子是准的**（2026-08-20 逐个实测）：
#   $LINENO 在函数内给的是函数定义行（第 12 行的失败报成第 8 行，也是「第 532 行」那条告警指错的原因）；
#   顶层的 $LINENO 在 case/if 等复合命令下给的是语句首行（真实 17 报成 15）；
#   BASH_LINENO 的调用点在简单调用下准，但在 for 循环里也偏（真实 586 报成 581）。
# 所以不再输出行号假装精确，只报**函数调用链**——函数名本身就足以定位，且它是准的。
err_stack() {
  local i out
  if [ "${#FUNCNAME[@]}" -le 3 ]; then printf 'main()'; return 0; fi
  out="${FUNCNAME[2]}()"
  for ((i=3; i<${#FUNCNAME[@]}; i++)); do out="${out} ← ${FUNCNAME[$i]}()"; done
  printf '%s' "$out"
}

on_err() { local rc=$?; [ "$rc" -eq 0 ] && return 0
  alert_once "$CURRENT_STEP" "以退出码 $rc 终止（未预期的失败）· 位置 $(err_stack)" "$rc"; }

fail() {
  echo "❌ $*"
  # run.end{ok:false} 先于 health：审计流是排障第一入口，health 只是最后状态
  { declare -F audit >/dev/null && audit run.end "$CURRENT_STEP" "$(jq -cn --arg e "$*" '{ok:false,error:$e}')"; } 2>/dev/null || true
  jq -n --arg t "$TS" --arg e "$*" '{last_run:$t,run_id:$t,ok:false,error:$e}' > "$HEALTH_FILE"
  alert_once "$CURRENT_STEP" "$*" 1
  exit 1
}

# ── Crashlytics 控制台直达链接（change crash-report-issue-identity）────────────
# 报告只给可定位对象与集中度，完整下钻交给控制台自己呈现——读者点过去看到的就是控制台口径，
# 于是「⛔ 不可与控制台对照」那一类注解失去存在理由。
# ⚠️ 链接必须用**完整 32 位 id**，⛔ 不能由展示用的 8 位短 id 拼回去（取数层拿到的本就是完整 id）。
# ⚠️ 两个 app id 在 bin/fetch-snapshot.sh 顶部另有一份（该脚本不 source 本文件，函数与常量都不跨进程）。
#    改动时两处都要动；这是已知的重复，登记在此而不是假装它不存在。
FIREBASE_PROJECT="${FIREBASE_PROJECT:-dino-english-497507}"
FIREBASE_APP_IOS="${FIREBASE_APP_IOS:-1:465344775452:ios:610bc2f8ea0750fff466d9}"
FIREBASE_APP_AND="${FIREBASE_APP_AND:-1:465344775452:android:2c546b57b0176325f466d9}"

issue_url() { # $1=平台键(ios/android) $2=完整 32 位 issue id → stdout: 控制台 URL（参数不全则空串）
  local _app
  # ⚠️ **两条链路的平台键不同**：L2 用 snapshot 的 `ios`/`android`，L1 内部一路用 `ios`/`and`
  #    （`AND_CRASH_TBL` / `mv_ and` / `xml_issues and` …）。只认 `android` 时 **Android 侧一条链接都不出**，
  #    而 iOS 侧正常——2026-09-02 实测：daily.xml 里 iOS 段 7 个链接、Android 段 0 个，静态看不出来。
  # ⛔ 仍保留 `(*)` 兜底返回空：拼错的键必须得到空串而不是猜一个平台。
  case "$1" in
    (ios|iOS|IOS)                 _app="$FIREBASE_APP_IOS" ;;
    (and|android|Android|ANDROID) _app="$FIREBASE_APP_AND" ;;
    (*)                           printf ''; return 0 ;;
  esac
  case "$2" in
    ([0-9a-f]*) : ;;
    (*) printf ''; return 0 ;;
  esac
  printf 'https://console.firebase.google.com/v1/appid/project/%s/crashlytics/app/%s/issues/%s' \
    "$FIREBASE_PROJECT" "$_app" "$2"
}

# jq 渲染的表格里没法调 shell 函数，故另给一个前缀版本：`<prefix><32位id>` 即完整 URL。
# ⛔ 两者共用同一组常量，不得各写一份 URL 形状。
issue_url_prefix() { # $1=平台键 → stdout: URL 前缀（平台无效则空串）
  local _app
  # ⚠️ **两条链路的平台键不同**：L2 用 snapshot 的 `ios`/`android`，L1 内部一路用 `ios`/`and`
  #    （`AND_CRASH_TBL` / `mv_ and` / `xml_issues and` …）。只认 `android` 时 **Android 侧一条链接都不出**，
  #    而 iOS 侧正常——2026-09-02 实测：daily.xml 里 iOS 段 7 个链接、Android 段 0 个，静态看不出来。
  # ⛔ 仍保留 `(*)` 兜底返回空：拼错的键必须得到空串而不是猜一个平台。
  case "$1" in
    (ios|iOS|IOS)                 _app="$FIREBASE_APP_IOS" ;;
    (and|android|Android|ANDROID) _app="$FIREBASE_APP_AND" ;;
    (*)                           printf ''; return 0 ;;
  esac
  printf 'https://console.firebase.google.com/v1/appid/project/%s/crashlytics/app/%s/issues/' \
    "$FIREBASE_PROJECT" "$_app"
}
