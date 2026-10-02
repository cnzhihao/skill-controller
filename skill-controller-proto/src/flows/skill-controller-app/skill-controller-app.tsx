// =============================================
// Skill Controller — Main Application (App Shell)
// Sidebar 四段导航（继承 sitemap.json，不自创结构）+ 全部 flow 集成
// Scenario: SaaS Management ｜ 组件库: shadcn/ui
// =============================================

import { useEffect, useState } from 'react'
import { Navigate, Route, Routes, useLocation } from 'react-router-dom'
import {
  BookOpenCheck,
  History,
  Moon,
  Settings,
  ShieldCheck,
  Sparkles,
  Sun,
} from 'lucide-react'
import { Link } from 'react-router-dom'

import { Toaster } from '@/components/ui/sonner'
import {
  Sidebar,
  SidebarContent,
  SidebarFooter,
  SidebarGroup,
  SidebarGroupContent,
  SidebarGroupLabel,
  SidebarHeader,
  SidebarMenu,
  SidebarMenuBadge,
  SidebarMenuButton,
  SidebarMenuItem,
  SidebarProvider,
  SidebarRail,
} from '@/components/ui/sidebar'
import { Button } from '@/components/ui/button'
import { Card, CardDescription, CardHeader, CardTitle } from '@/components/ui/card'

import { Flow1_ColdStart } from '../flow-1/flow1-cold-start'
import { Flow2_AssemblyReview } from '../flow-2/flow2-assembly-review'

// ── 未选入本批 flow 的导航页：诚实占位，不假装完成 ──
function SkeletonPage({
  title,
  story,
}: {
  title: string
  story: string
}) {
  return (
    <div className="flex h-full items-center justify-center p-8">
      <Card className="max-w-sm border-dashed">
        <CardHeader>
          <CardTitle className="text-base">{title}</CardTitle>
          <CardDescription>
            本批 flow 未展开此页（{story}）。导航在此保留是为了验证骨架：
            它真的只是侧栏第四项，不该抢清单的戏。
          </CardDescription>
        </CardHeader>
      </Card>
    </div>
  )
}

const nav: Array<{
  to: string
  label: string
  icon: typeof ShieldCheck
  demo?: boolean
}> = [
  { to: '/inventory', label: '全盘清单', icon: ShieldCheck },
  { to: '/flow2', label: '装配验收', icon: Sparkles, demo: true },
  { to: '/ledger', label: '挂载账', icon: BookOpenCheck },
  { to: '/rollback', label: '回退', icon: History },
  { to: '/settings', label: '设置', icon: Settings },
]

function AppSidebar() {
  const { pathname } = useLocation()
  return (
    <Sidebar>
      <SidebarHeader>
        <div className="flex items-center gap-2 px-2 py-1.5 text-sm font-semibold">
          <ShieldCheck className="h-4 w-4" />
          Skill 控制器
        </div>
      </SidebarHeader>
      <SidebarContent>
        <SidebarGroup>
          <SidebarGroupLabel>本地 · 无云端</SidebarGroupLabel>
          <SidebarGroupContent>
            <SidebarMenu>
              {nav.map((n) => (
                <SidebarMenuItem key={n.to}>
                  <SidebarMenuButton asChild isActive={pathname === n.to}>
                    <Link to={n.to}>
                      <n.icon />
                      <span>{n.label}</span>
                    </Link>
                  </SidebarMenuButton>
                  {n.demo && <SidebarMenuBadge>演示入口</SidebarMenuBadge>}
                </SidebarMenuItem>
              ))}
            </SidebarMenu>
          </SidebarGroupContent>
        </SidebarGroup>
      </SidebarContent>
      <SidebarFooter>
        <p className="px-2 text-xs text-muted-foreground">
          973 Skills · 21 MCP · 4 Agents · 全在本机
        </p>
      </SidebarFooter>
      <SidebarRail />
    </Sidebar>
  )
}

export function SkillControllerApp() {
  const [dark, setDark] = useState(false)
  useEffect(() => {
    document.documentElement.classList.toggle('dark', dark)
  }, [dark])

  return (
    <SidebarProvider className="h-screen">
      <AppSidebar />
      <main className="flex min-w-0 flex-1 flex-col">
        {/* 屏幕选择器：键盘可达的直达入口（原型审查用） */}
        <div className="flex items-center justify-end gap-2 border-b px-4 py-1.5">
          <Button size="sm" variant="ghost" aria-label="切换深浅色" onClick={() => setDark((d) => !d)}>
            {dark ? <Sun className="h-4 w-4" /> : <Moon className="h-4 w-4" />}
          </Button>
        </div>
        <div className="min-h-0 flex-1">
          <Routes>
            <Route path="/" element={<Navigate to="/inventory" replace />} />
            <Route path="/inventory" element={<Flow1_ColdStart />} />
            <Route path="/flow2" element={<Flow2_AssemblyReview />} />
            <Route
              path="/ledger"
              element={<SkeletonPage title="挂载账" story="story-5 · 零挂载清单/变动时间线/静态重叠对" />}
            />
            <Route
              path="/rollback"
              element={<SkeletonPage title="回退（日志 + 回收站）" story="story-4 · 一步撤销/≥30 天恢复窗" />}
            />
            <Route
              path="/settings"
              element={<SkeletonPage title="设置" story="扫描范围 · 保留窗 · CLI 安装（刻意极小）" />}
            />
          </Routes>
        </div>
      </main>
      <Toaster position="bottom-right" />
    </SidebarProvider>
  )
}
