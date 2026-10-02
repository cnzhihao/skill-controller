// CLIGuide.swift — CLI 检测编排与引导 Sheet（App 层；Core 面在 SetupGuide.swift）
//
// 编排（§2.3 数据流）：冷启动 + 每次前台活跃 + Sheet onAppear 三个触发点复检；
// 探测后台执行（同步 waitUntilExit 会阻塞主线程）、同一时刻最多一个在跑（单飞不叠加）；
// 自动呈现 = 缺口 ∧ 该级别未跳过 ∧ 授权门已收口（gate != .ask）。
//
// 出口只有两个，语义单一（K8，不重蹈 D28 的无标逃生缝）：
//   「复制提示词」→ NSPasteboard，按钮转「已复制」，不关 Sheet
//   「先不装」──→ 持久化当前缺口级别 + 关 Sheet；Esc（.cancelAction）接到同一按钮
//
// 红线：零网络零遥测（探测只读 PATH 与 exec）、探测不落操作日志（回退页不收探测噪音）。

import SwiftUI
import SkillControllerCore

// MARK: - 编排模型（设计档 §2.3）

@MainActor
final class CLIGuideModel: ObservableObject {
    /// 当前检测态（nil = 尚未探完；冷启动即后台探测，不阻塞首屏）
    @Published private(set) var status: CLIStatus?
    /// 探测在跑（设置页入口行据如实显示"正在检测"）
    @Published private(set) var probing = false
    /// 复制按钮态翻转（DetailPanel.swift:315-319 先例）
    @Published private(set) var copied = false

    /// 共享探测器实例；App 侧默认 `.system`。测试/真机注入经构造参数或注入缝。
    let probe: SkillctlProbe

    /// 跳过记录读写走 AppSettings（settings.json 单源）；App 注入 paths，测试注入隔离目录。
    private let paths: SkillControllerPaths
    /// 单飞守卫：同一时刻最多一个探测在跑，后来的触发复用在跑结果，不叠加（设计档 §2.1）。
    private var inFlight = false
    private var copiedResetTask: Task<Void, Never>?

    init(probe: SkillctlProbe = SkillctlProbe(.system),
         paths: SkillControllerPaths = SkillControllerPaths()) {
        self.probe = probe
        self.paths = paths
        // 冷启动即探测（不等授权门——探测只读 PATH 与 exec，不碰 skills 目录，与 TCC 授权面无关）
        recheck()
        // 前台活跃复检（§2.3 三触发点之二）：用户切去让 Agent 装，装完切回来，探测已翻成一致态，
        // 引导自然消失（F3 的实现路径）。与 AppState 的重扫观察者同一形状；模型与进程同生命周期，不摘。
        foregroundObserverBox.set(NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.recheck() }
        })
    }

    /// 前台活跃观察者 token。包在 Sendable 盒里：nonisolated deinit 不能直接读 @MainActor 隔离的
    /// non-Sendable 属性（Swift 6 严格并发），deinit 只碰盒子。
    private let foregroundObserverBox = ObserverTokenBox()

    /// AppSettings 里的跳过级别（读偏好存储，每次现读——单一真相在 settings.json）
    var skippedLevel: String? {
        AppSettings.load(paths: paths).cliGuideSkippedLevel
    }

    /// 自动呈现条件的 App 侧包装（§2.3）：缺口 ∧ 该级别未跳过 ∧ 本会话未按「先不装」收掉。
    /// 授权门条件（gate != .ask）由 RootView 的 sheet binding 叠加——gate 在 AppState 上。
    var wantsAutoPresent: Bool {
        guard !autoPresentDismissed else { return false }
        guard let status else { return false }
        return CLIGuideDecision.shouldAutoPresent(status: status, skippedLevel: skippedLevel)
    }

    /// 复检入口（冷启动 / 前台活跃 / Sheet onAppear 三个触发点共用）。后台探测，结果回主线程发布。
    func recheck() {
        guard !inFlight else { return }   // 单飞：在跑就直接复用它的结果
        inFlight = true
        probing = true
        Task.detached(priority: .utility) { [probe] in
            let outcome = probe.probe()
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.inFlight = false
                self.probing = false
                self.apply(outcome)
            }
        }
    }

    /// 探测结果落地：发布 status；翻成 current 时清掉跳过记录（§2.2——该记录已死，清掉保持状态最小）。
    private func apply(_ outcome: SkillctlProbe.ProbeOutcome) {
        let newStatus = CLIGuideDecision.decide(outcome, appVersion: SkillControllerVersion.string)
        status = newStatus
        if newStatus == .current, skippedLevel != nil {
            clearSkip()
        }
        // 新缺口级别到来时复位「先不装」的会话内收掉位：级别变了要重新弹（K5——
        // 跳过「未安装」后变「版本不对齐」（或反向），同一会话内也要能自动弹）
        if newStatus.gapKey != lastPresentedGapKey {
            autoPresentDismissed = false
        }
        lastPresentedGapKey = newStatus.gapKey
    }
    private var lastPresentedGapKey: String?

    /// 「先不装」：持久化当前缺口级别 + 关 Sheet（关闭动作在视图层）。写失败不阻断——
    /// 本次仍关闭，下次启动会再弹，如实行为、不假装已记住（§2.2）。
    func skip() {
        guard let gap = status?.gapKey else { return }
        var s = AppSettings.load(paths: paths)
        s.cliGuideSkippedLevel = gap
        try? s.save(paths: paths)
    }

    /// 清跳过记录（current 态落地时调用）；读-改-写整段在锁外单线程（@MainActor）执行。
    private func clearSkip() {
        var s = AppSettings.load(paths: paths)
        s.cliGuideSkippedLevel = nil
        try? s.save(paths: paths)
    }

    /// 「复制提示词」→ NSPasteboard，不关 Sheet（§2.3 出口语义）
    func copyPrompt() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(SetupGuidePrompt.text(appVersion: SkillControllerVersion.string),
                                       forType: .string)
        copied = true
        copiedResetTask?.cancel()
        copiedResetTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            if !Task.isCancelled { self?.copied = false }
        }
    }

    /// 手动入口（设置页「CLI 安装 / 升级」）开 Sheet 前先刷新一次：先复检再呈现（§2.3 Sheet onAppear 触发点）。
    func openManually() {
        recheck()
    }

    /// 自动呈现的关闭路径：只在「先不装」（含 Esc 映射到同一按钮）时被 RootView 的 binding set 触达。
    /// 跳过持久化本身在 skip() 里做；这里只把自动呈现位收回——缺口未变时下次启动照常再弹
    /// （写偏好失败时的如实行为：本次仍关闭，不假装已记住，§2.2）。
    func dismissAutoPresent() {
        autoPresentDismissed = true
    }

    deinit {
        // 观察者 token 是 non-Sendable 且 self 是 @MainActor 隔离——nonisolated deinit 不能直接读它，
        // 经 Sendable 盒转交（模型与进程同生命周期，此路径实际不触发；保守收口）。
        if let token = foregroundObserverBox.take() {
            NotificationCenter.default.removeObserver(token)
        }
    }

    // MARK: 私有状态

    /// 「先不装」在本次会话内收掉自动呈现（即使跳过持久化写失败）。重新探测出新缺口级别时复位——
    /// 级别变了要重新弹（K5）。
    private var autoPresentDismissed = false
}

// MARK: - 引导 Sheet（设计档 §8：宽 520 档、提示词块等宽只读可滚动、单一出口语义）

struct CliGuideSheet: View {
    /// 直持观察（评审发现②）：CLIGuideModel 的 @Published 不经 AppState 转发。
    @ObservedObject var guide: CLIGuideModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().overlay(Color.scBorder)
            content
            Divider().overlay(Color.scBorder)
            footer
        }
        .frame(width: LayoutMetrics.guideSheetWidth)
        .frame(maxHeight: 640)
        .background(Color.scBackground)
        // Sheet 出现也是复检触发点（§2.3）：手动入口先刷新再呈现
        .onAppear { guide.recheck() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            // 标题分派 C5 / C6 / C13（SetupGuidePrompt.title）；Sheet 无 current 变体（§2.3）——
            // status 探完翻 current 时这一屏维持既有内容，用户关闭后不再弹（K9）。
            Text(title)
                .font(.system(size: 16, weight: .semibold))
            Text(explanation)   // C7（安装态）/ C8（版本不对齐，落后超前共用）
                .font(.system(size: 14))
                .foregroundStyle(Color.scForeground)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
    }

    private var content: some View {
        ScrollView {
            // C12：提示词正文（唯一常量）。只读可滚动、等宽全局由 App 根视图施加。
            Text(SetupGuidePrompt.text(appVersion: SkillControllerVersion.string))
                .font(.system(size: 12))
                .foregroundStyle(Color.scForeground)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
        }
        .background(Color.scMuted.opacity(0.2))
    }

    private var footer: some View {
        VStack(spacing: 8) {
            // C9：探测失败注脚如实上屏（裁决④——不静默吞），不阻断引导本身
            if case .notInstalled(let note)? = guide.status, let note {
                Text("探测未能完成（\(note)）：按「未检测到」处理。")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.scMutedForeground)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if guide.probing {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("正在检测…")
                        .font(.system(size: 12))
                        .foregroundStyle(Color.scMutedForeground)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack {
                Button {
                    guide.copyPrompt()   // 复制不关 Sheet（K8 出口语义）
                } label: {
                    Label(guide.copied ? "已复制" : "复制提示词", systemImage: "doc.on.doc")   // C10
                }
                .buttonStyle(.bordered)
                Spacer()
                // C11：中性色非 destructive；Esc（.cancelAction）接到同一按钮（§2.3）
                Button {
                    guide.skip()
                    dismiss()
                } label: {
                    Text("先不装")
                }
                .buttonStyle(.bordered)
                .keyboardShortcut(.cancelAction)
                .help("本次缺口级别内不再自动弹出；「设置 → CLI 安装 / 升级」随时可回。")
            }
        }
        .padding(16)
    }

    /// 标题：status 未探完时先给 C5（Sheet 只在缺口态被打开，安装态占位探完即被 decide 修正）
    private var title: String {
        SetupGuidePrompt.title(for: guide.status ?? .notInstalled(note: nil),
                               appVersion: SkillControllerVersion.string)
    }

    /// 说明文案：C7 / C8 的槽位插值——两句话的骨架与措辞逐字取自设计档 §8 文案表。
    /// status 未探完时先按安装态呈 C7（Sheet 只在缺口态被打开，探完即被 decide 修正）。
    private var explanation: String {
        let v = SkillControllerVersion.string
        switch guide.status {
        case .outdated(let installed), .ahead(let installed):
            return "检测到已装 skillctl \(installed)，与当前 App（\(v)）不一致。把下面的提示词复制给你的任意 Agent，由它覆盖升级并回报版本。"   // C8
        case .current:
            // 不应到达：Sheet 无 current 变体（§2.3）。不发明新文案——C3 是设计档唯一定过的一致态句。
            return "已装 skillctl \(v)（与 App 一致）"   // C3
        case .notInstalled, nil:
            return "本机的 Agent 装配经命令行工具 skillctl 完成；当前没有在 PATH 上检测到它。把下面的提示词复制给你的任意 Agent，由它代为安装并回报版本。"   // C7
        }
    }
}

/// nonisolated deinit 摘通知观察者的 Sendable 载体（Swift 6 严格并发下的既有形状）
private final class ObserverTokenBox: @unchecked Sendable {
    private var token: NSObjectProtocol?
    func set(_ t: NSObjectProtocol) { token = t }
    func take() -> NSObjectProtocol? {
        let t = token
        token = nil
        return t
    }
}
