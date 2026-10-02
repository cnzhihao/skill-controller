# R2 · Agent 侦查表（agent-recon）

- 生成时间：2026-09-19
- 方法：本机实查（ls / find / 配置文件结构解析）+ 官方文档核查 + 社区口径（标注置信度）
- 用途：PRD R2 收口——决定扫描范围清单、`pull` 用复制还是软链、MCP 写回层设计
- 证据等级：**[实证]**=本机文件系统直接观察；**[官方]**=官方文档；**[社区]**=多来源社区教程一致；**[待验]**=需运行时验证

---

## 1 · 四家 Agent 适配矩阵

### 1.1 Codex

| 项 | 结论 | 证据 |
| --- | --- | --- |
| 用户级 skills 目录 | **`~/.agents/skills`**（官方 USER scope）。**注意**：本机 `~/.codex/skills` 同时存在（17 项，全实目录，含 `.system/` 6 个内置），官方文档未列该路径——疑为桌面版遗留/专用位置 | [官方]+[实证] |
| 项目级 skills | `$CWD/.agents/skills`、`$CWD/../.agents/skills`、`$REPO_ROOT/.agents/skills`（自 CWD 向上扫到 repo root） | [官方] |
| 其他 scope | ADMIN：`/etc/codex/skills`；SYSTEM：随 App 内置 | [官方] |
| symlink 接受度 | **官方支持**："Codex supports symlinked skill folders and follows the symlink target when scanning these locations" | [官方] |
| skill 禁用机制 | `~/.codex/config.toml` 中 `[[skills.config]]`（path + enabled=false），重启生效——**不采用**：跨 Agent 不统一，统一模型保持目录级语义 | [官方] |
| 生效条件 | 自动检测 skill 变更；不出现则重启会话 | [官方] |
| MCP 配置 | `~/.codex/config.toml` 的 `[mcp_servers.*]` 段（本机 8 个：chrome-devtools / node_repl / computer-use / openaiDeveloperDocs / scys-mcp(+oauth) / pencil） | [实证] |
| 写回生效条件 | 重启会话 | [官方/常识] |
| 敏感数据 | config.toml 含 OAuth token 段（`[mcp_servers.*.oauth]`）→ **MCP 写侧必须条目级替换 + 写前备份，禁止整文件重排** | [实证] |

### 1.2 Claude Code

| 项 | 结论 | 证据 |
| --- | --- | --- |
| 用户级 skills | `~/.claude/skills/<name>/SKILL.md`（另 `synced/` 子目录为保留名，来自 claude.ai） | [官方]+[实证] |
| 项目级 skills | `<repo>/.claude/skills/<name>/SKILL.md`；嵌套 `<subdir>/.claude/skills/` 也加载 | [官方]+[实证]（client-a/knowledge-base/.claude/skills 实证有 2 项） |
| 其他来源 | 插件 `<plugin>/skills/<name>`；legacy `commands/`；`--add-dir` 附加路径 | [官方] |
| symlink 接受度 | **官方支持**：skill 文件夹"can be a symlink to a directory elsewhere on disk"，并按目标去重。**本机实证**：`~/.claude/skills` 61 项中约 40+ 个 symlink → `~/.agents/skills/`（57 项共享库），长期生产使用 | [官方]+[实证] |
| 生效条件 | 会话启动时读取 | [官方/常识] |
| MCP 配置 | 三 scope：① Local/User 都存 `~/.claude.json`（User=全局 `mcpServers` 键，本机 9 个；Local=按项目路径 key，本机 33 个 project）② Project=项目根 `.mcp.json` ③ 插件/claude.ai connectors。同名 server 按 Local > Project > User 取优先级、不合并字段 | [官方]+[实证] |
| 写回生效条件 | `claude mcp` 写入立即保存；会话中途配置的 server 即时连接 | [官方] |
| 敏感数据 | `~/.claude.json` 600 权限、107KB、混有会话状态/审批记录 → **写侧仅动 `mcpServers`/`projects[].mcpServers` 两个键，保字段顺序，写前备份** | [实证] |

### 1.3 QoderWork / QwenWork

| 项 | 结论 | 证据 |
| --- | --- | --- |
| 用户级 skills | **`~/.qwenworkcn/skills`**（26 项：create-skill、dingtalk-* 等；含 `.dws-skill-state.json` 状态文件与 `.temp/`）。**设计稿写的是 `~/.qoderworkcn`——该目录在本机不存在，产品已更名** | [实证] |
| 插件 skills | `~/.qwenworkcn/plugins/<plugin>/skills/<name>/`（product-design ~14 项、product-management ~7 项） | [实证] |
| 项目级 skills | `projects/` 目录存在但结构未深查 | [实证·粗] |
| symlink 接受度 | 本机 0 个 symlink 实例，无官方公开文档 → [待验]；扫描引擎按"symlink 落点照常枚举"处理，风险低 | [实证]+[待验] |
| MCP 配置 | `~/.qwenworkcn/mcp-adaptor.config` 仅为连接器接入信息（url/token/headers），**未发现 MCP server 清单的稳定 JSON 落盘点**（疑存于 App 内部状态） | [实证] |
| 写回生效条件 | [待验]（App 重启） | — |

### 1.4 Cursor

| 项 | 结论 | 证据 |
| --- | --- | --- |
| 本机现状 | **未安装**：无 `~/.cursor`、无 `/Applications/Cursor.app` | [实证] |
| 用户级 skills | `~/.cursor/skills/` | [社区]（多来源一致；cursor.com/docs 对应页 404，未能核官方原文） |
| 项目级 skills | `<repo>/.cursor/skills/` | [社区] |
| symlink 接受度 | 未见官方/社区明确说明 → [待验] | — |
| MCP 配置 | 全局 `~/.cursor/mcp.json`；项目 `<repo>/.cursor/mcp.json` | [社区] |
| 生效条件 | 重启会话/窗口 | [社区] |

---

## 2 · 跨家横向结论

1. **共享库事实**：`~/.agents/skills`（57 项）是真实存在的跨 Agent 共享源——Claude 经 symlink 挂载其中 40+ 项。统一数据模型的 `duplicates`（同名多副本合并）天然覆盖"源目录 + symlink 引用"场景；归属上 symlink 落点记为该 Agent 的挂载点，源目录单独成条目。
2. **挂载语义裁定依据**：symlink 被两家主流官方支持 → **卸载 = 删 symlink（源永不自动删）**；挂载 = 建 symlink。与 PRD story-3"卸载 ≠ 删除，条目永远留在全集"完全对齐。
3. **`pull` 策略**：**默认 symlink，`--copy` 可选**。理由：① 两家官方支持 symlink 且跨目标去重；② symlink 让"装配 diff/恢复原状"变成删链接操作，零数据复制、天然可逆；③ copy 仅在 [待验] 的目标（Cursor/QwenWork）上作为降级路径。
4. **MCP 写回三原则**（从侦查事实直接推出）：条目级替换不整文件重排（Codex TOML 含 oauth 敏感段；Claude .claude.json 混会话状态）；写前整文件备份；写后保原生格式（TOML 注释/顺序、JSON 字段顺序）。
5. **本机规模实数**：`SKILL.md` 全盘（depth≤6，排除 Library/node_modules）= **1712 个**，高于原型 mock 的 973——"近千"体感成立，千级性能预算（冷启动 ≤5s）不变。

---

## 3 · ⚠️ 冲突清单（✅ 已裁决 · 2026-09-19 闸门通过）

| # | 冲突 | 裁决结果 |
| --- | --- | --- |
| C1 | 设计产物写 `~/.qoderworkcn`，本机实际为 `~/.qwenworkcn`（产品更名） | ✅ Agent 注册表用 `~/.qwenworkcn`，展示名仍「QoderWork」 |
| C2 | Codex 官方 USER scope=`~/.agents/skills`，本机 `~/.codex/skills` 并存 | ✅ 扫描引擎两处都扫，都记归属 Codex |
| C3 | 删除落在 symlink 上时语义未定 | ✅ 删 symlink 只删链接；源删除仅当源本身被显式操作（回收站照走） |
| C4 | 本机 Cursor 未安装 | ✅ Agent 列表为可配置注册表；无数据 Agent 清单自然为 0 |
| C5 | QwenWork MCP server 清单无稳定落盘点 | ✅ story-6（P2）前专项解决，不阻塞 MVP |
| C6 | Cursor 条目全部社区置信度 | ✅ 安装 Cursor 后实测回填本表 |
| C7 | tokens 实为 31 色非简报所写 28 | ✅ 按"视觉只从 tokens 取"全量生成 31 色 colorset |

**附加裁决**：
- **pull 策略**：默认 symlink + `--copy` 可选（卸载=删链接不删源，与 story-3"卸载≠删除"对齐）。
- **D1 项目清单来源**：允许从 `~/.claude.json` projects 键（配置性路径，非调用层会话日志）+ Codex 配置推导项目级扫描入口；设置页可增删。
- **D2 缺 Xcode**：方案 = 安装完整 Xcode；安装后生成三 target 工程并解挂 tests。

---

## 4 · 对 Phase 1/2 设计的直接输入

- 扫描范围注册表（v1）：`~/.codex/skills`、`~/.agents/skills`、`~/.claude/skills`、`~/.qwenworkcn/skills`、`~/.qwenworkcn/plugins/*/skills`、各项目 `.{claude,codex,cursor}/skills`（项目发现方式见 §2.1）、MCP：`~/.codex/config.toml`、`~/.claude.json`、项目 `.mcp.json`。
- 项目级目录的发现策略：全盘遍历找 `.claude/skills` 等不可行（性能）。**候选**：从 `~/.claude.json` 的 `projects` 键（本机 33 条已知项目路径）+ Codex session 记录路径推项目清单 → **需人确认**（见 phase-0-notes D1）。
- 写锁对象：`~/.claude.json`、`~/.codex/config.toml` 这类混合状态文件是并发写冲突的高危点（R3）。
