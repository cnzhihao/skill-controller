// ScopeDiscovery.swift — 发现驱动的扫描范围
//
// 为什么替换掉硬编码注册表（ScopeBuilder.defaultScope 旧版）：
//  注册表只认 4 家 Agent 的 6 个固定路径，而本机实测全盘有 897 处 skills 目录、
//  归属涉及 devin / goose / junie / openhands / trae / windsurf / grok / hermes /
//  zcode / box-agent / workbuddy 等注册表完全看不到的工具。注册表还带来副作用：
//  不存在的路径照样进设置页，形成大量「该路径不存在」无意义行（智昊 2026-09-20 裁决整改）。
//
// 本机实测（2026-09-20，同一剪枝规则）：
//   全盘遍历到的目录 98,173 个 · 耗时 44s · 命中 skills 目录 897 处 · 权限拒绝 230 处
//   home 一层快扫 1s · 897 处全量枚举 2.24s · SKILL.md 解析 2.95s
//  → 遍历发现是唯一慢环节，读取内容便宜。故：首屏走快扫，全盘发现放后台，发现结果缓存。
//
// 剪枝清单（智昊裁决：只留真实挂载位，不扫缓存/内置/应用包内）见 DiscoveryRules.standard。

import Foundation

// MARK: - 剪枝类别（用户可逐类勾选）

/// 每一类都是"同一性质的噪音"打包，用户按类决定是否扫描——不逼他逐个理解目录名
public enum PruneCategory: String, CaseIterable, Codable, Sendable, Hashable {
    case dependency      // 依赖包与构建产物
    case vcs             // 版本控制元数据
    case systemDirs      // 系统与索引目录（含 APFS firmlink 镜像）
    case cache           // 各类缓存
    case copy            // 工具自己的回收站/备份副本
    case appBundle       // 应用包与框架内部
    case builtin         // 工具内置副本
    case mediaLibraries  // 媒体库（音乐/照片/视频）
    case personalFolders // 桌面与下载（可能解压了 skill 包，默认不剪）
    case temp            // 工具临时检出/解压目录（~/.codex/.tmp/plugins/… 这类）

    /// 展示名（设置页）
    public var label: String {
        switch self {
        case .dependency: return "依赖包与构建产物"
        case .vcs: return "版本控制元数据"
        case .systemDirs: return "系统与索引目录"
        case .cache: return "缓存"
        case .copy: return "回收站与备份副本"
        case .appBundle: return "应用包内部"
        case .builtin: return "工具内置副本"
        case .mediaLibraries: return "媒体库（音乐 / 照片 / 视频）"
        case .personalFolders: return "桌面与下载"
        case .temp: return "临时检出目录"
        }
    }

    /// 这一类包含什么、剪它的理由，一句话讲清（含本机实测）
    public var note: String {
        switch self {
        case .dependency: return "node_modules 里有成千上万个叫 skills 的包"
        case .vcs: return ".git 内部结构，不是挂载位"
        case .systemDirs: return "Library 与系统索引树；含 /.nofollow 等 firmlink 镜像（不剪会把命中数扫成两倍）"
        case .cache: return ".cache / Caches / *-cache（如 grok 的 marketplace-cache）"
        case .copy: return "工具搬进 trash/backup 的历史副本：本机实测 902 处里 154 处是这种"
        case .appBundle: return "*.app / *.framework 包内资源，随应用升级重置"
        case .builtin: return "builtin 目录：工具自带的出厂 skill 副本"
        case .mediaLibraries: return "~/Music ~/Pictures ~/Movies：本机实测命中 0，剪掉省遍历"
        case .personalFolders: return "~/Desktop ~/Downloads：可能解压了 skill 包，默认仍扫描"
        case .temp: return "工具解压/临时检出（如 ~/.codex/.tmp/plugins/…）：本机实测 174 处，随工具重启重置，不是挂载位"
        }
    }

    /// 默认是否剪掉（智昊裁决：逐类可选；媒体库纯浪费遍历，个人目录留着）
    public var defaultPruned: Bool { self != .personalFolders }

    public var exactNames: [String] {
        switch self {
        case .dependency: return ["node_modules"]
        case .vcs: return [".git", ".svn", ".hg", ".bzr"]
        case .systemDirs: return ["Library", "DerivedData", ".vol", ".fseventsd",
                                  ".Spotlight-V100", ".DocumentRevisions-V100",
                                  // darwin 系统临时区（2026-10-03 台账 #10/#28）：POSIX TMPDIR 指向的
                                  // /var/folders/**/T/（/var→private/var 的 symlink，但 emitted 路径
                                  // standardized 后统一是 /var 形态——名字匹配对双形态天然一致，无需
                                  // canonical 化）。swift test 的 mkdtemp 夹具整棵住在 T 子树里，
                                  // 2026-10-03 查证：在册 65 条全是夹具。补前缀方案（/var/folders 进
                                  // pathPrefixes）被否：全仓测试 fixture 都建在 T 直下，子项判据会把
                                  // 它们整个剪掉。误伤面 2026-10-03 实测为 0（缓存 1,129 条在册位置
                                  // 含 T 组件的 102 处全在 /var/folders 下；真有用户目录名叫 T 的情形，
                                  // 设置页关掉 systemDirs 类即可豁免）
                                  "T"]
        case .cache: return [".cache", "Caches"]
        case .copy: return [".Trash", "Trash", "trash", ".trash", "backup", "backups", ".backup"]
        case .appBundle: return []
        case .builtin: return ["builtin"]
        case .temp: return [".tmp", ".temp"]
        case .mediaLibraries, .personalFolders: return []
        }
    }

    public var nameSuffixes: [String] {
        switch self {
        case .appBundle: return [".app", ".framework", ".bundle", ".lproj", ".xcassets",
                                 ".appintents", ".kext", ".dSYM"]
        case .cache: return ["-cache"]
        default: return []
        }
    }

    /// 绝对路径前缀（系统类）
    public var pathPrefixes: [String] {
        switch self {
        case .systemDirs: return ["/System/Volumes", "/.nofollow", "/dev", "/net", "/home", "/Volumes"]
        default: return []
        }
    }

    /// home 相对前缀（媒体库 / 个人目录）
    public var homeRelativePrefixes: [String] {
        switch self {
        case .mediaLibraries: return ["Music", "Pictures", "Movies", "Photos"]
        case .personalFolders: return ["Desktop", "Downloads"]
        default: return []
        }
    }
}

// MARK: - 发现与剪枝规则

/// 可序列化：设置页要能逐类开关，同时随缓存一起存（规则变了缓存即失效重扫）
public struct DiscoveryRules: Codable, Hashable, Sendable {
    /// 被剪掉的类别；不在集合内的类别一律照常扫描
    public var prunedCategories: Set<PruneCategory>
    /// 视为 skill 挂载目录的目录名
    public var skillsDirNames: [String]
    /// 视为 MCP 配置的文件名
    public var mcpFileNames: [String]
    /// 全盘发现的根
    public var fullDiskRoots: [String]
    /// 遍历深度上限（防病态深树；符号链接不跟随，故无环）
    public var maxDepth: Int

    public init(prunedCategories: Set<PruneCategory>, skillsDirNames: [String] = ["skills"],
                mcpFileNames: [String] = ["mcp.json", ".mcp.json", ".claude.json", "config.toml"],
                fullDiskRoots: [String] = ["/"], maxDepth: Int = 24) {
        self.prunedCategories = prunedCategories
        self.skillsDirNames = skillsDirNames
        self.mcpFileNames = mcpFileNames
        self.fullDiskRoots = fullDiskRoots
        self.maxDepth = maxDepth
    }

    /// 默认规则：除「桌面与下载」外全部剪（本机实测遍历 81K 目录 / 44s / 1,095 处位置）
    public static let standard = DiscoveryRules(
        prunedCategories: Set(PruneCategory.allCases.filter { $0.defaultPruned }))

    /// 通用容器目录：归属推断时可"看穿"到其下一层（~/.config/devin/skills → devin 而非 config）
    public static let genericContainers: Set<String> = [".config", ".local", ".var", ".share", ".support"]

    /// 这一类当前是否被剪掉（设置页开关的读取端）
    public func isCategoryPruned(_ c: PruneCategory) -> Bool { prunedCategories.contains(c) }

    /// 命中即剪的目录名类别（用于统计"这一类跳过了多少个目录"）
    public func category(forName name: String) -> PruneCategory? {
        for c in prunedCategories {
            if c.exactNames.contains(name) { return c }
            for suffix in c.nameSuffixes where name.hasSuffix(suffix) { return c }
        }
        return nil
    }

    /// 命中即剪的路径类别（系统前缀 / home 相对前缀）
    public func category(forPath path: String, home: String) -> PruneCategory? {
        for c in prunedCategories {
            for prefix in c.pathPrefixes where path == prefix || path.hasPrefix(prefix + "/") { return c }
            for rel in c.homeRelativePrefixes {
                let full = home + "/" + rel
                if path == full || path.hasPrefix(full + "/") { return c }
            }
        }
        return nil
    }

    public func isPrunedName(_ name: String) -> Bool { category(forName: name) != nil }

    public func isPrunedPath(_ path: String, home: String) -> Bool { category(forPath: path, home: home) != nil }

    /// MCP 文件收录闸门：config.toml / .claude.json 太过通用（任何工具都可能有个 config.toml），
    /// 只在 home 本身及其直属子目录内认；mcp.json / .mcp.json 够特异，全盘认。
    public func acceptsMCPFile(name: String, containerPath: String, home: String) -> Bool {
        switch name {
        case "mcp.json", ".mcp.json":
            return true
        case "config.toml", ".claude.json":
            let container = URL(fileURLWithPath: containerPath).standardizedFileURL.path
            if container == home { return true }
            return URL(fileURLWithPath: container).deletingLastPathComponent().path == home
        default:
            return false
        }
    }

    /// 遍历前一次性建好的剪枝索引。
    /// 必须用它做热路径判断：exactNames / nameSuffixes / pathPrefixes 都是计算属性，
    /// 每个目录条目都调 category(forName:)+category(forPath:) 会在 debug 构建下把全盘发现
    /// 从 44s 拖到 357s（真机实测，CLI 同一段代码复现）。
    public func pruneIndex(home: String) -> PruneIndex { PruneIndex(self, home: home) }
}

/// 剪枝查找索引：名字走字典，后缀与前缀各只有个位数条目，线性扫即可
public struct PruneIndex: Sendable {
    private var names: [String: PruneCategory] = [:]
    private var suffixes: [(String, PruneCategory)] = []
    private var prefixes: [(String, PruneCategory)] = []

    init(_ rules: DiscoveryRules, home: String) {
        for c in rules.prunedCategories {
            for n in c.exactNames { names[n] = c }
            for s in c.nameSuffixes { suffixes.append((s, c)) }
            for p in c.pathPrefixes { prefixes.append((p, c)) }
            for rel in c.homeRelativePrefixes { prefixes.append((home + "/" + rel, c)) }
        }
    }

    /// 目录名或路径任一命中即返回其类别
    public func category(name: String, path: String) -> PruneCategory? {
        if let c = names[name] { return c }
        for (suffix, c) in suffixes where name.hasSuffix(suffix) { return c }
        for (prefix, c) in prefixes where path == prefix || path.hasPrefix(prefix + "/") { return c }
        return nil
    }

    public func isPruned(name: String, path: String) -> Bool { category(name: name, path: path) != nil }
}

// MARK: - 发现结果

public struct DiscoveredLocation: Codable, Hashable, Sendable, Identifiable {
    public var path: String
    public var kind: ScanLocation.Kind
    public var id: String { kind.rawValue + ":" + path }

    public init(path: String, kind: ScanLocation.Kind) {
        self.path = path
        self.kind = kind
    }

    public var url: URL { URL(fileURLWithPath: path) }
    /// skills 目录的父目录（MCP 文件则为所在目录）
    public var containerDir: URL { url.deletingLastPathComponent() }
}

public struct DiscoveryOutcome: Sendable {
    public var locations: [DiscoveredLocation]
    /// 读不了的目录数（权限/消失）——中性计数，进降级说明，不判风险
    public var unreadableCount: Int
    public var dirsVisited: Int
    /// 每类剪枝跳过了多少个目录（设置页据此告诉他"关掉这一类会多走多少路"）
    public var prunedDirsByCategory: [PruneCategory: Int]
    /// 是否因取消/上限提前停止
    public var stoppedEarly: Bool

    public init(locations: [DiscoveredLocation], unreadableCount: Int, dirsVisited: Int,
                prunedDirsByCategory: [PruneCategory: Int] = [:], stoppedEarly: Bool = false) {
        self.locations = locations
        self.unreadableCount = unreadableCount
        self.dirsVisited = dirsVisited
        self.prunedDirsByCategory = prunedDirsByCategory
        self.stoppedEarly = stoppedEarly
    }
}

// MARK: - 遍历发现器

public final class ScopeDiscoverer: @unchecked Sendable {
    public let rules: DiscoveryRules
    private let fm = FileManager.default

    public init(rules: DiscoveryRules = .standard) { self.rules = rules }

    /// 批量流式发现：攒满 `batchSize` 条回调一次，让 App 能边发现边出清单。
    /// `shouldStop` 每访问一个目录检查一次，取消立即生效。
    /// `home` 显式传入（MCP 通用文件名的收录闸门要判"是否在 home 两层内"，不读全局状态才可测）。
    /// `maxDepth` 按命中项自身相对根的层数计：根=0，~/.codex/skills=2。
    public func discover(roots: [URL],
                         home: URL? = nil,
                         maxDepth: Int? = nil,
                         batchSize: Int = 40,
                         onBatch: (([DiscoveredLocation]) -> Void)? = nil,
                         shouldStop: @escaping @Sendable () -> Bool = { false }) -> DiscoveryOutcome {
        let depthLimit = maxDepth ?? rules.maxDepth
        let homePath = (home ?? fm.homeDirectoryForCurrentUser).standardizedFileURL.path
        let prune = rules.pruneIndex(home: homePath)   // 热路径判断走索引，不走计算属性
        var all: [DiscoveredLocation] = []
        var batch: [DiscoveredLocation] = []
        var unreadable = 0
        var visited = 0
        var stopped = false
        var prunedByCategory: [PruneCategory: Int] = [:]

        // 显式栈 DFS（不递归，避免深树爆栈）；符号链接一律不进入，故不会成环
        var stack: [(url: URL, depth: Int)] = roots.map { ($0.standardizedFileURL, 0) }
        // 同一目录只走一遍：macOS 上 /Users 与 /.nofollow/Users、/System/Volumes/Data/Users 是
        // firmlink 镜像，纯按路径去重会把整棵 home 树扫成两遍（实测命中数直接翻倍）
        var seenDirs = Set<String>()

        while !stack.isEmpty {
            if shouldStop() { stopped = true; break }
            let (dir, depth) = stack.removeLast()
            visited += 1

            let children: [URL]
            do {
                children = try fm.contentsOfDirectory(
                    at: dir,
                    includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey, .fileResourceIdentifierKey],
                    options: [])
            } catch {
                unreadable += 1
                continue
            }

            for child in children {
                let name = child.lastPathComponent
                let childDepth = depth + 1
                guard childDepth <= depthLimit else { continue }
                let values = try? child.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey,
                                                                 .fileResourceIdentifierKey])
                let isSymlink = values?.isSymbolicLink ?? false
                let isDir = (values?.isDirectory ?? false) && !isSymlink

                // 1) skills 挂载目录：命中即收录，不再深入（其子项是 skill 本身，交给扫描器枚举）
                if isDir, rules.skillsDirNames.contains(name) {
                    emit(DiscoveredLocation(path: child.standardizedFileURL.path, kind: .skillDirectory),
                         &all, &batch, batchSize, onBatch)
                    continue
                }
                // 2) MCP 配置文件：按文件名 + 位置闸门收录
                if !isDir, rules.mcpFileNames.contains(name),
                   rules.acceptsMCPFile(name: name, containerPath: dir.path, home: homePath) {
                    emit(DiscoveredLocation(path: child.standardizedFileURL.path, kind: mcpKind(of: child)),
                         &all, &batch, batchSize, onBatch)
                    continue
                }
                // 3) 继续下行（仅真目录；符号链接不跟随）
                guard isDir else { continue }
                let childPath = child.standardizedFileURL.path
                if let c = prune.category(name: name, path: childPath) {
                    prunedByCategory[c, default: 0] += 1
                    continue
                }
                guard seenDirs.insert(Self.dirIdentity(values)).inserted else { continue }
                stack.append((child, childDepth))
            }
        }
        if !batch.isEmpty, let onBatch { onBatch(batch); batch = [] }
        return DiscoveryOutcome(locations: all, unreadableCount: unreadable, dirsVisited: visited,
                                prunedDirsByCategory: prunedByCategory, stoppedEarly: stopped)
    }

    /// 目录身份（卷号+inode 的组合封装）；拿不到身份时退回唯一值
    /// （不影响正确性，只影响镜像目录能否被去重）
    private static func dirIdentity(_ values: URLResourceValues?) -> String {
        if let id = values?.fileResourceIdentifier { return "id:\(id)" }
        return "path:\(UUID().uuidString)"
    }

    /// config.toml 走 TOML 解析，其余 MCP 文件走 JSON 解析
    private func mcpKind(of url: URL) -> ScanLocation.Kind {
        url.pathExtension == "toml" ? .mcpTOML : .mcpJSON
    }

    private func emit(_ loc: DiscoveredLocation, _ all: inout [DiscoveredLocation], _ batch: inout [DiscoveredLocation],
                      _ batchSize: Int, _ onBatch: (([DiscoveredLocation]) -> Void)?) {
        all.append(loc)
        batch.append(loc)
        if batch.count >= batchSize, let onBatch {
            onBatch(batch)
            batch = []
        }
    }
}

// MARK: - 位置分类（层级 × 归属 × 项目）

/// 归属是怎么来的——决定它能不能被 Agent 引用
/// （智昊裁决：项目名冒充的归属要单独标注，不能和真 Agent 混在一个计数里）
public enum AgentOrigin: String, Codable, Hashable, Sendable {
    /// 官方四家的配置目录（~/.codex、~/.claude…）
    case officialAgentDir
    /// 其他工具自己的点目录（~/.thincoder、~/.workbuddy、~/.config/devin…）
    case toolDir
    /// 只能用所在目录名兜底——多半是项目名，不是 Agent
    case containerName
    /// Skill 元位置（中央库 ~/.skill-library）——库不是 Agent，也不是项目
    case skillLibrary

    /// 是否算一个真正的 Agent
    public var isRealAgent: Bool { self != .containerName && self != .skillLibrary }

    public var label: String {
        switch self {
        case .officialAgentDir, .toolDir: return ""
        case .containerName: return "目录名归属"
        case .skillLibrary: return "技能库"
        }
    }
}

public struct LocationClassification: Hashable, Sendable {
    public var agentId: String
    /// 归属推断的依据（真 Agent 目录 / 工具点目录 / 所在目录名兜底）
    public var agentOrigin: AgentOrigin
    /// 归属锚点目录（设置页展示"归属来自哪个目录"）
    public var agentDirPath: String
    public var level: Level
    public var projectId: String?
    public var projectRootPath: String?

    public init(agentId: String, agentOrigin: AgentOrigin = .containerName, agentDirPath: String,
                level: Level, projectId: String? = nil, projectRootPath: String? = nil) {
        self.agentId = agentId
        self.agentOrigin = agentOrigin
        self.agentDirPath = agentDirPath
        self.level = level
        self.projectId = projectId
        self.projectRootPath = projectRootPath
    }
}

public enum LocationClassifier {
    /// C1/C2 已裁决的官方映射：目录名 → Agent id（展示名由 AgentRegistry 负责）
    public static let knownAgentDirs: [String: String] = [
        ".agents": "codex",      // C2：官方 Codex USER scope
        ".codex": "codex",
        ".claude": "claude",
        ".qwenworkcn": "qoder",  // C1：产品更名后的本机实际目录
        ".cursor": "cursor",
    ]

    /// home 下的裸配置文件 → Agent（~/.claude.json 的父目录是 home 本身，取不到目录名）
    public static let knownAgentFiles: [String: String] = [
        ".claude.json": "claude",
    ]

    // MARK: 层级 + 项目

    /// 规则（智昊 2026-09-20 裁决）：home 直属 = 用户级，其余向上找 .git。
    /// 落地顺序（每一层都实测过本机路径）：
    ///  1. 文件直接躺在 home（~/.claude.json）→ 用户级
    ///  2. home 直属子目录是官方 Agent 配置目录（~/.codex、~/.agents…）→ 用户级，不再找 .git
    ///  3. 从所在目录向上找 .git（含 home 直属子目录本身，不含 home）→ 项目级，项目根 = 命中的仓库
    ///  4. 所在目录就是 home 直属子目录且非 Agent 配置目录（~/tools/skills）→ 用户级
    ///  5. 位于 home 直属的点目录树内（~/.grok/bundled/skills、~/.qwenworkcn/plugins/*/skills）→ 用户级
    ///  6. 以上都不成立（~/Downloads/some-kit/skills、/opt/foo/skills）→ 其他位置
    public static func classify(_ loc: DiscoveredLocation, home: URL) -> LocationClassification {
        let container = loc.containerDir.standardizedFileURL
        let homeStd = home.standardizedFileURL
        let rel = relativeComponents(of: container, to: homeStd)

        // 库特判（先于既有推导）：库根本身与其下任何位置一律是「技能库」层级——
        // 库不是 Agent（agentId=nil → 不计挂载、不进 Agent 收集，零挂载信号保真），
        // 也不是项目（库根的 container 是 home，走既有推导会判成用户级，必须挡在前面）。
        // 按位置自身路径判定而非 containerDir：注入位置是库根本身，它的 containerDir 是 home。
        let locPath = loc.url.standardizedFileURL.path
        let libRoot = SkillLibrary.defaultRoot(home: homeStd).standardizedFileURL.path
        if locPath == libRoot || locPath.hasPrefix(libRoot + "/") {
            return LocationClassification(agentId: "", agentOrigin: .skillLibrary, agentDirPath: libRoot,
                                          level: .library)
        }

        let (agentId, origin) = deriveAgent(loc: loc, container: container, rel: rel)
        let agentDir = container.path
        func result(_ level: Level, projectId: String? = nil, root: String? = nil) -> LocationClassification {
            LocationClassification(agentId: agentId, agentOrigin: origin, agentDirPath: agentDir,
                                   level: level, projectId: projectId, projectRootPath: root)
        }

        // 1
        if container.path == homeStd.path { return result(.user) }
        guard let rel, !rel.isEmpty else {
            // home 之外：只认 .git，认不出就是一处事实存在但层级未知的位置
            if let root = gitRoot(from: container, stopBefore: nil) {
                return result(.project, projectId: projectID(for: root), root: root.path)
            }
            return result(.project)
        }

        // 2
        if knownAgentDirs[rel[0]] != nil { return result(.user) }
        // 3
        if let root = gitRoot(from: container, stopBefore: homeStd) {
            return result(.project, projectId: projectID(for: root), root: root.path)
        }
        // 4
        if rel.count == 1 { return result(.user) }
        // 5
        if rel[0].hasPrefix(".") { return result(.user) }
        // 6
        return result(.project)
    }

    // MARK: 归属

    /// 未知归属直接用父目录名（智昊裁决：`.thincoder/skills` → thincoder）。
    /// 自 home 直属层向下取**最深**的匹配：官方映射 > 点目录（通用容器可看穿一层） > 所在目录名。
    static func deriveAgent(loc: DiscoveredLocation, container: URL, rel: [String]?) -> (String, AgentOrigin) {
        // home 内按相对段走；home 外按整条路径的段走（都自最深段向上）
        let names: [String]
        if let rel {
            guard !rel.isEmpty else {
                // 所在目录就是 home 本身（如 ~/.claude.json）：只能从文件名推
                if let byFile = knownAgentFiles[loc.url.lastPathComponent] { return (byFile, .officialAgentDir) }
                return ("local", .containerName)
            }
            names = rel
        } else {
            names = container.pathComponents.filter { $0 != "/" }
        }
        if let mapped = names.reversed().lazy.compactMap({ knownAgentDirs[$0] }).first {
            return (mapped, .officialAgentDir)
        }

        var deeper: String?
        for name in names.reversed() {
            guard name.hasPrefix(".") else { deeper = name; continue }
            if DiscoveryRules.genericContainers.contains(name), let d = deeper, !d.hasPrefix(".") {
                return (cleanDirName(d), .toolDir)   // ~/.config/devin/skills → devin 是工具
            }
            return (cleanDirName(name), .toolDir)
        }
        if let byFile = knownAgentFiles[loc.url.lastPathComponent] { return (byFile, .officialAgentDir) }
        // 只剩所在目录名可用——多半是项目名，不是 Agent
        return (cleanDirName(container.lastPathComponent), .containerName)
    }

    static func cleanDirName(_ raw: String) -> String {
        let stripped = raw.drop { $0 == "." }
        return stripped.isEmpty ? raw : String(stripped)
    }

    // MARK: 工具

    /// container 相对 home 的组件数组；不在 home 下返回 nil（container == home 返回 []）
    public static func relativeComponents(of container: URL, to home: URL) -> [String]? {
        let hp = home.path, cp = container.path
        if cp == hp { return [] }
        guard cp.hasPrefix(hp + "/") else { return nil }
        let start = cp.index(cp.startIndex, offsetBy: hp.count + 1)
        return cp[start...].split(separator: "/").map(String.init)
    }

    /// 向上找 .git：从 dir 自身开始逐级向上；stopBefore 非空时到该目录为止（不含）
    static func gitRoot(from dir: URL, stopBefore: URL?) -> URL? {
        let fm = FileManager.default
        var candidate = dir.standardizedFileURL
        let stop = stopBefore?.standardizedFileURL.path
        while true {
            let path = candidate.path
            if let stop, path == stop { return nil }
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: candidate.appendingPathComponent(".git").path, isDirectory: &isDir) {
                return candidate
            }
            let parent = candidate.deletingLastPathComponent()
            if parent.path == path || path == "/" { return nil }
            candidate = parent
        }
    }

    /// 项目 id 沿用既有 "proj-<目录名>" 方案；同名不同路径时追加确定性后缀（不用 hashValue，跨进程不稳）
    static func projectID(for root: URL) -> String {
        "proj-" + root.lastPathComponent
    }

    static func uniqueProjectID(for root: URL, takenPaths: [String: String]) -> String {
        if let existing = takenPaths["proj-" + root.lastPathComponent], existing != root.path {
            return "proj-" + root.lastPathComponent + "-" + String(fnv64(root.path), radix: 16)
        }
        return "proj-" + root.lastPathComponent
    }

    public static func fnv64(_ s: String) -> UInt64 {
        var h: UInt64 = 0xcbf29ce484222325
        for b in s.utf8 { h ^= UInt64(b); h = h &* 0x100000001b3 }
        return h
    }
}

// MARK: - 发现结果缓存（让二次启动不必等 44s）

public struct DiscoverySnapshot: Codable, Sendable {
    public var savedAt: Date
    public var rules: DiscoveryRules
    public var roots: [String]
    public var locations: [DiscoveredLocation]
    public var dirsVisited: Int
    public var unreadableCount: Int
    /// 上次全盘发现里每类剪枝跳过的目录数（键为 PruneCategory.rawValue）。
    /// 必须存：否则重启后设置页在新一轮发现跑完前会显示「跳过 0 个目录」，那是假话。
    /// 可选：旧版本缓存没这个字段，声明成非可选会让整个缓存解码失败、白白重扫一遍全盘。
    public var prunedDirsByCategory: [String: Int]?
    /// 写出这份缓存的 App 版本。可选（旧缓存没这字段，声明成非可选会让整个缓存解码失败、白白重扫全盘）。
    /// CLI 读缓存时拿它跟自己比：不一致就说明 PATH 上的 skillctl 是旧的，必须如实说，不能静默降级。
    public var builderVersion: String?

    public init(savedAt: Date, rules: DiscoveryRules, roots: [String], locations: [DiscoveredLocation],
                dirsVisited: Int = 0, unreadableCount: Int = 0, prunedDirsByCategory: [String: Int]? = nil,
                builderVersion: String? = nil) {
        self.savedAt = savedAt
        self.rules = rules
        self.roots = roots
        self.locations = locations
        self.dirsVisited = dirsVisited
        self.unreadableCount = unreadableCount
        self.prunedDirsByCategory = prunedDirsByCategory
        self.builderVersion = builderVersion
    }

    public var typedPrunedCounts: [PruneCategory: Int] {
        var out: [PruneCategory: Int] = [:]
        for (raw, n) in (prunedDirsByCategory ?? [:]) { if let c = PruneCategory(rawValue: raw) { out[c] = n } }
        return out
    }
}

public final class DiscoveryCache: @unchecked Sendable {
    private let fm = FileManager.default
    private let file: URL

    public init(paths: SkillControllerPaths = SkillControllerPaths()) {
        self.file = paths.discoveryCacheFile
    }

    public func load() -> DiscoverySnapshot? {
        guard let data = try? Data(contentsOf: file),
              let snap = try? JSONDecoder().decode(DiscoverySnapshot.self, from: data) else { return nil }
        return snap
    }

    /// 写失败不抛：缓存只是加速手段，丢了下次重新发现即可（磁盘满等如实留痕由调用方日志承担）
    public func save(_ snapshot: DiscoverySnapshot) {
        do {
            try fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            try encoder.encode(snapshot).write(to: file, options: .atomic)
        } catch {
            // 缓存写不进去不影响正确性
        }
    }

    public func clear() {
        try? fm.removeItem(at: file)
    }
}
