// =============================================
// FLOW: Assembly Review — Agent 自装配验收（⭐ 命门假设的验收界面）
// STORY: story-2 + story-3 ｜ SCREENS: 4
// 入口：智昊不在场时 Codex 经 CLI 完成装配；App 下次打开进入
// 三终态：✅ 验收通过（Banner 转已阅）｜ ❌ 写入失败在 diff 内行内留痕+单条重试（不静默、不 toast 一闪而过）｜ ↩ 关闭 diff = 默认接受（装配已实际发生；回退是显式动作）
// =============================================

import { useMemo, useState } from 'react'
import { toast } from 'sonner'
import {
  AlertTriangle,
  Bot,
  Check,
  ChevronRight,
  FolderOpen,
  RotateCcw,
  Server,
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
  Sheet,
  SheetContent,
  SheetDescription,
  SheetFooter,
  SheetHeader,
  SheetTitle,
} from '@/components/ui/sheet'
import { Separator } from '@/components/ui/separator'
import { ScrollArea } from '@/components/ui/scroll-area'

import type { InventoryItem } from '../shared/types'
import {
  agents,
  assemblyEvents,
  items as allItems,
  projects,
} from '../shared/mock-data'
import { Screen3_ItemDetail } from '../flow-1/flow1-cold-start'

const agentName = (id: string) => agents.find((a) => a.id === id)?.name ?? id
const itemById = (id: string) => allItems.find((i) => i.id === id)!

/* ================================================
   FLOW: Assembly Review
   SCREEN 1 of 4: Project View + Assembly Banner
   ------------------------------------------------
   ENTRY:  App 打开落在 by-project 视角（存在未验收装配事件时顶部出 Banner）
   EXIT:   Banner「查看装配记录」→ SCREEN 2（diff Sheet）
   设计裁定：Banner 用中性 muted 底色——"Agent 干了活"不是警告
   ================================================ */
export function Screen1_ProjectBanner({
  reviewed,
  restored,
  onOpenDiff,
}: {
  reviewed: boolean
  restored: boolean
  onOpenDiff: () => void
}) {
  const ev = assemblyEvents[0]
  const proj = projects.find((p) => p.id === ev.projectId)!
  const addedItems = ev.added.map(itemById)

  return (
    <div className="flex h-full min-h-0 flex-col gap-4 p-6">
      <div>
        <h1 className="text-xl font-semibold">按项目 · {proj.name}</h1>
        <p className="font-mono text-xs text-muted-foreground">{proj.path}</p>
      </div>

      {/* 装配 Banner（中性色，未验收时最显眼） */}
      <div
        className={
          reviewed || restored
            ? 'flex items-center justify-between rounded-lg border bg-muted/40 px-4 py-3 text-sm text-muted-foreground'
            : 'flex items-center justify-between rounded-lg border bg-muted px-4 py-3 text-sm'
        }
      >
        <span className="flex items-center gap-2">
          <Bot className="h-4 w-4" />
          {restored
            ? 'Codex 曾为该项目装配 5 项，你已恢复原状'
            : reviewed
              ? '昨晚 Codex 为该项目装配了 4 项 · 已验收'
              : '昨天 23:41 · Codex 为该项目装配了 4 项（跳过 1 项冲突）'}
        </span>
        {!reviewed && !restored ? (
          <Button size="sm" variant="outline" onClick={onOpenDiff}>
            查看装配记录
            <ChevronRight className="ml-1 h-4 w-4" />
          </Button>
        ) : (
          <Button size="sm" variant="ghost" onClick={onOpenDiff}>
            回看
          </Button>
        )}
      </div>

      {/* 该项目当前生效条目（新装配项以左边框标"新"，中性非彩色） */}
      <div className="min-h-0 flex-1">
        <ScrollArea className="h-full rounded-lg border">
          <ul className="divide-y">
            {addedItems.map((it) => (
              <li key={it.id} className="flex items-center gap-3 px-4 py-3 text-sm">
                {it.type === 'skill' ? (
                  <FolderOpen className="h-4 w-4 shrink-0 text-muted-foreground" />
                ) : (
                  <Server className="h-4 w-4 shrink-0 text-muted-foreground" />
                )}
                <span className="font-medium">{it.name}</span>
                <span className="text-muted-foreground">{it.description}</span>
                <Badge variant="outline" className="ml-auto shrink-0">
                  新装配
                </Badge>
              </li>
            ))}
            {!restored && (
              <li className="flex items-center gap-3 px-4 py-3 text-sm text-muted-foreground">
                <RotateCcw className="h-4 w-4" />
                恢复原状：回到 Codex 装配之前
                <Button
                  size="sm"
                  variant="outline"
                  className="ml-auto"
                  onClick={onOpenDiff}
                >
                  进入验收面
                </Button>
              </li>
            )}
          </ul>
        </ScrollArea>
      </div>
    </div>
  )
}

{/* → "查看装配记录" clicked → SCREEN 2: Assembly Diff Sheet */}

/* ================================================
   FLOW: Assembly Review
   SCREEN 2 of 4: Assembly Diff（Sheet，右侧滑入）
   ------------------------------------------------
   ENTRY:  Banner「查看装配记录」
   EXIT:   "关闭并验收" → 回到 SCREEN 1（Banner 转已阅态）—— 关闭 = 默认接受（裁定 ①）
   BRANCH: 点条目行 → SCREEN 3（详情右栏，diff 保持可见）
           "全部恢复原状" → SCREEN 4 AlertDialog
   ERROR:  冲突行行内留痕（AlertTriangle + 原因 + 单条重试）——不用 toast 一闪而过
   ================================================ */
export function Screen2_AssemblyDiff({
  open,
  onOpenChange,
  onSelectItem,
  onRequestRestore,
}: {
  open: boolean
  onOpenChange: (v: boolean) => void
  onSelectItem: (item: InventoryItem) => void
  onRequestRestore: () => void
}) {
  const ev = assemblyEvents[0]
  const [retried, setRetried] = useState(false)
  const rows = useMemo(
    () => ({
      added: ev.added.map(itemById),
      removed: ev.removed.map(itemById),
      conflicts: ev.conflicts,
    }),
    [ev],
  )

  return (
    <Sheet open={open} onOpenChange={onOpenChange}>
      <SheetContent className="w-[520px] gap-0 sm:max-w-[520px]">
        <SheetHeader>
          <SheetTitle>装配记录 · {agentName(ev.agentId)} → {projects.find((p) => p.id === ev.projectId)?.name}</SheetTitle>
          <SheetDescription className="font-mono text-xs">
            {ev.date} · 经 skillctl CLI · 来源均为用户级全集
          </SheetDescription>
        </SheetHeader>
        <Separator />
        <ScrollArea className="flex-1">
          <div className="space-y-6 p-4">
            {/* 带来组 */}
            <section>
              <h3 className="mb-2 flex items-center gap-1.5 text-sm font-medium">
                <Check className="h-4 w-4 text-muted-foreground" />
                挂上 {rows.added.length} 项（新装配）
              </h3>
              <ul className="space-y-1">
                {rows.added.map((it) => (
                  <li key={it.id}>
                    <button
                      className="flex w-full items-center gap-2 rounded-md px-2 py-2 text-left text-sm hover:bg-muted"
                      onClick={() => onSelectItem(it)}
                    >
                      <span className="font-medium">{it.name}</span>
                      <span className="truncate text-muted-foreground">{it.description}</span>
                      <span className="ml-auto shrink-0 font-mono text-xs text-muted-foreground">
                        {it.level === 'user' ? '用户级' : '项目级'}
                      </span>
                    </button>
                  </li>
                ))}
              </ul>
            </section>

            {/* 卸下组 */}
            {rows.removed.length > 0 && (
              <section>
                <h3 className="mb-2 flex items-center gap-1.5 text-sm font-medium">
                  <RotateCcw className="h-4 w-4 text-muted-foreground" />
                  卸下 {rows.removed.length} 项（项目未用到）
                </h3>
                <ul className="space-y-1">
                  {rows.removed.map((it) => (
                    <li key={it.id} className="px-2 py-1.5 text-sm text-muted-foreground">
                      {it.name} · 未脱离全集，可随时回挂
                    </li>
                  ))}
                </ul>
              </section>
            )}

            {/* 冲突/失败组：STATE error —— 行内留痕，可单条重试 */}
            {rows.conflicts.map((c) => (
              <section key={c.itemId}>
                <h3 className="mb-2 flex items-center gap-1.5 text-sm font-medium">
                  <AlertTriangle className="h-4 w-4" />
                  跳过 {rows.conflicts.length} 项（写入痕迹）
                </h3>
                <div className="rounded-md border bg-muted/40 p-3 text-sm">
                  <p className="font-medium">{itemById(c.itemId).name}</p>
                  <p className="mt-0.5 text-muted-foreground">
                    {retried
                      ? '重试成功 · 已挂载（第二次写入前已自动备份原文件）'
                      : c.reason}
                  </p>
                  {!retried && (
                    <Button
                      size="sm"
                      variant="outline"
                      className="mt-2"
                      onClick={() => {
                        setRetried(true)
                        toast.success('重试成功 · document-writer 已挂载')
                      }}
                    >
                      重试这一项
                    </Button>
                  )}
                </div>
              </section>
            ))}
          </div>
        </ScrollArea>
        <Separator />
        <SheetFooter className="flex-row justify-between pt-4">
          {/* 回退是显式动作（不是关掉就回滚） */}
          <Button variant="outline" onClick={onRequestRestore}>
            <RotateCcw className="mr-2 h-4 w-4" />
            全部恢复原状
          </Button>
          <Button
            onClick={() => {
              onOpenChange(false)
              toast.success('已验收 · 该装配记录转为已阅')
            }}
          >
            关闭并验收
          </Button>
        </SheetFooter>
      </SheetContent>
    </Sheet>
  )
}

{/* → 点条目行 → SCREEN 3: Item Detail（复用 F1-S3，diff 不关闭） */}
{/* → "关闭并验收" → SCREEN 1（Banner 已阅态，退出 flow） */}
{/* → "全部恢复原状" → SCREEN 4: Restore Confirmation */}

/* ================================================
   FLOW: Assembly Review
   SCREEN 3 of 4: Item Detail（复用 Flow 1 的右栏详情组件）
   ------------------------------------------------
   ENTRY:  diff 内条目行点击
   EXIT:   关闭详情 → 回到 SCREEN 2
   ================================================ */
/* （实现见 ../flow-1/flow1-cold-start.tsx 的 Screen3_ItemDetail —— 同一详情面
   服务两个 flow，避免两套规范。挂载时间线在此会显示 "mount · codex · 项目级"） */

/* ================================================
   FLOW: Assembly Review
   SCREEN 4 of 4: Restore Confirmation（AlertDialog）
   ------------------------------------------------
   ENTRY:  diff 底部「全部恢复原状」
   EXIT:   "确认恢复" → SCREEN 1（Banner 转已恢复态，Toast）
   BRANCH: "取消" → SCREEN 2（无任何改动）
   不可逆意识：其实完全可逆——日志里这次恢复本身还会再留一条
   ================================================ */
export function Screen4_RestoreConfirm({
  open,
  onOpenChange,
  onConfirmed,
}: {
  open: boolean
  onOpenChange: (v: boolean) => void
  onConfirmed: () => void
}) {
  const ev = assemblyEvents[0]
  return (
    <AlertDialog open={open} onOpenChange={onOpenChange}>
      <AlertDialogContent>
        <AlertDialogHeader>
          <AlertDialogTitle>
            把 {projects.find((p) => p.id === ev.projectId)?.name} 恢复到 Codex 装配之前？
          </AlertDialogTitle>
          <AlertDialogDescription>
            将卸下 {ev.added.length} 项、回挂 {ev.removed.length} 项。条目不会脱离全集；
            这一步本身也会写进操作日志，同样可以一步撤销。
          </AlertDialogDescription>
        </AlertDialogHeader>
        <AlertDialogFooter>
          <AlertDialogCancel>取消</AlertDialogCancel>
          <AlertDialogAction onClick={onConfirmed}>确认恢复</AlertDialogAction>
        </AlertDialogFooter>
      </AlertDialogContent>
    </AlertDialog>
  )
}

{/* → "确认恢复" → SCREEN 1（restored 态）↩ "取消" → SCREEN 2 */}

// =============================================
// Flow 容器（挂载于 /flow2 路由；入口即 S1）
// =============================================
export function Flow2_AssemblyReview() {
  const [diffOpen, setDiffOpen] = useState(false)
  const [reviewed, setReviewed] = useState(false)
  const [restored, setRestored] = useState(false)
  const [confirmOpen, setConfirmOpen] = useState(false)
  const [detail, setDetail] = useState<InventoryItem | null>(null)

  return (
    <div className="relative flex h-full min-h-0">
      <div className="min-w-0 flex-1">
        <Screen1_ProjectBanner
          reviewed={reviewed}
          restored={restored}
          onOpenDiff={() => setDiffOpen(true)}
        />
      </div>

      <Screen2_AssemblyDiff
        open={diffOpen}
        onOpenChange={(v) => {
          setDiffOpen(v)
          if (!v && !detail) setReviewed(true) // 裁定①：关闭 = 默认接受（查看详情不算关闭）
        }}
        onSelectItem={(it) => setDetail(it)}
        onRequestRestore={() => setConfirmOpen(true)}
      />

      {/* 详情浮在 diff 之上、贴右缘——diff 主体保持可见（骨架承诺） */}
      {detail && (
        <div className="absolute inset-y-0 right-0 z-[70] flex shadow-2xl">
          <Screen3_ItemDetail item={detail} onClose={() => setDetail(null)} />
        </div>
      )}

      <Screen4_RestoreConfirm
        open={confirmOpen}
        onOpenChange={setConfirmOpen}
        onConfirmed={() => {
          setConfirmOpen(false)
          setDiffOpen(false)
          setRestored(true)
          toast.success('已恢复至装配前 · 本次恢复也记入日志，可再撤销')
        }}
      />
    </div>
  )
}
