// InventoryView.swift — 清单页（flow1 Screen2 + edge Inventory must 态）
// 降级横幅/空态四型/搜索空态/truncate/键盘可达——逐态对照 edge 矩阵。

import SwiftUI
import SkillControllerCore

/// 清单表格各列的宽度区间（表头与行共用同一组常量，杜绝「数字挂错列」那类错位）。
/// max = 原设计定宽（宽窗口下的样子）；min = 窗口收窄时允许压到多窄。
/// 之所以从定宽改成区间：定宽列之和（490）+ 详情栏（360）+ 侧栏（200）= 1050 > 960，
/// 一旦开着详情栏把窗口收到 960，NavigationSplitView 又会回头压扁侧栏。
/// 让列可压缩，压力才留在「数据面」（它本就该跟窗口走），侧栏永远完整。
enum InventoryColumn {
    static let nameMin: CGFloat = 80
    static let levelMin: CGFloat = 92,  levelMax: CGFloat = 150
    static let agentMin: CGFloat = 96,  agentMax: CGFloat = 180
    static let mountMin: CGFloat = 52,  mountMax: CGFloat = 90
    static let projectMin: CGFloat = 44, projectMax: CGFloat = 70
}

struct InventoryView: View {
    @ObservedObject var app: AppState
    @State private var settingsPath = false

    var body: some View {
        // 全量聚合每屏只算一次再往下传：写成计算属性会被汇总条/表格/产品菜单各算一遍，
        // 真机 1970 条目 + 76 家产品时足以把主线程打到满负荷（2026-09-21 实测）
        let filtered = filteredItems
        let counts = app.index.agentCounts(type: app.typeFilter)
        let projCounts = app.index.projectCounts(type: app.typeFilter)
        let ranked = agentsByScale(counts)

        return HStack(spacing: 0) {
            // 列表区：数据面不限宽（跟窗口走，min-width 960 由窗口约束保证）
            VStack(alignment: .leading, spacing: 16) {
                header
                // 装配 Banner（story-2：CLI 装配后聚合提示；D8 多条待验收聚合；中性色）
                if !app.assemblyEvents.isEmpty {
                    AssemblyBanner(app: app)
                }
                if !app.index.degraded.isEmpty {
                    DegradedBanner(app: app, onOpenSettings: { settingsPath = true })
                }
                toolbar(filtered: filtered, ranked: ranked, counts: counts, projCounts: projCounts)
                table(filtered, rank: agentRank(ranked))
            }
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

            // 详情栏：360（阅读型容器限宽）
            if app.selectedItemId != nil {
                DetailPanel(app: app)
            }
        }
        .sheet(isPresented: $settingsPath) {
            SettingsView(app: app, onClose: { settingsPath = false })
        }
        .sheet(item: diffBinding) { _ in
            AssemblyDiffSheet(app: app)
        }
    }

    // diff Sheet 由 app.diffEventId 驱动
    private var diffBinding: Binding<DiffID?> {
        Binding(
            get: { app.diffEventId.map { DiffID(id: $0) } },
            set: { if $0 == nil { app.diffEventId = nil } }
        )
    }
    private struct DiffID: Identifiable, Hashable { let id: String }

    // MARK: - 页头

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("全盘清单")
                .font(.system(size: 20, weight: .semibold))
            Text(subtitle)
                .font(.system(size: 14))
                .foregroundStyle(Color.scMutedForeground)
                .monospacedDigit()
        }
    }

    private var subtitle: String {
        if app.showSkeleton { return "正在扫描…" }
        var parts = ["\(app.index.skillCount) Skills", "\(app.index.mcpCount) MCP",
                     "\(app.index.agents.count) Agents"]
        // 靠目录名兜底的归属不计入 Agents（多半是项目名，不是可引用的 Agent）
        if !app.pseudoAgentIds.isEmpty {
            parts.append("\(app.pseudoAgentIds.count) 目录名归属")
        }
        parts.append("\(app.index.projects.count) 项目")
        // edge loading-initial：>3s 增量出结果 → 计数标注
        if app.showIncrementalHint {
            parts.append("索引持续更新中")
        }
        return parts.joined(separator: " · ")
    }

    // MARK: - 工具栏（类型一级分段 + 产品/层级筛选 + 搜索 + 汇总条）
    // 2026-09-21 整改：筛选器链 = 类型 → 可激活产品 → 用户级/项目级；原视角切换退役。
    // 2026-09-22 补：产品之后插同构的「项目」多选（带每项目条目数、按规模降序）。

    private func toolbar(filtered: [InventoryItem], ranked: [Agent], counts: [String: Int],
                         projCounts: [String: Int]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            // 工具栏自适应 = 自动换行，不是横向滚动（滚动会把搜索框推出可视区＝另一种「看不见」）。
            // ViewThatFits 在两个布局里挑放得下的第一个：
            //   ① 一行（搜索右对齐）——窗口够宽时就是原设计的样子；
            //   ② FlowLayout——一行放不下就整件换到下一行，任何宽度都不裁切、不滚动。
            // 两者都不向 NavigationSplitView 报超大固有最小宽（一行版放不下即让位给换行版），
            // 所以侧栏永远完整（旧 bug：定宽件之和撑爆详情列 → 反压侧栏到 <180）。
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) {
                    toolbarLeading(ranked: ranked, counts: counts, projCounts: projCounts)
                    Spacer(minLength: 12)
                    toolbarTrailing()
                }
                FlowLayout(spacing: 12) {
                    toolbarLeading(ranked: ranked, counts: counts, projCounts: projCounts)
                    toolbarTrailing()
                }
            }

            summaryLine(filtered)
        }
    }

    /// 工具栏左侧一组：对象类型 + 产品/项目筛选 + 层级。两个布局共用，避免两处各写一遍对不上。
    @ViewBuilder
    private func toolbarLeading(ranked: [Agent], counts: [String: Int], projCounts: [String: Int]) -> some View {
        // 一级分段：对象类型（默认 Skill，去掉「全部」混合态）
        Picker("对象类型", selection: $app.typeFilter) {
            Text("Skill").tag(ObjectType.skill)
            Text("MCP").tag(ObjectType.mcp)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()

        productFilterMenu(ranked: ranked, counts: counts)

        projectFilterMenu(counts: projCounts)

        Picker("层级", selection: $app.levelFilter) {
            Text("全部层级").tag(Level?.none)
            Text("用户级").tag(Level?.some(.user))
            Text("项目级").tag(Level?.some(.project))
            Text("技能库").tag(Level?.some(.library))   // skill-library 批（文案①）
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
    }

    /// 工具栏右侧一组：搜索 + 轻量刷新。同样被两个布局共用。
    @ViewBuilder
    private func toolbarTrailing() -> some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(Color.scMutedForeground)
            TextField("搜索 Skill / MCP…", text: $app.query)
                .textFieldStyle(.plain)
                .frame(minWidth: 120)
            if !app.query.isEmpty {
                Button {
                    app.query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(Color.scMutedForeground)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(Color.scInput)
        .scControlRadius()
        .frame(width: 220)

        // 轻量刷新：按已知位置重扫（秒级）。与设置页「重新扫描全盘」（清缓存 + 44s 遍历）
        // 是两件事——"我就想看看 Agent 刚挂上没有"不该值 44 秒。
        Button {
            app.requestRescan(reason: .userAction)
        } label: {
            Image(systemName: "arrow.clockwise")
                .font(.system(size: 14))
                .foregroundStyle(app.isScanning ? Color.scMutedForeground : Color.scForeground)
        }
        .buttonStyle(.plain)
        .disabled(app.isScanning)
        .opacity(app.isScanning ? 0.5 : 1)
        .keyboardShortcut("r", modifiers: [.command])
        .help(app.isScanning ? "扫描进行中…"
                              : "按已知位置重扫（⌘R，不做全盘发现；全盘在「设置 · 重新扫描全盘」）")
    }

    /// 可激活产品多选筛选：只列当前类型下真实出现过的 Agent（目录名兜底的伪归属不进菜单）
    /// 每项带该 Agent 名下当前挂载数并按规模降序——选之前就知道每家体量
    private func productFilterMenu(ranked: [Agent], counts: [String: Int]) -> some View {
        let listed = ranked.filter { (counts[$0.id] ?? 0) > 0 }
        return Menu {
            Button("全部产品") { app.agentFilter = [] }
            if !app.agentFilter.isEmpty { Divider() }
            ForEach(listed) { agent in
                Button {
                    if app.agentFilter.contains(agent.id) {
                        app.agentFilter.remove(agent.id)
                    } else {
                        app.agentFilter.insert(agent.id)
                    }
                } label: {
                    let line = "\(AgentRegistry.agentName(agent.id)) · \(counts[agent.id] ?? 0)"
                    if app.agentFilter.contains(agent.id) {
                        Label(line, systemImage: "checkmark")
                    } else {
                        Text(line)
                    }
                }
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "line.3.horizontal.decrease.circle")
                    .font(.system(size: 12))
                Text(productFilterLabel)
                    .font(.system(size: 14))
                    .monospacedDigit()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color.scInput)
            .scControlRadius()
        }
        .fixedSize()
    }

    /// 项目多选（2026-09-22 补）：与产品菜单同构，行尾带该项目当前条目数、按规模降序。
    /// 只列 .git 祖先发现的真项目——靠目录名兜底出来的伪归属不是项目，列进去就是假筛选项。
    private func projectFilterMenu(counts: [String: Int]) -> some View {
        let listed = app.index.projects
            .filter { (counts[$0.id] ?? 0) > 0 }
            .sorted { a, b in
                let ca = counts[a.id] ?? 0, cb = counts[b.id] ?? 0
                if ca != cb { return ca > cb }
                return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
            }
        // 同名不同路径的项目（worktree / 多份 checkout）很常见：两行一模一样的话，
        // 筛选器就成了让人猜的选项。重名时把路径尾部带出来区分，不重名保持干净。
        let nameHits = Set(Dictionary(grouping: app.index.projects, by: \.name).filter { $0.value.count > 1 }.keys)
        return Menu {
            Button("全部项目") { app.projectFilter = [] }
            if !app.projectFilter.isEmpty { Divider() }
            ForEach(listed) { project in
                Button {
                    if app.projectFilter.contains(project.id) {
                        app.projectFilter.remove(project.id)
                    } else {
                        app.projectFilter.insert(project.id)
                    }
                } label: {
                    let line = "\(projectLabel(project, dupNames: nameHits)) · \(counts[project.id] ?? 0)"
                    if app.projectFilter.contains(project.id) {
                        Label(line, systemImage: "checkmark")
                    } else {
                        Text(line)
                    }
                }
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "folder.badge.gearshape")
                    .font(.system(size: 12))
                Text(projectFilterLabel)
                    .font(.system(size: 14))
                    .monospacedDigit()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color.scInput)
            .scControlRadius()
        }
        .fixedSize()
    }

    /// 项目显示名。同名不同路径（多份 checkout / worktree）时带出父目录，
    /// 否则菜单里会出现两行一模一样的选项——点哪个全凭猜。
    private func projectLabel(_ project: Project, dupNames: Set<String>) -> String {
        guard dupNames.contains(project.name) else { return project.name }
        let parent = (project.path as NSString).deletingLastPathComponent
        return "\(project.name)（\((parent as NSString).lastPathComponent)）"
    }

    /// 真实产品按挂载规模降序在前、目录名归属垫底。
    /// 本机 70+ 家产品、单个 Skill 可挂 52 家：一次排序，产品菜单与每行「可激活于」共用。
    private func agentsByScale(_ counts: [String: Int]) -> [Agent] {
        let real = app.index.agents
            .filter { !app.pseudoAgentIds.contains($0.id) }
            .sorted { a, b in
                let ca = counts[a.id] ?? 0, cb = counts[b.id] ?? 0
                if ca != cb { return ca > cb }
                return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
            }
        let pseudo = app.index.agents.filter { app.pseudoAgentIds.contains($0.id) }
        return real + pseudo
    }

    /// 行内「可激活于」的显示次序表（rank 越小越该露出来）
    private func agentRank(_ ranked: [Agent]) -> [String: Int] {
        // uniquingKeysWith 而非 uniqueKeysWithValues：agents 万一有重复 id 也不能崩在清单页
        Dictionary(ranked.enumerated().map { ($0.element.id, $0.offset) }, uniquingKeysWith: min)
    }

    private var productFilterLabel: String {
        app.agentFilter.isEmpty ? "产品：全部" : "产品 · \(app.agentFilter.count) 个"
    }

    private var projectFilterLabel: String {
        app.projectFilter.isEmpty ? "项目：全部" : "项目 · \(app.projectFilter.count) 个"
    }

    /// 汇总条：当前筛选结果的数量事实（只报总量，中性色）
    /// 挂载次数 = 落在某个 Agent 挂载目录里的落点数（D10=A 口径）
    private func summaryLine(_ filtered: [InventoryItem]) -> some View {
        let s = app.index.summary(for: filtered)
        let noun = app.typeFilter == .mcp ? "MCP" : "Skill"
        var parts = ["共 \(s.items) 个 \(noun)", "被挂 \(s.mounts) 次", "落点 \(s.locations) 处"]
        if s.projects > 0 { parts.append("跨 \(s.projects) 个项目") }
        return Text(parts.joined(separator: " · "))
            .font(.system(size: 12))
            .foregroundStyle(Color.scMutedForeground)
            .monospacedDigit()
            .help("被挂 N 次 = 落在某个 Agent 挂载目录里的落点数；落点 = 条目在盘上出现的总次数（含归不到 Agent 的副本）")
    }

    private var filteredItems: [InventoryItem] {
        app.index.filtered(type: app.typeFilter, agents: app.agentFilter, projects: app.projectFilter,
                           level: app.levelFilter, query: app.query,
                           sort: app.sortKey, ascending: app.sortAscending)
    }

    // MARK: - 表格

    private func table(_ filtered: [InventoryItem], rank: [String: Int]) -> some View {
        VStack(spacing: 0) {
            // 表头：名称/挂载/项目三列可点排序
            HStack(spacing: 0) {
                SortableHeader(title: "名称", key: .name, app: app)
                    .frame(minWidth: InventoryColumn.nameMin, maxWidth: .infinity, alignment: .leading)
                columnText("归属")
                    .frame(minWidth: InventoryColumn.levelMin, maxWidth: InventoryColumn.levelMax, alignment: .leading)
                columnText("可激活于")
                    .frame(minWidth: InventoryColumn.agentMin, maxWidth: InventoryColumn.agentMax, alignment: .leading)
                    .padding(.trailing, 10)   // 与行内同宽，表头列对齐
                SortableHeader(title: "挂载", key: .mounts, app: app)
                    .frame(minWidth: InventoryColumn.mountMin, maxWidth: InventoryColumn.mountMax, alignment: .leading)
                SortableHeader(title: "项目", key: .projects, app: app)
                    .frame(minWidth: InventoryColumn.projectMin, maxWidth: InventoryColumn.projectMax, alignment: .leading)
                    .padding(.leading, 12)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color.scMuted.opacity(0.4))

            ScrollView {
                LazyVStack(spacing: 0) {
                    if app.showSkeleton {
                        // STATE: loading-initial —— <1.5s 8 行 Skeleton
                        ForEach(0..<8, id: \.self) { _ in
                            SkeletonRow()
                        }
                    } else {
                        rows(filtered: filtered, rank: rank)
                    }
                }
            }
        }
        .overlay(RoundedRectangle(cornerRadius: LayoutMetrics.Radius.lg).stroke(Color.scBorder))
        .scContainerRadius()
        .frame(maxHeight: .infinity, alignment: .top)
    }

    @ViewBuilder
    private func rows(filtered: [InventoryItem], rank: [String: Int]) -> some View {
        if app.gate == .denied {
            // STATE: gate-denied（被「这次先不」挡住的真实形状）
            // 绝不能落到 empty-collection 文案上——那是"这台机器还没有 Skill"，
            // 而事实是"你还没让它看"，说反一次就毁掉清单的可信度。
            CenteredStateCard(
                title: "还没有授权读取磁盘，所以清单是空的 —— 这台机器上有 Skill，只是我还没看见",
                actionTitle: "授权并扫描",
                action: { app.grant() },
            )
            .padding(.top, 48)
        } else if app.index.items.isEmpty && app.gatePhase != .scanning {
            // STATE: empty-collection（授权成功但全盘 0 条目）
            CenteredStateCard(
                title: "这台机器还没有 Skill。装配是你未来 Agent 的事，也可以先检查扫描范围",
                actionTitle: "查看扫描范围",
                action: { settingsPath = true },
            )
            .padding(.top, 48)
        } else if filtered.isEmpty && !app.query.isEmpty {
            // STATE: searching-empty（带引导 CTA）
            CenteredStateCard(
                title: "没有匹配「\(app.query)」的条目 —— 清单没有藏东西，只是这次没搜到",
                actionTitle: "清空搜索",
                action: { app.query = "" },
            )
            .padding(.top, 48)
        } else if filtered.isEmpty {
            // STATE: empty-filter（产品/层级筛选无结果；筛选只改变展示，不改变磁盘事实）
            CenteredStateCard(
                title: "没有匹配当前筛选的条目。筛选只改变展示，不改变磁盘上的事实",
                actionTitle: "清除筛选",
                action: {
                    app.agentFilter = []
                    app.projectFilter = []
                    app.levelFilter = nil
                },
            )
            .padding(.top, 48)
        } else {
            ForEach(filtered) { item in
                InventoryRow(item: item, app: app, agentRank: rank)
                Divider().overlay(Color.scBorder)
            }
        }
    }

    private func columnText(_ s: String) -> some View {
        Text(s)
            .font(.system(size: 12))
            .foregroundStyle(Color.scMutedForeground)
    }
}

// MARK: - 可排序表头

/// 点一次按该列排序、再点翻转升降；当前排序列带箭头（硬规则：只有排序列可点，不做装饰性 affordance）
struct SortableHeader: View {
    let title: String
    let key: InventorySortKey
    @ObservedObject var app: AppState

    private var isCurrent: Bool { app.sortKey == key }

    var body: some View {
        Button {
            app.toggleSort(key)
        } label: {
            HStack(spacing: 3) {
                Text(title)
                if isCurrent {
                    Image(systemName: app.sortAscending ? "chevron.up" : "chevron.down")
                        .imageScale(.small)   // 继承表头 12pt，不自创字号
                }
            }
            .font(.system(size: 12))
            .foregroundStyle(isCurrent ? Color.scForeground : Color.scMutedForeground)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("点击按\(title)排序（再点一次翻转升降）")
    }
}

// MARK: - 行

struct InventoryRow: View {
    let item: InventoryItem
    @ObservedObject var app: AppState
    /// 产品显示优先级（真实产品按挂载规模降序、目录名归属垫底），由清单页一次算好传入
    let agentRank: [String: Int]

    var body: some View {
        Button {
            app.selectedItemId = item.id
        } label: {
            HStack(spacing: 0) {
                // 名称 + 副本数 + 描述 truncate（>40 字走 truncate，edge boundary-long-text）
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Image(systemName: item.type == .skill ? "folder" : "server.rack")
                            .foregroundStyle(Color.scMutedForeground)
                            .font(.system(size: 12))
                        Text(item.name)
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(Color.scForeground)
                            .lineLimit(1)
                            .truncationMode(.tail)
                        // story-1 GWT「副本 ×N」：与详情栏「落点 N 处」同源，避免两套数字
                        if totals.locations > 1 {
                            Text("副本 ×\(totals.locations)")
                                .font(.system(size: 12))
                                .foregroundStyle(Color.scMutedForeground)
                                .monospacedDigit()
                                .help("该条目在盘上出现 \(totals.locations) 处（实体源 + 引用）")
                        }
                    }
                    Text(item.description)
                        .font(.system(size: 12))
                        .foregroundStyle(Color.scMutedForeground)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .frame(minWidth: InventoryColumn.nameMin, maxWidth: .infinity, alignment: .leading)

                // 归属徽章（全中性；零挂载 = 中性事实，非警告；类型由一级分段表达，行内不再重复）
                HStack(spacing: 4) {
                    Badge(text: levelText, kind: .secondary)
                    if item.status == .zeroMount {
                        Badge(text: "从未挂载", kind: .muted)
                    }
                }
                .frame(minWidth: InventoryColumn.levelMin, maxWidth: InventoryColumn.levelMax, alignment: .leading)

                // 「可激活于」：真实产品优先、按挂载规模排序。
                // 挂 4 家以上只露 1 家 + 剩余家数（180pt 塞不下两家名字 + 计数，会被截成"Claude C…"）
                HStack(spacing: 4) {
                    Text(agentSummaryText)
                        .font(.system(size: 14))
                        .foregroundStyle(allMountsPseudo ? Color.scMutedForeground : Color.scForeground)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    if item.mountedBy.count > 2 {
                        Text("+\(item.mountedBy.count - (item.mountedBy.count > 3 ? 1 : 2)) 家")
                            .font(.system(size: 12))
                            .foregroundStyle(Color.scMutedForeground)
                            .monospacedDigit()
                            .fixedSize()
                    }
                }
                .frame(minWidth: InventoryColumn.agentMin, maxWidth: InventoryColumn.agentMax, alignment: .leading)
                .padding(.trailing, 10)   // 否则 +N 会贴到下一列的「N 次」上
                .help(allMountsPseudo
                      ? "目录名归属，非 Agent 可引用：\(allAgentNames)"
                      : "可激活于 \(item.mountedBy.count) 家：\(allAgentNames)")

                // 挂载次数：落在 Agent 挂载目录里的落点数（symlink 或实体都算，归不到 Agent 的不算）
                Text(mountCountText)
                    .font(.system(size: 14))
                    .foregroundStyle(totals.mounts == 0 ? Color.scMutedForeground : Color.scForeground)
                    .monospacedDigit()
                    .frame(minWidth: InventoryColumn.mountMin, maxWidth: InventoryColumn.mountMax, alignment: .leading)
                    .lineLimit(1)
                    .help("挂载次数 = 落在 Agent 挂载目录里的引用数；归不到 Agent 的同名副本只计入落点")

                // 出现过的具体项目数（含实体源所在项目）
                Text(totals.projects == 0 ? "—" : "\(totals.projects) 个")
                    .font(.system(size: 14))
                    .foregroundStyle(totals.projects == 0 ? Color.scMutedForeground : Color.scForeground)
                    .monospacedDigit()
                    .frame(minWidth: InventoryColumn.projectMin, maxWidth: InventoryColumn.projectMax, alignment: .leading)
                    .padding(.leading, 12)
                    .help(totals.projects == 0 ? "没有项目级落点" : "该条目在 \(totals.projects) 个项目里出现过（共 \(totals.locations) 处落点）")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(app.selectedItemId == item.id ? Color.scSecondary : Color.clear)
        // 硬规则 §3.7：键盘可达（Button 语义自带 Tab 焦点环 + Enter/Space 触发）
        .help(item.description) // truncate 全文 tooltip
    }

    /// 该行的归属全部来自"所在目录名"兜底（即项目名），不是可被 Agent 引用的工具
    private var allMountsPseudo: Bool {
        !item.mountedBy.isEmpty && item.mountedBy.allSatisfy { app.pseudoAgentIds.contains($0) }
    }

    /// 按显示优先级排好的归属（大品牌在前，目录名归属垫底）
    private var orderedAgents: [String] {
        item.mountedBy.sorted { (agentRank[$0] ?? .max) < (agentRank[$1] ?? .max) }
    }

    /// 露出来的那几家名字：≤3 家显示前 2 家，更多时只显示第 1 家（剩下的量由 +N 家表达）
    private var agentSummaryText: String {
        guard !item.mountedBy.isEmpty else { return "—" }
        let shown = item.mountedBy.count > 3 ? 1 : 2
        return orderedAgents.prefix(shown).map(AgentRegistry.agentName).joined(separator: " · ")
    }

    private var allAgentNames: String {
        orderedAgents.map(AgentRegistry.agentName).joined(separator: " · ")
    }

    /// 该条目落点计数（行内两个数字同源；只读三个 Int，不碰 spots）
    private var totals: MountTotals { app.index.totals(of: item.id) }

    /// 挂载次数文案：0 次显示破折号（"从未挂载"徽章已表达同一事实）
    private var mountCountText: String {
        totals.mounts == 0 ? "—" : "\(totals.mounts) 次"
    }

    private var levelText: String {
        if item.level == .user { return "用户级" }
        if item.level == .library { return "技能库" }   // 库层级（skill-library 批文案①）
        if let pid = item.projectId, let p = app.index.projects.first(where: { $0.id == pid }) {
            return p.name
        }
        // 全盘发现后会出现既不在 Agent 目录树内、也找不到 .git 的位置——中性说法，不判风险
        return "其他位置"
    }
}

// MARK: - 组件

struct Badge: View {
    enum Kind { case outline, secondary, muted }
    let text: String
    let kind: Kind

    var body: some View {
        Text(text)
            .font(.system(size: 12))
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .background(background)
            .foregroundStyle(foreground)
            .overlay(
                Capsule().stroke(kind == .outline ? Color.scBorder : Color.clear)
            )
            .clipShape(Capsule())
    }

    private var background: Color {
        switch kind {
        case .outline: return .clear
        case .secondary: return .scSecondary
        case .muted: return .clear
        }
    }

    private var foreground: Color {
        switch kind {
        case .outline, .secondary: return .scForeground
        case .muted: return .scMutedForeground
        }
    }
}

struct SkeletonRow: View {
    @State private var phase = false

    var body: some View {
        HStack {
            RoundedRectangle(cornerRadius: 4)
                .fill(Color.scMuted)
                .opacity(phase ? 0.5 : 0.9)
                .frame(height: 14)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .onAppear {
            withAnimation(.easeInOut(duration: 0.6).repeatForever(autoreverses: true)) {
                phase = true
            }
        }
    }
}

struct CenteredStateCard: View {
    let title: String
    let actionTitle: String
    let action: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            Text(title)
                .font(.system(size: 14))
                .foregroundStyle(Color.scMutedForeground)
                .multilineTextAlignment(.center)
            Button(actionTitle, action: action)
                .buttonStyle(.bordered)
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - 降级横幅（edge error-partial-degrade + G1 忽略出口）

struct DegradedBanner: View {
    @ObservedObject var app: AppState
    let onOpenSettings: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(bannerSummary)
                .font(.system(size: 14))
                .foregroundStyle(Color.scMutedForeground)
            ForEach(app.index.degraded) { d in
                HStack {
                    Text(d.path)
                        .font(.system(size: 12))
                        .foregroundStyle(Color.scMutedForeground)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text("· \(d.reason)")
                        .font(.system(size: 12))
                        .foregroundStyle(Color.scMutedForeground)
                    Spacer()
                    // G1：每行「忽略此位置」，忽略后不再提示，设置页可逆
                    Button("忽略此位置") {
                        app.ignoreLocation(d.path)
                    }
                    .buttonStyle(.link)
                    .font(.system(size: 12))
                }
            }
            HStack {
                Spacer()
                Button("查看扫描范围", action: onOpenSettings)
                    .buttonStyle(.link)
                    .font(.system(size: 12))
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.scMuted.opacity(0.4))
        .overlay(RoundedRectangle(cornerRadius: LayoutMetrics.Radius.md).stroke(Color.scBorder))
    }

    private var bannerSummary: String {
        let n = app.index.degraded.count
        // 句式照抄 flow1："N 个位置未能读取（…）——清单基于其余 M 个位置构建"
        let reasons = Dictionary(grouping: app.index.degraded, by: \.reason)
            .map { "\($1.count) \($0)" }
            .sorted()
            .joined(separator: " · ")
        let m = app.index.locationsScanned
        return "\(n) 个位置未能读取（\(reasons)）——清单基于其余 \(m) 个位置构建"
    }
}
