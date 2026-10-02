// SidePages.swift — 设置 / 挂载账占位 / 回退占位
// 占位页文案取自 edge must 态（empty-log / empty-first-day / error-validation），零观点。

import SwiftUI
import SkillControllerCore

// MARK: - 设置（扫描范围 = 全盘发现结果；不存在的路径不进列表）

struct SettingsView: View {
    @ObservedObject var app: AppState
    /// 仅 sheet 场景传入；侧栏页为 nil 不显示「完成」——
    /// 否则 dismiss() 无上层 presentation 可退，会关掉整个窗口（唯一窗口 → App 退出）。
    var onClose: (() -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("设置 · 扫描范围")
                    .font(.system(size: 20, weight: .semibold))
                Spacer()
                Button {
                    // #16（D39）：忙态 = 用户取消出口（协作取消，cancelScan 显式 cancel 三句柄）；
                    // 空闲 = 重新全盘。同一按钮、同一键位（⌘⇧R 随按钮走），语义随忙态分流。
                    app.isScanning ? app.cancelScan() : app.rescanFullDiskFromScratch()
                } label: {
                    HStack(spacing: 6) {
                        if app.isScanning {
                            ProgressView().controlSize(.small)
                        }
                        Text(app.isScanning ? "停止扫描" : "重新扫描全盘")
                    }
                }
                .buttonStyle(.bordered)
                // 忙态必须可点——disabled 的停止按钮就是又一个撒谎按钮（G7）
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .help(app.isScanning
                      ? "停止这次扫描：清单停在点停前的数字，不发布半截结果"
                      : "清掉发现缓存，重新全盘遍历（本机实测约 44s）。只想看 Agent 刚挂的没挂上，用清单页的 ⌘R。")

                if let onClose {
                    Button("完成") { onClose() }
                        .keyboardShortcut(.defaultAction)
                }
            }

            Text("扫描范围来自全盘发现：只列出盘上真实存在的 skills 目录与 MCP 配置文件，再判定用户级 / 项目级 / 归属。")
                .font(.system(size: 14))
                .foregroundStyle(Color.scMutedForeground)

            statusLine
            cliGuideSection
            pruneControls

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ignoredSection
                    userLevelSection
                    projectSection
                    otherSection
                }
                .padding(.bottom, 16)
            }
        }
        .padding(24)
        .frame(minWidth: LayoutMetrics.diffSheetWidth, idealWidth: LayoutMetrics.diffSheetWidth, minHeight: 480)
        .background(Color.scBackground)
    }

    // MARK: 进度与统计

    private var statusLine: some View {
        HStack(spacing: 8) {
            Text(app.scanPhaseText)
                .font(.system(size: 12))
                .foregroundStyle(Color.scMutedForeground)
            Spacer()
            Text(summary)
                .font(.system(size: 12))
                .foregroundStyle(Color.scMutedForeground)
                .monospacedDigit()
        }
        .padding(8)
        .background(Color.scMuted.opacity(0.2))
        .scControlRadius()
    }

    private var summary: String {
        var parts = ["\(app.scopeLocations.count) 处位置"]
        if let at = app.lastFullDiscovery {
            parts.append("全盘发现于 \(at.formatted(.dateTime.hour().minute().locale(Locale(identifier: "zh_CN"))))")
        }
        if app.discoveryDirsVisited > 0 {
            parts.append("遍历 \(app.discoveryDirsVisited.formatted(.number.notation(.compactName))) 个目录")
        }
        // 只报总量不报风险（既有文案口径）
        if app.discoveryUnreadable > 0 {
            parts.append("\(app.discoveryUnreadable) 处读不到")
        }
        return parts.joined(separator: " · ")
    }

    // MARK: CLI 安装 / 升级（台账 #19 · 设计档 §8）
    //
    // 常驻单行区（位置 = 统计条之下、剪枝开关区之上，§8 已定交互决策）：
    // 检测态四态文案（C2/C3/C4）+ 入口按钮（C1）。文案零观点、照抄设计档。
    //
    // 观察直持（评审发现②）：对 app.cliGuide 用 @ObservedObject 直取——CLIGuideModel 的
    // @Published 不经 AppState 转发，这里若只观察 AppState，检测态翻转不会触发本行重算。
    // 实现注意：SettingsView 自身已是 @ObservedObject app，SwiftUI 里子对象观察要落在
    // 实际渲染该行的视图上，所以这一区拆成独立 CliGuideSettingsRow（它自己持 @ObservedObject）。
    private var cliGuideSection: some View {
        CliGuideSettingsRow(guide: app.cliGuide)
    }

    /// 剪枝逐类可勾选：范围怎么被缩小由用户自己决定，每类如实标出本次跳过了多少个目录。
    /// 用 checkbox 而非 switch：本 App 的 primary 是近黑墨色，switch 的 ON 轨道会被填成
    /// 一坨黑胶囊、白色滑块看不见（智昊真机反馈）；checkbox 在任何尺寸下勾选态都可辨，
    /// 且不引入新色值（硬规则 §3.4）。
    private var pruneControls: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("不扫描以下位置（勾选即排除；改动会立即重新扫描全盘）")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Color.scMutedForeground)
            ForEach(PruneCategory.allCases, id: \.rawValue) { category in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Toggle(category.label, isOn: Binding(
                        get: { app.rules.isCategoryPruned(category) },
                        set: { app.setPruned(category, $0) }
                    ))
                    .toggleStyle(.checkbox)
                    .font(.system(size: 12, weight: .medium))
                    .disabled(app.isScanning)
                    Text(category.note)
                        .font(.system(size: 12))
                        .foregroundStyle(Color.scMutedForeground)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 4)
                    // 没有统计值就说"本次未统计"，不拿 0 冒充"一个都没跳过"
                    let skipped = app.prunedDirsByCategory[category]
                    Text(app.rules.isCategoryPruned(category)
                         ? (skipped.map { "跳过 \($0) 个目录" } ?? "本次未统计")
                         : "已纳入扫描")
                        .font(.system(size: 12))
                        .foregroundStyle(Color.scMutedForeground)
                        .monospacedDigit()
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(Color.scMuted.opacity(0.2))
                .scControlRadius()
            }
        }
    }

    // MARK: 分区

    @ViewBuilder private var ignoredSection: some View {
        let ignored = app.ignoredPaths()
        if !ignored.isEmpty {
            sectionTitle("已忽略 \(ignored.count) 处（点击恢复扫描）")
            ForEach(ignored.sorted(), id: \.self) { path in
                HStack {
                    Text(path).font(.system(size: 12)).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Button("恢复") { app.restoreLocation(path) }
                        .buttonStyle(.link).font(.system(size: 12))
                }
                .padding(8)
                .background(Color.scMuted.opacity(0.4))
                .scControlRadius()
            }
        }
    }

    @ViewBuilder private var userLevelSection: some View {
        let locs = app.scopeLocations.filter { $0.level == .user }
            .sorted { $0.url.path.localizedCaseInsensitiveCompare($1.url.path) == .orderedAscending }
        sectionTitle("用户级（\(locs.count) 处）")
        ForEach(locs, id: \.url) { loc in locationRow(loc) }
        if locs.isEmpty { emptyHint("没有发现用户级位置") }
    }

    /// 项目级按项目根分组折叠（全盘发现后项目可能上百个，平铺会淹掉设置页）
    @ViewBuilder private var projectSection: some View {
        let locs = app.scopeLocations.filter { $0.level == .project && $0.projectId != nil }
        let grouped = Dictionary(grouping: locs, by: { $0.projectId ?? "" })
            .sorted { ($0.value.first?.url.path ?? "") < ($1.value.first?.url.path ?? "") }
        sectionTitle("项目级（\(locs.count) 处 · \(grouped.count) 个项目）")
        ForEach(grouped, id: \.0) { pid, group in
            DisclosureGroup {
                ForEach(group.sorted { $0.url.path < $1.url.path }, id: \.url) { loc in
                    locationRow(loc)
                }
            } label: {
                HStack {
                    Text(app.index.projects.first(where: { $0.id == pid })?.name ?? pid)
                        .font(.system(size: 14, weight: .medium))
                    Text(app.index.projects.first(where: { $0.id == pid })?.path ?? "")
                        .font(.system(size: 12))
                        .foregroundStyle(Color.scMutedForeground)
                        .lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Text("\(group.count) 处")
                        .font(.system(size: 12)).foregroundStyle(Color.scMutedForeground)
                        .monospacedDigit()
                }
                .padding(8)
                .background(Color.scMuted.opacity(0.2))
                .scControlRadius()
            }
        }
        if grouped.isEmpty { emptyHint("没有发现项目级位置") }
    }

    /// 既不在已知 Agent 树内、也找不到 .git 的位置——中性收录，不判风险
    @ViewBuilder private var otherSection: some View {
        let locs = app.scopeLocations.filter { $0.isUnclassified }
            .sorted { $0.url.path.localizedCaseInsensitiveCompare($1.url.path) == .orderedAscending }
        if !locs.isEmpty {
            sectionTitle("其他位置（\(locs.count) 处：不在已知 Agent 目录内，也没有 .git 可判定项目）")
            ForEach(locs, id: \.url) { loc in locationRow(loc) }
        }
    }

    private func emptyHint(_ s: String) -> some View {
        Text(s).font(.system(size: 12)).foregroundStyle(Color.scMutedForeground).padding(.vertical, 4)
    }

    @ViewBuilder private func locationRow(_ loc: ScanLocation) -> some View {
        // 列表来自全盘发现 + sanitize，进到这里的位置一定存在；「该路径不存在」分支已随注册表一并退役
        HStack {
            Text(tilde(loc.url.path))
                .font(.system(size: 12))
                .lineLimit(1)
                .truncationMode(.middle)
            if loc.url.path.hasSuffix("/.agents/skills") {
                Badge(text: "共享源", kind: .outline)
            }
            Spacer()
            if let count = app.locationEntryCounts[loc.url.standardizedFileURL.path] {
                Text("\(count) 项")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.scMutedForeground)
                    .monospacedDigit()
            }
            Text(loc.kind == .skillDirectory ? "Skills 目录" : "MCP 配置")
                .font(.system(size: 12))
                .foregroundStyle(Color.scMutedForeground)
            if let agent = loc.agentId {
                Badge(text: AgentRegistry.agentName(agent),
                      kind: loc.agentOrigin.isRealAgent ? .secondary : .muted)
                if loc.agentOrigin == .containerName {
                    Text("目录名归属 · 非 Agent 可引用")
                        .font(.system(size: 12))
                        .foregroundStyle(Color.scMutedForeground)
                }
            }
            Button("忽略") { app.ignoreLocation(loc.url.standardizedFileURL.path) }
                .buttonStyle(.link)
                .font(.system(size: 12))
        }
        .padding(8)
        .background(Color.scMuted.opacity(0.2))
        .scControlRadius()
    }

    private func tilde(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }

    private func sectionTitle(_ s: String) -> some View {
        Text(s)
            .font(.system(size: 14, weight: .medium))
            .padding(.top, 8)
    }
}

// MARK: - 设置页 CLI 单行区（台账 #19 · 设计档 §8）
//
// 检测态四态文案 C2（未检测到）/ C3（已装一致）/ C4（版本不对齐，落后/超前共用）+ 入口按钮 C1。
// current 态入口按钮**隐藏**而非置灰（评审发现①落档）：current 无缺口可修，按钮保留只有两条去路——
// 点了呈现未经人工复核的新中性文案（撞「新文案逐一过目」红线），或做成点了无内容可呈现的撒谎按钮
// （撞 K8 出口收口与「按钮不撒谎」纪律）；C3 文案本身已是完整状态说明，隐藏零信息损失。
// 入口无视时机与跳过（设计裁定）：常驻，随时可点，点开先复检再呈现（§2.3）。
struct CliGuideSettingsRow: View {
    @ObservedObject var guide: CLIGuideModel   // 直持观察（评审发现②）
    @State private var showGuide = false

    var body: some View {
        HStack(spacing: 8) {
            Text("CLI 安装 / 升级")   // C1 入口标题
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Color.scMutedForeground)
            statusText
                .font(.system(size: 12))
                .foregroundStyle(Color.scMutedForeground)
            Spacer(minLength: 4)
            // C1（用户裁决定名「CLI 安装 / 升级」）：缺口态才显按钮（current 态隐藏，评审发现①）；
            // 探测未落地（status == nil）时同样不显——探测是毫秒级只读操作，等态落地再给可点出口，
            // 不做点开「还没有内容可呈现」的撒谎按钮（G7/K8）。
            if guide.status?.gapKey != nil {
                Button {
                    guide.openManually()
                    showGuide = true
                } label: {
                    Text("CLI 安装 / 升级")   // C1
                }
                .buttonStyle(.bordered)
                .font(.system(size: 12))
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(Color.scMuted.opacity(0.2))
        .scControlRadius()
        .sheet(isPresented: $showGuide) {
            CliGuideSheet(guide: guide)
        }
    }

    /// 检测态四态文案（§8）：C2 未检测到（可带探测失败原因）/ C3 已装一致 / C4 版本不对齐。
    /// status 未落地时如实显「正在检测」——这句与「尚未检测」是状态直述（探测毫秒级，
    /// 后者实际不可见），不是新观点文案；与 Sheet 内「正在检测…」同一性质，一并报备。
    @ViewBuilder private var statusText: some View {
        switch guide.status {
        case nil:
            Text(guide.probing ? "正在检测 skillctl…" : "尚未检测 skillctl")
        case .notInstalled(let note):
            // C2 + 如实注脚（探测失败原因——裁决④不静默吞；句式取 C9 同一措辞骨架）
            Text("未检测到 skillctl" + (note.map { "（探测未能完成：\($0)）" } ?? ""))
        case .outdated(let installed), .ahead(let installed):
            // C4：句式并列报两个版本号、方向中性，落后与超前原样共用（F3 四态齐，无新增条目）
            Text("已装 skillctl \(installed)，App 为 \(SkillControllerVersion.string)")
        case .current:
            // C3：已装且版本一致。此时入口按钮已隐藏，本行只剩这句完整状态说明
            Text("已装 skillctl \(SkillControllerVersion.string)（与 App 一致）")
        }
    }
}

// MARK: - 挂载账（story-5 视图②：谁挂了多少 / 哪些从没被挂过）

/// 只摆文件层事实：数据源是**当前磁盘快照**（清单索引），不是操作日志的历史聚合。
/// 视图①变动时间线要攒天数、视图③触发词重叠要先定 L1-L4 算法，本页如实写明未做，
/// 不拿空表冒充"没有挂载"，也不拿走查夹具糊历史（零观点 + 度量诚实性两条红线）。
struct LedgerView: View {
    @ObservedObject var app: AppState
    @State private var type: ObjectType = .skill
    @State private var sort: LedgerSort = .total
    @State private var ascending = false
    @State private var zeroQuery = ""

    enum LedgerSort: String, CaseIterable { case name = "产品", user = "用户级", project = "项目级", total = "合计" }

    /// 表头列序必须与行内列序一致（第一版把 allCases 直接当列序，结果表头是「合计 用户级 项目级 产品」
    /// 而行是「产品 用户级 项目级 合计」——数字全挂错列，比不排还糟）。
    private var columns: [(key: LedgerSort, width: CGFloat?)] {
        [(LedgerSort.name, nil), (.user, 90), (.project, 90), (.total, 90)]
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                agentTable
                zeroMountSection
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color.scBackground)
    }

    // MARK: 页头

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("挂载账")
                    .font(.system(size: 20, weight: .semibold))
                Spacer()
                Picker("对象类型", selection: $type) {
                    Text("Skill").tag(ObjectType.skill)
                    Text("MCP").tag(ObjectType.mcp)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 180)
            }
            Text(snapshotLine)
                .font(.system(size: 12))
                .foregroundStyle(Color.scMutedForeground)
                .monospacedDigit()
            Text("本页只摆文件层事实：谁挂着多少、哪些从来没被挂过。不排序好坏，也不建议删除。")
                .font(.system(size: 14))
                .foregroundStyle(Color.scMutedForeground)
        }
    }

    /// 快照口径必须说清楚：这些数来自哪一次扫描、按什么单位数
    private var snapshotLine: String {
        var parts: [String] = []
        if let at = app.lastFullDiscovery {
            parts.append("快照来自 \(at.formatted(.dateTime.hour().minute().locale(Locale(identifier: "zh_CN")))) 的扫描")
        } else {
            parts.append("快照来自本次扫描")
        }
        parts.append("单位是条目数（同一个 Skill 在用户级和几个项目里都挂着，对这家只算 1 个）")
        parts.append("只数落在某家目录里的挂载，靠目录名兜底的归属已单独打标")
        if app.index.isUpdating { parts.append("索引持续更新中") }
        return parts.joined(separator: " · ")
    }

    // MARK: 视图②·每家挂了多少

    private var rows: [InventoryIndex.AgentMountRow] {
        let all = app.index.agentMountRows(type: type)
        // 靠目录名兜底的"归属"多半是项目名，不是可引用的产品——排在表尾并打标，不混进排名
        let real = all.filter { !app.pseudoAgentIds.contains($0.agentId) }
        let pseudo = all.filter { app.pseudoAgentIds.contains($0.agentId) }
        // ascending=false 表示"大的在前"（默认看哪家最胖），翻转后变成小的在前
        func by(_ v: @escaping (InventoryIndex.AgentMountRow) -> Int) -> (InventoryIndex.AgentMountRow, InventoryIndex.AgentMountRow) -> Bool {
            { a, b in
                let (va, vb) = (v(a), v(b))
                if va != vb { return ascending ? va < vb : va > vb }
                return a.agentId.localizedCaseInsensitiveCompare(b.agentId) == .orderedAscending
            }
        }
        let sorted: (InventoryIndex.AgentMountRow, InventoryIndex.AgentMountRow) -> Bool
        switch sort {
        case .total: sorted = by(\.total)
        case .user: sorted = by(\.userLevel)
        case .project: sorted = by(\.projectLevel)
        case .name:
            sorted = { a, b in
                let r = a.agentId.localizedCaseInsensitiveCompare(b.agentId) == .orderedAscending
                return ascending ? r : !r
            }
        }
        return real.sorted(by: sorted) + pseudo.sorted(by: sorted)
    }

    private var agentTable: some View {
        let list = rows
        return VStack(spacing: 0) {
            HStack(spacing: 0) {
                ForEach(columns, id: \.key) { col in
                    Button {
                        if sort == col.key { ascending.toggle() } else { sort = col.key; ascending = col.key == .name }
                    } label: {
                        HStack(spacing: 3) {
                            Text(col.key.rawValue)
                            if sort == col.key {
                                Image(systemName: ascending ? "chevron.up" : "chevron.down").imageScale(.small)
                            }
                        }
                        .font(.system(size: 12))
                        .foregroundStyle(sort == col.key ? Color.scForeground : Color.scMutedForeground)
                        .frame(maxWidth: .infinity, alignment: col.width == nil ? .leading : .trailing)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .frame(width: col.width)
                    .help("点击按\(col.key.rawValue)排序（再点一次翻转升降）")
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color.scMuted.opacity(0.4))

            ForEach(list, id: \.agentId) { r in
                HStack(spacing: 0) {
                    HStack(spacing: 6) {
                        Text(AgentRegistry.agentName(r.agentId))
                            .font(.system(size: 14, weight: .medium))
                        if app.pseudoAgentIds.contains(r.agentId) {
                            Badge(text: "目录名归属", kind: .muted)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    number(r.userLevel, width: 90)
                    number(r.projectLevel, width: 90)
                    number(r.total, width: 90, emphasis: true)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                Divider().overlay(Color.scBorder)
            }
            if list.isEmpty {
                Text(type == .skill ? "还没有任何 Agent 挂载记录" : "还没有任何 Agent 写入 MCP 配置")
                    .font(.system(size: 14))
                    .foregroundStyle(Color.scMutedForeground)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 24)
            }
        }
        .overlay(RoundedRectangle(cornerRadius: LayoutMetrics.Radius.lg).stroke(Color.scBorder))
        .scContainerRadius()
    }

    private func number(_ v: Int, width: CGFloat, emphasis: Bool = false) -> some View {
        Text("\(v)")
            .font(.system(size: 14, weight: emphasis ? .semibold : .regular))
            .foregroundStyle(v == 0 ? Color.scMutedForeground : Color.scForeground)
            .monospacedDigit()
            .frame(width: width, alignment: .trailing)
    }

    // MARK: 视图②·零挂载清单

    // 9②：全量过滤每次渲染恰好一次（原实现 zeroItems 计算属性 + total 各算一遍 = 两次全量过滤；
    // 集合大时这就是挂载账页的主线程负担）。查询过滤在这一次结果上做，语义零变化。
    private var zeroMountSection: some View {
        let zeroAll = app.index.zeroMountItems(type: type)
        let q = zeroQuery.trimmingCharacters(in: .whitespaces)
        let list = q.isEmpty ? zeroAll
            : zeroAll.filter { $0.name.localizedCaseInsensitiveContains(q) || $0.description.localizedCaseInsensitiveContains(q) }
        let total = zeroAll.count
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("从来没被任何 Agent 挂载过")
                    .font(.system(size: 14, weight: .medium))
                Text("\(total) 个 · 中性事实，不是警告")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.scMutedForeground)
                    .monospacedDigit()
                Spacer()
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").foregroundStyle(Color.scMutedForeground)
                    TextField("在零挂载里搜索…", text: $zeroQuery)
                        .textFieldStyle(.plain)
                        .frame(width: 180)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(Color.scInput)
                .scControlRadius()
            }
            Text("点一行跳到清单看它的落点都在哪。")
                .font(.system(size: 12))
                .foregroundStyle(Color.scMutedForeground)

            VStack(spacing: 0) {
                ForEach(list.prefix(400)) { item in
                    Button {
                        app.selectedItemId = item.id
                        app.page = .inventory
                    } label: {
                        HStack(spacing: 8) {
                            Text(item.name)
                                .font(.system(size: 14))
                                .lineLimit(1).truncationMode(.tail)
                                .frame(width: 260, alignment: .leading)
                            Text(item.description)
                                .font(.system(size: 12))
                                .foregroundStyle(Color.scMutedForeground)
                                .lineLimit(1).truncationMode(.tail)
                            Spacer(minLength: 8)
                            Text("\(app.index.totals(of: item.id).locations) 处落点")
                                .font(.system(size: 12))
                                .foregroundStyle(Color.scMutedForeground)
                                .monospacedDigit()
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    Divider().overlay(Color.scBorder)
                }
                if list.isEmpty {
                    // 只说量到的那件事：不写成"每个都能被某家激活"——落点在 Agent 目录里 ≠ 一定加载得了
                    Text(zeroQuery.isEmpty ? "没有条目只躺在 Agent 目录之外" : "没有匹配「\(zeroQuery)」的条目")
                        .font(.system(size: 14))
                        .foregroundStyle(Color.scMutedForeground)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 24)
                } else if list.count > 400 {
                    Text("另有 \(list.count - 400) 个未列出，用上方搜索框缩小范围")
                        .font(.system(size: 12))
                        .foregroundStyle(Color.scMutedForeground)
                        .monospacedDigit()
                        .padding(12)
                }
            }
            .overlay(RoundedRectangle(cornerRadius: LayoutMetrics.Radius.lg).stroke(Color.scBorder))
            .scContainerRadius()
        }
    }
}

// MARK: - 回退（story-4：操作日志流 + 回收站，真数据）

struct RollbackView: View {
    @ObservedObject var app: AppState

    var body: some View {
        HStack(spacing: 0) {
            logStream
            Divider().overlay(Color.scBorder)
            trashList.frame(width: 320)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.scBackground)
        // #14（D41）：页面冷进入强制重读一次——isRestorable 是渲染时逐行现算，
        // 真正缺的是重渲染触发器；监听尚未起、或事件竞态窗口内，「进页面看到的是上次快照」
        // 的窗口由此关死（S12 翻转的触发链补全）
        .onAppear { app.refreshRollback() }
    }

    // 操作日志：按日分组折叠 + 虚拟列表（edge boundary-long-log）
    private var logStream: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0, pinnedViews: .sectionHeaders) {
                ForEach(groupedDays, id: \.0) { day, entries in
                    Section {
                        ForEach(entries) { e in
                            HStack(alignment: .top, spacing: 8) {
                                Text(timeOf(e.at))
                                    .font(.system(size: 12))
                                    .foregroundStyle(Color.scMutedForeground)
                                    .monospacedDigit()
                                    .frame(width: 56, alignment: .leading)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(e.action).font(.system(size: 14))
                                    Text(e.target)
                                        .font(.system(size: 12))
                                        .foregroundStyle(Color.scMutedForeground)
                                        .lineLimit(1).truncationMode(.middle)
                                }
                                Spacer()
                                if e.restored == true {
                                    Badge(text: "已恢复", kind: .muted)
                                }
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 8)
                        }
                    } header: {
                        Text(day)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(Color.scMutedForeground)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 6)
                            .background(Color.scMuted.opacity(0.4))
                    }
                }
                if app.logEntries.isEmpty {
                    // edge empty-log：空也是事实——不是"暂无数据"
                    Text("近 30 天没有任何删除与挂载变动")
                        .font(.system(size: 14))
                        .foregroundStyle(Color.scMutedForeground)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 48)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // 回收站：一步恢复；被 Finder 清空 → 置灰 + 行内"目标已不存在"（G7 恢复按钮不撒谎）
    private var trashList: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("回收站")
                .font(.system(size: 14, weight: .medium))
                .padding(16)
            Divider().overlay(Color.scBorder)
            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(app.trashEntries, id: \.entryId) { m in
                        let restorable = app.trash.isRestorable(m)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(m.itemName)
                                .font(.system(size: 14, weight: .medium))
                            Text("删除于 \(dateOf(m.deletedAt)) · \(m.locations.count) 个落点")
                                .font(.system(size: 12))
                                .foregroundStyle(Color.scMutedForeground)
                            HStack {
                                if !restorable {
                                    Text("目标已不在回收站，无法恢复")
                                        .font(.system(size: 12))
                                        .foregroundStyle(Color.scMutedForeground)
                                }
                                Spacer()
                                Button("恢复") { app.restoreEntry(m) }
                                    .buttonStyle(.bordered)
                                    .disabled(!restorable)
                                    .opacity(restorable ? 1 : 0.5)
                            }
                        }
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.scMuted.opacity(0.2))
                        .scControlRadius()
                    }
                    if app.trashEntries.isEmpty {
                        Text("回收站是空的")
                            .font(.system(size: 14))
                            .foregroundStyle(Color.scMutedForeground)
                            .padding(.top, 24)
                    }
                }
                .padding(12)
            }
        }
    }

    private var groupedDays: [(String, [LogEntry])] {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        let groups = Dictionary(grouping: app.logEntries) { e in
            guard let d = f.date(from: e.at) else { return "未知日期" }
            return d.formatted(.dateTime.year().month().day().locale(Locale(identifier: "zh_CN")))
        }
        return groups.sorted { $0.key > $1.key }.map { ($0.key, $0.value) }
    }

    private func timeOf(_ iso: String) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        guard let d = f.date(from: iso) else { return "--:--" }
        return d.formatted(.dateTime.hour().minute().locale(Locale(identifier: "zh_CN")))
    }

    private func dateOf(_ iso: String) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        guard let d = f.date(from: iso) else { return iso }
        return d.formatted(.dateTime.year().month().day().hour().minute().locale(Locale(identifier: "zh_CN")))
    }
}
