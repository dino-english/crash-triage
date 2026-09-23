## 1. 重命名

- [x] 1.1 RENAMED：标题改为「issue 开关状态经确定性查询可得，但不得回到只返回 OPEN 的通路」
- [x] 1.2 删掉正文里「新条文（标题改为……）」那句过渡说明
- [x] 1.3 ⛔ 条文与全部 Scenario 逐字不变
      → verify：归档后 `git diff` 里除标题行与那句过渡话外无其他改动

## 2. 验收

- [x] 2.1 `openspec validate --strict` 通过
- [x] 2.2 归档后 `grep -n '不可得' openspec/specs/crash-source-bigquery-migration/spec.md`
      只剩正文里讲「原条文曾断言不可得」的历史陈述，⛔ 标题里不得再有
