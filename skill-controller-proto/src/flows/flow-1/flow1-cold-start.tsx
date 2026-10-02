// =============================================
// FLOW: Cold Start — Full Inventory (冷启动即满)
// STORY: story-1 ｜ SCREENS: 3
// Scenario: SaaS Management（Sidebar 三段式）
// 三终态：✅ 满盘可检索 ｜ ❌ 授权被拒→半空引导态（非白屏）｜ ↩ 关闭授权→下次再问，不骚扰
// =============================================

import { useEffect, useMemo, useState } from 'react'
import { Link } from 'react-router-dom'
import { toast } from 'sonner'
import {
  Check,
  FolderOpen,
  History,
  Plug,
  Search,
  Server,
  ShieldCheck,
  X,
} from 'lucide-react'

import {
  AlertDialog,
  AlertDialogAction,
  AlertDialogCancel,
  AlertDialogContent,
  AlertDialogDescription,
  AlertDialogFooter,
  AlertDialogHeader,
  AlertDialogTitle,
} from '@/components/ui/alert-dialog'
import { Badge } from '@/components/ui/badge'
import { Button } from '@/components/ui/button'
import {
  Card,
  CardContent,
  CardDescription,
  CardHeader,
  CardTitle,
} from '@/components/ui/card'
import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogFooter,
  DialogHeader,
  DialogTitle,
} from '@/components/ui/dialog'
import { Input } from '@/components/ui/input'
import { ScrollArea } from '@/components/ui/scroll-area'
import {
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue,
} from '@/components/ui/select'
import { Separator } from '@/components/ui/separator'
import {
  Skeleton,
} from '@/components/ui/skeleton'
import {
  Table,
  TableBody,
  TableCell,
  TableHead,
  TableHeader,
  TableRow,
} from '@/components/ui/table'
import { Tabs, TabsList, TabsTrigger } from '@/components/ui/tabs'

import type { InventoryItem, ViewMode } from '../shared/types'
import {
  agents,
  items as allItems,
  projects,
  scannedTotals,
} from '../shared/mock-data'

const agentName = (id: string) => agents.find((a) => a.id === id)?.name ?? id
const projectName = (id?: string) =>
  id ? projects.find((p) => p.id === id)?.name ?? id : undefined

/* ================================================
   FLOW: Cold Start
   SCREEN 1 of 3: Disk Access Gate
   ------------------------------------------------
   ENTRY:  App 首次启动（无授权记录）
   EXIT:   "授权并扫描" → SCREEN 2
   BRANCH: "拒绝" → SCREEN 2（denied 引导态）
   ================================================ */
export function Screen1_DiskAccessGate({
  onGranted,
  onDenied,
}: {
  onGranted: () => void
  onDenied: () => void
}) {
  return (
    <Dialog open>
      <DialogContent showCloseButton={false} className="max-w-md">
        <DialogHeader>
          <ShieldCheck className="mb-2 h-8 w-8 text-muted-foreground" />
          <DialogTitle>让控制器看见全盘 Skill</DialogTitle>
          <DialogDescription asChild>
            <div className="space-y-3 pt-1 text-sm">
              <p>
                本工具需要读取以下目录来构建清单（一次授权，全程本地，无任何网络请求）：
              </p>
              <ul className="list-disc space-y-1 pl-4 font-mono text-xs">
                <li>~/.codex · ~/.claude · ~/.qoderworkcn · ~/.cursor</li>
                <li>你的工作目录中的项目级 skills/ 与 mcp 配置</li>
              </ul>
              <p className="text-muted-foreground">
                扫描结果只存在本机。你随时可以在「设置」里缩小扫描范围。
              </p>
            </div>
          </DialogDescription>
        </DialogHeader>
        {/* STATE: default — 两按钮可用 */}
        <DialogFooter className="gap-2 sm:gap-0">
          <Button variant="ghost" onClick={onDenied}>
            这次先不
          </Button>
          <Button
            onClick={() => {
              onGranted()
            }}
          >
            <Check className="mr-2 h-4 w-4" />
            授权并扫描
          </Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  )
}

{/* → "授权并扫描" clicked → SCREEN 2: Inventory（loading → filled） */}
{/* → "这次先不" clicked → SCREEN 2（STATE: denied）；下次启动再问，不骚扰 */}

/* ================================================
   FLOW: Cold Start
   SCREEN 2 of 3: Inventory（清单）
   ------------------------------------------------
   ENTRY:  授权完成（S1）/ App 已有授权记录直接进
   EXIT:   点行 → SCREEN 3 详情栏（同屏右栏，不跳页）
   BRANCH: denied → 半空引导态（解释 + 重新授权按钮）
   STATES: loading(≤5s Skeleton) / filled / searching-empty / denied
   ================================================ */
export function Screen2_Inventory({
  denied,
  onRegrant,
  selected,
  onSelect,
}: {
  denied: boolean
  onRegrant: () => void
  selected: InventoryItem | null
  onSelect: (item: InventoryItem | null) => void
}) {
  const [loading, setLoading] = useState(true)
  const [view, setView] = useState<ViewMode>('by-agent')
  const [type, setType] = useState<'all' | 'skill' | 'mcp'>('all')
  const [q, setQ] = useState('')

  useEffect(() => {
    if (denied) return
    const t = setTimeout(() => {
      setLoading(false)
      toast.success(`全盘扫描完成 · ${scannedTotals.skills} Skills · ${scannedTotals.mcps} MCP`)
    }, 1200) // 真实实现：首版索引 ≤5s 出清单
    return () => clearTimeout(t)
  }, [denied])

  const filtered = useMemo(
    () =>
      allItems.filter(
        (i) =>
          (type === 'all' || i.type === type) &&
          (q === '' ||
            i.name.toLowerCase().includes(q.toLowerCase()) ||
            i.description.includes(q)),
      ),
    [type, q],
  )

  // ── 授权被拒：半空引导态（❌ error 分支，绝不白屏）──
  if (denied) {
    return (
      <div className="flex h-full items-center justify-center p-8">
        <Card className="max-w-sm">
          <CardHeader>
            <CardTitle className="text-base">清单是空的，因为你还没授权</CardTitle>
            <CardDescription>
              不授权也能用，但控制器看不见任何东西。授权后 5 秒内出全盘清单，全程本地。
            </CardDescription>
          </CardHeader>
          <CardContent>
            <Button onClick={onRegrant}>
              <ShieldCheck className="mr-2 h-4 w-4" />
              授权并扫描
            </Button>
          </CardContent>
        </Card>
      </div>
    )
  }

  return (
    <div className="flex h-full min-h-0">
      <div className="flex min-w-0 flex-1 flex-col gap-4 p-6">
        {/* PageHeader */}
        <div className="flex items-center justify-between">
          <div>
            <h1 className="text-xl font-semibold">全盘清单</h1>
            <p className="text-sm text-muted-foreground">
              {loading ? '正在扫描…' : `${scannedTotals.skills} Skills · ${scannedTotals.mcps} MCP · ${scannedTotals.agents} Agents · ${scannedTotals.projects} 项目`}
            </p>
          </div>
          {/* 无「+ 新建」类写操作——GUI 动作封顶：删除/恢复（Story 4） */}
        </div>

        {/* Major#2：部分降级态——读不到的位置如实报数，中性色，不红色告警 */}
        {!loading && (
          <div className="flex items-center justify-between gap-4 rounded-md border bg-muted/40 px-3 py-2 text-sm">
            <span className="text-muted-foreground leading-relaxed">
              2 个位置未能读取（1 无权限 · 1 JSON 解析失败）——清单基于其余 44 个位置构建
            </span>
            <Link className="shrink-0 underline underline-offset-4" to="/settings">
              查看扫描范围
            </Link>
          </div>
        )}

        {/* Toolbar：视角 Tabs + 对象 Select + 搜索 */}
        <div className="flex items-center gap-3">
          <Tabs value={view} onValueChange={(v) => setView(v as ViewMode)}>
            <TabsList>
              <TabsTrigger value="by-agent">按 Agent</TabsTrigger>
              <TabsTrigger value="by-project">按项目</TabsTrigger>
              <TabsTrigger value="by-scope">按层级</TabsTrigger>
            </TabsList>
          </Tabs>
          <Select value={type} onValueChange={(v) => setType(v as typeof type)}>
            <SelectTrigger className="w-32">
              <SelectValue placeholder="对象类型" />
            </SelectTrigger>
            <SelectContent>
              <SelectItem value="all">全部对象</SelectItem>
              <SelectItem value="skill">Skill</SelectItem>
              <SelectItem value="mcp">MCP</SelectItem>
            </SelectContent>
          </Select>
          <div className="relative ml-auto w-64">
            <Search className="absolute left-2.5 top-1/2 h-4 w-4 -translate-y-1/2 text-muted-foreground" />
            <Input
              value={q}
              onChange={(e) => setQ(e.target.value)}
              placeholder="搜索 Skill / MCP…"
              className="pl-8"
            />
          </div>
        </div>

        {/* Table */}
        <div className="min-h-0 flex-1 overflow-x-auto rounded-lg border">
          <ScrollArea className="h-full">
            <Table>
              <TableHeader>
                <TableRow>
                  <TableHead>名称</TableHead>
                  <TableHead>归属</TableHead>
                  <TableHead>被谁挂载</TableHead>
                  <TableHead>最近变动</TableHead>
                </TableRow>
              </TableHeader>
              <TableBody>
                {/* STATE: loading — Skeleton 兜底 */}
                {loading ? (
                  Array.from({ length: 8 }).map((_, i) => (
                    <TableRow key={i}>
                      <TableCell colSpan={4}>
                        <Skeleton className="h-5 w-full" />
                      </TableCell>
                    </TableRow>
                  ))
                ) : filtered.length === 0 ? (
                  /* STATE: searching-empty（P1-3：空态带引导 CTA） */
                  <TableRow>
                    <TableCell colSpan={4} className="h-28 text-center text-muted-foreground">
                      <div className="flex flex-col items-center gap-3">
                        <p>没有匹配「{q}」的条目 —— 清单没有藏东西，只是这次没搜到</p>
                        <Button size="sm" variant="outline" onClick={() => setQ('')}>
                          清空搜索
                        </Button>
                      </div>
                    </TableCell>
                  </TableRow>
                ) : (
                  filtered.map((item) => (
                    <TableRow
                      key={item.id}
                      className="cursor-pointer focus-visible:outline-none focus-visible:ring-1 focus-visible:ring-ring"
                      tabIndex={0}
                      role="button"
                      aria-label={`查看 ${item.name} 详情`}
                      onClick={() => onSelect(item)}
                      onKeyDown={(e) => {
                        if (e.key === 'Enter' || e.key === ' ') {
                          e.preventDefault()
                          onSelect(item)
                        }
                      }}
                    >
                      <TableCell>
                        <div className="flex items-center gap-2 font-medium">
                          {item.type === 'skill' ? (
                            <FolderOpen className="h-4 w-4 text-muted-foreground" />
                          ) : (
                            <Server className="h-4 w-4 text-muted-foreground" />
                          )}
                          {item.name}
                          {item.duplicates.length > 0 && (
                            <span className="text-xs text-muted-foreground">
                              副本 ×{item.duplicates.length + 1}
                            </span>
                          )}
                        </div>
                        <p className="max-w-[280px] truncate text-xs text-muted-foreground">
                          {item.description}
                        </p>
                      </TableCell>
                      <TableCell>
                        <div className="flex flex-wrap gap-1">
                          <Badge variant="outline">
                            {item.type === 'skill' ? 'Skill' : 'MCP'}
                          </Badge>
                          <Badge variant="secondary">
                            {item.level === 'user'
                              ? '用户级'
                              : projectName(item.projectId) ?? '项目级'}
                          </Badge>
                          {/* 零挂载：中性徽章——工具零观点，不用 destructive 色 */}
                          {item.status === 'zero-mount' && (
                            <Badge variant="outline" className="text-muted-foreground">
                              从未挂载
                            </Badge>
                          )}
                        </div>
                      </TableCell>
                      <TableCell className="text-sm">
                        {item.mountedBy.length
                          ? item.mountedBy.map(agentName).join(' · ')
                          : '—'}
                      </TableCell>
                      <TableCell className="text-sm text-muted-foreground tabular-nums">
                        {item.mounts[0]?.at ?? '—'}
                      </TableCell>
                    </TableRow>
                  ))
                )}
              </TableBody>
            </Table>
          </ScrollArea>
        </div>
      </div>

      {/* 右栏：详情面板（选中才出现，Finder 式同屏） */}
      {selected && <Screen3_ItemDetail item={selected} onClose={() => onSelect(null)} />}
    </div>
  )
}

{/* → User clicks a row → SCREEN 3: Item Detail（右栏滑入，清单保持可见） */}

/* ================================================
   FLOW: Cold Start
   SCREEN 3 of 3: Item Detail（右栏面板）
   ------------------------------------------------
   ENTRY:  清单行点击
   EXIT:   "关闭" → 回到 SCREEN 2（选中态清除）
   动作封顶：仅 恢复挂载 / 删除（Story 4 的 GUI 上限）
   ================================================ */
export function Screen3_ItemDetail({
  item,
  onClose,
}: {
  item: InventoryItem
  onClose: () => void
}) {
  const [confirmDelete, setConfirmDelete] = useState(false)
  const overlaps = item.triggerOverlapWith.map(
    (id) => allItems.find((i) => i.id === id)!,
  )
  return (
    <aside className="flex w-[360px] shrink-0 flex-col border-l bg-muted/30">
      <div className="flex items-center justify-between p-4">
        <div className="flex items-center gap-2 font-medium">
          {item.type === 'skill' ? (
            <Plug className="h-4 w-4 text-muted-foreground" />
          ) : (
            <Server className="h-4 w-4 text-muted-foreground" />
          )}
          {item.name}
        </div>
        <Button variant="ghost" size="icon" aria-label="关闭详情" onClick={onClose}>
          <X className="h-4 w-4" />
        </Button>
      </div>
      <Separator />
      <ScrollArea className="flex-1">
        <div className="space-y-5 p-4 text-sm">
          <p className="leading-relaxed text-muted-foreground">{item.description}</p>

          <div>
            <h2 className="mb-1 font-medium">落点</h2>
            <p className="font-mono text-xs">{item.sourcePath}</p>
            {item.duplicates.map((d) => (
              <p key={d} className="font-mono text-xs text-muted-foreground">
                {d}（副本）
              </p>
            ))}
          </div>

          <div>
            <h2 className="mb-1 font-medium">被哪些 Agent 挂载</h2>
            {item.mountedBy.length ? (
              <div className="flex flex-wrap gap-1">
                {item.mountedBy.map((a) => (
                  <Badge key={a} variant="secondary">
                    {agentName(a)}
                  </Badge>
                ))}
              </div>
            ) : (
              <p className="text-muted-foreground">当前无人挂载（中性事实，不是警告）</p>
            )}
          </div>

          <div>
            <h2 className="mb-2 flex items-center gap-1 font-medium">
              <History className="h-4 w-4 text-muted-foreground" />
              挂载变动
            </h2>
            <ul className="space-y-2">
              {item.mounts.length === 0 && (
                <li className="text-muted-foreground">近 90 天无变动</li>
              )}
              {item.mounts.map((m, i) => (
                <li key={i} className="flex items-center justify-between">
                  <span>
                    {m.action === 'mount' ? '挂上' : '卸下'} · {agentName(m.agentId)}
                    {m.scope === 'project' ? ` · ${projectName(m.projectId)}` : ' · 用户级'}
                  </span>
                  <span className="text-xs text-muted-foreground">{m.at}</span>
                </li>
              ))}
            </ul>
          </div>

          {/* 静态触发词重叠并列——只摆数，不判断谁该让位 */}
          {overlaps.length > 0 && (
            <div>
              <h2 className="mb-2 font-medium">触发词重叠（静态文案比对）</h2>
              <div className="grid grid-cols-2 gap-2">
                <Card>
                  <CardHeader className="p-3">
                    <CardTitle className="text-xs">{item.name}</CardTitle>
                    <CardDescription className="text-xs">{item.description}</CardDescription>
                  </CardHeader>
                </Card>
                {overlaps.map((o) => (
                  <Card key={o.id}>
                    <CardHeader className="p-3">
                      <CardTitle className="text-xs">{o.name}</CardTitle>
                      <CardDescription className="text-xs">{o.description}</CardDescription>
                    </CardHeader>
                  </Card>
                ))}
              </div>
              <p className="mt-1 text-xs text-muted-foreground">
                并列展示。谁留谁走，你或你的 Agent 决定。
              </p>
            </div>
          )}

          <Separator />
          <div className="flex gap-2">
            {item.mountedBy.length === 0 ? (
              <Button
                variant="outline"
                size="sm"
                onClick={() => toast.success(`已回挂 ${item.name}（走 CLI 写回目录）`)}
              >
                恢复挂载
              </Button>
            ) : (
              <Button
                variant="outline"
                size="sm"
                onClick={() => toast(`已请 ${item.mountedBy[0]} 卸下 ${item.name}`)}
              >
                卸下
              </Button>
            )}
            <Button
              variant="outline"
              size="sm"
              onClick={() => setConfirmDelete(true)}
            >
              删除
            </Button>
          </div>
        </div>
      </ScrollArea>

      {/* P1-5：不可逆动作二次确认，明说后果与恢复窗 */}
      <AlertDialog open={confirmDelete} onOpenChange={setConfirmDelete}>
        <AlertDialogContent>
          <AlertDialogHeader>
            <AlertDialogTitle>把「{item.name}」移入回收站？</AlertDialogTitle>
            <AlertDialogDescription>
              磁盘文件将移入本工具回收站，30 天内可在「回退」页一步恢复；
              各 Agent 的挂载将同时卸下。这一步会写入操作日志。
            </AlertDialogDescription>
          </AlertDialogHeader>
          <AlertDialogFooter>
            <AlertDialogCancel>取消</AlertDialogCancel>
            <AlertDialogAction
              onClick={() => toast(`${item.name} 已移入回收站 · 30 天内可恢复`)}
            >
              移入回收站
            </AlertDialogAction>
          </AlertDialogFooter>
        </AlertDialogContent>
      </AlertDialog>
    </aside>
  )
}

{/* → "关闭" / Esc → SCREEN 2（选中态清除，退出 flow） */}

// =============================================
// Flow 容器（App Shell 直接挂载此组件作为 /inventory 路由）
// =============================================
export function Flow1_ColdStart() {
  const [gate, setGate] = useState<'ask' | 'granted' | 'denied'>('ask')
  const [selected, setSelected] = useState<InventoryItem | null>(null)

  return (
    <div className="h-full">
      {gate === 'ask' && (
        <Screen1_DiskAccessGate
          onGranted={() => setGate('granted')}
          onDenied={() => setGate('denied')}
        />
      )}
      <Screen2_Inventory
        denied={gate === 'denied'}
        onRegrant={() => setGate('ask')}
        selected={selected}
        onSelect={(i) => setSelected(i)}
      />
    </div>
  )
}
