# scripts/crash-report/ — 源副本（非运行时真相源）

本目录是 git 管理的**源副本**，`setup.sh` 自装时把 `*.sh` / `*.plist` 复制到运行目录
`$CRASH_REPORT_ROOT/bin/`（本机 = `~/gitWorkspace/crash-triage/bin/`）。

**运行时真相源是 `bin/`**（`config.env`、`mcp.json`、plist 指向的脚本、`sql/` 都在那里）。
改脚本行为请改 `bin/`，改完同步回本目录（`cp bin/*.sh bin/*.plist bin/sql/* scripts/crash-report/`），
避免两份副本再次分叉（2026-08-14 评审发现 fetch-snapshot.sh 反引号转义只改了一侧）。

INSTALL.md 装机清单与两个 launchd plist 也以 `bin/` 为准。
