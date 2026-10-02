# Edge States — 本地 Skill 管理工具（Skill 控制器）

- 生成时间：2026-09-19T07:24:17Z
- 屏数：9｜状态：25（must 14 / 条件态 1 / should 7 / nice 3；条件态=error-permission，2026-09-25 裁决改判）｜离线类 N/A（纯本地 App）
- 文案口径：只报总量不报风险；中性色默认，destructive 红全应用仅 error-disk-full 一处；工具拿不到的不做（账本起点诚实态）；空态四型分开：首次/搜索/过滤/数据起点


## 关键缺失（G1-G8）

- **G1** Inventory 降级横幅缺『忽略此位置』出口
- **G2** ItemDetail 并发消失态未设计
- **G3** AssemblyDiff 验收期间清单再变化无并发提示
- **G4** RestoreConfirm loading 与部分恢复失败态缺位
- **G5** 磁盘满→回收站失效→删除不可逆（唯一 destructive 场景）
- **G6** Ledger 数据起点诚实态缺位
- **G7** 回收站被 Finder 清空后的二次删除灰态
- **G8** 卸下/回挂提交态与状态即时更新

## 状态矩阵


### DiskAccessGate (F1-S1)（overlay-disk-auth）

| 状态 | sev | 设计描述 | 用户出口/行为 | 文案 |
| --- | --- | --- | --- | --- |
| loading-submit | must | 「授权并扫描」按下：按钮 disabled+spinner，文案「正在建立索引…」；期间 Dialog 其余控件不可交互 | 防重复触发；索引后台继续 | 正在建立索引… |
| error-permission | 条件态（2026-09-25 裁决，智昊拍 B） | 触发条件当前不存在：非沙箱 App 读点目录无 TCC 门槛（Phase 0 spike 实证，docs/agent-recon.md），工具亦不读会话日志；将来进入沙箱或新增受系统权限保护的读取面时恢复 must，并按原规格实现（中性说明行 + 深链按钮 + 返回自动重试；文案「系统还没放行 · 在系统设置中允许后会自动重试」） | 不可达，无出口 | — |

### Inventory (F1-S2)（page-inventory）

| 状态 | sev | 设计描述 | 用户出口/行为 | 文案 |
| --- | --- | --- | --- | --- |
| loading-initial | must | 分层加载：<1.5s 用 8 行 Skeleton；>3s 切「增量优先」——先出已扫到位置的结果，其余静默并入，页头计数提示「索引持续更新中」 | 不干等；新条目并入不打乱滚动位置 | 973 Skills · 索引持续更新中 |
| empty-collection | must | 授权成功但全盘 0 条目（新机器）：居中卡+解释+两出口（查扫描范围/等 Agent 首次装配） | 知道不是坏了而是真没有 | 这台机器还没有 Skill。装配是你未来 Agent 的事，也可以先检查扫描范围 |
| empty-filter | should | 对象过滤（MCP）后为 0：不复用搜索空态文案，出口「恢复全部对象」 | 一键回全量 | 没有 MCP。恢复全部对象看看 |
| error-partial-degrade | must | （已实现横幅）补出口：每行可「忽略此位置」，忽略后不再每日提示，设置页可逆 | 降级信息不升级为每日噪音 | 忽略此位置（可在设置中恢复） |
| error-disk-full | must | 磁盘满致回收站写不进——全应用唯一允许 destructive 红的场景：删除确认升级「无法移入回收站，此删除不可恢复」+ 键入名称确认 | 不可逆事实如实告知 | 磁盘空间不足，该条目将无法恢复。确认仍要删除？ |
| boundary-long-text | must | 名称>40字/描述>80字：truncate + tooltip 全文 | 不破行高 | — |
| boundary-overflow | nice | 计数≥1000 显示 1.2K 缩写 | — | 1.2K |

### ItemDetail (F1-S3 共享)（page-item-detail）

| 状态 | sev | 设计描述 | 用户出口/行为 | 文案 |
| --- | --- | --- | --- | --- |
| error-target-vanished | must | 面板开着时条目被另一 Agent CLI 移走/删除：内容替换为中性说明+唯一出口「关闭」；清单行同步消失 | 不展示幽灵数据不报错 | 这条目刚刚被 Claude Code 移出了清单（日志可查） |
| loading-submit | must | 卸下/回挂：按钮 loading→成功后徽章与时间线即时更新（修 check Minor#3） | 状态原地更新，不止 toast | 卸下中… |
| boundary-null | should | description 缺失显示「SKILL.md 未写描述」，不显示空/undefined | — | SKILL.md 未写描述 |

### ProjectBanner (F2-S1)（page-inventory#banner）

| 状态 | sev | 设计描述 | 用户出口/行为 | 文案 |
| --- | --- | --- | --- | --- |
| empty-assembly | nice | CLI 跑了但 0 增 0 删：Banner 如实一句「Codex 检查过了，没带来新东西」 | 事实陈述非错误 | 检查过了，没带来新东西 |

### AssemblyDiff (F2-S2)（overlay-assembly-diff）

| 状态 | sev | 设计描述 | 用户出口/行为 | 文案 |
| --- | --- | --- | --- | --- |
| error-concurrent-change | must | diff 展示期间清单又变：顶部中性提示「清单在你验收期间又变了 · 重新加载」，重载前禁用「关闭并验收」防旧快照验收 | 避免对旧状态验收 | 清单已更新。重新加载后再验收 |
| retry-failed-again | should | 冲突行重试仍败：行文案转「重试未成功 · 已记入日志」+日志入口，不加红 | 失败不吞不放大 | 已记入日志，可稍后再来或直接处理 |
| boundary-huge-diff | should | 单次装配>30 项：分组折叠前 10 +「展开全部 N」；验收粒度仍支持单条 | 千级世界不爆炸 | 展开全部 80 项 |

### RestoreConfirm (F2-S4)（overlay-restore-confirm）

| 状态 | sev | 设计描述 | 用户出口/行为 | 文案 |
| --- | --- | --- | --- | --- |
| loading-submit | must | 「确认恢复」按下：按钮 loading「恢复中…」，期间不可关闭 | 防中断回滚 | 恢复中… |
| error-partial-restore | must | 部分条目恢复失败（目录被占）：结果态如实「3/5 项已恢复 · 2 项未能恢复（已记日志）」+日志跳转；Banner 进「部分恢复」三态 | 底线承诺失败也诚实 | 未能恢复的 2 项保留在日志中，可重试 |

### 回退页（占位·规范先行）（page-rollback）

| 状态 | sev | 设计描述 | 用户出口/行为 | 文案 |
| --- | --- | --- | --- | --- |
| empty-log | must | 无任何变动：「近 30 天没有任何删除与挂载变动」——不是「暂无数据」 | 空也是事实 | 近 30 天没有任何变动 |
| error-second-delete | must | 回收站条目被 Finder 清空：恢复按钮置灰+行内「目标已不存在」；日志保留仅审计 | 恢复按钮不撒谎 | 目标已不在回收站，无法恢复 |
| boundary-long-log | should | >200 条日志：按日分组折叠+虚拟列表 | 千级可浏览 | — |

### 挂载账页（占位·规范先行）（page-ledger）

| 状态 | sev | 设计描述 | 用户出口/行为 | 文案 |
| --- | --- | --- | --- | --- |
| empty-first-day | must | 数据起点诚实态：「账本从 2026-09-19 开始记录，此前的挂载无从得知」防误读零频 | 零幻觉口径落点 | 以下数字只反映安装之后的挂载 |
| boundary-sparse | should | 记录<7 天：表头注「仅 5 天数据」，不做高低暗示 | — | 仅 5 天数据 |
| loading-aggregate | nice | 90 天聚合本地 <200ms 可不做加载态 | — | — |

### 设置页（规范先行）（page-settings）

| 状态 | sev | 设计描述 | 用户出口/行为 | 文案 |
| --- | --- | --- | --- | --- |
| error-validation | should | 扫描路径不存在：字段下 inline 中性提示「该路径不存在，已跳过保存」实时提示 | — | 该路径不存在 |