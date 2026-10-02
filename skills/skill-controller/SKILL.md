---
name: skill-controller
description: 管理本机的 Agent Skill 时使用。凡是要查看已装的 Skill/MCP 清单、给项目装配技能、卸下技能、查某个技能装在哪，一律通过 skillctl 命令行完成，不要手动增删任何 skills 目录里的文件夹。
---

# 用 skillctl 自管技能

前提：skillctl CLI 已构建并安装到 PATH（构建方法见仓库 README 的 Quick Start）。
本 skill 经 `npx skills add` 安装时，skills CLI 已按你的 Agent 自动落位到对应 skills 目录，
无需手动放置本文件。

你在为本项目或本机维护技能集时，唯一通道是 `skillctl`（不要用 rm/mkdir/cp 直接动 skills 目录）。

- 查全集：`skillctl search <关键词>`（返回 JSON，含落点与描述）
- 看单个：`skillctl info <name>`
- 收编进库：`skillctl add <owner>/<repo>`（或本地路径 / https:// Git URL）——把 skill 收进元位置 `~/.skill-library/`，每个 skill 在本机的唯一权威副本
- 装到本项目：`skillctl pull <name> --target <项目根>`（默认建 symlink；确需物理副本再加 --copy）。pull 只从库解析：库里没有该条目会报错并给出可照抄的收编命令，先 add 再 pull
- 挂到某 Agent：`skillctl mount <name> --on <agent>`
- 从某 Agent 卸下：`skillctl unmount <name> --on <agent>`（只删链接，不删源）

原则：目标已存在时命令会跳过并说明原因，不要强推覆盖；每次操作都会写操作日志，
用户可在 App「回退」页一步恢复。
