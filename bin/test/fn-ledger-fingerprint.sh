#!/usr/bin/env bash
# deliver.sh 台账现状表的「内容一致」指纹（_ledger_fingerprint）
#
# ⛔ 本夹具存在的理由（2026-10-02 实测，F60 的另一面）：旧指纹 = 数据行数 + 8 位 id 集合，
#    处置状态 / 本次状态 / 表头全不在里面。测试文档里把 3 行「修了仍在」预置成「已修待验」，
#    投递日志打「✅ 内容与线上一致，跳过替换」，读回 3 行原样未改——**状态更正被静默丢弃**。
# ⚠️ 也不能逐字比：往返有噪声（分隔行 |-| vs |---|、标题里的 <init> 被飞书剥掉），
#    下面的「线上」样本照抄这两种实测噪声。逐列实测：表头与状态列往返一字不差。
ROOT="${CRASH_REPORT_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}"
. "$ROOT/bin/test/harness.sh"
h_load "$ROOT/bin/deliver.sh" _ledger_fingerprint

LOCAL='| 平台 | Issue ID | 标题 | 类型 | 首次纳入 | 处置状态 | 本次状态 | 事件量趋势 | 备注 |
|---|---|---|---|---|---|---|---|---|
| Android | [85c581ed](https://x/issues/85c581edcdb39b941df627e7b1324a71) | [libc.so] | FATAL | 2026-08-20 | 修了仍在 | 🔁遗留 | 3 | 9bbe8b15 fix(ai): teardown |
| Android | [d3675e82](https://x/issues/d3675e8284504c27f6b53d3205a45c32) | SsmlBuilder.<clinit> | FATAL | 2026-09-28 | 未处理 | 🆕新增 | 2 | — |'
# 线上 = 同一内容的往返结果：分隔行变短、<clinit> 被剥
ONLINE_SAME='| 平台 | Issue ID | 标题 | 类型 | 首次纳入 | 处置状态 | 本次状态 | 事件量趋势 | 备注 |
|-|-|-|-|-|-|-|-|-|
| Android | [85c581ed](https://x/issues/85c581edcdb39b941df627e7b1324a71) | [libc.so] | FATAL | 2026-08-20 | 修了仍在 | 🔁遗留 | 3 | 9bbe8b15 fix(ai): teardown |
| Android | [d3675e82](https://x/issues/d3675e8284504c27f6b53d3205a45c32) | SsmlBuilder. | FATAL | 2026-09-28 | 未处理 | 🆕新增 | 2 | — |'
ONLINE_OLD_STATUS="${ONLINE_SAME/修了仍在/已修待验}"
ONLINE_OLD_BADGE="${ONLINE_SAME/🆕新增/🔁遗留}"
# F60：同一批 issue、同样行数，但少一列（表结构变了）
ONLINE_OLD_HEADER='| 平台 | Issue ID | 标题 | 类型 | 首次纳入 | 处置状态 | 本次状态 | 备注 |
|-|-|-|-|-|-|-|-|
| Android | [85c581ed](https://x/issues/85c581edcdb39b941df627e7b1324a71) | [libc.so] | FATAL | 2026-08-20 | 修了仍在 | 🔁遗留 | 9bbe8b15 fix(ai): teardown |
| Android | [d3675e82](https://x/issues/d3675e8284504c27f6b53d3205a45c32) | SsmlBuilder. | FATAL | 2026-09-28 | 未处理 | 🆕新增 | — |'
# NON_FATAL 表只有「处置状态」，没有「本次状态」
NF_LOCAL='| 平台 | Issue ID | 位置 | 异常 | 事件 | 影响安装 | 最新 | 处置状态 | 备注 |
|---|---|---|---|---|---|---|---|---|
| iOS | [9c984b20](https://x/issues/9c984b2039797209105ff961fd18d222) | FIRCLS | avfaudio | 230 | 32 | 10-01 | ⚠️存量待验 | 21ef358b 仅进 1.8.0 |'
NF_ONLINE_SAME="${NF_LOCAL/|---|---|---|---|---|---|---|---|---|/|-|-|-|-|-|-|-|-|-|}"
NF_ONLINE_OLD="${NF_ONLINE_SAME/⚠️存量待验/未处理}"

fp() { printf '%s\n' "$1" | h_run _ledger_fingerprint; }

h_assert_eq "$(fp "$LOCAL")" "$(fp "$ONLINE_SAME")"   "① 同一内容往返（分隔行变短、<clinit> 被剥）→ 指纹相同（⛔ 平稳周不得误替换）"
[ "$(fp "$LOCAL")" != "$(fp "$ONLINE_OLD_STATUS")" ] && r=diff || r=same
h_assert_eq "diff" "$r" "② 只改处置状态 → 指纹必须不同（⛔ 旧指纹判同、更正被丢）"
[ "$(fp "$LOCAL")" != "$(fp "$ONLINE_OLD_BADGE")" ] && r=diff || r=same
h_assert_eq "diff" "$r" "③ 只改本次状态 → 指纹必须不同"
[ "$(fp "$LOCAL")" != "$(fp "$ONLINE_OLD_HEADER")" ] && r=diff || r=same
h_assert_eq "diff" "$r" "④ 表结构变了（少一列）、id 与行数不变 → 指纹必须不同（F60）"
h_assert_eq "$(fp "$NF_LOCAL")" "$(fp "$NF_ONLINE_SAME")" "⑤ NON_FATAL 同一内容往返 → 相同"
[ "$(fp "$NF_LOCAL")" != "$(fp "$NF_ONLINE_OLD")" ] && r=diff || r=same
h_assert_eq "diff" "$r" "⑥ NON_FATAL 只改处置状态 → 必须不同"
h_assert_eq "0:::" "$(fp "")" "⑦ 空输入不报错（取回失败时 _cur 为空，调用方另有判空）"
h_summary
