#!/usr/bin/env bash
# 外壳层——公开商店当前版本（change crash-fix-store-version）。「已上线」的唯一真值来源。
#
# 两端都**不用凭证**（2026-10-21 实测）：
#   iOS     苹果官方公开接口 iTunes Lookup：.results[0].version
#   Android Google Play 公开详情页 HTML 内嵌数据里的 `[[["x.y.z"]]]`（google-play-scraper 同一取法）
#           ⚠️ 不是正式接口，Google 改版就会取不到——取不到必须**返回空**，由调用方标「发版判定不可得」，
#           ⛔ 不得回落成任何推测信号（tag / main / 设备数——都已实测说反过）。
# 只读网络，不写盘。区域取 MY（团队所在、两端都上架）。
#
# 覆盖：CRASH_REPORT_STORE_VERSIONS='{"ios":"1.8.2","android":"1.8.2"}' —— 夹具与冻结等价性用，⛔ 生产不设。

STORE_BUNDLE_ID="${STORE_BUNDLE_ID:-com.prime.dino.english}"

# store_version：$1=ios|android → 版本号（x.y.z）或空串；恒返回 0（失败也不得触发 ERR trap）
store_version() {
  local v=""
  if [ -n "${CRASH_REPORT_STORE_VERSIONS:-}" ]; then
    v="$(printf '%s' "$CRASH_REPORT_STORE_VERSIONS" | jq -r --arg p "$1" '.[$p] // ""' 2>/dev/null || true)"
  elif [ "$1" = ios ]; then
    v="$(curl -sL --max-time 20 "https://itunes.apple.com/lookup?bundleId=${STORE_BUNDLE_ID}&country=my" 2>/dev/null \
         | jq -r '.results[0].version // ""' 2>/dev/null || true)"
  else
    v="$(curl -sL --max-time 20 -A "Mozilla/5.0" \
           "https://play.google.com/store/apps/details?id=${STORE_BUNDLE_ID}&hl=en&gl=MY" 2>/dev/null \
         | grep -oE '\[\[\["[0-9]+(\.[0-9]+)+"\]\]' 2>/dev/null | head -1 | grep -oE '[0-9]+(\.[0-9]+)+' || true)"
  fi
  # ⛔ 格式不对一律当取不到：宁可「不可得」，不可拿一个怪值去比版本
  case "$v" in
    *[!0-9.]*|'') v="";;
  esac
  printf '%s' "$v"
  return 0
}
