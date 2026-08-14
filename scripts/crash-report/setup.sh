#!/usr/bin/env bash
# Mac mini 一次性安装。幂等，可重复跑。
# 前置：已装 brew、node、git；已跑过授权（gcloud auth login + firebase-tools login，见文末清单）。
set -euo pipefail

ROOT="${CRASH_REPORT_ROOT:-$HOME/crash-triage}"
IOS_REMOTE="${IOS_REMOTE:-https://github.com/dino-english/dino-english-ios.git}"
AND_REMOTE="${AND_REMOTE:-https://github.com/dino-english/dino-english-android.git}"

echo "=== 崩溃周报安装 → $ROOT ==="
mkdir -p "$ROOT"/{bin,repos,state,reports,logs}

# ── 0. 自装：把本脚本同目录的可执行脚本复制到运行目录 ──
# 源在仓库 scripts/crash-report/，运行时在 $ROOT/bin/，两者分离——
# 仓库版本随 git 管理，运行版本可被 setup 覆盖更新。
SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ "$SRC_DIR" != "$ROOT/bin" ]; then
  echo "--- 安装脚本 $SRC_DIR → $ROOT/bin ---"
  cp "$SRC_DIR"/*.sh "$ROOT/bin/"
  chmod +x "$ROOT/bin"/*.sh
fi

# ── 1. 探测二进制真实路径，写 config.env ──────────────
# 不硬编码：launchd 只给最小 env，各机器 node / brew 路径不一定相同。
echo "--- 探测工具路径 ---"
MISSING=()
declare -a DIRS=()
for b in node jq git claude npx; do
  p="$(command -v "$b" 2>/dev/null || true)"
  if [ -z "$p" ]; then MISSING+=("$b"); else
    printf '  %-10s %s\n' "$b" "$p"
    DIRS+=("$(dirname "$p")")
  fi
done
if [ ${#MISSING[@]} -gt 0 ]; then
  echo "❌ 缺少：${MISSING[*]}"
  echo "   node/jq/git 用 brew 装；claude 用 npm -g 装"
  exit 1
fi
# 去重后拼 PATH，尾部补系统目录兜底
UNIQ="$(printf '%s\n' "${DIRS[@]}" | awk '!seen[$0]++' | paste -sd: -)"
printf 'PATH="%s:/usr/bin:/bin:/usr/sbin:/sbin"\n' "$UNIQ" > "$ROOT/bin/config.env"
echo "  → 写入 $ROOT/bin/config.env"

# ── 2. MCP 配置（复用本机 firebase login 凭证，不含密钥）──
cat > "$ROOT/bin/mcp.json" <<'JSON'
{
  "mcpServers": {
    "firebase": {
      "command": "npx",
      "args": ["-y", "firebase-tools@latest", "mcp", "--only", "crashlytics"]
    }
  }
}
JSON
echo "--- MCP 配置已写 ---"

# ── 3. 准备仓库：同级（REPOS_ROOT，本机=gitWorkspace）看得到就用，看不到才 clone 到隔离副本 ──
echo "--- 准备仓库 ---"
REPOS_ROOT="${REPOS_ROOT:-$ROOT/repos}"
clone_or_fetch() {
  local url="$1" name="$2"
  # 同级里已有仓库 → 直接用（fetch 保持最新），不重复 clone
  if [ -d "$REPOS_ROOT/$name/.git" ]; then
    echo "  ✅ 同级已有 $REPOS_ROOT/$name，跳过 clone（fetch 保持最新）"
    git -C "$REPOS_ROOT/$name" fetch --all --tags --prune --quiet
    return 0
  fi
  # 同级看不到 → 隔离 clone 到 $ROOT/repos
  local dir="$ROOT/repos/$name"
  if [ -d "$dir/.git" ]; then
    echo "  已存在，fetch：$dir"; git -C "$dir" fetch --all --tags --prune --quiet
  else
    echo "  clone：$url → $dir"; git clone --quiet "$url" "$dir"
  fi
}
clone_or_fetch "$IOS_REMOTE" "dino-english-ios"
clone_or_fetch "$AND_REMOTE" "dino-english-android"

# ── 4. 探活 ───────────────────────────────────────────
echo "--- 探活 ---"
# shellcheck disable=SC1091
. "$ROOT/bin/config.env"; export PATH
npx -y firebase-tools@latest login:list 2>/dev/null | grep -q '@' \
  && echo "  ✅ firebase 已登录" || { echo "  ❌ firebase 未登录，跑 npx -y firebase-tools@latest login"; exit 1; }

echo
echo "=== 安装完成 ==="
echo "先 DRY RUN 验一次（不发消息）："
echo "  CRASH_REPORT_ROOT=$ROOT CRASH_REPORT_CHAT_ID=<你的 ou_xxx> CRASH_REPORT_DRY_RUN=1 $ROOT/bin/crash-weekly.sh"
echo
echo "确认无误后装定时（每周一 06:30）："
echo "  cp $ROOT/bin/com.dino.crash-weekly.plist ~/Library/LaunchAgents/"
echo "  launchctl load ~/Library/LaunchAgents/com.dino.crash-weekly.plist"
