## 1. 合并逻辑

- [x] 1.1 `crash-weekly.sh` 的 `$REPORT` 生成块末尾增追加段：`ANALYSIS_OK=1` 且 `$TRIAGE_REPORT` 非空时，打印 `## 分析层 · 根因分析（模型产出，**未经人工复核**）` 后接 triage 正文
- [x] 1.2 追加时用 awk 丢弃 triage 的**第一行 h1**，其余行原样。⛔ 标题层级零改动（design D2）
- [x] 1.3 投递分支由二选一改为单分支：`REPORT_FILE` 恒指向 `$REPORT`；删除 `if [ -s "$TRIAGE_REPORT" ]` 分支
- [x] 1.4 改写该处注释——原注释只解释了「为什么平稳周也要建文档」，需补上「为什么不再二选一」

## 2. 不变量确认

- [x] 2.1 `split-fix-list.py` 在合并后的文件里正常定位并分组（08-20 真 triage + 08-23 真数据层周报，rc=0，修复清单段被拆成 iOS / Android / 通用三组）
- [x] 2.2 `md2docx.py` rc=0、stderr 空，产出 40,284 字符 XML；h1 恰好 1 个，`## 四、修复清单` 仍是二级
- [x] 2.3 缺分析路径产物与改动前**逐字节一致**（冻结缓存，改前 W0 / 改后 W1 同缓存重放，三层产物各 11/8/35 项，`diff -r` 为空）

## 3. 静态检查

- [x] 3.1 `bash bin/check-scripts.sh` 七项通过

## 4. 跑批验收

- [x] 4.1 ⚠️ 先备份 `$STATE/last-snapshot.json`（L2 基线提升在 NO_DELIVER 闸门之前）
- [x] 4.2 `CRASH_REPORT_SKIP_ANALYSIS=1 CRASH_REPORT_NO_DELIVER=1` 整跑两轮，rc 均为 0，见 2.3
- [x] 4.3 含分析的整跑（NO_DELIVER）rc=0：weekly.md 23,852 字节 / weekly.xml 35,199 字符，h1 恰好 1 个，数据层六项关键词命中数 5/1/3/2/2/1（改前有分析的周全为 0），运行日志含「✅ 修复清单已按平台分组」。⚠️ **本轮实测撞号**：triage 自己写出 `## 六、修复清单`，与初版插入的「## 六、根因分析」重号 → 标题改为不带序号的「## 分析层 · 根因分析」，重验 split rc=0 / md2docx rc=0（35,449 字符）
- [x] 4.4 `baseline.sh` 的快照回滚协议已自动还原，与手工备份逐字节一致，备份已删除

## 5. 文档

- [x] 5.1 `docs/CLAUDE-架构与数据口径.md` 记一条：周报文档 = 数据层主干 + 分析层追加段，不是二选一
