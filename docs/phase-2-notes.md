# Phase 2 Notes · CLI + 回滚底座 + 验收面

- 时间：2026-09-20
- 分支：`dev/phase0-recon`
- 状态：**实现完成 + 真机验收通过，停此等闸门**（Phase 2 三块全落地）

---

## 做了什么（严格按"先底线件、再写操作"顺序）

### ① 回滚底座（先于任何写操作）

- **WriteLock**：进程内 `NSRecursiveLock`（同线程可重入、多线程互斥）+ 跨进程 `flock`（fd 只开一次）。修掉第一版"每次 lock 新开 fd → 自死锁"。
- **OperationLog**：JSONL 追加式；恢复不覆盖原记录，追加事件闭合审计链（`restored` 由链条推导）。
- **TrashManager**：实体目录入回收站、symlink 只删链接（C3）；一步恢复磁盘 diff 为空；G4 部分恢复如实报 N/M 且保留可重试；G7 被 Finder 清空 → `isRestorable=false`。

### ② skillctl 写侧（story-2/3）

- `AssemblyService`：`search/info/pull/mount/unmount`，写锁内落位，默认相对 symlink（`--copy` 可选），目标已存在 → `skipped-conflict` 不覆盖。
- 卸载 ≠ 删除：symlink 落点只删链接；条目本体所在落点**拒绝卸下**并指向删除（不静默半成功）。
- 每次写落结构化日志 + 装配事件（含清单 `revision`）。
- CLI 输出 JSON 面向 Agent；退出码 0/64/69。

### ③ 验收面（story-2 diff）

- **Banner 三态**（项目视角顶部，全中性色）：未验收（bg-muted 实底 + "查看装配记录"）/ 已验收（半透明 + "回看"）/ 已恢复；empty-assembly 事实态"检查过了，没带来新东西"。
- **diff Sheet 520**：三组分区（挂上/卸下/跳过）；冲突行内留痕 + 单条重试（重试成功/仍败两态文案，不红）；关闭=验收（裁定①）；全部恢复原状 → confirmationDialog（story-4 GWT 文案逐字）；恢复中 loading 不可关闭（G4）；>10 项折叠 + "展开全部 N"（boundary-huge-diff）。
- **G3**：验收期间清单变化 → 顶部"清单已更新·重新加载"，重载前禁用「关闭并验收」。

## 真机验收（Computer Use，浅色外观）

授权 → 按项目视角 → Banner「未验收」→ 打开 diff → 关闭并验收 → Banner「已验收 · 回看」。**过程中抓出并修复一个真 bug**：

- **revision 跨进程不稳定**：`AssemblyService.revision` 原用 Swift `hashValue`，而 hashValue 每进程随机加盐 → CLI 写入的事件版本永远 ≠ App 计算的版本 → diff 一打开就误报"清单已更新"、永久禁用验收。改用 FNV-1a 64（跨进程确定），补"跨实例 revision 一致"回归测试。

## 测试

32 测试全绿（新增 AssemblyReviewTests：accept 不动磁盘 / restore 往返卸落点+置 restored+落日志 / revision 驱动过期 + 跨实例稳定）。三 target build/test 全绿。

## 待裁决 / 遗留

| # | 事项 | 建议 |
| --- | --- | --- |
| D7 | `AssemblyEvent.removed` 恒为空（当前 unmount 不产 removed 列表）| story-3 全量"卸下→可回挂"时回填；MVP 装配 diff 以 added+conflicts 为主，符合 story-2 GWT |
| D8 | Banner 只显 assemblyEvents.first（最新一条）| 多项目并发装配时是否要"聚合 Banner（N 项目 M 项待验收）"？建议 story-5 挂载账阶段一并定 |
| D9 | ✅ 已真机验收：diff→全部恢复原状→确认→磁盘落点卸下·源完好·日志「1/1 回位」·Banner 转「已恢复」 | 关闭 |

## 下一步

Phase 2 三块（回滚底座 + CLI + 验收面）齐。按 PRD §8.1，**先做 Phase 3 验证环**（5 行采集表 + dogfooding 周计划），再谈 story-3 全量/story-5 挂载账/story-6 MCP 写侧——等 R1 回填由人决定。
