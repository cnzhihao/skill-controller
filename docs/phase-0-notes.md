# Phase 0 Notes · 侦查与基建

- 时间：2026-09-19
- 分支：`dev/phase0-recon`
- 状态：**✅ 闸门通过（2026-09-19）**——C1-C7 全按建议裁决、pull=symlink 默认、D1 允许、D2=装完整 Xcode。裁决已回填 agent-recon.md §3。
- 下一步：用户安装 Xcode 后 → 生成三 target 工程（App + skillctl + tests，解挂 Package.swift 注释）→ 进 Phase 1。

---

## 做了什么

### ① docs/agent-recon.md（R2 侦查表，已完成）

- 四家 Agent 的 skills 目录 / symlink / MCP 格式 / 生效条件全矩阵；证据分四级标注（实证/官方/社区/待验）。
- **关键实证**：`~/.claude/skills` 61 项中 40+ 是指向 `~/.agents/skills`（57 项共享库）的 symlink，长期生产使用——Claude 对 symlink 的接受度不是文档理论，是本机事实。Codex 也有官方 symlink 支持。
- **`pull` 策略建议（待裁决 C3 一并确认）**：默认 symlink，`--copy` 可选。symlink 让"卸载=删链接、源永不自动删"，与 PRD story-3"卸载 ≠ 删除"直接对齐。
- MCP 写回三原则：条目级替换（Codex config.toml 含 oauth 段、Claude .claude.json 混会话状态）、写前整文件备份、保原生格式。
- 本机 `SKILL.md` 实测 1712 个（depth≤6）——"近千"体感成立，千级冷启动 ≤5s 预算不变。

### ② TCC spike（通过 ✅）

- 产物：`docs/spike/tcc-spike.swift`（可丢弃 Swift CLI，非 sandbox）。
- **结论 1**：非 sandbox 进程直接读 `~/.codex`、`~/.claude`、`~/.qwenworkcn`、`~/.agents` 全部 OK（含 600 权限文件），**无需 security-scoped bookmarks，无 TCC 提示**——点目录不在 TCC 保护集。
- **结论 2**：FSEvents 在点目录上正常送达变更事件（自造 probe 文件触发，事件 3 个 batch 到达）。
- 工程含义：App 必须非 sandbox（不启用 com.apple.security.app-sandbox），扫描引擎可走 FSEvents 增量，路线 A 成立，无需绕路。
- 待办遗留：GUI App 进程（非 CLI）的同等验证列入 Phase 1 手动动线清单（风险极低，CLI 与 App 进程在 TCC 面前同权）。

### ③ 工程骨架（部分完成）

- SwiftPM：`SkillControllerCore` + `skillctl`（executable）构建绿；`skillctl --version / help / 写类子命令拒绝` 冒烟通过。写类子命令在回滚底座落地前 exit 69 拒绝执行——底线件顺序落进了代码。
- `LayoutMetrics.swift`：360 / 520 / 960 / z70 / Radius 6·8·10·14 / 150ms / truncate 40 全部收敛（与 extract tokens 逐一对应）。
- **Asset Catalog 31 色 colorset**（`App/SkillController/Resources/Assets.xcassets/`）：由 `docs/spike/gen-colorsets.py` 从 variables.css 自动生成，Any/Dark 双 appearance，oklch→sRGB 精确换算（destructive #E7000B/#FF6467 与 shadcn 基准吻合）；dark `sidebar-primary` 蓝残留按 design-language §17.1 统一为灰阶。
  - 注意：当初任务简报写"28 色"，tokens 实际为 **31** 个颜色变量（18 语义 + 5 chart + 8 sidebar）——按"视觉只从 tokens 取"原则全量生成，见 C7。
- App 源骨架（`App/SkillController/`：入口 + Theme.swift），已用 CLT 的 macOS SDK **typecheck 全绿**（SwiftUI / Color token / LayoutMetrics 引用均验证）。

---

## 卡在哪 / 需要裁决

### D2（阻塞项）：本机无完整 Xcode

- 现状：只有 Command Line Tools（无 xcodebuild / actool / ibtool），且 CLT 无 XCTest、无 swift-testing 宏插件 → **App target 无法打包、Asset Catalog 无法编译、单元测试无法运行**。
- 已做：App 源码 + xcassets 就绪；test target 暂从 Package.swift 摘除（源文件保留），装 Xcode 后一行解挂。
- 方案（选一）：
  1. **安装完整 Xcode**（App Store / xcodes），此后我生成 Xcode 工程（App + skillctl + tests 三 target）并跑通测试——推荐，Phase 1 起本来就必须有；
  2. 允许 `brew install xcodegen`，我写 project.yml 生成工程（仍需 Xcode 才能编译，只是工程文件生成自动化）；
  3. 暂缓 App target，Phase 1 先在 SPM 内开发数据模型 + 扫描引擎 + skillctl（全部可测），App UI 层等 Xcode 就绪后回补。

### 待裁决清单（详 agent-recon.md §3）

| # | 事项 | 建议 |
| --- | --- | --- |
| C1 | 设计稿写 `~/.qoderworkcn`，本机实际 `~/.qwenworkcn`（产品更名） | 注册表用 `.qwenworkcn`，展示名保持「QoderWork」 |
| C2 | Codex 官方 USER scope=`~/.agents/skills`，但本机 `~/.codex/skills`（17 项）并存 | 两处都扫，都记 Codex；加载与否留给 dogfooding |
| C3 | 删除落在 symlink 上的语义 | 只删链接不删源；源删除仅限显式操作（回收站照走） |
| C4 | 本机 Cursor 未安装（设计假定四 Agent） | Agent 表可配置；无数据=清单自然 0 |
| C5 | QwenWork MCP server 清单无稳定落盘点 | P2 前专项解决，不阻塞 MVP |
| C6 | Cursor 条目全部社区置信度 | 装 Cursor 后实测回填 |
| C7 | tokens 实为 31 色非 28 | 已全量生成，如需裁到 28 请指明剔除项 |

### 另需一个输入（Phase 1 前）

项目级 skills 的**项目清单来源**：全盘遍历找 `.claude/skills` 不可行（性能）。候选方案：从 `~/.claude.json` 的 `projects` 键（本机 33 条）+ Codex 会话记录路径推导——但这靠近"读会话日志"的禁区边界（禁区是"不读 Agent 会话日志"= 调用层；projects 键是配置不是日志）。**请裁决**：是否允许用配置文件中的项目路径清单作为项目级扫描入口（我的建议：允许，它不是调用层数据）。

---

## 进度对照（Phase 0-1）

- [x] Phase 0-1 agent-recon.md
- [x] Phase 0-2 TCC spike（PASS，路线确认）
- [~] Phase 0-3 工程骨架（SPM 绿 / 31 色 colorset / App 源码 typecheck 绿；**Xcode 工程三 target 被 D2 阻塞**）
- 下一步：过闸后进 Phase 1（数据模型 1:1 翻译 + 扫描引擎 + fixture 1000 基准）
