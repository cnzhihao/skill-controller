// =============================================
// Mock data — 让原型在无后端/无真实全盘扫描时可交互
// 数字感刻意贴近真实：近千 Skill 的世界（此处取代表性样本）
// =============================================

import type {
  Agent,
  AssemblyEvent,
  InventoryItem,
  LogEntry,
  Project,
} from './types'

export const agents: Agent[] = [
  { id: 'codex', name: 'Codex', homeDir: '~/.codex/skills' },
  { id: 'claude', name: 'Claude Code', homeDir: '~/.claude/skills' },
  { id: 'qoder', name: 'QoderWork', homeDir: '~/.qoderworkcn/skills' },
  { id: 'cursor', name: 'Cursor', homeDir: '~/.cursor/skills' },
]

export const projects: Project[] = [
  { id: 'proj-x', name: 'proj-x（客户交付站）', path: '~/work/proj-x' },
  { id: 'sketchlib', name: 'sketchlib（组件库）', path: '~/work/sketchlib' },
  { id: 'sidefolio', name: 'sidefolio（作品集）', path: '~/personal/sidefolio' },
]

export const items: InventoryItem[] = [
  {
    id: 'item-docx', name: 'docx', description: 'Word 文档端到端创建与编辑',
    type: 'skill', level: 'user', sourcePath: '~/.qoderworkcn/skills/docx',
    mountedBy: ['codex', 'claude', 'qoder'], duplicates: ['~/.codex/skills/docx'],
    triggerOverlapWith: ['item-writer'],
    mounts: [
      { at: '2026-09-18', action: 'mount', agentId: 'codex', scope: 'project', projectId: 'proj-x' },
      { at: '2026-08-02', action: 'mount', agentId: 'claude', scope: 'user' },
    ],
    status: 'mounted',
  },
  {
    id: 'item-pdf', name: 'pdf', description: '表单填充 / 合并 / 拆分 / 水印',
    type: 'skill', level: 'user', sourcePath: '~/.qoderworkcn/skills/pdf',
    mountedBy: ['claude', 'qoder'], duplicates: [],
    triggerOverlapWith: [],
    mounts: [{ at: '2026-07-15', action: 'mount', agentId: 'claude', scope: 'user' }],
    status: 'mounted',
  },
  {
    id: 'item-writer', name: 'document-writer', description: '生成排版规范的长文档',
    type: 'skill', level: 'user', sourcePath: '~/.codex/skills/document-writer',
    mountedBy: ['codex'], duplicates: [],
    triggerOverlapWith: ['item-docx'],
    mounts: [{ at: '2026-06-20', action: 'mount', agentId: 'codex', scope: 'user' }],
    status: 'mounted',
  },
  {
    id: 'item-i18n', name: 'i18n-audit', description: '检查界面文案的本地化遗漏',
    type: 'skill', level: 'project', projectId: 'proj-x', sourcePath: '~/work/proj-x/.codex/skills/i18n-audit',
    mountedBy: ['codex'], duplicates: [],
    triggerOverlapWith: [],
    mounts: [{ at: '2026-09-18', action: 'mount', agentId: 'codex', scope: 'project', projectId: 'proj-x' }],
    status: 'mounted',
  },
  {
    id: 'item-figma-mcp', name: 'Figma Dev Mode', description: '读取设计稿变量与 frame 结构',
    type: 'mcp', level: 'user', sourcePath: '~/.codex/config.toml#mcp.figma',
    mountedBy: ['codex', 'cursor'], duplicates: [],
    triggerOverlapWith: [],
    mounts: [{ at: '2026-09-01', action: 'mount', agentId: 'cursor', scope: 'user' }],
    status: 'mounted',
  },
  {
    id: 'item-puppeteer-mcp', name: 'Puppeteer', description: '无头浏览器截图与自动化',
    type: 'mcp', level: 'project', projectId: 'proj-x', sourcePath: '~/work/proj-x/.cursor/mcp.json#puppeteer',
    mountedBy: ['cursor'], duplicates: [],
    triggerOverlapWith: [],
    mounts: [{ at: '2026-09-18', action: 'mount', agentId: 'cursor', scope: 'project', projectId: 'proj-x' }],
    status: 'mounted',
  },
  {
    id: 'item-legacy-eps', name: 'eps-converter', description: '老 EPS 素材转 SVG（2024 外包项目遗留）',
    type: 'skill', level: 'user', sourcePath: '~/.codex/skills/eps-converter',
    mountedBy: [], duplicates: [],
    triggerOverlapWith: [],
    mounts: [{ at: '2026-03-11', action: 'unmount', agentId: 'codex', scope: 'user' }],
    status: 'zero-mount',
  },
  {
    id: 'item-legacy-seo', name: 'seo-grader', description: '站点 SEO 打分',
    type: 'skill', level: 'user', sourcePath: '~/.claude/skills/seo-grader',
    mountedBy: [], duplicates: ['~/.cursor/skills/seo-grader'],
    triggerOverlapWith: [],
    mounts: [],
    status: 'zero-mount',
  },
  {
    id: 'item-token-lookup', name: 'design-tokens', description: '跨项目读取 design-tokens.json',
    type: 'skill', level: 'project', projectId: 'sketchlib', sourcePath: '~/work/sketchlib/.claude/skills/design-tokens',
    mountedBy: ['claude'], duplicates: [],
    triggerOverlapWith: [],
    mounts: [{ at: '2026-09-18', action: 'mount', agentId: 'claude', scope: 'project', projectId: 'sketchlib' }],
    status: 'mounted',
  },
  {
    id: 'item-supabase-mcp', name: 'Supabase', description: '数据库查询与 schema 迁移',
    type: 'mcp', level: 'user', sourcePath: '~/.claude.json#mcp.supabase',
    mountedBy: ['claude'], duplicates: [],
    triggerOverlapWith: [],
    mounts: [{ at: '2026-08-27', action: 'mount', agentId: 'claude', scope: 'user' }],
    status: 'unmounted',
  },
  {
    id: 'item-a11y', name: 'a11y-check', description: 'WCAG 2.1 AA 自动核查',
    type: 'skill', level: 'project', projectId: 'proj-x', sourcePath: '~/work/proj-x/.codex/skills/a11y-check',
    mountedBy: ['codex'], duplicates: [],
    triggerOverlapWith: [],
    mounts: [{ at: '2026-09-18', action: 'mount', agentId: 'codex', scope: 'project', projectId: 'proj-x' }],
    status: 'mounted',
  },
  {
    id: 'item-archive', name: 'archive-2024', description: '历史归档项目的杂项技能包（未拆）',
    type: 'skill', level: 'user', sourcePath: '~/.codex/skills/archive-2024',
    mountedBy: [], duplicates: [],
    triggerOverlapWith: [],
    mounts: [],
    status: 'zero-mount',
  },
]

export const assemblyEvents: AssemblyEvent[] = [
  {
    id: 'asm-1',
    date: '2026-09-18 23:41',
    agentId: 'codex',
    projectId: 'proj-x',
    added: ['item-i18n', 'item-a11y', 'item-docx', 'item-token-lookup'],
    removed: ['item-supabase-mcp'],
    conflicts: [{ itemId: 'item-writer', reason: '与 docx 触发词重叠（"写文档"），Codex 跳过了它' }],
    reviewed: false,
  },
]

export const logEntries: LogEntry[] = [
  { id: 'log-3', at: '2026-09-18 23:41', actor: 'codex', actorKind: 'agent', action: '为 proj-x 装配 4 项（跳过 1 项冲突）', target: '~/work/proj-x/.codex/skills', reversible: true },
  { id: 'log-2', at: '2026-09-17 10:02', actor: 'qoder', actorKind: 'agent', action: '卸载 supabase-mcp（项目未用数据库）', target: '~/.claude.json#mcp.supabase', reversible: true },
  { id: 'log-1', at: '2026-09-16 09:30', actor: '智昊', actorKind: 'human', action: '删除 archive-2024 副本', target: '~/.cursor/skills/archive-2024', reversible: true },
]

/** 演示用总量：让清单页显得"接近真实规模"而不是 12 条 */
export const scannedTotals = { skills: 973, mcps: 21, agents: 4, projects: 36 }
