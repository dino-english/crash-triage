## Why

`crash-issue-state-visibility` 归档后，正典里留下一条**标题与正文互相矛盾**的 requirement：

```
### Requirement: issue 开关状态不可得，且必须登记为不可得
⚠️ 本条整体重写：前提已被实测推翻……开关状态经确定性查询**可得**
```

MODIFIED delta 按**标题**匹配 requirement，所以标题原样留了下来，正文里那句
「新条文（标题改为……）」成了一句没人执行的话。

⛔ 这正是 F26「同名不同义」：读者 grep「不可得」会拿到**相反**的结论，
而这条 spec 恰恰是昨天那次订正的对象——一条刚被推翻的论断，标题还在替它说话。

## What Changes

- **RENAMED** 该 requirement 的标题为「issue 开关状态经确定性查询可得，但不得回到只返回 OPEN 的通路」，
  并删掉正文里那句「新条文（标题改为……）」的过渡说明。⛔ 条文与 Scenario 一字不动。

## Non-goals

- ⛔ 不改任何条文内容与 Scenario——本 change 只修标题与一句过渡话，
  **不得**借机调整口径（那会让「纯重命名」的验收标准失效）。
