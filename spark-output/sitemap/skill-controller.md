# Sitemap — 本地 Skill 管理工具（Skill 控制器）

- **生成时间**：2026-09-19T05:58:00Z
- **平台**：macOS 原生 SwiftUI（NavigationSplitView 桌面三段式；platform 字段记 web 桌面型供下游 Flow 消费，路由为应用内导航的逻辑映射）
- **数据源**：brief.json + frame.json + stories.json
- **页面总数**：9（6 页 + 3 覆盖层）｜**最大深度**：3
- **鉴权**：单用户本地，无登录，access 一律 public

## 架构级决策（本次锁定）

1. **清单 / Agent / 项目 = 同一份数据的三个观察视角**，不是三个页面——"两类对象（Skill/MCP）× 归属三维（Agent/层级/项目）"统一数据模型 v1 定死（Story 6 的前提）。
2. **工具拿不到的信息不做（用户硬约束）**：账本收敛为「挂载账」——只呈现文件系统可观测的事实（挂载变动、零挂载、静态重叠对）；调用层、会话日志解析器、atime 全部 out of scope。
3. 主导航 4 项，防超载：日志+回收站合并为「回退」的两个 Tab。

## 主导航（侧栏）

- 📦 清单 — /inventory（icon: shippingbox）
- 📒 挂载账 — /ledger（icon: list-ordered）
- ↩️ 回退 — /rollback（icon: history）
- ⚙️ 设置 — /settings（icon: settings）

## 站点树

```
App 主窗口（NavigationSplitView）
├── /inventory 全盘清单 [story-1,2,3,6]
│   ├── 视角：by-agent / by-project / by-scope（平级切换，非子页）
│   ├── 对象：skill ⇄ mcp（同一列表模型）
│   └── /inventory/item/[id] 条目详情栏 [story-1,3,4,5]
├── /ledger 挂载账 [story-5]
│   └── Tab：零挂载清单 / 挂载变动时间线 / 静态重叠对
├── /rollback 回退 [story-4]
│   ├── /rollback/log 操作日志（按时间/按 Agent 过滤）
│   └── /rollback/trash 回收站（≥30 天）
├── /settings 设置（扫描范围/保留窗/CLI 安装）[story-3,6 支撑]
└── 覆盖层（Sheet/Toast，不占导航层级）
    ├── sheet:disk-access 首次全盘访问授权 [story-1]
    ├── sheet:assembly-diff 装配 diff「昨天 Agent 带来了什么」[story-2 ⭐]
    └── toast:write-error 写入失败/冲突痕迹卡 [story-2,3,6]
```

## 页面清单

| ID | Route | Label | Purpose | 关联 Story |
| --- | --- | --- | --- | --- |
| page-inventory | /inventory | 全盘清单 | 打开即满；视角×对象双过滤 | 1,2,3,6 |
| page-item-detail | /inventory/item/[id] | 条目详情栏 | 归属·来源·挂载变动·重叠并列·回挂 | 1,3,4,5 |
| page-ledger | /ledger | 挂载账 | 纯文件层观测，只摆数零观点 | 5 |
| page-rollback-log | /rollback/log | 操作日志 | 每次读写可查、一步撤销 | 4 |
| page-rollback-trash | /rollback/trash | 回收站 | ≥30 天恢复窗 | 4 |
| page-settings | /settings | 设置 | 极小：扫描范围/保留窗/CLI 安装 | 3,6 |
| overlay-disk-auth | sheet:disk-access | 授权 Sheet | 冷启动一次性 | 1 |
| overlay-assembly-diff | sheet:assembly-diff | 装配 diff | Agent 自装配的验收面 ⭐ | 2 |
| overlay-write-error | toast:write-error | 失败痕迹卡 | 不静默失败 | 2,3,6 |

## 关键 Flow

1. **冷启动即满**：sheet:disk-access → /inventory → /inventory/item/[id]
2. **Agent 自装配验收 ⭐（命门假设）**：Agent CLI → /inventory(by-project) → sheet:assembly-diff →（若错）/rollback/log 一步恢复
3. **数据化瘦身**：/ledger 零挂载清单 → /inventory 框选删除 → /rollback/trash 30 天内恢复

## 下游提醒

- 这是原生 macOS App：下游 Flow 阶段建议用 flow-web 的桌面布局规格做**交互规格**，视觉/组件最终需映射回 SwiftUI；或直接跳过 Flow 走 `/prd` 给 coding agent。
- Edge（异常态矩阵）价值较高：授权被拒、目录权限、JSON 解析失败、CLI 并发写等错误态多。
