# 清单筛选与挂载可观测整改（2026-09-21）

> 触发：智昊要求「清单里要能直观看到我装了几个 Skill、分别被装了多少次、在不同项目里被 symlink 了多少遍」，
> 并指定筛选器链顺序 = 类型 → 可激活产品 → 用户级/项目级。
> 本文档记录改法、口径、真机结果、以及两处需要人裁决的遗留问题。

## 1 · 改了什么

| 位置 | 改前 | 改后 |
| --- | --- | --- |
| 一级筛选 | 类型分段含「全部」混合态 + 视角切换（按 Agent/项目/层级） | 类型分段只有 Skill / MCP（默认 Skill）；**视角切换退役**，由筛选器链 + 表头排序承担 |
| 筛选器链 | 无 | 类型 → 可激活产品（多选，带每家挂载数、按规模降序）→ 层级（全部/用户级/项目级）→ 搜索 |
| 汇总条 | 「N Skills · M MCP · K Agents」 | 「共 1970 个 Skill · 被挂 3079 次 · 落点 5049 处 · 跨 37 个项目」（跟随当前筛选） |
| 表格列 | 名称 / 归属 / 挂载于 / 落点（1 个数字） | 名称 / 归属 / 可激活于（前 1–2 家 + N 家）/ **挂载（N 次）** / **项目（N 个）** |
| 排序 | 固定按名称 | 表头可点：名称 / 挂载 / 项目，再点翻转升降；数量列默认降序 |
| 详情栏落点 | 源路径 + 一串标「（副本）」的路径 | 按「用户级 / 每个项目 / 其他位置」分组，逐条标性质（实体源 / 实体副本 / symlink / 配置项）+ 归属 + 路径，symlink 额外显示指向 |

代码落点：`InventoryIndex.swift`（MountSpot / MountTotals / MountStat / filtered 排序 / summary / agentCounts）、
`AppState.swift`（typeFilter / agentFilter / levelFilter / sortKey / sortAscending / toggleSort）、
`InventoryView.swift`（筛选器链 / 可排序表头 / 行内两列）、`DetailPanel.swift`（落点分组）。

## 2 · 口径（定稿）

**挂载次数 = 该条目落在某个 Agent 挂载目录里的落点数。**

- symlink 引用（在某家 skills 目录下）：算 1 次。
- 实体目录（在某家 skills 目录下，含被选为"实体源"的那一份）：算 1 次——那一家确实装着它。
- 归不到 Agent 的位置（别的 skill 内部的同名子目录、未分类角落）：**只算落点，不算挂载**。
  这条是 D10 的裁决（智昊选 A）。不这么定的话 `references` 会显示「被挂 26 次」，
  而 26 处里只有 1 处真在某个 Agent 的 skills 目录下。
- 源在共享目录（`~/.agents/skills` 这类无 Agent 归属的存放地）且无人引用 → 挂载 0 次 + 「从未挂载」徽章，
  这就是最初确认的"孤本 = 0 次"语义，保留不变。
- MCP：每处配置声明都归属一家产品，因此「被挂 N 次」恒等于「落点 N 处」。

两条口径互相校验的等式（真机自洽检查）：`可激活于家数 ≤ 挂载次数 ≤ 落点数`。
之前那版把"实体源本身"一律排除，会出现「可激活于 workbuddy · 挂载 0 次」这种自相矛盾的行，已废弃。

**落点数** = 条目在盘上出现的总次数（含实体源与一切未识别位置），详情栏标题与「副本 ×N」徽章都用它，
避免同一屏出现两套数（原「副本 ×N」取 `duplicates.count + 1`，会把 symlink 的解析目标也计进去，
与落点数不一致——现改为同源 `MountTotals.locations`）。

> **口径变更声明**：本次行内那个数字的定义换了两轮（落点 → 引用数 → Agent 目录内落点数），
> 是**度量口径变化，不是成果**。此前所有以「落点」为口径记录的清单数字（含 R1 采集表与 phase notes 里的计数）
> 与新数字**不可比**，不做前后对比；R1 基线自本次起按新口径重测。

## 3 · 真机验收（2026-09-21，本机）

- 冷启动授权 → 首屏秒出（发现缓存命中）→ 后台全盘发现校核期间 UI 可点、可排序、可切类型（CPU 33–55%，走查全程无卡顿）。
- 全量：1970 Skills / 510 MCP / 76 Agents / 44 项目 / 落点 5049 处 / 被挂 5049 次 / 跨 37 项目。
- 表头点「挂载」→ 降序：`dbs-xhs-title 57 次 · 2 个项目 · Codex +50 家` 置顶 ✓
- 产品菜单带数并按规模降序：Codex · 908 / workbuddy · 818 / Claude Code · 169 / QoderWork · 84 ✓
- 切 MCP + 项目级：26 个 MCP · 被挂 37 次 · 跨 4 个项目 ✓
- 详情栏（github）：「落点 27 处 · 挂载 26 次 · 跨 5 个项目」→ 用户级 · 18 处 / client-a · 2 处 /
  agent-x · 1 处 / agent-x · 1 处 / 其他位置 · 3 处，每条标性质与归属 ✓

**但 D10=A 落地后立刻发现它不解决问题**：本机「被挂 5049 次」与「落点 5049 处」完全相等，
因为所有落点都归得到某家 Agent。真正的噪声不在"归不到 Agent"，而在条目本身就是假的——见 §5 D12。

## 4 · 踩到的两个坑（已修，留此备忘）

1. **渲染热路径打满主线程**：第一版把 `MountStat`（含 `[MountSpot]`）直接用于排序比较器与行内取数，
   `projectIds` 又是每次访问重建 `Set` 的计算属性。真机 1970 条目时 `sample` 显示主线程 100% CPU 全在
   SwiftUI `updateGraph`，清单点一下要卡几十秒。
   修法：重建时算一次 `MountTotals`（三个 Int）存字典，行内/排序只读它；`filtered` 排序前先物化排序键，
   比较器里不再查聚合。`spots` 只留给详情栏按单条查询。
2. **每屏重复全量聚合**：`filteredItems` / `agentCounts` 写成计算属性后被汇总条、表格、产品菜单各算一遍。
   修法：`body` 顶部算一次，作为参数往下传。
   红线测试：`Tests/SkillControllerTests/InventoryQueryBenchmarkTests.swift`（2000 条目 × 25 落点，
   12 屏查询 + 汇总 + 产品计数 < 3s；实测 ~0.4s）。

## 5 · 裁决与遗留

**D10 · 非 Agent 位置的副本是否计入「挂载次数」→ 选 A：不计。已实现，但真机证明它不解决目标问题。**
实现：`MountStat.init` 里 `mounts` 只累加 `agentId != nil` 的落点。
连带修正：实体源若在 Agent 目录内则计入（否则会出现「可激活于 1 家 · 挂载 0 次」的自相矛盾行），
共享目录里的孤本仍为 0 次。红线测试：`unclassifiedCopyCountsAsLocationNotMount`、
`sharedSourceAloneIsZeroMounts_agentDirSourceIsOne`。
**结果**：本机 `mounts == locations`（5049 == 5049）——所有落点都归得到 Agent，A 是空转。

**D11 · 产品菜单里的可疑"产品"（venv / github / agent / box-agent）→ 选 C：不动，等 dogfooding 反馈。**

**D12 · 新发现（待裁决）：深层模式把 skill 的文档目录当成了独立 skill**
证据（本机实测）：`~/.workbuddy/connectors-marketplace/connectors/<name>/skills/` 里
直接放着 `SKILL.md` + `references/` + `scripts/`——也就是说 `skills/` 本身就是那一个 skill。
而扫描器的深层模式（D6 为 QoderWork 插件 `plugins/*/skills/<skill>` 加的两层结构）
会把 `skills/` 的每个子目录都当成一个 skill，于是 `references`、`scripts` 变成条目：
- 该市场下 136 个 connector 的 `skills/` 自带 SKILL.md（真 skill）
- 其中 39 个子目录（`references/` `scripts/` `assets/` `templates/` `examples/`）被误判成 skill
- 清单里因此出现 `references`（27 处、"被挂 27 次"）、`scripts`、`__pycache__`、`LICENSE` 同级目录等假条目
  它们各自都归得到 Agent，所以 D10=A 拦不住；它们也是"1970 Skills"这个总数虚高的主要来源之一。

建议修法（一处判定，风险可控）：深层模式下先看 `child/skills/SKILL.md` 是否存在——
存在则把 `child/skills` 整体当一个 skill（名字取 connector/plugin 名），不再枚举其子目录；
不存在才按现在的两层模式枚举。通用化版本是：**没有 SKILL.md 的目录不成为 skill 条目**。
影响面：条目总数与所有以"条目数"为口径的数字都会下降 → 属口径变更，需标注旧计数作废。

## 6 · 对既有裁定的影响

- D3（消失态 actor 日志回填）不受影响。
- **D6（插件 skills 深层计入）需要修正**：当时为了把 QoderWork 插件里的真 skill 收进来加了"两层结构"模式，
  但这条规则对 `connectors/<name>/skills/` 这种"skills 目录本身就是 skill"的布局会误伤，
  把 `references/`、`scripts/` 收成条目（见 §5 D12）。D6 的意图不变，判定条件要收紧。
- `duplicates` 字段仍按原语义填充（`TrashManager` 删除全部落点依赖它），未受本次改动影响。
- types.ts 统一数据模型**未增删字段**：新增的 `MountSpot` / `MountTotals` 是索引层的派生聚合，不进 `InventoryItem`。
- 文案新增待确认项（照 §3 硬规则 3 需过一遍）：「被挂 N 次」「挂载」「项目」「实体源」「实体副本」「配置项」「其他位置」「+N 家」「目录名」。
