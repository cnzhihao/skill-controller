// =============================================
// Shared types — Skill Controller prototype
// Maps to sitemap.json unified data model:
//   两类对象 (skill | mcp) × 归属三维 (agent / level / project)
// =============================================

export type ObjectType = 'skill' | 'mcp'
export type Level = 'user' | 'project'
export type ItemStatus = 'mounted' | 'unmounted' | 'zero-mount'
export type ViewMode = 'by-agent' | 'by-project' | 'by-scope'

export interface Agent {
  id: string
  name: string
  /** 挂载目录展示，纯本地路径 */
  homeDir: string
}

export interface Project {
  id: string
  name: string
  path: string
}

export interface MountRecord {
  at: string // ISO date
  action: 'mount' | 'unmount'
  agentId: string
  scope: Level
  projectId?: string
}

export interface InventoryItem {
  id: string
  name: string
  description: string
  type: ObjectType
  level: Level
  projectId?: string
  /** 实际文件落点 */
  sourcePath: string
  /** 当前被哪些 Agent 挂载 */
  mountedBy: string[] // agent ids
  /** 同名多副本落点（合并展示） */
  duplicates: string[]
  /** 静态触发词重叠对（基于 SKILL.md 文案，工具拿不到的调用数据不做） */
  triggerOverlapWith: string[] // item ids
  mounts: MountRecord[]
  status: ItemStatus
}

export interface AssemblyEvent {
  id: string
  date: string
  agentId: string
  projectId: string
  added: string[] // item ids
  removed: string[] // item ids
  conflicts: Array<{ itemId: string; reason: string }>
  reviewed: boolean
}

export interface LogEntry {
  id: string
  at: string
  actor: string // agent id 或 '智昊'
  actorKind: 'agent' | 'human'
  action: string
  target: string
  reversible: boolean
  restored?: boolean
}
