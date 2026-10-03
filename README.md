# Skill Controller

全盘 Skill/MCP 清单 · Agent 自主装配 · 文件级可回滚 — 数据留在本机的 macOS 工具。

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
![Platform: macOS](https://img.shields.io/badge/platform-macOS%2014%2B-black)
![Swift](https://img.shields.io/badge/Swift-6-orange)

**English**: Skill Controller is a native SwiftUI app for macOS that gives you a complete, at-a-glance inventory of every Agent Skill and MCP configuration on your machine, organized by agent, scope (user/project), and project. Management actions are delegated to your AI agents via the `skillctl` CLI — humans observe and verify, agents assemble; every write operation is logged, trashed, and one-step reversible. Data stays local with no telemetry. On startup, the CLI setup guide makes one unauthenticated request to GitHub Releases metadata to check for CLI updates; it does not download binaries automatically.

---

## 是什么 / 为什么

你的每台电脑上，AI 编码工具（Codex、Claude Code、Cursor 等）启动时都会无差别加载用户级 skills 目录里的全部内容——几十到上千个 Skill。Agent 因此变慢、变笨，触发词互相打架；新开项目要手工重装一套技能；删又不敢删，因为没有任何"谁在用"的记录。

**Skill Controller 打开即满**：启动即全盘扫描，把 Skill 与 MCP 两类对象按「Agent × 用户级/项目级 × 具体项目」三维归属完整列出，零配置问答。它做两件事：

1. **清单**——打开即满的全盘清单（FSEvents 增量更新），人只看不管：看不评、不推荐、不打分（零观点）。
2. **装配与回滚**——管理动作全部由 Agent 经 `skillctl` CLI 完成（search / info / pull / mount / unmount）；每次写操作三步齐：操作日志 + 回收站/备份 + 一步恢复。

核心设计：**人只看，Agent 来管；一切可回滚**。

## Quick Start

**前置**：macOS 14+、Xcode 27+（或 Xcode Command Line Tools）。

**构建**：

```bash
git clone https://github.com/cnzhihao/skill-controller.git
cd skill-controller
swift build          # 构建核心库 + skillctl CLI
swift test           # 187 项测试
```

**运行 App**（SwiftUI 原生）：

```bash
xcodebuild -scheme SkillController build
open .build/debug/SkillController.app
```

**安装 CLI 到 PATH**：

```bash
cp .build/debug/skillctl ~/.local/bin/skillctl
```

**装元 skill（skills.sh 生态）**：

```bash
npx skills add cnzhihao/skill-controller
```

skills CLI 会按你使用的 Agent 自动落位（codex→`~/.codex/skills`、claude-code→`~/.claude/skills` 等），无需手动放置文件。元 skill 的内容见 [`skills/skill-controller/SKILL.md`](skills/skill-controller/SKILL.md)——装完之后，你的 Agent 就掌握了「用 skillctl 自管技能」的管理纪律：查全集、收编进库、装到项目、挂到 Agent、卸下，全走 CLI，不手动增删 skills 目录。

**Skill 元位置**：`skillctl add <owner>/<repo>`（或本地路径 / https:// Git URL）把 skill 收编进中央库 `~/.skill-library/`——每个 skill 在本机的唯一权威副本；`pull / mount` 一律从库以符号链接引用，不再指向盘上散落副本。库里没有的条目会明确报错并给出可照抄的收编命令。

**Getting Started（通用化）**：挑一个真实项目，让 Agent 经 `skillctl search / pull / mount / unmount` 自管一周；人只在 App 里看清单、验收每次装配的 diff、必要时一键恢复。App 会在 Agent 装配后弹出验收面（挂上/卸下/冲突三组分区、冲突行内留痕、关闭=验收），全部写操作可在「回退」页一步恢复。

## 架构一览

三层结构：

- **App**（SwiftUI 原生 macOS）——三栏清单 + 详情栏、装配验收面（Banner 三态 + diff Sheet）、挂载账、回退页、设置页。
- **skillctl**（CLI）——Agent 的唯一管理通道：`search / info / add / pull / mount / unmount / events`。
- **SkillControllerCore**（SwiftPM 库）——扫描引擎与索引、发现范围（全盘 DFS + 分类器）、写锁（全进程一把）、操作日志 ↔ 回收站（三步齐、全有或全无回滚）、装配服务（diff + 快照验收基线）。

关键机制一行一个：FSEvents 增量监听 · 写前备份 + 操作日志 · 回收站可一步恢复 · 装配验收 diff（快照基线 + rebase）· 发现范围用户可调（9 类剪枝开关）。

## 文档导览

- [`docs/agent-recon.md`](docs/agent-recon.md) — 各 Agent 工具的 skills 目录、symlink 接受度、MCP 配置格式侦查表
- [`spark-output/prd/skill-controller.md`](spark-output/prd/skill-controller.md) — 产品需求文档（PRD）
- [`spark-output/extract/skill-controller-proto/skill-controller-proto-design-language.md`](spark-output/extract/skill-controller-proto/skill-controller-proto-design-language.md) — 视觉语言与设计 tokens
- [`docs/design/concurrency-model.md`](docs/design/concurrency-model.md) — 持久化层并发模型
- [`docs/test-report.md`](docs/test-report.md) — GWT ↔ 测试映射表
- [`docs/scan-scope-redesign.md`](docs/scan-scope-redesign.md) 等整改史 — 设计→发现缺陷→裁决→收口的工程留痕

## License

[MIT](LICENSE) © 2026 智昊
