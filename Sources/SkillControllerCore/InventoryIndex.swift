// InventoryIndex.swift — 落点合并为统一条目（同名多副本合并展示）
// 三维归属：Agent × 用户级/项目级 × 具体项目（架构裁定：统一对象模型）

import Foundation

/// 单个落点的性质（2026-09-21 清单筛选整改新增）。
/// 一个 Skill 在盘上可能出现多次，每次出现就是一个「落点」：
/// entitySource = 本体认定的实体源（合并时选定；本体认库时即库落点，散落实体副本不得抢占）；
/// entityCopy = 别处的独立实体目录（同名重装）；
/// symlink = 指向别处的符号链接（Agent 挂载的常见形态）；
/// configEntry = MCP 配置里的一项声明（不存在"源"，每处都是独立生效点）。
public struct MountSpot: Hashable, Sendable {
    public enum Kind: String, Sendable {
        case entitySource
        case entityCopy
        case symlink
        case configEntry

        /// 详情栏与列表里显示的性质标签
        public var label: String {
            switch self {
            case .entitySource: return "实体源"
            case .entityCopy: return "实体副本"
            case .symlink: return "symlink"
            case .configEntry: return "配置项"
            }
        }
    }

    public var path: String
    public var kind: Kind
    /// symlink 的指向（仅 symlink 有值）——详情栏用它显示"→ 源"
    public var target: String?
    /// 该落点所在挂载目录的归属 Agent（nil = 共享目录 / 未识别）
    public var agentId: String?
    public var level: Level
    public var projectId: String?

    public init(path: String, kind: Kind, target: String? = nil, agentId: String? = nil,
                level: Level, projectId: String? = nil) {
        self.path = path
        self.kind = kind
        self.target = target
        self.agentId = agentId
        self.level = level
        self.projectId = projectId
    }
}

/// 清单行内计数与排序用的轻量聚合（三个 Int）。
/// 渲染热路径专用：绝不要把 spots 带进这里——真机 1970 条目时，
/// 比较器里反复拷贝 [MountSpot] 会把主线程打到 100% CPU（2026-09-21 实测）。
public struct MountTotals: Hashable, Sendable {
    public var locations: Int
    public var mounts: Int
    public var projects: Int

    public init(locations: Int = 0, mounts: Int = 0, projects: Int = 0) {
        self.locations = locations
        self.mounts = mounts
        self.projects = projects
    }

    public static let zero = MountTotals()
}

/// 单条目的落点聚合（详情栏逐条列 spots；计数走 totals）。
/// locations = 盘上出现次数（含实体源与一切未识别位置）；
/// mounts = 挂载次数 = 落在某个 Agent 挂载目录里的落点数。
///          口径 2026-09-21 定稿（D10=A）：
///          - 归不到 Agent 的位置（别的 skill 内部的同名子目录、未分类角落）只算落点、不算挂载，
///            否则 `references` 这类伪条目会刷出 26 次；
///          - 实体源若本身就躺在某家 Agent 的 skills 目录里，那一家确实装着它，计入挂载——
///            否则会出现「可激活于 workbuddy · 挂载 0 次」这种自相矛盾的行。
///            源在共享目录（无 Agent 归属）时仍不计，孤本 = 0 次的语义保留。
/// projectIds = 出现过的具体项目集合（含实体源所在项目）。
public struct MountStat: Hashable, Sendable {
    public var spots: [MountSpot]
    public var totals: MountTotals
    public var projectIds: Set<String>

    public var locations: Int { totals.locations }
    public var mounts: Int { totals.mounts }
    public var projects: Int { totals.projects }

    public init(spots: [MountSpot] = []) {
        var ids = Set<String>()
        var mounts = 0
        for s in spots {
            if let p = s.projectId { ids.insert(p) }
            if s.agentId != nil { mounts += 1 }
        }
        self.spots = spots
        self.projectIds = ids
        self.totals = MountTotals(locations: spots.count, mounts: mounts, projects: ids.count)
    }
}

/// 清单排序键（2026-09-21 整改：表头可点排序，让"挂得最多的"一眼可见）
public enum InventorySortKey: String, CaseIterable, Sendable {
    case name
    case mounts
    case projects
}

public final class InventoryIndex: @unchecked Sendable {
    public private(set) var items: [InventoryItem] = []
    public private(set) var degraded: [DegradedLocation] = []
    public private(set) var locationsScanned: Int = 0
    public private(set) var agents: [Agent] = AgentRegistry.knownAgents
    public private(set) var projects: [Project] = []
    /// 条目 id → 落点聚合（详情栏数据源；只查单条，别在渲染循环里遍历它）
    public private(set) var mountStats: [String: MountStat] = [:]
    /// 条目 id → 轻量计数（清单行内两个数字 + 表头排序的数据源）
    public private(set) var mountTotals: [String: MountTotals] = [:]
    /// 索引是否仍在增量更新（edge loading-initial >3s 的"索引持续更新中"数据源）
    public private(set) var isUpdating: Bool = false

    /// App 在分批扫描期间手动维持"更新中"标记（>3s 增量出结果用）
    public func setUpdating(_ v: Bool) { isUpdating = v }

    public init() {}

    // MARK: - 构建

    @discardableResult
    public func rebuild(from result: ScanResult, projects: [Project], discoveredAgents: [Agent] = []) -> [InventoryItem] {
        degraded = result.degraded
        locationsScanned = result.locationsScanned
        self.projects = projects
        self.agents = AgentRegistry.merged(withDiscovered: discoveredAgents)

        // 按 (type, name) 合并：同一 Skill 的多落点（实体目录 + symlink 引用）为一个条目
        var grouped: [String: [RawEntry]] = [:]
        var order: [String] = []
        var seen: Set<String> = []
        for e in result.entries {
            let id = "\(e.type.rawValue):\(e.name)"
            grouped[id, default: []].append(e)
            // seen 集合去重：全盘发现后条目量级从 ~180 涨到数千，order.contains 的 O(n²) 会成为新瓶颈
            if !seen.contains(id) { seen.insert(id); order.append(id) }
        }

        var items2: [InventoryItem] = []
        var stats: [String: MountStat] = [:]
        var totals: [String: MountTotals] = [:]
        for id in order {
            let es = grouped[id]!
            let first = es[0]
            // 源路径优先实体目录；纯 symlink 引用（源在扫描范围外）则用解析目标。
            // **库落点优先**（skill-library 批 §2.1）：同一条目存在库落点（实体）时，本体认库——
            // 否则"权威副本"随扫描顺序漂移，违背库的本体语义。库落点是实体目录
            // （resolvedPath == nil），在与既有实体源的竞争中按库形状判定
            // （SkillLibrary.isInsideSkillLibrary，本条与下方 libIdx 分支同一谓词）显式置顶。
            var primaryIndex = es.firstIndex(where: { $0.resolvedPath == nil }) ?? 0
            let hasEntitySource = es[primaryIndex].resolvedPath == nil
            var primary = hasEntitySource ? es[primaryIndex].locationPath
                : (first.resolvedPath ?? first.locationPath)
            // 条目级三维归属跟本体走（2026-09-30 走查修复，台账 #23）：本体优先取库落点时
            // level/projectId 必须一并取库落点的值——库条目被 mount 过时 Agent 落点
            // （project/user 级）在扫描序里排前，first 是 Agent 落点，条目会被误判成
            // project 级，「技能库」筛选段恒空、CLI list/info 的 level 字段失真。
            // 库落点的 level 恒 .library、projectId 恒 nil（LocationClassifier 库特判保证），
            // 直接取即可；纯库条目首条即库落点，两值与 first 相同，行为不变。
            var level = first.level
            var projectId = first.projectId
            // 实体源身份与本体同源（2026-09-30 台账 #24）：本体认库时 primaryIndex 一并改指库落点，
            // spots(for:) 的 kind 判定与本文件 addLandingFact 的 sourcePath 判定（按
            // path == item.sourcePath）随之收敛为同一张表——此前库根追加在扫描范围末尾，
            // 盘上有实体散落副本时它持「实体源」、库本体被降格「实体副本」，与本体认库相悖。
            // 库落点必有实体源资格：level 恒 .library、resolvedPath 恒 nil（LocationClassifier 库特判）。
            if hasEntitySource, let libIdx = es.firstIndex(where: {
                $0.resolvedPath == nil && SkillLibrary.isInsideSkillLibrary($0.locationPath)
            }) {
                primary = es[libIdx].locationPath
                level = es[libIdx].level
                projectId = es[libIdx].projectId
                primaryIndex = libIdx
            }
            var dups = Set(es.flatMap { [$0.locationPath] + ($0.resolvedPath.map { [$0] } ?? []) })
            dups.remove(primary)
            let mountedBy = Array(Set(es.compactMap(\.mountedAgentId))).sorted()
            // spots 只在重建时算一次；行内/排序读 totals，避免渲染期反复拷贝落点数组
            let stat = MountStat(spots: spots(for: es, type: first.type, primaryIndex: primaryIndex))
            stats[id] = stat
            totals[id] = stat.totals
            let item = InventoryItem(
                id: id,
                name: first.name,
                description: first.description,
                type: first.type,
                level: level,
                projectId: projectId,
                sourcePath: primary,
                mountedBy: mountedBy,
                duplicates: dups.sorted(),
                triggerOverlapWith: [],
                mounts: [],
                status: mountedBy.isEmpty ? .zeroMount : .mounted,
            )
            items2.append(item)
        }
        items2.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        items = items2
        mountStats = stats
        mountTotals = totals
        isUpdating = false
        return items2
    }

    /// 同一 (type,name) 的落点集合 → 带性质的 spots。
    /// 规则：只有真实体目录才有「实体源」身份（它自己不是一次挂载）；
    /// 若该条目在范围内只有 symlink（源在范围外），那每一处都是挂载引用，不降级成"源"。
    /// MCP 每一项都是独立生效的配置声明，全部计为挂载。
    private func spots(for es: [RawEntry], type: ObjectType, primaryIndex: Int) -> [MountSpot] {
        es.enumerated().map { i, e in
            let kind: MountSpot.Kind
            switch type {
            case .mcp:
                kind = .configEntry
            case .skill:
                if e.resolvedPath != nil { kind = .symlink }
                else { kind = (i == primaryIndex) ? .entitySource : .entityCopy }
            }
            return MountSpot(path: e.locationPath, kind: kind, target: e.resolvedPath,
                             agentId: e.mountedAgentId, level: e.level, projectId: e.projectId)
        }
        .sorted { a, b in
            // 用户级在前；实体源排在同层级最前；其余按路径（详情栏按此顺序分组）
            if a.level != b.level { return a.level == .user }
            let ra = a.kind == .entitySource ? 0 : 1
            let rb = b.kind == .entitySource ? 0 : 1
            if ra != rb { return ra < rb }
            return a.path < b.path
        }
    }

    private func isSymlinkPath(_ path: String) -> Bool {
        (try? FileManager.default.attributesOfItem(atPath: path)[.type] as? FileAttributeType) == .some(.typeSymbolicLink)
    }

    /// 就地摘掉一个条目：本工具刚把它整体移进回收站时用它（D16 的连带处理）。
    /// 重扫改成"收尾一次性发布"之后，界面上的数字会停在上一版直到本轮扫完；
    /// 删除回执已经写了"已移入回收站"，行却还留在清单里等人再点一次，那是自己给自己造二次删除。
    /// 只用于**我们自己刚做完写操作**的条目——别的变动一律等扫描落定，不拿猜测改索引。
    @discardableResult
    public func removeItem(id: String) -> Bool {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return false }
        items.remove(at: i)
        mountStats[id] = nil
        mountTotals[id] = nil
        return true
    }

    // MARK: - 落点事实定向更新（#13 / D40）

    /// 把我们自己工具（skillctl 装配事件）刚写下的落点事实就地反映进索引——
    /// 信任锚与 removeItem 同级：added/removed 是本工具写下的磁盘事实，不是猜测。
    /// 用途：三段式扫描在跑时 FSEvents 触发的轻量重扫只能排队（收尾要 40s+），
    /// 这条毫秒级定向更新让「CLI 卸下后行内计数」立刻回落，权威兜底仍是后面的重扫。
    ///
    /// 口径（与 spots(for:) 同文件同源，单条目重derive 不许抄第二份表——两份表 = D19 的成因）：
    /// - 只对**文件系统落点**动手：含 `#` 的 MCP 路径跳过（MCP 呈现由扫描管线管）；
    /// - removed 只摘 symlink 落点（unmount 对实体一律 refused，removed 恒为链接）；
    ///   条目整行不会消失——摘不掉实体源（D16 的"模态作废"形状在此路径不可达）；
    /// - added 只往**已在索引**的条目加路径（pull 的源必来自全集）；条目找不到 = 盘面
    ///   已被别的操作改变，跳过（重扫兜底）。
    /// - 返回是否有变化；调用方有变化才发 objectWillChange。
    @discardableResult
    public func applyLandingFacts(added: [String], removed: [String], home: URL) -> Bool {
        var changed = false
        for path in removed { changed = removeLandingFact(path: path) || changed }
        for path in added { changed = addLandingFact(path: path, home: home) || changed }
        return changed
    }

    /// 从含该落点的条目摘除一处 symlink 落点，并单条目重derive MountStat。
    /// 路径不落在任何已知条目下（已被别处处理/盘面已变）→ no-op 返回 false。
    private func removeLandingFact(path: String) -> Bool {
        guard !path.contains("#") else { return false }
        guard let id = itemId(containingLandingPath: path) else { return false }
        guard var stat = mountStats[id] else { return false }
        let target = URL(fileURLWithPath: path).standardizedFileURL.path
        guard let idx = stat.spots.firstIndex(where: {
            URL(fileURLWithPath: $0.path).standardizedFileURL.path == target
        }) else { return false }
        guard stat.spots[idx].kind == .symlink else { return false }   // 实体源/副本不摘（unmount 摘不掉它们）
        stat.spots.remove(at: idx)
        rederive(statFor: id, spots: stat.spots)
        return true
    }

    /// 把一处新落点（symlink 或实体）加进已知的同名条目，并单条目重derive MountStat。
    private func addLandingFact(path: String, home: URL) -> Bool {
        guard !path.contains("#") else { return false }
        let name = (path as NSString).lastPathComponent
        guard let id = items.first(where: { $0.id == "skill:\(name)" })?.id else { return false }
        guard var stat = mountStats[id] else { return false }
        let target = URL(fileURLWithPath: path).standardizedFileURL.path
        guard !stat.spots.contains(where: {
            URL(fileURLWithPath: $0.path).standardizedFileURL.path == target
        }) else { return false }   // 幂等：已在索引里（重扫先到）→ 零变化
        let isLink = Self.isSymlink(path)
        let kind: MountSpot.Kind = isLink ? .symlink : (target == URL(fileURLWithPath: items.first { $0.id == id }!.sourcePath).standardizedFileURL.path ? .entitySource : .entityCopy)
        // 归属判定走 LocationClassifier 同一张读侧表（与扫描期 rebuild 完全同源）。
        // kind 按当前 sourcePath 判是暂态口径：定向更新不重选本体，新库落点可能
        // 暂标 entityCopy，下轮 rebuild 后与扫描期身份收敛（本体认库时 sourcePath 即库落点）。
        // agentId 原样取——**不做 isRealAgent 过滤**（评审轮 1 点修）：扫描期 rebuild 的
        // spots 原样带 loc.agentId（InventoryScanner.swift:151，目录名兜底的伪归属也算挂载），
        // 这里若过滤就造出第二份口径（D19 的成因形状）；伪归属的单独标注由 UI 层
        // pseudoAgentIds 承担（AppState.agents(in:) 同一判定），不由索引分叉。
        let containerDir = URL(fileURLWithPath: path).deletingLastPathComponent()
        let loc = DiscoveredLocation(path: containerDir.path, kind: .skillDirectory)
        let c = LocationClassifier.classify(loc, home: home)
        stat.spots.append(MountSpot(path: path, kind: kind, target: isLink
            ? (try? FileManager.default.destinationOfSymbolicLink(atPath: path))
            // 库特判的 agentId 空串在此折成 nil（与 ScopeBuilder 同款）——
            // 空串若进 spots 会被 MountStat 计成挂载，库落点还挂着伪归属
            : nil, agentId: c.agentId.isEmpty ? nil : c.agentId, level: c.level, projectId: c.projectId))
        rederive(statFor: id, spots: stat.spots)
        return true
    }

    /// 单条目 MountStat 重derive（totals 由 MountStat.init 统一算，条目行集合不动）。
    /// 条目的 duplicates / mountedBy 同步按剩余 spots 同构重derive——与 rebuild 的
    /// dups（locationPath + symlink 解析目标，去 primary）/ mountedBy（agentId 集合）完全同口径，
    /// 详情栏「挂载变动」按落点命中日志（D3）与搜索命中才不会说旧话。
    /// 排序同样同构（评审轮 1 点修）：与 rebuild 的 spots 排序（用户级在前 → 实体源最前 → 按路径，
    /// :202-209）同一套键——详情栏的分组顺序不因定向更新而暂态错乱。
    private func rederive(statFor id: String, spots: [MountSpot]) {
        let sorted = spots.sorted { a, b in
            if a.level != b.level { return a.level == .user }
            let ra = a.kind == .entitySource ? 0 : 1
            let rb = b.kind == .entitySource ? 0 : 1
            if ra != rb { return ra < rb }
            return a.path < b.path
        }
        let stat = MountStat(spots: sorted)
        mountStats[id] = stat
        mountTotals[id] = stat.totals
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        let primary = URL(fileURLWithPath: items[i].sourcePath).standardizedFileURL.path
        var dups = Set<String>()
        for s in spots {
            dups.insert(URL(fileURLWithPath: s.path).standardizedFileURL.path)
            if let t = s.target { dups.insert(URL(fileURLWithPath: t).standardizedFileURL.path) }
        }
        dups.remove(primary)
        items[i].duplicates = dups.sorted()
        items[i].mountedBy = Set(spots.compactMap(\.agentId)).sorted()
    }

    /// 哪个条目的落点集合（sourcePath + duplicates）含这条路径
    private func itemId(containingLandingPath path: String) -> String? {
        let target = URL(fileURLWithPath: path).standardizedFileURL.path
        return items.first(where: { item in
            [item.sourcePath].compactMap { $0 }.map {
                URL(fileURLWithPath: $0).standardizedFileURL.path
            }.contains(target)
            || item.duplicates.map { URL(fileURLWithPath: $0).standardizedFileURL.path }.contains(target)
        })?.id
    }

    private static func isSymlink(_ path: String) -> Bool {
        (try? FileManager.default.attributesOfItem(atPath: path)[.type] as? FileAttributeType) == .some(.typeSymbolicLink)
    }

    // MARK: - 查询

    public var skillCount: Int { items.filter { $0.type == .skill }.count }
    public var mcpCount: Int { items.filter { $0.type == .mcp }.count }

    public func item(id: String) -> InventoryItem? {
        items.first { $0.id == id }
    }

    public func mountStat(of id: String) -> MountStat {
        mountStats[id] ?? MountStat()
    }

    /// 行内两个数字与排序键的取数入口（只有三个 Int，渲染循环里可以放心反复读）
    public func totals(of id: String) -> MountTotals {
        mountTotals[id] ?? .zero
    }

    /// 筛选：类型（nil=全部）× 可激活产品（空集=全部）× 项目（空集=全部）× 层级（nil=全部）× 搜索 × 排序。
    /// 视角切换（按 Agent/项目/层级 分组排序）已于 2026-09-21 清单整改退役，改由表头排序承担。
    /// 项目维度 2026-09-22 补上：产品的差异化说法是"按项目装配"，此前只能筛到「项目级」一个笼统档，
    /// 「proj-x 到底挂了哪些」在 App 里答不出来。
    public func filtered(type: ObjectType?, agents: Set<String> = [], projects: Set<String> = [],
                         level: Level? = nil, query: String = "",
                         sort: InventorySortKey = .name, ascending: Bool = true) -> [InventoryItem] {
        var result = items
        if let t = type {
            result = result.filter { $0.type == t }
        }
        if !agents.isEmpty {
            result = result.filter { item in !agents.isDisjoint(with: item.mountedBy) }
        }
        if !projects.isEmpty {
            result = result.filter { item in
                !projects.isDisjoint(with: mountStats[item.id]?.projectIds ?? [])
            }
        }
        if let l = level {
            result = result.filter { $0.level == l }
        }
        let q = query.trimmingCharacters(in: .whitespaces)
        if !q.isEmpty {
            // 搜索口径（2026-09-22 扩）：名字/描述之外，路径与项目名也命中——
            // 人记不住 skill 叫什么，记得住"它在 proj-x 里"和"它在 .codex/skills 下"
            result = result.filter { matches($0, query: q) }
        }
        // 排序前先算一次键：比较器里查字典 + 拷贝落点数组会把 1970 行的清单打到满 CPU
        struct SortKey { var mounts: Int; var projects: Int; var name: String }
        let keyed: [(InventoryItem, SortKey)] = result.map { item in
            let t = self.mountTotals[item.id] ?? .zero
            return (item, SortKey(mounts: t.mounts, projects: t.projects, name: item.name))
        }
        let ordered: [(InventoryItem, SortKey)] = keyed.sorted { a, b in
            let primary: Int
            switch sort {
            case .name: primary = 0
            case .mounts: primary = a.1.mounts - b.1.mounts
            case .projects: primary = a.1.projects - b.1.projects
            }
            if primary != 0 { return ascending ? primary < 0 : primary > 0 }
            // 同分一律按名称收口，保证稳定且严格弱序（同名返回 false）
            let byName = a.1.name.localizedCaseInsensitiveCompare(b.1.name)
            return ascending ? byName == .orderedAscending : byName == .orderedDescending
        }
        return ordered.map(\.0)
    }

    /// 搜索命中判定：名字 / 描述 / 实体源路径 / 任一落点路径 / 落点所在项目名。
    /// 大小写不敏感走 localizedCaseInsensitive，跟列表里其它文本比较同一口径。
    private func matches(_ item: InventoryItem, query q: String) -> Bool {
        if item.name.localizedCaseInsensitiveContains(q) { return true }
        if item.description.localizedCaseInsensitiveContains(q) { return true }
        if item.sourcePath.localizedCaseInsensitiveContains(q) { return true }
        if item.duplicates.contains(where: { $0.localizedCaseInsensitiveContains(q) }) { return true }
        let names = Set((mountStats[item.id]?.projectIds ?? []).compactMap { pid in
            projects.first { $0.id == pid }?.name
        })
        return names.contains { $0.localizedCaseInsensitiveContains(q) }
    }

    /// 项目筛选项的行尾数字：每个项目里当前挂着多少个该类型条目。
    /// 只数 .git 祖先发现的真项目——靠目录名兜底出来的伪归属不是项目，列进去会造出假筛选项。
    public func projectCounts(type: ObjectType) -> [String: Int] {
        var counts: [String: Int] = [:]
        for it in items where it.type == type {
            for pid in mountStats[it.id]?.projectIds ?? [] { counts[pid, default: 0] += 1 }
        }
        return counts
    }

    /// 汇总条：给定条目集合的（条目数, 落点总数, 挂载次数, 跨项目数）
    public func summary(for selected: [InventoryItem]) -> (items: Int, locations: Int, mounts: Int, projects: Int) {
        var locations = 0, mounts = 0
        var projects = Set<String>()
        for it in selected {
            if let t = mountTotals[it.id] {
                locations += t.locations
                mounts += t.mounts
            }
            if let ids = mountStats[it.id]?.projectIds { projects.formUnion(ids) }
        }
        return (selected.count, locations, mounts, projects.count)
    }

    /// 每个 Agent 名下当前挂了多少个该类型条目（产品筛选项的行尾实测数字）
    public func agentCounts(type: ObjectType) -> [String: Int] {
        var counts: [String: Int] = [:]
        for it in items where it.type == type {
            for a in it.mountedBy { counts[a, default: 0] += 1 }
        }
        return counts
    }

    /// 挂载账视图②的一行：某家 Agent 当前挂了多少条目，按作用域拆开。
    /// 单位是**条目数（去重）**，不是落点数：同一个 Skill 在用户级和两个项目里都挂着，
    /// 对这家仍然只是"能激活 1 个 Skill"，写成 3 会把规模虚报三倍。
    /// 合计同样去重——所以「用户级 + 项目级」可以大于合计（跨作用域重复挂的那部分）。
    public struct AgentMountRow: Hashable, Sendable {
        public var agentId: String
        public var userLevel: Int
        public var projectLevel: Int
        public var total: Int
        public var projects: Int

        public init(agentId: String, userLevel: Int, projectLevel: Int, total: Int, projects: Int) {
            self.agentId = agentId
            self.userLevel = userLevel
            self.projectLevel = projectLevel
            self.total = total
            self.projects = projects
        }
    }

    /// 按 Agent 汇总当前挂载事实（含靠目录名兜底的伪归属，由调用方决定怎么区分展示）。
    /// 只读 mountTotals/mountStats，一轮 O(条目)，可以在进页面时算一次。
    public func agentMountRows(type: ObjectType) -> [AgentMountRow] {
        var userSets: [String: Set<String>] = [:]
        var projSets: [String: Set<String>] = [:]
        var allSets: [String: Set<String>] = [:]
        var projIds: [String: Set<String>] = [:]
        for it in items where it.type == type {
            let stat = mountStats[it.id]
            var agentsAtUser: Set<String> = []
            var agentsAtProj: Set<String> = []
            for s in stat?.spots ?? [] {
                guard let a = s.agentId else { continue }
                if s.level == .user { agentsAtUser.insert(a) } else { agentsAtProj.insert(a) }
            }
            for a in agentsAtUser { userSets[a, default: []].insert(it.id) }
            for a in agentsAtProj { projSets[a, default: []].insert(it.id) }
            for a in it.mountedBy {
                allSets[a, default: []].insert(it.id)
                if let ids = stat?.projectIds, !ids.isEmpty { projIds[a, default: []].formUnion(ids) }
            }
        }
        let ids = Set(allSets.keys)
        return ids.map { id in
            AgentMountRow(agentId: id,
                          userLevel: userSets[id]?.count ?? 0,
                          projectLevel: projSets[id]?.count ?? 0,
                          total: allSets[id]?.count ?? 0,
                          projects: projIds[id]?.count ?? 0)
        }
        .sorted { $0.total != $1.total ? $0.total > $1.total
            : $0.agentId.localizedCaseInsensitiveCompare($1.agentId) == .orderedAscending }
    }

    /// 零挂载清单：盘上存在、但没有任何一处落在 Agent 挂载目录里的条目。
    /// 中性事实（story-5 硬约束：绝不写成"建议删除"），排序由调用方决定。
    /// D21 收口（skill-library 批决策⑤）：口径 = `mounts == 0`（全落点无 Agent 归属）——
    /// 库条目未装配时天然零挂载，「在库里但零挂载」由此成为真实信号；
    /// 挂载账视图②与清单页 zeroMount 徽章消费的是这**同一个谓词**，不再有第二张表。
    public func zeroMountItems(type: ObjectType) -> [InventoryItem] {
        items.filter { $0.type == type && (mountTotals[$0.id]?.mounts ?? 0) == 0 }
    }

    /// 三维归属的测试友好出口：条目 → (agents, level, projectId)
    public func ownership(of id: String) -> (agents: [String], level: Level, projectId: String?)? {
        guard let it = item(id: id) else { return nil }
        return (it.mountedBy, it.level, it.projectId)
    }
}
