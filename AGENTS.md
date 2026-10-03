# AGENTS.md — Skill Controller 仓库指令

> 本文件是给 AI Agent 协作者与本仓库贡献者的仓库指令。Skill Controller 是一个 SwiftUI
> 原生 macOS App + `skillctl` CLI：打开即满的全盘 Skill/MCP 清单（两类对象 × Agent/层级/项目
> 三维归属），管理动作全部由 Agent 经 CLI 完成，人只看不管、只删/恢；一切操作文件级可回滚；
> 纯本地零云端。构建与安装见 [README](README.md)。

## 3 · 硬规则（违反 = 返工，不接受"顺手优化"）

1. **零观点**：不出现推荐、评分、"建议删除"、自动清理；"从未挂载"等状态一律中性徽章。
2. **destructive 红全应用唯一豁免 = 磁盘满不可逆删除**（edge G5）；其余错误/事件全用 muted 中性系。
3. **文案照抄 PRD/Edge 的 copy_hint**（含"只报总量不报风险"的降级横幅句式、"谁留谁走，你或你的 Agent 决定"），要改先提出讨论。
4. **视觉只从 tokens 取**：无自创色值/字号/圆角；等宽全局；数字 `.monospacedDigit()`；每屏 primary ≤1。
5. **数据面不限宽**（跟窗口走，min-width 960）；阅读型容器限宽（详情 360/Sheet 520/对话框 max-w）。
6. **App 进程零遥测**；不读 Agent 会话日志（调用层永久排除）。联网仅限两处：`skillctl add` 的 HTTPS git clone；CLI 安装引导每次冷启动只读一次 GitHub 最新稳定 Release 元数据（公开 API、无认证、5 秒超时、不下载、不含设备标识）。
7. 可点击行必须键盘可达（focus ring + Enter/Space）；禁用态 opacity+cursor 双标识。
8. 所有写操作三步齐：操作日志 + 回收站/备份 + 可一步恢复；恢复失败如实报部分态（G4），恢复按钮不撒谎（G7）。

## 4 · 测试要求（每个开发阶段出口跑）

- 单元：数据模型合并（同名副本/duplicates）、三维归属计算、日志↔回收站恢复往返（磁盘状态 diff 为空）。
- 基准：冷启动 ≤5s fixture 测试（CI 断言，不达标即红）。
- 集成：skillctl 双进程并发写（锁生效）、TCC 拒绝路径、磁盘满路径（fixture 模拟小分区）。
- UI：关键屏快照测试 + 手动动线清单（授权→清单→详情→diff→恢复 全走一遍，对照 proto 原型行为）。
- 交付文档 `docs/test-report.md`：每条 PRD GWT ↔ 测试用例编号的映射表，无映射的 GWT 视为未测。

## 7 · 禁区清单

不做：hooks/rules/memory 管理、云同步、macOS 之外的端、调用频次统计、引导流程（onboarding=设计失败）、任何后台常驻服务、对 `~/.codex` 等目录的破坏性批量操作（所有删除经回收站）。

---

## 工程协作约定

- 三层架构：`App/`（SwiftUI 原生）· `Sources/skillctl/`（CLI）· `Sources/SkillControllerCore/`（SwiftPM 共享库）。App 侧视图不在 `swift test` 覆盖内，UI 变更以真机验收为证据。
- 数据模型以 `skill-controller-proto/src/flows/shared/types.ts` 1:1 翻译为准（字段不许增删改；统一对象模型是架构裁定）。
- 改 `skillctl` 行为必须同一次提交 bump `SkillControllerVersion` 并重装 PATH 上的二进制（版本单一真相：tag = `builderVersion` = `skillctl --version`）。
- 设计文档在 `docs/design/`；PRD 在 `spark-output/prd/`；交互规格源在 `skill-controller-proto/src/flows/`。
