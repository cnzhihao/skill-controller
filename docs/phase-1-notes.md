# Phase 1 Notes · 清单地基（story-1）

- 时间：2026-09-19
- 分支：`dev/phase0-recon`（Phase 0 收尾与 Phase 1 同分支推进）
- 状态：**✅ 闸门通过（2026-09-19）**——D3-D6 全部裁决：D3 日志就绪后回填 / D4 "未写描述" / D5 渲染但禁用 / D6 插件 skills v1 计入（已实现，179 Skills 真机验证）。下一步 Phase 2。

---

## 走查结论（2026-09-19 · Computer Use 自主走查，真数据全流程）

按 proto 动线对运行中的 App 走查（授权门→清单→详情→搜索→过滤→设置→挂载账），**发现并当场修复 4 个 bug**：

| # | 问题 | 根因 | 修复 |
| --- | --- | --- | --- |
| W1 | 列表行文字整体不可见 | Assets.car 根本没编进 App（sync group 未归类 xcassets → 显式引用后，colorset 缺 `"idiom":"universal"` 被 actool 静默丢弃） | xcassets 移出同步目录显式挂 Resources phase；colorset 全部补 idiom。**另发现 actool 把 alpha `"1"` 当十六进制（=1/255）→ 全部分量改十进制小数** |
| W2 | `dbs` 系列描述显示为 `|` | SKILL.md 的 YAML 块标量（`description: |`）未解析 | SkillFrontmatter 支持块标量（多行拼接），补测试 |
| W3 | 用户级位置被重复扫为"项目级" | `~/.claude.json` projects 键包含 home 目录本身 | discoverProjects 过滤 home；24→23 项目 |
| W4 | `~/.agents/skills` 条目归属丢失 | 实现时误标为共享源（nil），C2 裁决应记 Codex | 归属 Codex（同时保留共享源徽章），`dbs` 系列恢复 Claude Code · Codex |

**走查通过项**：授权门文案/布局（照抄 flow1 S1）；清单页等宽+徽章+副本 ×N+truncate+中性"从未挂载"；搜索空态文案+清空 CTA；MCP 过滤（15 条准确：Claude 9 + Codex 5 + pencil 跨 Agent 副本合并 + playwright 项目级来自 .mcp.json）；详情栏 360（落点+副本、挂载徽章、中性时间线、D5 禁用动作区）；设置页（共享源徽章、"该路径不存在"中性提示、D1 项目位置）；挂载账占位（起点诚实态）。

**真数据规模**：145 Skills · 15 MCP · 4 Agents · 23 项目（D1 来源）；扫描 + 渲染秒级完成。

---

## 做了什么

### ① D2 解除（Phase 0 遗留）

- 完整 Xcode 27.0 安装后：手写 objectVersion 77 pbxproj（fileSystemSynchronizedGroups + 本地 SPM 包引用），三 target（App / skillctl / tests）**全部 BUILD/TEST 绿**。
- 踩坑记录：Xcode 链接本地包产品需要 Package.swift 显式声明 `products`（library + executable），缺了报 "Missing package product"。

### ② 数据模型 1:1（types.ts → Swift）

- `Sources/SkillControllerCore/Models.swift`：ObjectType / Level / ItemStatus / ViewMode / Agent / Project / MountRecord / InventoryItem / AssemblyEvent / LogEntry，**字段零增删改**。
- `ItemStatus.unmounted` 保留：Phase 1 无日志数据，全部按事实落在 mounted / zero-mount；unmounted 等 story-3/5 的日志落地后启用。

### ③ 扫描引擎 + 索引 + FSEvents

- `ScanScope.swift`：Agent 注册表（C1 用 `~/.qwenworkcn` / C2 Codex 双目录都扫 / C4 Cursor 保留注册）；D1 项目发现=读 `~/.claude.json` projects 键（已裁决）；项目级位置按官方口径（`.claude/skills`、`.agents/skills`、`.cursor/skills`、`.mcp.json`、`.cursor/mcp.json`）。
- `InventoryScanner.swift`：skill 目录枚举（symlink 解析落 duplicates）+ MCP 三源（claude.json user+local scope / codex config.toml `[mcp_servers.*]` / 项目 .mcp.json）；读不到的位置如实入 degraded（不存在≠降级，读不了才是降级）。
- `InventoryIndex.swift`：同名多副本按 (type,name) 合并；源路径优先实体目录、symlink 引用进 `duplicates`；三维归属查询出口 `ownership(of:)`。
- `FSEventWatcher.swift`：防抖 0.5s；spike 的参数位序教训已注释进代码。
- `AppState.swift`：分批扫描（每 6 个位置一批）→ 每批合并入索引 → **增量出结果**（edge >3s 规则的真实实现，不是摆设）；扫描结束后自动挂 FSEvents。

### ④ 清单 UI（对照 flow1 + edge must 态逐条实现）

| flow1/edge 状态 | 实现位置 | 落实 |
| --- | --- | --- |
| S1 授权门默认态 | GateSheet | 文案照抄（含目录列表、"这次先不/授权并扫描"） |
| S1 loading-submit | GateSheet | 按下后 disabled+spinner「正在建立索引…」其余不可交互 |
| S1 error-permission | GateSheet | 中性说明+系统设置深链（非 sandbox 下预计极少触发） |
| S2 denied 半空引导 | RootView+InventoryView | "清单是空的，因为你还没授权"+重新授权 |
| S2 loading-initial | InventoryView | <1.5s 8 行 Skeleton；>3s 增量出结果+页头"索引持续更新中" |
| S2 empty-collection | InventoryView | 照抄"这台机器还没有 Skill。装配是你未来 Agent 的事，也可以先检查扫描范围" |
| S2 empty-filter | InventoryView | "没有 MCP。恢复全部对象看看"（不复用搜索空态文案） |
| S2 searching-empty | InventoryView | "没有匹配「q」的条目 —— 清单没有藏东西…" + 清空搜索 |
| S2 error-partial-degrade | DegradedBanner | "N 个位置未能读取（…）——清单基于其余 M 个位置构建"；**G1 每行「忽略此位置」，设置页可逆** |
| boundary-long-text | Row/Detail | 名称/描述 lineLimit+truncate+tooltip 全文 |
| S3 boundary-null | DetailPanel | "SKILL.md 未写描述"（MCP 用"未写描述"，见下方 D4） |
| S3 落点/副本/徽章/时间线 | DetailPanel | "当前无人挂载（中性事实，不是警告）"；"近 90 天无变动"（账本未落日志，如实显示） |
| S3 error-target-vanished | DetailPanel | 中性消失态+唯一出口「关闭」（attribution 处理见 D3） |
| 回退页 empty-log | RollbackPlaceholder | "近 30 天没有任何变动"（不是"暂无数据"） |
| 挂载账 empty-first-day | LedgerPlaceholder | "账本从 {安装日} 开始记录…" + "以下数字只反映安装之后的挂载" |

### ⑤ 测试与基准

- **14 测试全绿**：模型合并（3 副本→1 条目/duplicates 并列）、symlink 语义（源优先）、三维归属、skill 与 mcp 同名不合并、零挂载中性态、过滤搜索、TOML 子表不误报、claude.json user+local scope、降级路径。
- **基准：fixture 1000 skills 冷扫描 0.44s**（预算 5s，CI 断言已进测试）。
- `xcodebuild`：App / skillctl BUILD SUCCEEDED，tests TEST SUCCEEDED。

---

## 需要裁决 / 留意

| # | 事项 | 裁决结果（2026-09-19 闸门） |
| --- | --- | --- |
| D3 ✅ 日志就绪后回填（维持现状实现） | 消失态 attribution：设计文案"这条目刚刚被 {agent} 移出了清单"，但 Phase 1 无操作日志无法知 actor | 现实现为"这条目刚刚被移出了清单（日志可查）"（去 {agent} 槽位）；Phase 2 日志落地后回填 actor。如需保留原句式请指出数据来源建议 |
| D4 ✅ "未写描述"（维持现状实现） | MCP 描述缺失的 boundary-null 文案：设计只定义了"SKILL.md 未写描述"（Skill 专属） | MCP 空描述现显示"未写描述"。要改成别的口径请给文案 |
| D5 ✅ 渲染但禁用（维持现状实现） | 详情栏动作区（恢复挂载/卸下/删除）Phase 1 渲染但**禁用**（opacity+cursor 双标识+说明行"写操作将在装配与回滚底座就绪后启用"） | 理由：写操作依赖 Phase 2 日志+回收站底线件，启用即违反"先做日志与回收站"的底线件顺序。备选：Phase 1 干脆不渲染动作区。请裁决 |
| D6 | ✅ 已裁决：v1 计入 | 扫描器加 `depth` 字段（深层模式），`plugins/*/skills/*` 两层结构已计入清单（真机验证 145→179 Skills）；"product-design" 系列与共享库重名条目正常合并为副本 |
| 验收待办 | 手动动线清单（授权→清单→详情→diff→恢复）需真人按 proto 走查；App 已启动，diff/恢复两屏属 Phase 2 | 走查发现问题随时回报，闸门后修 |

## 下一步（过闸后）

Phase 2：**先做操作日志+回收站（底线件，顺序不可逆）**，再 skillctl search|info|pull|mount|unmount + 写锁/写前备份/结构化日志 + 并发双写集成测试 + Banner 三态/diff Sheet（三组分区、冲突行内留痕+单条重试、关闭=验收、恢复=AlertDialog）。
