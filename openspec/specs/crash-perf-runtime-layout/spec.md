# crash-perf-runtime-layout Specification

## Purpose

定义运行时布局契约：路径如何解析（不写死绝对路径）、代码与可变状态如何分开放置、哪些运行产物必须进版本控制。

## Requirements

### Requirement: 路径自解析

脚本 SHALL 按自身位置解析运行根，MUST NOT 依赖写死的绝对路径默认值。

#### Scenario: 默认运行根

- **WHEN** 未设置 `CRASH_REPORT_ROOT`
- **THEN** 运行根 MUST 解析为脚本所在 `bin/` 目录的上级
- **AND** MUST NOT 回落到任何写死的路径（如 `$HOME/crash-triage`）

#### Scenario: 显式配置优先

- **WHEN** cron / plist 显式设置了 `CRASH_REPORT_ROOT`
- **THEN** MUST 以该值为准

#### Scenario: 业务仓库位置探测

- **WHEN** 未设置 `REPOS_ROOT`
- **THEN** MUST 优先使用运行根的同级目录（若其中存在业务仓库的 `.git`）
- **AND** 探测不到时 MUST 回落到 `$ROOT/repos` 隔离 clone
- **AND** MUST NOT 写死任何具体工作区目录名

#### Scenario: launchd plist 生成

- **WHEN** 安装定时任务
- **THEN** 仓库中 MUST 只存带占位符的 plist 模板
- **AND** 实际 plist MUST 由安装脚本按本机路径生成到状态目录
- **AND** MUST NOT 把含本机绝对路径的 plist 写回仓库

### Requirement: 代码与状态分离

代码与可变运行数据 SHALL 分处两个根，可变数据 MUST NOT 落在仓库目录内。

#### Scenario: 状态目录默认位置

- **WHEN** 未设置 `CRASH_REPORT_STATE_DIR`
- **THEN** 状态根 MUST 为 `${XDG_STATE_HOME:-$HOME/.local/state}/crash-triage`

#### Scenario: 哪些落状态根

- **WHEN** 脚本产出日志、生成的日报周报、快照、天级历史、投递中间产物、本机 `config.env`
- **THEN** 这些 MUST 落在状态根
- **AND** 跑完一轮后仓库 MUST NOT 出现新增的运行时文件

#### Scenario: 不可再生产物入库

- **WHEN** 产出周报归档索引（历次周报的飞书文档 URL）
- **THEN** MUST 写入仓库内的 `reports/weekly-index.jsonl` 并纳入版本控制
- **AND** MUST NOT 只存在于状态根（飞书端无法枚举本 bot 文档，丢失即永久断链）

### Requirement: 单一脚本副本

仓库 SHALL 只保留一份脚本，MUST NOT 维护需要人工同步的第二份拷贝。

#### Scenario: 无源副本目录

- **WHEN** 修改任一脚本
- **THEN** MUST 只有一处需要改动
- **AND** 安装流程 MUST NOT 依赖「把脚本复制到另一个运行目录」
