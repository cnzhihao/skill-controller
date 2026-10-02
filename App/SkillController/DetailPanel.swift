// DetailPanel.swift — 详情栏 360（flow1 Screen3 + edge ItemDetail must 态）
// 动作区（恢复挂载/卸下/删除）按设计稿渲染；Phase 1 无回滚底座 → 禁用态
// （opacity+cursor 双标识，硬规则 §3.7），Phase 2 日志+回收站落地后启用。

import SwiftUI
import AppKit   // NSPasteboard：复制指令给 Agent 是"人把动作交出去"的唯一出口
import SkillControllerCore

struct DetailPanel: View {
    @ObservedObject var app: AppState

    private var item: InventoryItem? { app.selectedItem }

    var body: some View {
        VStack(spacing: 0) {
            if let item {
                detailContent(item)
            } else if app.selectedItemId != nil {
                // STATE: error-target-vanished —— 条目被并发移走，中性消失态，唯一出口「关闭」
                vanishedState
            }
        }
        .frame(width: LayoutMetrics.detailPanelWidth)
        .frame(maxHeight: .infinity)
        .background(Color.scMuted.opacity(0.3))
        .overlay(Rectangle().frame(width: 1).foregroundStyle(Color.scBorder), alignment: .leading)
    }

    // MARK: - 正常态

    @ViewBuilder
    private func detailContent(_ item: InventoryItem) -> some View {
        VStack(spacing: 0) {
            HStack {
                HStack(spacing: 6) {
                    Image(systemName: item.type == .skill ? "point.3.connected.trianglepath.dotted" : "server.rack")
                        .foregroundStyle(Color.scMutedForeground)
                        .font(.system(size: 12))
                    Text(item.name)
                        .font(.system(size: 14, weight: .medium))
                        .lineLimit(1)
                }
                Spacer()
                Button {
                    app.selectedItemId = nil
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 12))
                        .foregroundStyle(Color.scMutedForeground)
                }
                .buttonStyle(.plain)
                .help("关闭详情")
            }
            .padding(16)

            Divider().overlay(Color.scBorder)

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    // boundary-null：description 缺失显示固定文案，不显示空/undefined
                    Text(item.description.isEmpty
                         ? (item.type == .skill ? "SKILL.md 未写描述" : "未写描述")
                         : item.description)
                        .font(.system(size: 14))
                        .foregroundStyle(Color.scMutedForeground)
                        .lineSpacing(4)

                    // 落点逐条列：按「用户级 / 项目名」分组，每条标性质（实体源/实体副本/symlink/配置项）
                    // —— 一眼数清"在几个项目里被 symlink 了几遍"
                    VStack(alignment: .leading, spacing: 10) {
                        sectionTitle(landingTitle(item))
                        ForEach(spotGroups(item)) { group in
                            VStack(alignment: .leading, spacing: 4) {
                                Text("\(group.title) · \(group.spots.count) 处")
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundStyle(Color.scMutedForeground)
                                ForEach(group.spots, id: \.self) { spot in
                                    spotRow(spot)
                                    if let target = spot.target {
                                        Text("→ \(abbrev(target))")
                                            .font(.system(size: 12))
                                            .foregroundStyle(Color.scMutedForeground)
                                            .lineLimit(1)
                                            .truncationMode(.middle)
                                            .padding(.leading, 4)
                                            .textSelection(.enabled)
                                    }
                                }
                            }
                        }
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        sectionTitle("被哪些 Agent 挂载")
                        if item.mountedBy.isEmpty {
                            // 中性事实，不是警告
                            Text("当前无人挂载（中性事实，不是警告）")
                                .font(.system(size: 14))
                                .foregroundStyle(Color.scMutedForeground)
                        } else {
                            FlowLayout(spacing: 4) {
                                ForEach(item.mountedBy, id: \.self) { a in
                                    Badge(text: AgentRegistry.agentName(a), kind: .secondary)
                                }
                            }
                        }
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        sectionTitle("挂载变动")
                        if app.itemChanges.isEmpty {
                            // 起点诚实（edge empty-first-day 同一口径）：只说"自记录之日起"，
                            // 不再写死"近 90 天无变动"——Phase 2 之后日志有真数据，
                            // 硬编码会让刚被删过、刚被挂上的条目也显示"无变动"，那是假话。
                            Text("自 \(ledgerStartText) 起记录挂载变动，这条还没有记录")
                                .font(.system(size: 14))
                                .foregroundStyle(Color.scMutedForeground)
                        } else {
                            ForEach(app.itemChanges.prefix(6)) { e in
                                HStack(alignment: .top, spacing: 6) {
                                    Text(dayOf(e.at))
                                        .font(.system(size: 12))
                                        .foregroundStyle(Color.scMutedForeground)
                                        .monospacedDigit()
                                        .frame(width: 52, alignment: .leading)
                                    Text(e.action)
                                        .font(.system(size: 12))
                                        .foregroundStyle(Color.scForeground)
                                        .lineLimit(2)
                                        .truncationMode(.tail)
                                        .textSelection(.enabled)
                                    Spacer(minLength: 0)
                                }
                            }
                            if app.itemChanges.count > 6 {
                                Text("另有 \(app.itemChanges.count - 6) 条，见「回退」页日志")
                                    .font(.system(size: 12))
                                    .foregroundStyle(Color.scMutedForeground)
                                    .monospacedDigit()
                            }
                        }
                    }

                    actionArea(item)
                }
                .padding(16)
            }
        }
    }

    @State private var confirmDelete = false
    /// #1 预检不足时呈现的升级确认（替换流：两框永不同屏——macOS 上 confirmationDialog 叠 sheet 不可靠）
    @State private var irreversibleDelete: (item: InventoryItem, needed: Int64, free: Int64)?

    private func actionArea(_ item: InventoryItem) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Divider().overlay(Color.scBorder)
            // #3（智昊拍 A 堵入口）：MCP 删除属于 story-6 写侧，尚未实现——
            // 不摆一个必败按钮（TrashManager 剥掉 `#` 落点后必抛 nothingToDelete）。
            if item.type != .mcp {
                HStack(spacing: 8) {
                    Button("删除") { confirmDelete = true }
                        .buttonStyle(.bordered)
                }
            }
            // 「卸下」不再是这里的一个禁用按钮：CLI 写侧 Phase 2 就交付了，
            // 但它的正确粒度是"某一家 / 某一项目上的那一次挂载"，所以落在上面每个落点行里。
            Text(actionHint(item))
                .font(.system(size: 12))
                .foregroundStyle(Color.scMutedForeground)
        }
        // P1-5：不可逆动作二次确认，明说后果与恢复窗（文案照抄 story-4 GWT）
        .confirmationDialog(
            "把「\(item.name)」移入回收站？",
            isPresented: $confirmDelete,
            titleVisibility: .visible
        ) {
            // #1 预检时机：点「移入回收站」之后、任何磁盘写之前，同步执行（读卷可用空间，毫秒级）。
            // 充足 → requestDelete 内部走原流；不足 → 关普通确认框、呈现升级 Sheet（替换，不是叠加）。
            Button("移入回收站") {
                if let shortage = app.requestDelete(item) {
                    irreversibleDelete = (item, shortage.needed, shortage.free)
                } else {
                    app.selectedItemId = nil
                }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("磁盘文件将移入本工具回收站，30 天内可在「回退」页一步恢复；各 Agent 的挂载将同时卸下。这一步会写入操作日志。")
        }
        // #1 升级确认 Sheet：普通确认框已关（isPresented 归 false）才呈现，两框永不同屏。
        // Esc / 取消 = 整次删除作废，回详情栏原状，不清 selectedItemId。
        .sheet(isPresented: Binding(
            get: { irreversibleDelete != nil },
            set: { if !$0 { irreversibleDelete = nil }
        })) {
            if let shortage = irreversibleDelete {
                IrreversibleDeleteSheet(app: app, item: shortage.item,
                                        neededBytes: shortage.needed, freeBytes: shortage.free,
                                        onCancel: { irreversibleDelete = nil })
            }
        }
    }

    // MARK: - 消失态

    private var vanishedState: some View {
        VStack(spacing: 16) {
            Spacer()
            Text(vanishedText)
                .font(.system(size: 14))
                .foregroundStyle(Color.scMutedForeground)
                .multilineTextAlignment(.center)
            Button("关闭") {
                app.selectedItemId = nil
            }
            .buttonStyle(.bordered)
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .padding(16)
    }

    /// D3：设计句式「这条目刚刚被 {agent} 移出了清单」——操作日志落地后 actor 可查了。
    /// 但只有"最近一条变动确实是一次移出"才配报名字：日志里最近一条也可能是**挂上**，
    /// 若条目随后被外部直接 rm 掉，照抄 actor 就成了"是 Codex 移走的"这种假话。
    /// 判定不了就保持中性说法（不拿猜的填槽位）。
    private var vanishedText: String {
        let neutral = "这条目刚刚被移出了清单（日志可查）"
        guard let rec = app.itemChanges.first else { return neutral }
        // LogEntry 不带结构化的 action（types.ts 1:1 裁定），只能按落盘时的人读句式判；
        // 这三段分别是 CLI unmount / App 删除 / 回收站恢复的固定开头。
        let isRemoval = rec.action.hasPrefix("经 skillctl unmount 卸下")
            || rec.action.hasPrefix("删除 ")
            || rec.action.hasPrefix("移出 ")
        guard isRemoval else { return neutral }
        switch rec.actorKind {
        case .agent:
            return "这条目刚刚被 \(AgentRegistry.agentName(rec.actor)) 移出了清单（日志可查）"
        case .human:
            return "这条目刚刚被你移出了清单（日志可查）"
        }
    }

    private func sectionTitle(_ s: String) -> some View {
        Text(s)
            .font(.system(size: 14, weight: .medium))
    }

    // MARK: - 落点分组

    private struct SpotGroup: Identifiable {
        let id: String
        let title: String
        let spots: [MountSpot]
    }

    private func landingTitle(_ item: InventoryItem) -> String {
        let stat = app.index.mountStat(of: item.id)
        var parts = ["落点 \(stat.locations) 处", "挂载 \(stat.mounts) 次"]
        if stat.projects > 0 { parts.append("跨 \(stat.projects) 个项目") }
        return parts.joined(separator: " · ")
    }

    /// 用户级一组、库一组、每个项目一组、剩下的归"其他位置"
    private func spotGroups(_ item: InventoryItem) -> [SpotGroup] {
        let stat = app.index.mountStat(of: item.id)
        var user: [MountSpot] = []
        var library: [MountSpot] = []
        var other: [MountSpot] = []
        var byProject: [String: [MountSpot]] = [:]
        for spot in stat.spots {
            if spot.level == .user {
                user.append(spot)
            } else if spot.level == .library {
                library.append(spot)                     // 技能库组（skill-library 批文案②）
            } else if let pid = spot.projectId {
                byProject[pid, default: []].append(spot)
            } else {
                other.append(spot)
            }
        }
        var groups: [SpotGroup] = []
        if !user.isEmpty { groups.append(SpotGroup(id: "__user", title: "用户级", spots: user)) }
        if !library.isEmpty { groups.append(SpotGroup(id: "__library", title: "技能库", spots: library)) }
        let names = byProject.keys.sorted {
            projectName($0).localizedCaseInsensitiveCompare(projectName($1)) == .orderedAscending
        }
        for pid in names {
            groups.append(SpotGroup(id: pid, title: projectName(pid), spots: byProject[pid] ?? []))
        }
        if !other.isEmpty { groups.append(SpotGroup(id: "__other", title: "其他位置", spots: other)) }
        return groups
    }

    private func projectName(_ id: String) -> String {
        app.index.projects.first { $0.id == id }?.name ?? id
    }

    private func spotRow(_ spot: MountSpot) -> some View {
        HStack(spacing: 6) {
            Badge(text: spot.kind.label, kind: .outline)
                .fixedSize()
            Text(spotOwner(spot))
                .font(.system(size: 12))
                .foregroundStyle(Color.scMutedForeground)
                .fixedSize()
                .lineLimit(1)
            Text(abbrev(spot.path))
                .font(.system(size: 12))
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
                .help(spot.path)
            Spacer(minLength: 0)
            // 卸下指令挂在**这一条落点**上：作用域（哪家 / 哪个项目）由落点自己决定，
            // 不给整条目一个笼统按钮——那会让人以为一次点击能把所有地方都摘掉。
            if let cmd = unmountCommand(for: spot) {
                Button(copiedSpot == spot.path ? "已复制" : "复制卸下指令") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(cmd, forType: .string)
                    copiedSpot = spot.path
                }
                .buttonStyle(.link)
                .font(.system(size: 12))
                .help(cmd + "\n只摘掉这一处链接（源不动，条目仍在清单里）；正在跑的会话要重启才看不见它")
            }
        }
    }

    @State private var copiedSpot: String?

    /// 只有"链接落点 + 真 Agent"才配给卸下指令：
    /// 本体（实体源/实体副本）被 unmount 会直接拒绝——卸下会使其脱离全集，那是删除的活；
    /// 目录名归属不是可引用的产品，CLI 认不出它；MCP 配置项的写侧还没开（story-6）。
    private func unmountCommand(for spot: MountSpot) -> String? {
        guard spot.kind == .symlink, let agent = spot.agentId,
              !app.pseudoAgentIds.contains(agent), item?.type == .skill else { return nil }
        let quoted = spotNameNeedsQuotes ? "\"\(name)\"" : name
        guard spot.level == .project else { return "skillctl unmount \(quoted) --on \(agent)" }
        // --project 必须从**落点路径反推**，不能拿索引里的"项目根"：
        // CLI 的解析规则是 <project>/<agentDir>/skills/<name>，而落点可以在项目的子目录里
        // ——某落点落在 client-a/knowledge-base/.claude/skills/，项目根却是 client-a。
        // 照仓库根拼出来的指令 CLI 找不到落点，演示当场就会报"该位置没有挂载"，那是假话。
        // 形状不认识（倒数第二段不是 skills）就宁可不给指令，也不给一条打不到的。
        let comps = spot.path.split(separator: "/")
        guard comps.count > 3, comps[comps.count - 2] == "skills" else { return nil }
        let proj = "/" + comps.dropLast(3).joined(separator: "/")
        let quotedProj = proj.contains(" ") ? "\"\(proj)\"" : proj
        return "skillctl unmount \(quoted) --on \(agent) --project \(quotedProj)"
    }

    private var name: String { item?.name ?? "" }

    /// 动作区那句说明。三种情形说三种话，不拿一句通用文案糊过去。
    private func actionHint(_ item: InventoryItem) -> String {
        if item.type == .mcp {
            // 原文案「这里只能整体删除（走回收站）」是假话：TrashManager 剥掉 `#` 落点后
            // 必抛 nothingToDelete——MCP 删除入口按智昊拍 A 堵掉了，这句换成 story-6 等待提示。
            return "MCP 条目的删除属 story-6 写侧，尚未实现：配置项由各 Agent 按自己的格式写回，删除入口会随该能力一起提供。"
        }
        if app.index.mountStat(of: item.id).spots.contains(where: { unmountCommand(for: $0) != nil }) {
            return "「卸下」在上面每一条链接落点的行尾：复制指令交给 Agent 跑，只摘那一处、源不动；"
                + "正在跑的会话要重启才看不见它。"
        }
        return "这个条目没有可卸下的链接落点（盘上是本体，或归属来自目录名）；"
            + "要整体移除用「删除」——全部落点进本工具回收站，30 天内一步恢复。"
    }

    private var spotNameNeedsQuotes: Bool {
        name.contains(" ") || name.contains("&") || name.contains(";")
    }

    /// 落点归属：真实 Agent 直接报名字；靠目录名兜底的注明"目录名"，不假装是可引用的产品
    private func spotOwner(_ spot: MountSpot) -> String {
        guard let agent = spot.agentId else { return "共享" }
        return app.pseudoAgentIds.contains(agent)
            ? "\(AgentRegistry.agentName(agent))（目录名）"
            : AgentRegistry.agentName(agent)
    }

    /// home 前缀收成 ~（详情栏 360 宽，全路径没法读）
    private func abbrev(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }

    /// 账本起点（与挂载账页 empty-first-day 同一个日期，两处不说两套话）
    private var ledgerStartText: String {
        app.ledgerStartDate
            .formatted(.dateTime.year().month().day().locale(Locale(identifier: "zh_CN")))
    }

    /// 变动时间戳 → 月日（日志里的 ISO8601；解析不出来就原样给，不假装是时间）
    private func dayOf(_ iso: String) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        guard let d = f.date(from: iso) else { return "--/--" }
        return d.formatted(.dateTime.month().day().locale(Locale(identifier: "zh_CN")))
    }
}

// MARK: - 简易流式布局（徽章换行）

struct FlowLayout: Layout {
    var spacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 320
        var x: CGFloat = 0, y: CGFloat = 0, rowH: CGFloat = 0
        for sub in subviews {
            let s = sub.sizeThatFits(.unspecified)
            if x + s.width > width, x > 0 {
                x = 0; y += rowH + spacing; rowH = 0
            }
            x += s.width + spacing
            rowH = max(rowH, s.height)
        }
        return CGSize(width: width, height: y + rowH)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowH: CGFloat = 0
        for sub in subviews {
            let s = sub.sizeThatFits(.unspecified)
            if x + s.width > bounds.maxX, x > bounds.minX {
                x = bounds.minX; y += rowH + spacing; rowH = 0
            }
            sub.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(s))
            x += s.width + spacing
            rowH = max(rowH, s.height)
        }
    }
}
