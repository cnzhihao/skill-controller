// RootView.swift — 导航壳（侧栏 4 项：清单/挂载账/回退/设置）
// 最小窗口宽 960（LayoutMetrics）；全局等宽在 App 入口施加。
// 授权门：首次启动 Sheet（"这次先不" → 下次启动再问，不骚扰）。
//
// 宽度分配纪律（2026-09-23 修「窗口收窄时侧栏被压扁」）：
// 侧栏是导航锚点，必须永远完整可见；挤压只允许发生在右侧内容区。
// NavigationSplitView 会拿「详情列内容的固有最小宽」去挤压侧栏——清单页工具栏
// 全是定宽件（类型 + 两个 fixedSize 菜单 + 层级 + 搜索 ≈ 900+ 硬下限），
// 在 960 窗口下详情列吃不下，于是反过来把侧栏压到 <180、搜索框还被右边缘切掉。
// 根因收在工具栏本身（见 InventoryView.toolbar：宽则一行、放不下即自动换行），侧栏 min 抬到 200 兜底。

import SwiftUI
import SkillControllerCore

enum NavPage: String, CaseIterable, Identifiable {
    case inventory = "清单"
    case ledger = "挂载账"
    case rollback = "回退"
    case settings = "设置"
    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .inventory: return "list.bullet.rectangle"
        case .ledger: return "chart.bar.doc.horizontal"
        case .rollback: return "arrow.uturn.backward"
        case .settings: return "gearshape"
        }
    }
}

struct RootView: View {
    @ObservedObject var app: AppState
    /// CLI 引导编排的**直持观察**（设计档 §2.3 观察接线，评审发现②落档）：CLIGuideModel 是
    /// AppState 的嵌套 ObservableObject，它的 @Published 不经 AppState 转发——不挂这行，
    /// 「探测翻成 current」「跳过后 wantsAutoPresent 翻转」都不会让 sheet binding 重新求值，
    /// F3「安装成功后引导自然消失」静默失效。
    @ObservedObject var cliGuide: CLIGuideModel

    var body: some View {
        NavigationSplitView {
            List(selection: $app.page) {
                ForEach(NavPage.allCases) { p in
                    Label(p.rawValue, systemImage: p.symbol)
                        .tag(p)
                }
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 200, ideal: 200, max: 280)
        } detail: {
            // 写操作回执放在页面之上：删除/恢复发生在任何一页，回执就该在任何一页看得见
            VStack(spacing: 0) {
                // 判据收在一个计算属性里：D32=B 加「重新挂回」回执时，我第一版忘了改这里，
                // 结果状态位有值、容器不出现——写操作结果上屏这条承诺又只对了一半。
                if app.hasWriteOutcome {
                    WriteOutcomeBanner(app: app)
                        .padding(.horizontal, 24)
                        .padding(.top, 16)
                }
                pageView
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Color.scBackground)
        }
        .frame(minWidth: LayoutMetrics.minWindowWidth, minHeight: 600)
        .background(Color.scBackground)
        .sheet(isPresented: showGate) {
            GateSheet(app: app)
                .interactiveDismissDisabled(app.gatePhase == .scanning)
        }
        // CLI 引导（台账 #19）：自动呈现 = 缺口 ∧ 该级别未跳过 ∧ 授权门已收口（gate != .ask）。
        // cliGuide 由上方 @ObservedObject 直持（评审发现②），探测/跳过的 @Published 直达本视图。
        // 授权门排前面（flow1 must 态）：门开着时引导在门后等（D23 现状下可接受串行）。
        .sheet(isPresented: showCliGuide) {
            CliGuideSheet(guide: cliGuide)
        }
    }

    private var showGate: Binding<Bool> {
        Binding(get: { app.gate == .ask }, set: { v in
            if !v, app.gate == .ask { app.deny() }
        })
    }

    /// 引导 Sheet 的开关 binding：想弹时开；用户经「先不装」（含 Esc）关闭时把想弹位翻回去。
    /// 复制按钮不关 Sheet（K8），所以 set(false) 只会由「先不装」触达。
    private var showCliGuide: Binding<Bool> {
        Binding(
            get: { app.gate != .ask && cliGuide.wantsAutoPresent },
            set: { if !$0 { cliGuide.dismissAutoPresent() } }
        )
    }

    @ViewBuilder
    private var pageView: some View {
        switch app.page {
        case .inventory:
            InventoryView(app: app)
        case .ledger:
            LedgerView(app: app)
        case .rollback:
            RollbackView(app: app)
        case .settings:
            SettingsView(app: app)
        }
    }
}
