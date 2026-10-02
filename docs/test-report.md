# 测试报告（GWT ↔ 测试映射）

> PRD §6.1-6.6 共 28 条 GWT（2026-09-26 主代理逐条清点，26 为粗计误差，承接见批记录 §1 追记）。
> 每条 GWT 必须有映射，无映射 = 未测（仓库测试纪律）。验证面取值：`swift test <用例>` ／ 真机验收 ／ CLI 实测。
> App 视图层不在 `swift test` 覆盖内——该面的行如实标「真机验收」，不硬凑自动化测试。
> 本表随审计整改批（台账 #1-#9）初建；真机项由 Agent 于 2026-09-26 实际执行并回填。失败/部分/未安全触发均保留原状，不用「尝试过」冒充通过。

| # | Story | GWT 要点 | 验证面 | 证据 |
| --- | --- | --- | --- | --- |
| 1 | 6.1 | ≤5s 可交互（冷启动首版清单） | swift test ScannerBenchmarkTests · InventoryQueryBenchmarkTests | 1000 skills 冷扫描实测 0.44s ≤ 5s（CI 断言，不达标即红） |
| 2 | 6.1 | 副本 ×3 合并（同名多副本并一条） | swift test ModelsMergeTests | 同名副本合并为一条、落点计数含全部副本 |
| 3 | 6.1 | 系统层拒绝不白屏 | 条件态·不可达（2026-09-25 裁决，见 edge error-permission 行） | — |
| 4 | 6.1 | 降级横幅 + 忽略出口（可逆） | 真机验收 2026-09-27（通过） | `chmod 000` 专用夹具后见「1 个位置未能读取（1 无权限）」及真实路径、忽略出口；忽略后设置页列出已忽略位置并可恢复，恢复权限 755 后重新纳入扫描。 |
| 5 | 6.1 | >3s 增量出结果 + 名称 >40 字 truncate | swift test ScanPublishPolicyTests · 真机验收 2026-09-26（部分） | 慢扫描中先见 707、后见 1,451 项；长名视觉截断且 AX 能读全名。tooltip 未能验证。 |
| 6 | 6.1 | 全盘 0 条目空态（empty-collection） | 未能安全触发（2026-09-26） | 本机清单有千余项；不忽略真实路径来制造全盘空态，故两个 empty-collection 出口未验。 |
| 7 | 6.2 | search→pull 落位 + 落结构化日志 | swift test AssemblyServiceTests · CLI 实测 `skillctl pull <name> --target <项目>` 退出码 0 | pull 产出 WriteOutcome + 装配事件 + 操作日志各一条 |
| 8 | 6.2 | App 未开时 CLI 装配，App 开后 Banner 出现 | 真机验收 2026-09-26 | App 退出时 CLI pull 返回 added=1/eventId；重启后 Banner 有 3 条待验收，详情显示项目落点。 |
| 9 | 6.2 | 冲突行留痕 + 单条重试 | 真机验收 2026-09-26（部分） | 冲突原因显示；占位仍在时重试仅显示通用失败回执、缺具体原因；移开占位后单条重试成功。 |
| 10 | 6.2 | 快照过期禁验收（G3） | swift test BaselineWithCacheTests · 真机验收 2026-09-27（通过） | 加入影响面内 `wt-s6-impact` 后验收禁用并提示清单已更新；「重新加载」刷新 revision，`added/date` 不变，验收按钮放行。 |
| 11 | 6.2 | 关闭=验收 + 显式恢复（AlertDialog） | 真机验收 2026-09-26 | 正常验收事件 accepted；恢复先弹确认且取消无落盘；「保留待验收」和 Esc 后事件仍 pending、Banner 仍待验收。 |
| 12 | 6.2 | 0 增 0 删事实态（empty-assembly） | 未能独立验证（2026-09-27） | A1 失败注入现在显示失败组与权限原因，不再落成 0/0/0 no-op；本轮没有产生一次成功但无新增/移除的正常装配，因此 empty-assembly 仍未独立验证。 |
| 13 | 6.3 | unmount 后生效集合减一（卸下口径 D19=A） | swift test AssemblyServiceTests · CLI 实测 `skillctl unmount <name> --on <agent>` 退出码 0 | 一次卸下清掉该家全部候选目录落点；清单计数随之减一 |
| 14 | 6.3 | 跨 Agent 授权拒绝（写别家目录被拒） | swift test AssemblyServiceTests | 未知 Agent 报 unknownAgent，退出码 69 |
| 15 | 6.3 | 详情栏消失态（error-target-vanished） | 真机验收 2026-09-27（通过） | 移走 `wt-s9-vanish` 实体源后 <1 秒条目消失，详情显示中性「这条目刚刚被移出了清单（日志可查）」且只有「关闭」出口；随后放回夹具。 |
| 16 | 6.3 | 写回失败行内原因（不静默） | swift test AssemblyServiceTests · 真机验收 2026-09-27（部分） | 只读目标下 CLI exit 69、`failed=1`、`logged=true`；Banner/diff 有 muted 失败组和真实权限原因，无 0/0/0 no-op、无误导 no-op 文案、无重试按钮。失败行只显示名称而未显示完整目标路径，见 D42；权限恢复 755。 |
| 17 | 6.3 | 状态原地更新（卸下后徽章即时变） | swift test ScanPublishPolicyTests(removeOnlyOurOwnWrittenItem) · 真机验收 2026-09-27（通过） | 全盘重扫中执行夹具 unmount，约 1 秒内详情由 2 次/2 项目降为 1 次/1 项目；页头数字不缩水，扫描完成后计数未反弹。 |
| 18 | 6.4 | 删除→回收站→一步恢复（磁盘 diff 为空） | swift test RollbackTests · TrashRollbackTests | 恢复往返后磁盘状态 diff 为空（含 symlink 原样重建） |
| 19 | 6.4 | 回收站被 Finder 清空灰态（G7） | 真机验收 2026-09-27（通过） | 移出测试条目 `files/0/wt-a3-archive-missing` 后在场与冷进入均禁用恢复并显示目标缺失提示；归档放回后恢复按钮重新启用。 |
| 20 | 6.4 | 磁盘满升级确认（→本批 #1） | swift test DiskSpaceDecisionTests · IrreversibleDeleteFlowTests · 真机验收 2026-09-27（通过） | 直接 exec Debug 主二进制并注入 `SKILLCTL_FAKE_FREE_BYTES=0`；精确输入 `wt-b1-irreversible-delete` 后真实点击「仍然删除」。回执为磁盘满不可恢复；夹具消失、日志 `reversible:false`、无回收站条目。另测 Esc 取消无磁盘/日志/回收站变化；去掉环境变量后普通删除进回收站且恢复成功。 |
| 21 | 6.4 | 部分恢复如实报（G4） | swift test RollbackTests · 真机验收 2026-09-27（通过） | 既有占位冲突观察到 0/1 及占用原因，移开后重试 1/1；本轮多落点夹具包含实体源与两个项目 symlink，删除回执/manifest 覆盖 3 处，恢复 3/3 后源哈希与链接目标不变、磁盘状态回到操作前。 |
| 22 | 6.4 | 无变动空态（回退页 empty-log） | 真机验收 2026-09-26 | 隔离空日志与回收站后，显示「近 30 天没有任何删除与挂载变动」；测试数据已恢复。 |
| 23 | 6.5 | 账本起点说明（empty-first-day） | 真机验收 2026-09-26 | 注明快照来自 17:39 扫描、统计单位为去重条目数；夹具改变展示总数，不与无夹具基线比较。 |
| 24 | 6.5 | 触发词重叠并列（triggerOverlapWith） | swift test ModelsMergeTests | 1:1 模型字段保留；并列展示不排序好坏 |
| 25 | 6.5 | 全页零观点检查（无推荐/评分/建议删除） | 真机验收 2026-09-27 | 检查到的清单、详情、挂载账、回退、设置、授权与 diff 页面均为中性事实/徽章，无推荐、评分或「建议删除」文案；纯 MCP `skill-b-space` 详情无删除按钮并显示 story-6 写侧提示，D38 关闭。 |
| 26 | 6.6 | MCP 写回保格式 + 备份 | 未测——story-6 写侧未开工（边界裁决：本工具拿不到的不做） | — |
| 27 | 6.6 | 同 server 两处配置并列 | 未测——story-6 写侧未开工（同上） | — |
| 28 | 6.6 | JSON 非法中性态 | 未测——story-6 写侧未开工（同上） | — |

## 诚实边界

- **26-28（6.6 MCP 写侧）**：story-6 未开工是合同内的边界（PRD §8 阶段划分：等 R1 回填由人决定），不是漏测。
- **条件态行（#3）**：error-permission 已裁决为条件态（2026-09-25，智昊拍 B），不可达故无验证路径。
- **真机记录纪律**：App 侧视图不在 swift test 覆盖内；本轮已尝试执行待测项，证据列按事实记录通过、部分、失败或未能安全触发，未将尝试本身写成通过。
- **#20 双栏证据**：磁盘满是 Core 纯函数表（DiskSpaceDecisionTests）+ DEBUG 环境变量注入真机链路两栏都填——纯函数证明判定，注入链路证明交互。
