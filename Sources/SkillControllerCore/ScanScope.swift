// ScanScope.swift — 扫描范围（发现驱动）
// 范围不再是写死的注册表，而是 ScopeDiscovery 从磁盘发现 + LocationClassifier 分类的结果。
// 依据 docs/agent-recon.md（C1/C2/C4/D1 已裁决）与 docs/scan-scope-redesign.md（2026-09-20 整改）：
//  - C1: QoderWork 用 ~/.qwenworkcn（产品更名），展示名仍「QoderWork」
//  - C2: Codex 双目录都扫（官方 ~/.agents/skills + 本机 ~/.codex/skills），都记归属 Codex
//  - C4: Agent 列表为可配置注册表；发现出的新工具目录自动成为中性归属
//  - D1: 项目清单改由磁盘发现（.git 祖先）推导，不再依赖 ~/.claude.json 的 projects 键

import Foundation

public struct ScanLocation: Hashable, Sendable {
    public enum Kind: String, Hashable, Codable, Sendable {
        /// skill 目录：直接子目录 = skill 文件夹
        case skillDirectory
        /// MCP JSON 配置（{"mcpServers": {...}} 或 ~/.claude.json 顶层）
        case mcpJSON
        /// Codex config.toml 中的 [mcp_servers.*]
        case mcpTOML
    }

    public var url: URL
    public var kind: Kind
    /// 挂载归属的 Agent；nil = 共享源（如 ~/.agents/skills，不归属任何 Agent）
    public var agentId: String?
    /// 归属推断依据：区分"真 Agent 目录"与"项目名兜底"（智昊裁决：后者要单独标注）
    public var agentOrigin: AgentOrigin
    public var level: Level
    public var projectId: String?
    /// 1 = 直接子目录是 skill；2 = 子目录/<skills>/ 的孙目录是 skill（D6 保留兼容入口）
    public var depth: Int = 1

    public init(url: URL, kind: Kind, agentId: String? = nil, agentOrigin: AgentOrigin = .containerName,
                level: Level, projectId: String? = nil, depth: Int = 1) {
        self.url = url
        self.kind = kind
        self.agentId = agentId
        self.agentOrigin = agentOrigin
        self.level = level
        self.projectId = projectId
        self.depth = depth
    }

    /// 既不在已知 Agent 树内也找不到 .git —— 中性事实态
    public var isUnclassified: Bool { level == .project && projectId == nil }
}

public struct ScanScope: Sendable {
    public var locations: [ScanLocation]
    public var projects: [Project]

    public init(locations: [ScanLocation], projects: [Project] = []) {
        self.locations = locations
        self.projects = projects
    }
}

public enum AgentRegistry {
    /// 官方已知四家（C1/C4 裁决）；发现出的工具目录不在此表内，走动态归属
    public static let knownAgents: [Agent] = [
        Agent(id: "codex", name: "Codex", homeDir: "~/.codex/skills"),
        Agent(id: "claude", name: "Claude Code", homeDir: "~/.claude/skills"),
        Agent(id: "qoder", name: "QoderWork", homeDir: "~/.qwenworkcn/skills"),
        Agent(id: "cursor", name: "Cursor", homeDir: "~/.cursor/skills"),
    ]

    /// 兼容旧调用名（C4：未安装的 Cursor 也留在表里，清单自然为 0）
    public static var agents: [Agent] { knownAgents }

    public static func agentName(_ id: String) -> String {
        if let hit = knownAgents.first(where: { $0.id == id })?.name { return hit }
        // 动态归属：目录名本身就是展示名（thincoder / trae-cn / devin…），不加观点
        return id
    }

    /// 发现出的 Agent 与官方表合并成清单页的归属列表（按名字排序，官方不置顶——零观点）
    public static func merged(withDiscovered discovered: [Agent]) -> [Agent] {
        var byId: [String: Agent] = [:]
        for a in knownAgents { byId[a.id] = a }
        for a in discovered where byId[a.id] == nil { byId[a.id] = a }
        return byId.values.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}

public enum ScopeBuilder {
    /// 用户级共享源（C2：官方 Codex USER scope，也是 Claude symlink 的挂载源）
    public static let sharedSources: [String] = [".agents/skills"]

    /// 把发现到的位置分类为可扫描范围。
    /// 存在性在这里就把关：缓存的位置可能已被删（Agent 自己清目录），
    /// 不存在的位置一律不进范围——设置页因此不会再出现「该路径不存在」的空行。
    ///
    /// **库位置单点注入**（skill-library 批）：在此无条件追加 `~/.skill-library`——
    /// 这是 App 与 CLI 共用的「发现结果 → 扫描范围」唯一闸口，一处注入两边同时生效
    /// （App 三段扫描与 CLI buildIndex）。目录不存在也收录：InventoryScanner 对不存在位置的
    /// 既有语义是「不算降级、零条目」。选 ScopeBuilder 而非 ScopeDiscoverer 的理由：
    /// 发现遍历只认名为 `skills` 的目录（ScopeDiscovery.swift:315），库根永远不会被它发现。
    public static func scope(discovered: [DiscoveredLocation], home: URL, ignored: Set<String> = []) -> ScanScope {
        var locations: [ScanLocation] = []
        var projectsById: [String: Project] = [:]
        var takenPaths: [String: String] = [:]
        let fm = FileManager.default
        var all = discovered
        // 库注入排在 ignored 过滤**之前**：用户手动忽略库位置仍是有效的（按路径精确忽略），
        // 但默认不进 ignored——库是权威源，不该被误关
        let library = SkillLibrary(home: home)
        let libPath = library.root.standardizedFileURL.path
        if !all.contains(where: { $0.url.standardizedFileURL.path == libPath }) {
            all.append(DiscoveredLocation(path: libPath, kind: .skillDirectory))
        }

        for loc in all {
            let path = loc.url.standardizedFileURL.path
            guard !ignored.contains(path) else { continue }
            let c = LocationClassifier.classify(loc, home: home)
            // 库位置跳过存在性守卫（设计决策①显式否决「只注入已存在目录」——那会让首库出现前
            // App 没有监听根，add 后不可见）。InventoryScanner 对不存在位置的既有语义是
            // 「不算降级、零条目」，进范围是安全的；非库位置维持原守卫（设置页不再出现
            // 「该路径不存在」的空行）。
            if c.agentOrigin != .skillLibrary {
                guard fm.fileExists(atPath: path) else { continue }
            }
            // classify 的 agentId 是非可选 String，库特判用空串表达「库不是 Agent」；
            // ScanLocation.agentId 是 Optional（nil 才不计挂载），空串在这里折成 nil——
            // 否则 MountStat 按 != nil 计数会把库落点全算成挂载，零挂载信号（D21）失真。
            let agentId: String? = c.agentId.isEmpty ? nil : c.agentId
            if let root = c.projectRootPath {
                let rootURL = URL(fileURLWithPath: root)
                var id = LocationClassifier.projectID(for: rootURL)
                if let existing = takenPaths[id], existing != root {
                    id = LocationClassifier.uniqueProjectID(for: rootURL, takenPaths: takenPaths)
                }
                if projectsById[id] == nil {
                    projectsById[id] = Project(id: id, name: rootURL.lastPathComponent, path: root)
                }
                takenPaths[id] = root
                locations.append(ScanLocation(url: loc.url, kind: loc.kind, agentId: agentId,
                                              agentOrigin: c.agentOrigin, level: .project, projectId: id))
            } else {
                locations.append(ScanLocation(url: loc.url, kind: loc.kind, agentId: agentId,
                                              agentOrigin: c.agentOrigin, level: c.level))
            }
        }
        // C2 裁决沿用：~/.agents/skills 归 Codex（官方 USER scope），它同时是 Claude symlink 的共享源，
        // 各 Agent 的挂载仍由自己的 symlink 落点记账；设置页对这类路径打「共享源」徽章。
        let projects = projectsById.values.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        return ScanScope(locations: locations, projects: projects)
    }

    /// 发现 → 范围的完整链路（App 与 CLI 共用；CLI 传缓存位置，绝不做全盘遍历）
    public static func scope(home: URL, rules: DiscoveryRules = .standard,
                             ignored: Set<String> = [], maxDepth: Int? = nil,
                             roots: [URL]? = nil,
                             onBatch: ((ScanScope) -> Void)? = nil) -> (ScanScope, DiscoveryOutcome) {
        let discoverRoots = roots ?? rules.fullDiskRoots.map { URL(fileURLWithPath: $0) }
        let discoverer = ScopeDiscoverer(rules: rules)
        var merged: [DiscoveredLocation] = []
        let outcome = discoverer.discover(roots: discoverRoots, home: home, maxDepth: maxDepth, batchSize: 40,
                                          onBatch: { batch in
            merged += batch
            onBatch?(scope(discovered: merged, home: home, ignored: ignored))
        })
        return (scope(discovered: merged, home: home, ignored: ignored), outcome)
    }
}

