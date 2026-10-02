// AssemblyReview.swift — 装配验收面（story-2：flow2 的 SwiftUI 落地）
// Banner 三态（未验收/已验收/已恢复）+ empty-assembly 事实态，全中性色（"Agent 干了活"不是警告）
// diff Sheet 520：三组分区（挂上/卸下/跳过）+ 冲突行内留痕·单条重试 + 关闭=验收（D28 起另留「保留待验收」中性出口）+ 恢复=显式 AlertDialog
// G3：验收期间清单又变 → 顶部提示 + 重载前禁用「关闭并验收」

import SwiftUI
import SkillControllerCore

// MARK: - 写操作回执（sitemap overlay-write-error ＋ edge G4 部分恢复如实报 ＋ G7 按钮不撒谎）
//
// 硬规则 §3.2：全应用唯一允许的 destructive 红是「磁盘满不可逆删除」，
// 所以写失败与部分恢复一律 muted 中性系——不放大也不藏起来。
// 出口只有「知道了」：不自动消失，人得先把哪个落点没回来看完。

struct WriteOutcomeBanner: View {
    @ObservedObject var app: AppState

    var body: some View {
        if let error = app.lastError {
            line(error, extra: [])
        } else if let outcome = app.lastRestoreOutcome {
            if outcome.complete {
                line("\(outcome.restored) 个落点已回位，磁盘状态与操作前一致", extra: [])
            } else {
                // #22 问题2（走查拍板）：--force 旧副本占位失败的特例说明一行，经 hint 通道
                // 完整显示（line() 的 extra 行有 lineLimit(1) 截断，长文案被截等于没说）；
                // 普通恢复失败（无特例）回执维持现状零改动。
                line("\(outcome.restored) 个落点已回位 · \(outcome.failed.count) 个未能恢复（已记日志，可重试）",
                     extra: outcome.failed.map { "\($0.path) · \($0.reason)" },
                     hint: outcome.forceReplacedHint)
            }
        } else if let outcome = app.lastReapplyOutcome {
            // D32=B 的回执。不复用上面那句"磁盘状态与操作前一致"——对挂回动作它是反的
            if outcome.complete {
                line("已重新挂回 \(outcome.restored) 个落点（那次装配的结果又回到盘上，条目源未动）", extra: [])
            } else {
                line("已重新挂回 \(outcome.restored) 个落点 · \(outcome.failed.count) 个未成功（已记日志，可重试）",
                     extra: outcome.failed.map { "\($0.path) · \($0.reason)" })
            }
        } else if let receipt = app.lastDeleteReceipt {
            // D18：删除成功也要当场说得清——只让行消失，等于把不可逆动作的结果藏起来
            line("「\(receipt.name)」已移入回收站（\(receipt.locations) 个落点，\(receipt.days) 天内可在「回退」页一步恢复）",
                 extra: [])
        } else if let receipt = app.lastIrreversibleDeleteReceipt {
            // #1 磁盘满直接删除的回执：不复用「已移入回收站」文案——那句对这条路是假话（G7）。
            // 日志没写成时如实带一句（用例 E2：不假装落了日志）。
            let extra: [String] = receipt.logFailed
                ? ["操作日志未能记录（磁盘已满）——这次删除没有留档"]
                : []
            line("已直接删除 \(receipt.locations) 个落点（磁盘满，未入回收站）· 此操作不可恢复",
                 extra: extra)
        }
    }

    private func line(_ text: String, extra: [String], hint: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "tray.full")
                    .foregroundStyle(Color.scMutedForeground)
                    .font(.system(size: 12))
                Text(text)
                    .font(.system(size: 14))
                    .foregroundStyle(Color.scForeground)
                    .textSelection(.enabled)
                Spacer(minLength: 12)
                Button("知道了") { app.dismissWriteOutcome() }
                    .buttonStyle(.bordered)
                    .font(.system(size: 14))
            }
            // 特例说明（#22 问题2）：完整多行显示，不进 lineLimit(1) 的明细区——
            // 「先删除库内同名条目，再回来恢复」被截断就等于没说（G7）。
            if let hint {
                Text(hint)
                    .font(.system(size: 12))
                    .foregroundStyle(Color.scMutedForeground)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 20)
                    .textSelection(.enabled)
            }
            ForEach(extra.prefix(3), id: \.self) { detail in
                Text(detail)
                    .font(.system(size: 12))
                    .foregroundStyle(Color.scMutedForeground)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .padding(.leading, 20)
                    .textSelection(.enabled)
            }
            if extra.count > 3 {
                Text("另有 \(extra.count - 3) 项，见「回退」页日志")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.scMutedForeground)
                    .padding(.leading, 20)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.scMuted)
        .overlay(RoundedRectangle(cornerRadius: LayoutMetrics.Radius.lg).stroke(Color.scBorder))
        .scContainerRadius()
    }
}

// MARK: - Banner（项目视角顶部；D8：多条待验收时聚合提示）

struct AssemblyBanner: View {
    @ObservedObject var app: AppState
    @State private var showList = false

    var body: some View {
        // 有待验收：>1 走聚合，==1 直接显该条
        // D27（2026-09-23 真机抓到）：原来这条分支写的是 `assemblyEvents.first`——那是
        // **按时间倒序的全量第一条**，不是那条待验收的。于是真机上我刚验收完「挂上 1 项」的
        // sc-wt2，横幅立刻变成另一条已验收旧事件的「装配了 0 项 · 已验收」：
        // 既跟我三秒前在 Sheet 里看到的数字自相矛盾，又把还剩的那条待验收彻底藏没了
        // （聚合入口只在 >1 时出现，等于只剩一条待验收时它没有任何出口）。
        // 注释写的意图一直是"显该条"，代码接错了数组，按意图接回来。
        if app.pendingAssemblies.count > 1 {
            aggregateBanner
        } else if let one = app.pendingAssemblies.first ?? app.assemblyEvents.first {
            singleBanner(one)
        } else {
            EmptyView()
        }
    }

    private var aggregateBanner: some View {
        let pend = app.pendingAssemblies
        let projects = Set(pend.map { $0.event.projectId }).count
        let items = pend.reduce(0) { $0 + $1.event.added.count + $1.event.removed.count }
        return Button { showList = true } label: {
            HStack(spacing: 8) {
                Image(systemName: "cpu").foregroundStyle(Color.scMutedForeground)
                Text("\(projects) 个项目 · \(items) 项装配 · 待验收")
                    .font(.system(size: 14)).foregroundStyle(Color.scForeground)
                Spacer()
                Text("查看装配记录").font(.system(size: 14)).foregroundStyle(Color.scMutedForeground)
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.scMuted)
            .overlay(RoundedRectangle(cornerRadius: LayoutMetrics.Radius.lg).stroke(Color.scBorder))
            .scContainerRadius()
        }
        .buttonStyle(.plain)
        .sheet(isPresented: $showList) { AssemblyListSheet(app: app) }
    }

    private func singleBanner(_ stored: StoredAssemblyEvent) -> some View {
        SingleAssemblyBanner(app: app, stored: stored)
    }
}

/// 单条 Banner（三态：未验收/已验收/已恢复 + empty 事实态）
struct SingleAssemblyBanner: View {
    @ObservedObject var app: AppState
    let stored: StoredAssemblyEvent

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "cpu").foregroundStyle(Color.scMutedForeground)
            Text(text).font(.system(size: 14)).foregroundStyle(Color.scForeground)
            Spacer()
            if state == .pending {
                Button("查看装配记录") { app.openDiff(stored.event.id) }
                    .buttonStyle(.bordered).font(.system(size: 14))
            } else {
                Button("回看") { app.openDiff(stored.event.id) }
                    .buttonStyle(.plain).font(.system(size: 14))
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.scMuted.opacity(state == .pending ? 1.0 : 0.4))
        .overlay(RoundedRectangle(cornerRadius: LayoutMetrics.Radius.lg).stroke(Color.scBorder))
        .scContainerRadius()
    }

    enum State { case pending, reviewed, restored, empty }
    private var state: State {
        if stored.restored { return .restored }
        if stored.accepted { return .reviewed }
        // #12（D37）：no-op 判定必须把失败组也算进去——全失败事件三组全空但 failed 非空，
        // 不算这个判据它会被呈成「检查过了，没带来新东西」（G7：把失败说成没带来新东西）
        if stored.event.added.isEmpty && stored.event.conflicts.isEmpty && stored.event.removed.isEmpty
            && (stored.failed ?? []).isEmpty { return .empty }
        return .pending
    }

    private var text: String {
        let agent = AgentRegistry.agentName(stored.event.agentId)
        let n = stored.event.added.count
        switch state {
        case .restored: return "\(agent) 曾为该项目装配 \(n) 项，你已恢复原状"
        case .reviewed: return "\(agent) 为该项目装配了 \(n) 项 · 已验收"
        case .empty: return "\(agent) 检查过了，没带来新东西"
        case .pending:
            let c = stored.event.conflicts.count
            let f = stored.failed?.count ?? 0
            // 失败段（新拟文案①，上抛过目）：全失败呈 pending 态——它确实需要人看，不是 no-op。
            // 冲突与失败并处 →「（跳过 C 项冲突 · 失败 F 项）」；只有失败 →「（失败 F 项）」
            var detail = ""
            if c > 0 { detail += "跳过 \(c) 项冲突" }
            if f > 0 { detail += detail.isEmpty ? "失败 \(f) 项" : " · 失败 \(f) 项" }
            // skillctl 收编事件（add 不面向某 Agent，projectId 为空）：文案⑧专用句式
            if stored.event.agentId == "skillctl" {
                return detail.isEmpty ? "skillctl 为技能库收编了 \(n) 项"
                                      : "skillctl 为技能库收编了 \(n) 项（\(detail)）"
            }
            return detail.isEmpty ? "\(timeLabel) · \(agent) 为该项目装配了 \(n) 项"
                                  : "\(timeLabel) · \(agent) 为该项目装配了 \(n) 项（\(detail)）"
        }
    }

    private var timeLabel: String {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime]
        guard let d = f.date(from: stored.event.date) else { return "" }
        return d.formatted(.dateTime.month().day().hour().minute().locale(Locale(identifier: "zh_CN")))
    }
}

// MARK: - 待验收清单页（D8 聚合入口）

struct AssemblyListSheet: View {
    @ObservedObject var app: AppState
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("待验收装配").font(.system(size: 20, weight: .semibold))
                Spacer()
                Button("完成") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding(16)
            Divider().overlay(Color.scBorder)
            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(app.pendingAssemblies, id: \.event.id) { s in
                        HStack(spacing: 10) {
                            Image(systemName: "cpu").foregroundStyle(Color.scMutedForeground)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(projectName(s.event.projectId)).font(.system(size: 14, weight: .medium))
                                Text(listRowDetail(s)).font(.system(size: 12)).foregroundStyle(Color.scMutedForeground)
                            }
                            Spacer()
                            Button("查看") { dismiss(); DispatchQueue.main.async { app.openDiff(s.event.id) } }
                                .buttonStyle(.bordered).font(.system(size: 14))
                        }
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.scMuted.opacity(0.2))
                        .scControlRadius()
                    }
                }
                .padding(16)
            }
        }
        .frame(width: LayoutMetrics.diffSheetWidth, height: 520)
        .background(Color.scBackground)
    }

    private func projectName(_ pid: String) -> String {
        guard !pid.isEmpty else { return "用户级" }
        return app.index.projects.first { $0.id == pid }?.name ?? pid
    }

    /// 待验收清单行的明细段；失败非空时按非空拼「 · 失败 F」（#12，与 Banner 同一拼接规则）
    private func listRowDetail(_ s: StoredAssemblyEvent) -> String {
        let f = s.failed?.count ?? 0
        let failure = f > 0 ? " · 失败 \(f)" : ""
        return "\(AgentRegistry.agentName(s.event.agentId)) · 挂上 \(s.event.added.count) · 卸下 \(s.event.removed.count) · 跳过 \(s.event.conflicts.count)\(failure)"
    }
}

// MARK: - diff Sheet

struct AssemblyDiffSheet: View {
    @ObservedObject var app: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var confirmRestore = false
    @State private var restoring = false
    @State private var retriedPaths: Set<String> = []
    @State private var retryFailedPaths: Set<String> = []
    @State private var expandedAll = false

    private var event: AssemblyEvent? { app.diffEvent?.event }

    /// 只有「还没验收 / 没恢复」的记录才需要"先不验收"这个出口；
    /// 从「回看」进来的已验收记录不显示，否则等于暗示还有一件事没做完。
    private var isPendingReview: Bool {
        guard let stored = app.diffEvent else { return false }
        return !stored.accepted && !stored.restored
    }

    /// 这条记录已经「全部恢复原状」过了（回看态）
    private var isRestored: Bool { app.diffEvent?.restored ?? false }

    /// 恢复时是否留下了可重建凭据（软链目标或回收站条目）。
    /// 没有凭据的老记录不该出现「重新挂回」——点了什么也不会发生。
    private var hasReapplyCredentials: Bool { (app.diffEvent?.reapplyableCount ?? 0) > 0 }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(Color.scBorder)
            content
            Divider().overlay(Color.scBorder)
            footer
        }
        .frame(width: LayoutMetrics.diffSheetWidth)
        .frame(maxHeight: 640)
        .background(Color.scBackground)
        .onAppear { app.refreshDiffStaleness() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("装配记录 · \(AgentRegistry.agentName(event?.agentId ?? "")) → \(projectName)")
                    .font(.system(size: 16, weight: .semibold))
                Spacer()
            }
            Text("\(dateLabel) · 经 skillctl CLI · 来源均为用户级全集")
                .font(.system(size: 12))
                .foregroundStyle(Color.scMutedForeground)
            // G3：验收期间清单又变 → 中性提示 + 重载前禁用验收
            if app.diffSurfaceGone {
                // 影响面整个消失 ≠ 清单又变了：没有可比的对象，锁验收会把人关死在出口外
                Text("这次装配影响的位置已经不在盘上了（项目被移走或目录被删）——没有你还没看到的变动，可以直接验收留档。")
                    .font(.system(size: 14))
                    .foregroundStyle(Color.scMutedForeground)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.scMuted.opacity(0.4))
                    .scControlRadius()
            }
            if app.diffRebased {
                // 「重新加载」的真实语义：我已经看过当前清单，以现在为准刷新比对基线。
                // 没有这一步，那句"重新加载后再验收"就是空头支票——影响面再变一次就永远比不过。
                Text("已按当前清单刷新比对基线。下面列的是这次装配当时改动的内容，验收即确认你已看过现状。")
                    .font(.system(size: 14))
                    .foregroundStyle(Color.scMutedForeground)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.scMuted.opacity(0.4))
                    .scControlRadius()
            }
            if app.diffStale {
                HStack {
                    Text(app.reloadingDiff ? "正在按已知位置重扫，扫完再比对…"
                                           : "清单已更新。重新加载后再验收")
                        .font(.system(size: 14))
                        .foregroundStyle(Color.scMutedForeground)
                    Spacer()
                    if app.reloadingDiff {
                        ProgressView().controlSize(.small)
                    }
                    Button("重新加载") { app.reloadDiff() }
                        .buttonStyle(.link).font(.system(size: 14))
                        .disabled(app.reloadingDiff || app.diffRevisionPending)
                        .help("按已知位置重扫（秒级），扫完再比对清单快照")
                }
                .padding(8)
                .background(Color.scMuted.opacity(0.4))
                .scControlRadius()
            }
            // 9①：后台比对进行中——中性一句 + 两按钮禁用；这句话消失即比对落定
            if app.diffRevisionPending {
                Text("正在比对清单…")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.scMutedForeground)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.scMuted.opacity(0.4))
                    .scControlRadius()
            }
        }
        .padding(16)
    }

    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                if let e = event {
                    addedGroup(e)
                    removedGroup(e)
                    conflictsGroup(e)
                    failedGroup
                    // #12（D37）：空态判定加 failed 空判据——全失败事件不再呈 no-op 文案
                    if e.added.isEmpty && e.removed.isEmpty && e.conflicts.isEmpty
                        && (app.diffEvent?.failed ?? []).isEmpty {
                        Text("检查过了，没带来新东西").font(.system(size: 14)).foregroundStyle(Color.scMutedForeground)
                    }
                }
            }
            .padding(16)
        }
    }

    /// #12（D37）失败组：落点 + 原因，muted 中性（destructive 红唯一豁免=磁盘满，失败态属中性系）。
    /// **不挂「重试这一项」**——conflicts 的重试语义（占位移开后重挂）对失败不成立
    /// （成因是权限/IO，动作可能该 unmount），照抄一个必然语义错位的按钮是又一个撒谎按钮（G7）。
    @ViewBuilder private var failedGroup: some View {
        ForEach(app.diffEvent?.failed ?? [], id: \.itemId) { f in
            VStack(alignment: .leading, spacing: 8) {
                Label("失败 \(app.diffEvent?.failed?.count ?? 0) 项（未写入盘）", systemImage: "xmark")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Color.scMutedForeground) // 中性，不红
                VStack(alignment: .leading, spacing: 6) {
                    Text((f.itemId as NSString).lastPathComponent).font(.system(size: 14, weight: .medium))
                    Text(f.reason)
                        .font(.system(size: 12)).foregroundStyle(Color.scMutedForeground)
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.scMuted.opacity(0.4))
                .overlay(RoundedRectangle(cornerRadius: LayoutMetrics.Radius.md).stroke(Color.scBorder))
                .scControlRadius()
            }
        }
    }

    @ViewBuilder private func addedGroup(_ e: AssemblyEvent) -> some View {
        if !e.added.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Label("挂上 \(e.added.count) 项（新装配）", systemImage: "checkmark")
                    .font(.system(size: 14, weight: .medium))
                ForEach(displayAdded(e), id: \.self) { path in
                    HStack(spacing: 8) {
                        Image(systemName: "folder").foregroundStyle(Color.scMutedForeground).font(.system(size: 12))
                        Text((path as NSString).lastPathComponent).font(.system(size: 14, weight: .medium))
                        Spacer()
                        Text(path).font(.system(size: 12)).foregroundStyle(Color.scMutedForeground)
                            .lineLimit(1).truncationMode(.middle).frame(maxWidth: 220, alignment: .trailing)
                    }
                    .padding(.vertical, 4)
                }
                if e.added.count > 10 && !expandedAll {
                    Button("展开全部 \(e.added.count) 项") { expandedAll = true }
                        .buttonStyle(.link).font(.system(size: 12))
                }
            }
        }
    }

    @ViewBuilder private func removedGroup(_ e: AssemblyEvent) -> some View {
        if !e.removed.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Label("卸下 \(e.removed.count) 项（未脱离全集，可随时回挂）", systemImage: "arrow.uturn.backward")
                    .font(.system(size: 14, weight: .medium))
            }
        }
    }

    @ViewBuilder private func conflictsGroup(_ e: AssemblyEvent) -> some View {
        ForEach(e.conflicts, id: \.itemId) { c in
            VStack(alignment: .leading, spacing: 8) {
                Label("跳过 \(e.conflicts.count) 项（写入痕迹）", systemImage: "exclamationmark.triangle")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Color.scMutedForeground) // 中性，不红
                VStack(alignment: .leading, spacing: 6) {
                    Text((c.itemId as NSString).lastPathComponent).font(.system(size: 14, weight: .medium))
                    Text(retriedPaths.contains(c.itemId) ? "重试成功 · 已挂载"
                        : retryFailedPaths.contains(c.itemId) ? "重试未成功 · 已记入日志" : c.reason)
                        .font(.system(size: 14)).foregroundStyle(Color.scMutedForeground)
                    if !retriedPaths.contains(c.itemId) {
                        Button("重试这一项") {
                            if app.retryConflict(landingPath: c.itemId, projectId: e.projectId, agent: e.agentId) {
                                retriedPaths.insert(c.itemId)
                            } else {
                                retryFailedPaths.insert(c.itemId)
                            }
                        }
                        .buttonStyle(.bordered).font(.system(size: 14))
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.scMuted.opacity(0.4))
                .overlay(RoundedRectangle(cornerRadius: LayoutMetrics.Radius.md).stroke(Color.scBorder))
                .scControlRadius()
            }
        }
    }

    private var footer: some View {
        VStack(spacing: 8) {
            // #4：验收写失败时 Sheet 不关（可重试）。全局 Banner 在 Sheet 底下看不见，
            // 这里内联绑 lastError 给一句实况（muted 中性，不红）；关闭后全局 Banner 仍按既有通道显示。
            if let error = app.lastError {
                Text(error)
                    .font(.system(size: 12))
                    .foregroundStyle(Color.scMutedForeground)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .background(Color.scMuted.opacity(0.4))
                    .scControlRadius()
            }
            HStack {
                if isRestored {
                    // D32=B（智昊拍"真做撤销"）：已恢复的记录不再给「全部恢复原状」——
                    // 落点早摘掉了，再点必然进失败分支，把一次成功的恢复渲染成"0/1 未恢复"。
                    // 给它真正做得动的那一步：按恢复时记下的链接目标重新挂回。
                    if hasReapplyCredentials {
                        Button {
                            if let id = event?.id {
                                restoring = true
                                app.reapplyAssembly(eventId: id)
                                restoring = false
                                dismiss()
                            }
                        } label: {
                            Label("重新挂回", systemImage: "arrow.counterclockwise")
                        }
                        .buttonStyle(.bordered)
                        .disabled(restoring)
                        .help("把这条装配当初挂上的落点按记录重建（源未动）；目标位已被占用时不覆盖、逐条如实报")
                    } else {
                        // 老记录没有凭据：没有可做的动作就不摆一个点不动的按钮骗人
                        Text("这次恢复没留下可重建的链接记录，要再挂上请让 Agent 重新 pull 一次")
                            .font(.system(size: 12)).foregroundStyle(Color.scMutedForeground)
                    }
                } else {
                    Button { confirmRestore = true } label: {
                        Label("全部恢复原状", systemImage: "arrow.uturn.backward")
                    }
                    .buttonStyle(.bordered)
                    .disabled(restoring)
                }
                Spacer()
                // D28（2026-09-23 智昊裁决：承认逃生口，补显式中性出口）
                // 裁定①原来只留「关闭=验收」一个出口，于是 G3 锁住验收时人会被关在 Sheet 里
                // ——那句"重新加载后再验收"要求人必须先把验收做掉才能走，逻辑上是个死结。
                // 这个出口不碰任何状态：事件保持待验收、横幅继续提醒、磁盘一个字节都不动。
                // 文案刻意不写「取消」——那会被读成"撤销这次装配"，而那正是「全部恢复原状」干的事。
                // Esc 也接到这里：以前按 Esc 其实能静默退出（界面上没标），现在让它成为有据可查的出口。
                if isPendingReview {
                    Button("保留待验收") { dismiss() }
                        .buttonStyle(.bordered)
                        .keyboardShortcut(.cancelAction)
                        .disabled(restoring)
                        .help("先不验收：这条记录保持待验收，横幅会继续提醒；不改动任何文件")
                }
                Button {
                    if let id = event?.id { app.acceptDiff(id) }
                    dismiss()
                } label: {
                    Text(restoring ? "恢复中…" : "关闭并验收")
                }
                .keyboardShortcut(.defaultAction)
                // G3：快照过期时禁用验收（禁止对旧快照验收）
                // 9①：后台比对没落定时同样禁用——不让人对着没算完的快照做决定
                .disabled(app.diffStale || restoring || app.diffRevisionPending)
                .opacity(app.diffStale ? 0.5 : 1)
            }
        }
        .padding(16)
        .confirmationDialog(
            "把 \(projectName) 恢复到 \(AgentRegistry.agentName(event?.agentId ?? "")) 装配之前？",
            isPresented: $confirmRestore, titleVisibility: .visible
        ) {
            Button("确认恢复") {
                guard let e = event else { return }
                restoring = true
                app.restoreAssembly(e)
                restoring = false
                dismiss()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("将卸下 \(event?.added.count ?? 0) 项。条目不会脱离全集；这一步会写进操作日志，要反悔可在本条「装配记录」里点「重新挂回」（链接目标当场记下，源未动）。")
        }
    }

    private func displayAdded(_ e: AssemblyEvent) -> [String] {
        expandedAll ? e.added : Array(e.added.prefix(10))
    }

    private var projectName: String {
        // skillctl 收编事件：add 不面向某 Agent、projectId 为空——如实显示「技能库」，不借"用户级"顶名
        if event?.agentId == "skillctl" { return "技能库" }
        guard let pid = event?.projectId else { return "用户级" }
        return app.index.projects.first { $0.id == pid }?.name ?? pid
    }

    private var dateLabel: String {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime]
        guard let d = f.date(from: event?.date ?? "") else { return "" }
        return d.formatted(.dateTime.year().month().day().hour().minute().locale(Locale(identifier: "zh_CN")))
    }
}
