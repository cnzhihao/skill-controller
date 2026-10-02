# 扫描范围整改：从硬编码注册表到全盘发现

日期：2026-09-20 · 触发：智昊真机使用反馈 · 状态：已实现 + 真机验收通过

## 1 · 问题

设置页的「扫描范围」是硬编码注册表（`ScopeBuilder.defaultScope`）：把 `~/.codex/skills`、
`~/.claude/skills`、`~/.qwenworkcn/skills`、`~/.cursor/skills`、`~/.agents/skills`、
`~/.qwenworkcn/plugins` 六个位置写死，项目级则从 `~/.claude.json` 的 `projects` 键推导。

后果有两个，智昊原话是「完全没达到我想要的效果」：

1. **大量「该路径不存在」的空行**——注册表不管存不存在都塞进 `locations`，设置页照着全列。
2. **看不见真实的散落 Skill**——本机实际有几百处 skills 目录属于注册表完全不知道的
   工具（devin / goose / junie / openhands / trae / windsurf / grok / hermes / zcode /
   box-agent / workbuddy / codebuddy / lingma / roo / kilocode …）。产品最初的痛点正是
   「归属不明」，而注册表把归属写死成了 4 家。

## 2 · 决策（智昊裁决）

| 决策点 | 结论 |
| --- | --- |
| 扫描边界 | 全盘跑（从 `/` 开始），遍历时避开 node_modules，剩下的都要跑 |
| 层级判定 | home 直属 = 用户级，其余向上找 `.git` 定项目根 |
| 未知归属 | 直接用父目录名：`~/.thincoder/skills` → 归属 `thincoder` |
| MCP 对象 | 一起发现，按文件名扫 MCP 配置 |
| 噪音处理 | 剪掉 `.cache` / `Library` / `*.app` 包内 / `builtin`（只留真实挂载位） |
| 首屏策略 | 分层：home 先出 → 全盘后台续 → 结果缓存 |

## 3 · 本机实测数据

整改前先用 `find` 量过成本，这组数字决定了架构：

| 测量项 | 未剪枝 | 剪枝后 |
| --- | --- | --- |
| 遍历到的目录数 | 443,098 | 81,204 |
| 全盘发现耗时 | ≈3 分钟 | **44 秒** |
| 发现的 skills 目录 | 1,018 | 748 |
| 这些目录里的条目 | 6,557（4,650 个带 SKILL.md） | — |
| 枚举 + 解析全部条目 | 合计 **5.2 秒** | — |
| home 两层快扫 | 1 秒（53 处） | 1 秒 |
| 权限拒绝 | 449 | 226 |

**结论：遍历发现是唯一慢的环节，读取内容很便宜。** 所以三段式扫描成立：
慢的那段放后台，快的那段保证首屏。

## 4 · 分类规则（`LocationClassifier.classify`）

按顺序命中，每条都用本机真实路径验证过：

1. 位置就在 home 本身（`~/.claude.json`）→ 用户级
2. home 直属子目录是官方 Agent 配置目录（`~/.codex`、`~/.agents`、`~/.claude`、
   `~/.qwenworkcn`、`~/.cursor`）→ 用户级，不再找 `.git`
3. 从所在目录向上找 `.git`（含 home 直属子目录本身，不含 home）→ 项目级，项目根 = 命中的仓库
4. 所在目录就是 home 直属子目录（`~/tools/skills`）→ 用户级
5. 位于 home 直属点目录树内（`~/.grok/bundled/skills`、`~/.qwenworkcn/plugins/*/skills`）→ 用户级
6. 以上都不成立（`~/Downloads/some-kit/skills`、`~/.hermes/profiles/x/home/.codex/skills`）→ **其他位置**

归属推断：自 home 直属层向下取最深的匹配 —— 官方映射表 > 点目录（`.config`/`.local`
这类通用容器可看穿一层，所以 `~/.config/devin/skills` → `devin`）> 所在目录名。

### 已知取舍（不是 bug，是规则的字面后果）

- `~/some-repo/skills`（仓库直接躺在 home 且未再分层）判**用户级**——这是「home 直属 =
  用户级」的字面结果。带分层的仓库（`~/repo/sub/skills`）会正确判项目级。
- 无 `.git` 又非 home 直属的位置一律进「其他位置」，不猜它是项目。
- `~/.workbuddy/**` 下 345 处、`~/.codex/**` 下 101 处深层 skills 全收录并判用户级——
  它们在 Agent 配置树内，符合规则 5。

## 5 · 剪枝：按类别可勾选（智昊二次裁决）

第一版把剪枝写死在代码里、设置页只读展示。智昊否掉了：「把剪枝这件事做一个选择，用户自己选择
是否查看特定文件夹的类型」，并指出扫描会走进音乐相册这类默认目录。改为 **9 个类别、设置页逐类
开关**，每类如实标出本次跳过了多少个目录：

| 类别 | 默认 | 内容 |
| --- | --- | --- |
| 依赖包与构建产物 | 剪 | `node_modules` |
| 版本控制元数据 | 剪 | `.git` `.svn` `.hg` `.bzr` |
| 系统与索引目录 | 剪 | `Library` `DerivedData` `.vol` `.fseventsd` `.Spotlight-V100` + `/.nofollow` 等 firmlink 镜像前缀 |
| 缓存 | 剪 | `.cache` `Caches` `*-cache`（如 grok 的 marketplace-cache） |
| 回收站与备份副本 | 剪 | `trash` `Trash` `backup`——本机实测 902 处里 154 处是这种 |
| 应用包内部 | 剪 | `*.app` `*.framework` `*.bundle` `*.lproj` `*.xcassets` 等 |
| 工具内置副本 | 剪 | `builtin` |
| 媒体库 | 剪 | `~/Music` `~/Pictures` `~/Movies` `~/Photos`——本机实测命中 0，剪掉纯省遍历 |
| 桌面与下载 | **不剪** | `~/Desktop` `~/Downloads`——可能解压了 skill 包，默认仍扫描 |

`vendor` / `tests` / `fixtures` **不设剪枝**：那些地方可能真的写了 skill，剪了会误伤。

开关存 `AppSettings.prunedCategories`（settings.json），改动即重建 `DiscoveryRules` → 发现缓存因
规则不一致自动失效 → 立即重新扫描全盘。CLI 读同一份设置，保证 App 与 `skillctl` 范围一致。

控件形态：先用 `switch`，智昊真机反馈「开关看不到了」——本 App 的 primary 是近黑墨色，switch 的
ON 轨道被填成一坨黑胶囊、白色滑块吞在里面。改回 macOS 原生 `checkbox`：任何尺寸下勾选态都可辨，
且不引入新色值（硬规则 §3.4）。

每类的「跳过 N 个目录」计数随发现快照一起持久化，重启后直接回填；**没有统计值时显示
「本次未统计」而不是 0**——拿 0 冒充"一个都没跳过"是假话。

MCP 文件闸门（与剪枝正交）：`mcp.json` / `.mcp.json` 全盘认；`config.toml` / `.claude.json` 太通用，
只在 home 及其直属子目录内认。

关于 `~/.box-agent`（智昊问"这是什么 agent，我从没见过"）：查证是 **Box Agent**，
`config/config.yaml` 里后端指向 `xiaohuanxiong.com`（小浣熊）、模型 `raccoon-chat-ml-5-5`；
`skills/` 下 50 个真 skill，另有 **201 个它自己搬进 `trash/` 的历史副本**——之前那 128 处全是副本，
剪掉「回收站与备份副本」这一类后整体消失。

## 5.1 · 归属来源分级（智昊二次裁决）

全盘发现后出现 111 个"归属"，其中混着项目名（`Sandustry`、`GEOFlow`、`plugin-a`）——那是项目根
下直接放 `skills/` 时按"父目录名"兜底的结果，不是可被 Agent 引用的工具。智昊裁决：分开，单独用
标签展示，表明它不是 Agent 可引用的 skill。

`AgentOrigin` 三级：

- `officialAgentDir`：官方四家配置目录（`~/.codex` `~/.claude` `~/.agents` `~/.qwenworkcn` `~/.cursor`）
- `toolDir`：其他工具自己的点目录（`~/.thincoder`、`~/.workbuddy`、`~/.config/devin` 看穿一层）
- `containerName`：只能用所在目录名兜底 → **项目名，不算 Agent**

落地：`Agents` 计数只统计前两级，第三级单列「N 目录名归属」；设置页该类位置行打
「目录名归属 · 非 Agent 可引用」标签 + muted 徽章；清单行「被谁挂载」若全部来自目录名兜底则转
muted 色并在 tooltip 说明。写侧 `MountTargets` 仍只认官方四家，未扩。

## 6 · 三段式扫描与缓存

```
段 1 quick      home 两层内（53 处）        → 秒级首版清单
段 2 backfill   缓存里的其余位置（~1000 处） → 5 秒内近全量
段 3 discovering 全盘发现（44s）             → 只扫新出现的位置 → 写回缓存
```

- 发现结果缓存在 `~/Library/Application Support/cn.zhihao.SkillController/scan-scope-cache.json`，
  只存路径列表不存内容；规则变更即失效重扫。
- `rescan()`（FSEvents 触发、删除/恢复后触发）**只按已知位置重扫，绝不隐式触发全盘遍历**。
- 新位置的发现 = 启动后台一次 + 设置页「重新扫描全盘」手动触发。不做常驻定时器（硬规则禁区清单）。

## 7 · CLI 侧的关键约束

`AssemblyService.currentIndex()` 读缓存；无缓存时只做 home 两层快扫。
**全盘遍历的 44 秒绝不能进 `skillctl search` 的关键路径**——那是 Agent 装配时的同步等待。
实测无缓存冷调用 0.7 秒。

写侧目标目录仍是 `MountTargets.table` 的 4 家白名单：发现出的新工具（thincoder / trae-cn…）
**只读不可装配**，要支持得先补写回规则，属 story-3/6 范围，未擅自扩。

## 8 · 真机验收发现并修掉的四个 bug

1. **APFS firmlink 镜像导致命中数翻倍**：从 `/` 遍历时 `/Users` 与 `/.nofollow/Users` 是同一
   份数据的两个入口，位置数 1,285 → 实际应为 ~750。修：`/.nofollow` 进前缀剪枝 + 按
   `(卷号, inode)` 做目录身份去重（`fileResourceIdentifier`）。修后 `/.nofollow` 命中 0。
2. **后台补扫卡死 UI**：1,800 处位置按每批 24 个重建索引 = 主线程 75 次全量 merge+sort，
   走查时点击设置直接超时。修：批量 120，全程重建压到十几次；点击恢复响应。
3. **剪枝判断退化成计算属性**：类别化重构时把 `exactNames` / `nameSuffixes` / `pathPrefixes`
   写成了计算属性，于是热路径上每个目录条目都要重建 8 个类别的数组。修：遍历前一次性建
   `PruneIndex`（名字走字典、后缀前缀线性扫），并用 `discoveryOverWideTreeStaysFast`
   （3,200 个目录 < 5s）卡住预算。
4. **扫描期间误显示「扫描已完成」**：`scanPhase` 初始位没置上。修：加 `preparing` 态。

### 一次测量失误，记下来避免再犯

修 bug 3 期间我量到 CLI 冷启动 0.7s → 357s → 899s，一度判定为严重回归。真相是**测量污染**：
当时 App 里还有一个没跑完的全盘发现进程在抢磁盘。停掉 App 单独重测，同一条命令 1 秒。
教训：测 IO 密集路径前先 `pgrep` + 看 `%cpu` 确认没有同类进程在跑，否则数字全是噪声。
`PruneIndex` 这个优化本身仍然成立（计算属性是白给的开销），但它的真实收益没被隔离测量出来。

顺带修的：`InventoryIndex.rebuild` 里 `order.contains(id)` 的 O(n²) 去重（条目从 ~180 涨到
数千后会成新瓶颈）→ 换 Set。

## 9 · 待智昊确认的文案改动

按硬规则 §3.3，改文案要提出来。这次动了三处：

1. **新增「其他位置」**——清单页层级徽章 + 设置页分区标题。原 `levelText` 兜底是「项目级」，
   但对既不在 Agent 树内也找不到 `.git` 的位置那是假话。措辞：中性、不判风险。
2. **授权门副文案**——原来列 `~/.codex · ~/.claude · ~/.qwenworkcn · ~/.cursor` 四个目录，
   发现驱动后这句是错的。改为「全盘发现名为 skills 的目录与 MCP 配置文件 / 跳过
   node_modules、缓存与回收站副本，其余一律收录」。
3. **设置页说明句**——原「以下位置参与全盘扫描」改为「扫描范围来自全盘发现：只列出盘上
   真实存在的 skills 目录与 MCP 配置文件，再判定用户级 / 项目级 / 归属」。

## 10 · 验证

- 单测 50 个全绿，含 16 个新增 `ScopeDiscoveryTests`：剪枝类别命中与可开关、索引与计算属性
  等价、宽树时间预算、maxDepth、符号链接不跟随、分类表驱动、归属三级区分、不存在位置剔除、
  缓存往返、firmlink 前缀回归。
- 既有基准 `benchmarkColdScan1000SkillsUnder5s` 仍绿（0.65s）。
- CLI 干净环境冷启动（无缓存，走 home 快扫）实测 **1 秒**。
- 真机验收（2026-09-21 07:03 那一轮）：
  - 授权 → 段 1 约 1 秒出 **250 Skills · 53 Agents**
  - 段 3 全盘发现约 44 秒后 → **1,970 Skills · 510 MCP · 76 Agents · 35 目录名归属 · 44 项目**
  - 设置页：**1,095 处位置 · 遍历 74K 目录 · 226 处读不到 · 零「路径不存在」空行**
  - 9 个剪枝开关逐个显示本次跳过目录数（依赖包 352 / 应用包 200 / 版本控制 78 / 缓存 20 /
    系统索引 19 / 回收站备份 13 / 内置 3 / 媒体库 3；桌面与下载显示「已纳入扫描」）
  - 项目名冒充的归属（`Sandustry` / `GEOFlow` / `plugin-a`）在「被谁挂载」列转 muted 色，
    与真 Agent（`adal` / `Codex`）的黑色可区分；页头不再把它们计入 Agents

