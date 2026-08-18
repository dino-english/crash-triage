## D1 运行根用 `BASH_SOURCE` 自解析，不用 `$HOME` 默认值

```bash
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export CRASH_REPORT_ROOT="${CRASH_REPORT_ROOT:-$(dirname "$SELF_DIR")}"
```

一条规则同时覆盖三种布局，不需要分支判断（实测验证）：

| 怎么跑 | 解析结果 |
|---|---|
| 仓库里跑 `bin/crash-daily.sh` | 运行根 = 仓库根 |
| 老式独立安装 `~/crash-triage/bin/crash-daily.sh` | 运行根 = `~/crash-triage`，行为不变 |
| cron / plist 显式设 `CRASH_REPORT_ROOT` | 环境变量优先 |

因此改动向后兼容：只改默认值，不改任何已显式配置的行为。

## D2 状态目录默认走 XDG，而不是仓库子目录

状态必须落在某个绝对路径上，问题只是「谁来定」。选 `${XDG_STATE_HOME:-$HOME/.local/state}/crash-triage`：这是 Unix 下用户级常驻任务的通行位置，`$HOME` 由环境给出、不是写死在脚本里。

不选「仓库子目录 + gitignore」的理由是具体的：`git clean -xfd` 会连同被忽略的文件一起删。逐个看后果——`config.env` 重跑 setup 即可、`metrics-history.jsonl` 一周长回来、`daily-snapshot.json` 次日恢复、`last-snapshot.json` 丢了会把下周所有 issue 报成新增（一周后自愈）。**唯一不可再生的是 `weekly-index.jsonl`**（历次周报的飞书文档 URL，飞书端无法枚举本 bot 文档）。

## D3 `weekly-index.jsonl` 反向进 git，而不是留在状态目录

它性质上不是运行缓存而是持久档案，和 `LEDGER.md` 同类。放进 `reports/` 并纳入版本控制后，D2 的唯一残余风险被堵掉，其余状态可以放心当作一次性数据。

## D4 plist 用占位符模板，生成物落在状态目录

launchd 不展开 `$HOME` 或变量，plist 里必须是绝对路径。折中：仓库存 `__ROOT__` / `__STATE__` 模板，`setup.sh` 按本机实际路径生成到 `$STATE/`。既保证换机器只要重跑 setup，又避免把带本机路径的脏文件写回仓库。

## D5 删双副本，而不是继续靠纪律同步

`scripts/crash-report/` 的存在前提是「源在 git、运行在别处、setup 负责搬运」。运行根改成仓库自己之后这个前提消失，`setup.sh` 里的 cp 分支变成死代码（`[ "$SRC_DIR" != "$ROOT/bin" ]` 恒假）。

保留的成本是实打实的：每次改动手工双改 + `diff -rq` 核对，已经出过两次分叉。失去的只有 INSTALL.md 里「只 scp 脚本目录过来」这一条路径——而那台机器要拿更新本来就得有 git，需要离线分发时 `tar czf x.tgz bin/` 一条命令即可。

## D6 投递用 lark-cli 而不是 LLM agent

投递四步——导入文档、拿 URL、回填占位符、发卡片——没有一步需要判断力。用 agent 的代价已经登记在案：重复投递、可能改写卡片数字（所以卡片 JSON 里到处写着「agent 原样投递禁止改写」）、以及为兜住这些而设计的整套投递幂等台账。

`lark-cli im +messages-send --idempotency-key`（max 50 字符，`run_id` 正好）原生解决重复投递。台账、`card_sent` 闸门、同日补投策略随之全部不需要。

**L2 的 triage agent 保留**：读事件、推根因、写修复方案是真的 LLM 活。区分标准是「有没有判断」，不是「是不是自动化」。

## D7 投递顺序与失败语义

顺序不可换：导入日报 → 导入台账镜像 → 回填索引页的两个 URL → 导入索引页 → 回填卡片的两个 URL → 发卡片。占位符必须在导入前填好，因为 `drive +import` 只能新建不能覆盖。

周报的归档追加必须在**卡片发出之后**：先追加再发的话，发送失败会在索引里留下一条指向「已投递报告」的假记录。

生成与投递分成两个脚本、串行调用，投递失败不改变生成脚本的退出码——数据已落盘，重跑 `deliver.sh` 补投即可，幂等键保证不会发出第二张卡片。

## D8 陈旧 manifest 闸门

`deliver.sh` 读的是「上一次生成留下的」manifest。脚本失败时不会重写它，照投就会把昨天的卡片当今天发出去——正是这套系统最该避免的静默错误。manifest 增加 `day` 字段，不等于今天就拒投并报错。宁可不投让人来看，也不投错。
