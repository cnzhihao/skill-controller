// AssemblyService.swift — CLI 写侧（story-2/3 的执行体）
// 三步齐硬规则：每次写 = 写锁 + 写前备份/回收站 + 结构化日志（PRD §3.8）
// 落位策略（闸门裁决）：默认 symlink，--copy 可选；卸载 ≠ 删除（卸下本体所在落点会被拒）

import Foundation

// MARK: - Agent 落位目录映射（写侧；与 ScanScope 的读侧口径一致）

public struct MountTargets: Sendable {
    public struct Entry: Sendable {
        public var userLevel: String?          // 相对 home
        public var projectLevel: String?       // 相对项目根
    }

    /// C2：Codex 写回用官方 USER scope（~/.agents/skills），项目级用 .agents/skills
    public static let table: [String: Entry] = [
        "codex": Entry(userLevel: ".agents/skills", projectLevel: ".agents/skills"),
        "claude": Entry(userLevel: ".claude/skills", projectLevel: ".claude/skills"),
        "qoder": Entry(userLevel: ".qwenworkcn/skills", projectLevel: nil),
        "cursor": Entry(userLevel: ".cursor/skills", projectLevel: ".cursor/skills"),
    ]

    public static func resolve(agent: String, projectPath: String?, home: URL) -> URL? {
        guard let e = table[agent] else { return nil }
        if let p = projectPath {
            guard let rel = e.projectLevel else { return nil }
            return URL(fileURLWithPath: p).appendingPathComponent(rel)
        }
        guard let rel = e.userLevel else { return nil }
        return home.appendingPathComponent(rel)
    }

    /// 该 Agent 名下的**全部**候选挂载目录（D19）
    ///
    /// 写侧（mount/pull）仍然只用 primary——那是 C2 裁定的官方 USER scope，
    /// 不能因为"别处也能读"就拿它当写入目标。
    /// 但**卸下必须看全部候选**：读侧按 `LocationClassifier.knownAgentDirs` 认多目录
    /// （Codex 的 `.agents/skills` 与 `.codex/skills` 都算它挂着），
    /// 只看 primary 就会出现「清单说 Codex 挂载 1 次、`skillctl unmount --on codex`
    /// 说该位置没有挂载」——App 说挂着，Agent 自己说没挂。
    ///
    /// `indexDirs` 传索引里该条目实际归属到这家的那些落点父目录，用来兜住
    /// 动态发现的工具（thincoder / trae-cn… 表里没有）与表落后于盘的情况。
    public static func candidates(agent: String, projectPath: String?, home: URL,
                                  indexDirs: [URL] = []) -> [URL] {
        let scopeRoot = projectPath.map { URL(fileURLWithPath: $0).standardizedFileURL } ?? home
        var out: [URL] = []
        var seen = Set<String>()
        func add(_ url: URL?) {
            guard let url else { return }
            let key = url.standardizedFileURL.path
            if seen.insert(key).inserted { out.append(url.standardizedFileURL) }
        }
        add(resolve(agent: agent, projectPath: projectPath, home: home))   // primary 恒在第一位
        // 其余候选直接取读侧那张表，不再抄第二份清单（两份表不一致就是 D19 的成因）
        for (dir, mapped) in LocationClassifier.knownAgentDirs.sorted(by: { $0.key < $1.key })
        where mapped == agent {
            add(scopeRoot.appendingPathComponent(dir).appendingPathComponent("skills"))
        }
        for d in indexDirs.sorted(by: { $0.path < $1.path }) { add(d) }
        return out
    }
}

// MARK: - 结果类型

public struct SearchResult: Codable, Sendable {
    public var id: String, name: String, description: String, type: String
    public var level: String, sourcePath: String, mountedBy: [String], duplicates: [Int]
}

public struct WriteOutcome: Sendable {
    public enum Status: Sendable, Equatable { case created, skippedConflict, refused, failed(reason: String) }
    public var status: Status
    public var path: String
    public var reason: String?
    /// true = 这是一次"卸下"（unmount），进 diff 的"卸下"组；false = 挂上/装配
    public var isRemoval: Bool
    public init(status: Status, path: String, reason: String?, isRemoval: Bool = false) {
        self.status = status; self.path = path; self.reason = reason; self.isRemoval = isRemoval
    }
}

public struct AssemblyReport: Sendable {
    public var event: AssemblyEvent
    public var outcomes: [WriteOutcome]
    /// 写侧如实警告（#6c：发现缓存合并不了锁时不再静默；nil = 一切正常）。
    /// CLI 进 reportJSON 的 "warning" 字段；App 侧落 lastError（接口契约：设计档 §2）。
    public var warning: String?

    public init(event: AssemblyEvent, outcomes: [WriteOutcome], warning: String? = nil) {
        self.event = event
        self.outcomes = outcomes
        self.warning = warning
    }
}

/// 整体重写的计数（#6a；并发模型 §4：损坏行原样保留、计数上抛，绝不静默清除——
/// 调用方决定上不上屏，Core 不打印、不弹窗）。
public struct RewriteStats: Sendable, Equatable {
    public var linesRead: Int
    public var eventsRewritten: Int
    public var corruptPreserved: Int

    public init(linesRead: Int, eventsRewritten: Int, corruptPreserved: Int) {
        self.linesRead = linesRead
        self.eventsRewritten = eventsRewritten
        self.corruptPreserved = corruptPreserved
    }
}

// MARK: - 装配事件存储（App Banner 数据源）

public struct StoredAssemblyEvent: Codable, Sendable {
    public var event: AssemblyEvent
    /// 写入时的清单快照版本（G3：版本不一致 → 验收前必须重载）
    public var revision: Int
    /// revision 的**口径范围**：这次装配动过的目录（项目根 / 落点所在目录）。
    /// 可选——旧事件没这个字段，声明成非可选会让整份事件文件解码失败，
    /// 已有的待验收 Banner 会凭空消失。nil 表示旧的全盘口径，App 不再拿它锁验收。
    public var revisionScope: [String]?
    /// 用户已「关闭并验收」（裁定①：关闭=默认接受）
    public var accepted: Bool
    /// 用户已「全部恢复原状」
    public var restored: Bool
    /// 「全部恢复原状」时摘掉的软链：落点路径 → 当时记录的链接目标（原样存，含相对写法）。
    /// D32=B：有了它，"恢复"这一步才真能一步撤销——回看态那个「重新挂回」按这张表重建链接。
    /// 可选：旧事件没这个字段，声明成非可选会让整份事件文件解码失败、Banner 凭空消失。
    public var restoredLinks: [String: String]?
    /// 恢复时进了回收站的复制件：落点路径 → 回收站条目 id（复制件的撤销＝从回收站取回，不是重建链接）
    public var restoredCopies: [String: String]?
    /// 写失败的落点（路径 + 原因）。可选：旧事件没这个字段，缺省/nil = 旧事件（D15 同款兼容）。
    /// 不放 AssemblyEvent：那是 types.ts 1:1 模型（字段不许增删改）；
    /// App 侧持久化扩展字段的既有位置就是 Stored 层（D15 revisionScope / D32 restoredLinks 先例）。
    /// 空失败组也存 nil——省得旧事件与新事件形状无谓分叉。
    public var failed: [AssemblyConflict]?

    public init(event: AssemblyEvent, revision: Int, revisionScope: [String]? = nil,
                accepted: Bool = false, restored: Bool = false,
                restoredLinks: [String: String]? = nil, restoredCopies: [String: String]? = nil,
                failed: [AssemblyConflict]? = nil) {
        self.event = event
        self.revision = revision
        self.revisionScope = revisionScope
        self.accepted = accepted
        self.restored = restored
        self.restoredLinks = restoredLinks
        self.restoredCopies = restoredCopies
        self.failed = failed
    }

    /// 这次恢复留下了多少可重建的凭据（软链 + 复制件）。0 表示老事件，界面上不该给「重新挂回」。
    public var reapplyableCount: Int {
        (restoredLinks?.count ?? 0) + (restoredCopies?.count ?? 0)
    }
}

public final class AssemblyEventStore: @unchecked Sendable {
    private let paths: SkillControllerPaths
    private let lock: WriteLock

    public init(paths: SkillControllerPaths = SkillControllerPaths(), lock: WriteLock) {
        self.paths = paths
        self.lock = lock
    }

    private var file: URL { paths.assemblyEventsFile }

    public func append(_ stored: StoredAssemblyEvent) throws {
        try paths.ensureDirs()
        let data = try JSONEncoder().encode(stored)
        guard let text = String(data: data, encoding: .utf8) else { return }
        try lock.withLock {
            // 并发模型 §4 追加自愈：文件尾缺换行（并发方写了一半）时先补一个 \n——
            // 否则新记录拼在半行上、两条一起解码失败，all() 读不到 = 待验收 Banner 凭空消失
            let prefix = fileTailNeedsNewline(file) ? "\n" : ""
            if let h = try? FileHandle(forWritingTo: file) {
                defer { try? h.close() }
                h.seekToEndOfFile()
                h.write((prefix + text + "\n").data(using: .utf8)!)
            } else {
                try (prefix + text + "\n").data(using: .utf8)!.write(to: file)
            }
        }
    }

    public func all() -> [StoredAssemblyEvent] {
        guard let raw = try? Data(contentsOf: file), let s = String(data: raw, encoding: .utf8) else { return [] }
        return s.split(separator: "\n").compactMap {
            try? JSONDecoder().decode(StoredAssemblyEvent.self, from: $0.data(using: .utf8)!)
        }
    }

    /// 验收：关闭 diff 即默认接受（裁定①）——只改状态，不动磁盘
    public func markReviewed(eventId: String) throws {
        _ = try update(eventId: eventId) {
            $0.accepted = true
            $0.event.reviewed = true   // 与 1:1 模型的 reviewed 字段保持一致
        }
    }

    /// 恢复原状完成后置位（Banner 进"已恢复"态），并留下可重建凭据（D32=B）。
    /// 凭据按路径合并——部分恢复（有些落点没动成）时，已经摘掉的那些也得记住，
    /// 否则那半截链接就再也挂不回去了。
    public func markRestored(eventId: String, links: [String: String] = [:],
                             copies: [String: String] = [:], complete: Bool = true) throws {
        _ = try update(eventId: eventId) { s in
            if !links.isEmpty { s.restoredLinks = (s.restoredLinks ?? [:]).merging(links) { _, new in new } }
            if !copies.isEmpty { s.restoredCopies = (s.restoredCopies ?? [:]).merging(copies) { _, new in new } }
            if complete { s.restored = true }
        }
    }

    /// 撤销恢复成功后清掉"已恢复"标记与凭据（磁盘回到装配后的样子，事件仍是已验收态）
    public func markReapplied(eventId: String) throws {
        _ = try update(eventId: eventId) {
            $0.restored = false
            $0.restoredLinks = nil
            $0.restoredCopies = nil
        }
    }

    /// 重载基线（G3 的唯一出口）。
    ///
    /// 界面那句「清单已更新。重新加载后再验收」承诺的是"重载之后就能验收"，
    /// 而旧实现里重新加载只是拿同一个历史快照再比一次——影响面只要真的变过（Agent 还在干活，
    /// 这是常态而不是异常），就永远比不过，验收按钮永久灰着，人只能 Esc 走人、Banner 永远挂着。
    /// 2026-09-23 真机撞上：一条 pull 事件在影响面又变动过一次之后彻底验收不掉。
    ///
    /// 所以"重新加载"的语义必须是：**我已经看过当前清单，以现在为准刷新比对基线**。
    /// 只动 revision（基线），不动 added / removed / date——那才是"这次装配干了什么"的事实，
    /// 不能被后来的状态覆盖掉。
    public func rebaseRevision(eventId: String, to revision: Int) throws {
        _ = try update(eventId: eventId) { $0.revision = revision }
    }

    /// 通用状态更新：读—改—写**全程持锁**（并发模型 §2，#6a）。
    ///
    /// 旧实现（读在锁外 + 锁内整体重写）的洞：先 `all()` 再拿锁，读到的是旧快照，
    /// 锁内写回时把并发方刚 append 的行整体抹掉——「锁外读 + 整体重写」等于把别人的追加当没发生过。
    /// 重写走 `.atomic`（§3：进程被杀 / 磁盘满时旧文件完整保留，坏只坏在追加层面，可由 §4 兼住）。
    ///
    /// 损坏行（解码失败的行）**原样保留并计数**（§4，绝不静默清除）——它可能是并发方写了一半的行，
    /// 删掉它等于替别人销毁数据。损坏行存在时事件下标 ≠ 输出行下标，所以按行替换、
    /// 非目标行原文不动（逐字节保留），而不是把事件集合重新编码一遍。
    /// 找不到该事件时不写盘（既有语义），返回 eventsRewritten == 0 的计数让调用方知道。
    @discardableResult
    public func update(eventId: String, _ mutate: (inout StoredAssemblyEvent) -> Void) throws -> RewriteStats {
        try lock.withLock {
            let raw = try? Data(contentsOf: file)
            let text = raw.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            // components 保留空段：joined(separator: "\n") 回去后非目标部分逐字节不变
            var lines = text.components(separatedBy: "\n")
            var stats = RewriteStats(linesRead: 0, eventsRewritten: 0, corruptPreserved: 0)
            var hitIndex: Int?
            var hitEvent: StoredAssemblyEvent?
            for (i, line) in lines.enumerated() where !line.isEmpty {
                stats.linesRead += 1
                guard let e = try? JSONDecoder().decode(StoredAssemblyEvent.self, from: Data(line.utf8)) else {
                    stats.corruptPreserved += 1
                    continue
                }
                if e.event.id == eventId {
                    hitIndex = i
                    hitEvent = e
                }
            }
            guard let idx = hitIndex, var target = hitEvent else { return stats }
            mutate(&target)
            let encoded = try JSONEncoder().encode(target)
            guard let newLine = String(data: encoded, encoding: .utf8) else { return stats }
            lines[idx] = newLine
            try (lines.joined(separator: "\n")).data(using: .utf8)!.write(to: file, options: .atomic)
            stats.eventsRewritten = 1
            return stats
        }
    }
}

// MARK: - 服务

/// CLI 这次拿到的全集是从哪来的、可信到什么程度（面向 Agent 的自述，不是内部日志）
public struct IndexScope: Codable, Sendable {
    public enum Source: String, Codable, Sendable {
        /// App 写好的全盘发现缓存——与 App 清单同源
        case appCache
        /// 缓存不可用，只扫了 home 两层——必然比 App 少
        case homeShallowFallback
    }
    public var source: Source
    public var locations: Int
    public var warning: String?

    public init(source: Source, locations: Int, warning: String?) {
        self.source = source; self.locations = locations; self.warning = warning
    }
}

public final class AssemblyService: @unchecked Sendable {
    public let paths: SkillControllerPaths
    /// 以下四件对 extension（LibraryAdd.swift 的 add 流程）可见：同模块 internal，
    /// 不进 public 面——库内写流程与主服务共享同一把锁、同一份日志与事件存储（D19 单一真相的写侧同款纪律）。
    let lock: WriteLock
    let log: OperationLog
    let events: AssemblyEventStore
    let home: URL

    /// `lock` 传 nil 时自建一把。App 侧必须把自己那把传进来：
    /// 同一进程里多把 flock = 同一文件多个 fd 互斥，嵌套加锁会自己把自己锁到超时
    /// （真机验收抓到过：删除走 TrashManager 持锁 → 写日志换一把锁 → 卡死）。
    public init(paths: SkillControllerPaths = SkillControllerPaths(),
                lock: WriteLock? = nil,
                home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        let lock = lock ?? WriteLock(paths: paths)
        self.paths = paths
        self.lock = lock
        self.log = OperationLog(paths: paths, lock: lock)
        self.events = AssemblyEventStore(paths: paths, lock: lock)
        self.home = home
    }

    /// 只读：构建当前清单（search/info 与写侧落位前的事实核对共用）
    /// CLI 关键路径绝不进全盘遍历（实测 44s）：优先用 App 写好的发现缓存，
    /// 无缓存时只做 home 两层快扫（实测 1s）——宁可少几处角落位置，也不让 Agent 等。
    public func currentIndex() -> InventoryIndex { buildIndex().index }

    /// 同上，但把「这份全集是从哪来的、可信到什么程度」一起交出来。
    /// 降级必须是显式的：静默用一份偏小的全集，Agent 会以为"这个 Skill 不存在"，
    /// 而 App 那边明明看得见（2026-09-21 真机就是这么断的）。
    public func buildIndex() -> (index: InventoryIndex, scope: IndexScope) {
        buildIndex(from: cliLocations())
    }

    private func buildIndex(from located: ([DiscoveredLocation], IndexScope)) -> (index: InventoryIndex, scope: IndexScope) {
        let (locations, scope) = located
        let scope2 = ScopeBuilder.scope(discovered: locations, home: home)
        let idx = InventoryIndex()
        var byId: [String: Agent] = [:]
        for loc in scope2.locations where loc.agentOrigin.isRealAgent {
            guard let id = loc.agentId, byId[id] == nil else { continue }
            byId[id] = Agent(id: id, name: AgentRegistry.agentName(id), homeDir: loc.url.path)
        }
        idx.rebuild(from: InventoryScanner().scan(scope: scope2), projects: scope2.projects,
                    discoveredAgents: Array(byId.values))
        return (idx, scope)
    }

    /// 算 G3 基线用的全集：CLI 那份缓存全集 **+ 这次装配真正碰过的 skills 目录**。
    ///
    /// 不补这一刀的话有个隐蔽的必现 bug：`pull` 现场新建的 `<项目>/.agents/skills/`
    /// 根本还没进过发现缓存，基线就在这份"看不见它"的索引上算出来 = **空集哈希**；
    /// 而 App 下一次全盘发现会发现这个目录，比对必然对不上——事件一出生就永远"已过期"。
    /// 2026-09-23 真机就是这么卡的：那条 pull 事件存的 revision 正好是 FNV 的初始值。
    /// 算基线用的索引。internal（不是 private）只为测试能取到同一份取证数据（D34）；
    /// 不进 public 面，产品调用方看到的仍是 finishAssembly / currentRevision。
    func indexForBaseline(event: AssemblyEvent) -> InventoryIndex {
        baselineAndCacheWarning(event: event).index
    }

    /// 同上，但把「这次缓存合并有没有做成」一起交出来（#6c）——
    /// warning 非空说明发现缓存没合进去（锁超时/读失败），App 可能要等下一次扫描才看得见这次的目录。
    /// internal（不是 private）只为测试能取到同一份取证数据；不进 public 面。
    func baselineAndCacheWarning(event: AssemblyEvent) -> (index: InventoryIndex, cacheWarning: String?) {
        let located = cliLocations()
        let fm = FileManager.default
        var extra: [DiscoveredLocation] = []
        for path in event.added + event.removed {
            let skillsDir = URL(fileURLWithPath: path).deletingLastPathComponent()
            guard fm.fileExists(atPath: skillsDir.path) else { continue }   // 已消失的落点不参与
            let loc = DiscoveredLocation(path: skillsDir.path, kind: .skillDirectory)
            if located.0.contains(where: { $0.id == loc.id }) { continue }
            if !extra.contains(where: { $0.id == loc.id }) { extra.append(loc) }
        }
        // D35=B：先落缓存，再算基线——顺序反了就还是两份真相。
        var cacheWarning: String?
        if !extra.isEmpty { cacheWarning = mergeLocationsIntoCache(extra) }
        return (buildIndex(from: (located.0 + extra, located.1)).index, cacheWarning)
    }

    /// 把这次装配动过、但还没进发现缓存的 skills 目录写回缓存（D35=B，智昊拍"一处真相"）。
    ///
    /// 为什么必须写缓存而不是只在内存里合并：App 的轻量重扫（⌘R / FSEvents）**只读这份缓存**，
    /// 全盘发现才贵。CLI 单方面"看得见"新目录，App 看不见，于是事件一出生就被判"清单已更新"，
    /// 人得先点一次重新加载才能验收——2026-09-24 真机两条都这样。
    ///
    /// 三条边界：
    /// - **只追加位置**。`savedAt` / `dirsVisited` / `unreadableCount` / 各类剪枝计数是"上一次
    ///   全盘发现了什么"的记账，CLI 补一个目录不是一次新的全盘发现，动了就是替 App 说谎。
    /// - 没有缓存时**不创建**：空缓存会让 App 以为"上次发现的结果就是空"，那比不一致更糟。
    /// - 读—改—写整段持写锁，避免和 App 正在写的那份互相覆盖。
    ///
    /// 返回 nil = 合并成功（或无事可做）；非 nil = 人读警告（#6c，并发模型 §5：锁超时**不允许 try? 吞掉**——
    /// 吞掉的后果是调用方以为缓存合并成功、实际什么都没写，「一处真相」变成「零处真相」）。
    /// `timeout` 仅供测试注入短超时（生产默认 10s 与其它写路径一致）；internal 同理只为了测试。
    func mergeLocationsIntoCache(_ extra: [DiscoveredLocation], timeout: TimeInterval = 10) -> String? {
        let cache = DiscoveryCache(paths: paths)
        do {
            return try lock.withLock(timeout: timeout) { () -> String? in
                guard var snap = cache.load() else { return nil }
                let known = Set(snap.locations.map(\.id))
                let added = extra.filter { !known.contains($0.id) }
                guard !added.isEmpty else { return nil }
                snap.locations += added
                cache.save(snap)
                return nil
            }
        } catch {
            return "发现缓存没能更新：\(error.localizedDescription)——这次装配涉及的目录没有写进发现缓存，App 里可能要等下一次扫描才能看见"
        }
    }

    /// 位置来源与如实警告（不抛错、不假装拿到的就是全集）
    private func cliLocations() -> ([DiscoveredLocation], IndexScope) {
        let rules = AppSettings.load(paths: paths).discoveryRules
        if let snap = DiscoveryCache(paths: paths).load() {
            var warnings: [String] = []
            if let v = snap.builderVersion, v != SkillControllerVersion.string {
                warnings.append("发现缓存由 \(v) 写出，本 skillctl 是 \(SkillControllerVersion.string)——"
                                + "两者不是同一次构建，请重装 skillctl 或在 App 里重新扫描全盘")
            }
            if snap.rules != rules {
                warnings.append("发现缓存的扫描范围与你当前设置不一致，这份清单可能偏旧——"
                                + "在 App「设置 · 重新扫描全盘」可刷新")
            }
            let warning = warnings.isEmpty ? nil : warnings.joined(separator: "；")
            return (snap.locations,
                    IndexScope(source: .appCache, locations: snap.locations.count, warning: warning))
        }
        let shallow = ScopeDiscoverer(rules: rules)
            .discover(roots: [home], home: home, maxDepth: 2).locations
        return (shallow, IndexScope(source: .homeShallowFallback, locations: shallow.count,
                                    warning: "没有可用的发现缓存，本次只扫了 home 两层——"
                                    + "这份全集比 App 里看到的少，先打开一次 App 扫描再试"))
    }

    // MARK: 查询

    public func search(_ query: String, type: ObjectType? = nil) -> [SearchResult] {
        currentIndex().filtered(type: type, query: query).map {
            SearchResult(id: $0.id, name: $0.name, description: $0.description, type: $0.type.rawValue,
                         level: $0.level.rawValue, sourcePath: $0.sourcePath,
                         mountedBy: $0.mountedBy, duplicates: [Int](repeating: 1, count: $0.duplicates.count))
        }
    }

    public func info(_ name: String) -> InventoryItem? {
        let idx = currentIndex()
        return idx.items.first { $0.name == name }
    }

    // MARK: 写入

    /// pull：把库里的 skill 落位到目标项目（默认 symlink）
    /// 严格模式（§2.3 站点 1）：源只从库解析，缺货抛 notInLibrary（可照抄补救命令），不回退散落副本
    @discardableResult
    public func pull(name: String, target: String, agent: String = "codex", copy: Bool = false) throws -> AssemblyReport {
        guard let dir = MountTargets.resolve(agent: agent, projectPath: target, home: home) else {
            throw AssemblyError.unknownAgent(agent: agent)
        }
        let source = try resolveFromLibrary(name)
        let outcome = try land(source: source, into: dir, name: name, copy: copy)
        return try finishAssembly(agent: agent, projectPath: target, outcomes: [outcome],
                                  detail: "经 skillctl pull 装配 \(name)")
    }

    /// mount：把条目挂到某 Agent 的生效集合（用户级或项目级）
    /// 严格模式（§2.3 站点 2）：类型守卫保留在解析**之前**——MCP 名照旧如实报类型不对，
    /// 不谎报缺货；skill 名再从库解析（缺货 notInLibrary，不回退）
    @discardableResult
    public func mount(name: String, on agent: String, projectPath: String? = nil) throws -> AssemblyReport {
        guard let dir = MountTargets.resolve(agent: agent, projectPath: projectPath, home: home) else {
            throw AssemblyError.unknownAgent(agent: agent)
        }
        let idx = currentIndex()
        // 类型守卫：MCP 不是可挂载对象（story-6 写侧未开）——
        // 只加守卫会把「存在但不是 Skill」谎报成 notFound（另一种假话），所以类型化抛 notASkill。
        if !idx.items.contains(where: { $0.name == name && $0.type == .skill }),
           idx.items.contains(where: { $0.name == name }) {
            throw AssemblyError.notASkill(name: name)
        }
        let source = try resolveFromLibrary(name)
        let outcome = try land(source: source, into: dir, name: name, copy: false)
        return try finishAssembly(agent: agent, projectPath: projectPath, outcomes: [outcome],
                                  detail: "经 skillctl mount 挂上 \(name)")
    }

    /// unmount：卸下某 Agent 的落点
    /// 卸载 ≠ 删除：落点是 symlink → 删链接；落点是条目本体（唯一实体）→ 拒绝并指向删除
    @discardableResult
    public func unmount(name: String, on agent: String, projectPath: String? = nil) throws -> AssemblyReport {
        let fm = FileManager.default
        // 第一轮：primary + 读侧认的其它容器目录（Codex 的 .agents/.codex 双目录就在这轮覆盖到）
        var outcomes = try removeLandings(
            name: name, dirs: MountTargets.candidates(agent: agent, projectPath: projectPath, home: home), fm: fm)
        if outcomes.isEmpty {
            // 第二轮：表里没有的工具（thincoder / trae-cn… 靠目录名动态归属）——
            // 问索引要"这家实际挂在哪些目录"，而不是因为表里查不到就说自己没挂
            let idx = currentIndex()
            var extra: [URL] = []
            if let item = idx.items.first(where: { $0.name == name }) {
                extra = idx.mountStat(of: item.id).spots.filter { $0.agentId == agent }
                    .map { URL(fileURLWithPath: $0.path).deletingLastPathComponent() }
            }
            outcomes = try removeLandings(
                name: name,
                dirs: MountTargets.candidates(agent: agent, projectPath: projectPath, home: home, indexDirs: extra),
                fm: fm)
        }
        guard !outcomes.isEmpty else {
            throw AssemblyError.notMounted(path: MountTargets
                .candidates(agent: agent, projectPath: projectPath, home: home)
                .map { $0.appendingPathComponent(name).path }
                .joined(separator: "、"))
        }
        // 一次卸下可能命中同一家多个目录，全部如实进 diff 的「卸下」组
        return try finishAssembly(agent: agent, projectPath: projectPath, outcomes: outcomes,
                                  detail: "经 skillctl unmount 卸下 \(name)")
    }

    /// 在给定候选目录里卸下该条目的落点：链接删掉、本体拒绝、没挂过的目录跳过。
    /// 返回空数组 = 这些目录里一个落点都没有（调用方据此决定要不要再问索引）。
    private func removeLandings(name: String, dirs: [URL], fm: FileManager) throws -> [WriteOutcome] {
        var outcomes: [WriteOutcome] = []
        for dir in dirs {
            let landing = dir.appendingPathComponent(name)
            guard Self.pathOccupied(landing.path) else { continue }   // lstat：悬空链接也算"挂过"，可卸下
            if (try? fm.destinationOfSymbolicLink(atPath: landing.path)) != nil {
                do {
                    try lock.withLock { try fm.removeItem(atPath: landing.path) }
                    outcomes.append(WriteOutcome(status: .created, path: landing.path,
                                                 reason: "链接已卸下", isRemoval: true))
                } catch {
                    outcomes.append(WriteOutcome(status: .failed(reason: "移除链接失败"),
                                                 path: landing.path, reason: nil))
                }
            } else {
                // 本体：卸下会使其脱离全集 → 拒绝（不静默半成功）
                outcomes.append(WriteOutcome(status: .refused, path: landing.path,
                                             reason: "该落点是条目本体，卸下会使其脱离全集；如需移除请用删除（走回收站）"))
            }
        }
        return outcomes
    }

    // MARK: 内部

    /// 落位：默认 symlink；目标已存在 → 冲突跳过（不覆盖、不静默）
    private func land(source: String, into dir: URL, name: String, copy: Bool) throws -> WriteOutcome {
        let fm = FileManager.default
        let dest = dir.appendingPathComponent(name)
        // 存在性用 lstat：实体、有效链接、悬空链接都算"已占用"（不静默覆盖）
        if Self.pathOccupied(dest.path) {
            return WriteOutcome(status: .skippedConflict, path: dest.path, reason: "目标已存在，未覆盖")
        }
        return try lock.withLock {
            do {
                try fm.createDirectory(at: dir, withIntermediateDirectories: true)
                if copy {
                    try fm.copyItem(atPath: source, toPath: dest.path)
                } else {
                    // 相对链接（与本机既有 symlink 习惯一致，随目录整体搬迁仍可用）
                    let rel = relativePath(from: dir, to: URL(fileURLWithPath: source))
                    try fm.createSymbolicLink(atPath: dest.path, withDestinationPath: rel)
                }
                return WriteOutcome(status: .created, path: dest.path, reason: copy ? "已复制" : "已建链接")
            } catch {
                return WriteOutcome(status: .failed(reason: error.localizedDescription), path: dest.path, reason: nil)
            }
        }
    }

    private func canonical(_ url: URL) -> URL {
        if let v = try? url.resourceValues(forKeys: [.canonicalPathKey]), let c = v.canonicalPath {
            return URL(fileURLWithPath: c)
        }
        return url.standardizedFileURL
    }

    /// 路径是否已存在（含悬空 symlink——lstat 语义）
    static func pathOccupied(_ path: String) -> Bool {
        var st = stat()
        return lstat(path, &st) == 0
    }

    /// 相对链接计算：必须按 canonical（realpath）算层数。
    /// 注意 URL.resolvingSymlinksInPath() 会剥掉 /private 前缀，/tmp 场景下会算错层数 → 悬空链接。
    private func relativePath(from dir: URL, to target: URL) -> String {
        let base = canonical(dir).path.split(separator: "/").map(String.init)
        let tgt = canonical(target).path.split(separator: "/").map(String.init)
        var common = 0
        while common < base.count, common < tgt.count, base[common] == tgt[common] { common += 1 }
        let up = Array(repeating: "..", count: base.count - common)
        return (up + tgt[common...]).joined(separator: "/")
    }

    /// 落日志 + 落装配事件（Banner 数据源）；0 增 0 删也如实记（empty-assembly 事实态）。
    /// #12（D37）：`.failed` outcome 原来被整体丢弃——只读目录下 pull 全失败时事件三组全空，
    /// App 把「两次写入都失败」呈成「检查过了，没带来新东西」（G7 级撒谎）。
    /// 原因在枚举关联值里（`o.reason` 对 failed 恒为 nil），必须从关联值取。
    private func finishAssembly(agent: String, projectPath: String?, outcomes: [WriteOutcome], detail: String) throws -> AssemblyReport {
        let ok = outcomes.filter { if case .created = $0.status { return true }; return false }
        let addedPaths = ok.filter { !$0.isRemoval }.map(\.path)
        let removedPaths = ok.filter { $0.isRemoval }.map(\.path)
        let conflicts = outcomes.compactMap { o -> AssemblyConflict? in
            guard case .skippedConflict = o.status else { return nil }
            return AssemblyConflict(itemId: o.path, reason: o.reason ?? "冲突")
        }
        let failed = outcomes.compactMap { o -> AssemblyConflict? in
            guard case .failed(let why) = o.status else { return nil }
            return AssemblyConflict(itemId: o.path, reason: why)
        }
        let projectId = projectPath.map { "proj-" + (($0 as NSString).lastPathComponent) } ?? ""
        let event = AssemblyEvent(
            id: UUID().uuidString,
            date: LogRecord.nowISO(),
            agentId: agent,
            projectId: projectId,
            added: addedPaths,
            removed: removedPaths,
            conflicts: conflicts,
            reviewed: false,
        )
        let baseline = baselineAndCacheWarning(event: event)
        let idx = baseline.index
        let dirs = Self.affectedDirs(event: event, projectPath: projectPath)
        // 失败条目的变动史必须查得到（D3 口径按落点路径命中日志）——itemIds 追加失败路径
        let itemIds = addedPaths + removedPaths + failed.map(\.itemId)
        // 日志尾注如实带失败段（空数组不拼，与「空失败组也存 nil」同一口径）
        let failureNote = failed.isEmpty ? "" : " · 失败 \(failed.count)"
        let record = LogRecord(actor: agent, actorKind: .agent, action: .assembly,
                               detail: detail + "（挂上 \(addedPaths.count) · 卸下 \(removedPaths.count) · 跳过 \(conflicts.count)\(failureNote)）",
                               target: projectId.isEmpty ? "用户级" : projectId,
                               reversible: true, itemIds: itemIds)
        try log.append(record)
        // 快照只覆盖影响面：全盘哈希会把无关目录的变动也算成"这次装配过期了"
        try events.append(StoredAssemblyEvent(event: event,
                                             revision: Self.revision(of: idx, within: dirs),
                                             revisionScope: dirs,
                                             failed: failed.isEmpty ? nil : failed))
        // #6c：缓存合并的失败如实上抛，不再静默——CLI 进 warning 字段，App 落 lastError
        return AssemblyReport(event: event, outcomes: outcomes, warning: baseline.cacheWarning)
    }

    /// 清单快照版本（G3 用：验收前比对，不一致则禁用「关闭并验收」）
    /// 必须跨进程稳定——不能用 Swift hashValue（每进程随机加盐，CLI 与 App 算出的值必然不同）
    ///
    /// 口径变更（2026-09-21 真机验收后）：**只哈希这次装配影响面内的条目**。
    /// 原来哈希整盘条目 id，于是别家 Agent 装了个东西、某个临时目录多出一列，
    /// 都会把这次验收锁住——真机上「清单已更新」几乎必然出现，人根本点不下去「关闭并验收」。
    /// G3 的本意是"这次装配的结果在验收前又被人改了"，那只需要看动过的那几个目录。
    /// 旧事件（revisionScope == nil）持的是全盘口径，与新口径不可比，App 不再拿它锁人。
    public static func revision(of idx: InventoryIndex, within dirs: [String]) -> Int {
        let keys = dirs.map(pathKey)
        var h: UInt64 = 0xcbf29ce484222325 // FNV-1a 64
        for item in idx.items.sorted(by: { $0.id < $1.id }) where Self.item(item, touches: keys) {
            for byte in item.id.utf8 {
                h ^= UInt64(byte)
                h = h &* 0x100000001b3
            }
        }
        return Int(truncatingIfNeeded: Int64(bitPattern: h))
    }

    /// 比较用的路径键：一律先解到 canonical。
    /// macOS 上 /var → /private/var（临时目录全中），项目目录本身也可能是一棵软链——
    /// 直接做字符串前缀比较会漏判，表现成"影响面内变了却说不算过期"。
    /// 路径不存在时退回标准化结果（落点可能已被别处搬走，不能因此崩）。
    static func pathKey(_ path: String) -> String {
        let url = URL(fileURLWithPath: path).standardizedFileURL
        if let c = try? url.resourceValues(forKeys: [.canonicalPathKey]).canonicalPath {
            return URL(fileURLWithPath: c).standardizedFileURL.path
        }
        return url.path
    }

    /// 条目的任一处落点在范围内就算（实体源搬走了也算，不能只看 sourcePath）
    /// 传入的 dirs 必须已是 pathKey 结果（revision(of:within:) 里统一转换）
    static func item(_ item: InventoryItem, touches dirKeys: [String]) -> Bool {
        for path in [item.sourcePath] + item.duplicates {
            let key = pathKey(path)
            for dir in dirKeys where key == dir || key.hasPrefix(dir + "/") { return true }
        }
        return false
    }

    /// 这次装配动过哪些目录：项目根 + 每个落点所在目录。影响面之外的事不该作废这次验收。
    public static func affectedDirs(event: AssemblyEvent, projectPath: String?) -> [String] {
        var dirs = Set<String>()
        if let p = projectPath, !p.isEmpty {
            dirs.insert(pathKey(p))
        }
        for path in event.added + event.removed {
            dirs.insert(pathKey(URL(fileURLWithPath: path).deletingLastPathComponent().path))
        }
        return dirs.sorted()
    }

    /// 当前清单在指定范围内的版本（App 比对事件快照判断是否过期）
    public func currentRevision(within dirs: [String]) -> Int {
        Self.revision(of: currentIndex(), within: dirs)
    }

    /// 影响面里是否**还有至少一处**存在于盘上。
    ///
    /// 全都不在 = 那次装配影响的位置已经从磁盘消失（整个项目被移走、目录被删）。
    /// 这时"清单在你验收前又变了"这件事已经没有对象可比：范围内的条目集合恒为空，
    /// 无论重扫多少次都对不上当年那个快照，于是「关闭并验收」被永久锁死——
    /// 而 diff Sheet 按裁定①没有"不验收也能退出"的出口（关闭即默认接受），
    /// 人就只剩 Esc 走人，Banner 从此一直挂着待验收。2026-09-22 真机撞上：
    /// 一次装配的落点项目被丢进废纸篓之后，那条事件再也验收不掉。
    ///
    /// 消失不是"过期"，是"没有待确认的变动了"——所以这种情况放行验收，
    /// 由界面中性说明落点已不在盘上（不假装还能恢复）。
    public static func scopeStillPresent(_ dirs: [String]) -> Bool {
        let fm = FileManager.default
        return dirs.contains { fm.fileExists(atPath: $0) }
    }

    public var eventStore: AssemblyEventStore { events }

    // MARK: 验收面动作（story-2 diff）

    /// 全部恢复原状：撤销该事件的净效果——
    ///  · event.added（当初挂上的）→ 卸下（链接删除；copy 实体走回收站）
    ///  · event.removed（当初卸下的）→ 重新挂回（按名从全集解析源）
    /// 部分失败如实报（G4），全成才 markRestored。
    @discardableResult
    public func restoreAssembly(event: AssemblyEvent) throws -> RestoreOutcome {
        let fm = FileManager.default
        var restored = 0
        var failed: [(path: String, reason: String)] = []
        // 「重新挂回」的凭据：软链记目标，复制件记回收站 id（D32=B）
        var links: [String: String] = [:]
        var copies: [String: String] = [:]
        let total = event.added.count + event.removed.count

        for path in event.added {
            guard Self.pathOccupied(path) else {
                failed.append((path, "落点已不存在"))
                continue
            }
            if let linkDest = try? fm.destinationOfSymbolicLink(atPath: path) {
                do {
                    try lock.withLock { try fm.removeItem(atPath: path) }
                    restored += 1
                    // 原样记下链接目标（相对就存相对，随目录整体搬迁仍可用）——
                    // 这是「重新挂回」唯一的凭据，没它那句"可以一步撤销"就是空话
                    links[path] = linkDest
                }
                catch { failed.append((path, "移除链接失败")) }
            } else {
                // copy 落点是实体目录 → 走回收站（不永久删）
                let item = InventoryItem(id: "path:\(path)", name: (path as NSString).lastPathComponent,
                                        description: "", type: .skill, level: .project, projectId: event.projectId,
                                        sourcePath: path, mountedBy: [], status: .mounted)
                do {
                    let manifest = try TrashManager(paths: paths, lock: lock).trash(item: item, actor: event.agentId)
                    restored += 1
                    copies[path] = manifest.entryId   // 撤销时按这个 id 从回收站取回
                } catch { failed.append((path, "移入回收站失败")) }
            }
        }
        // 撤销"卸下"：把当初 unmount 掉的链接重新挂回（严格模式 §2.3 站点 3：源只从库解析；
        // 库缺 → 该落点进 failed 组如实报部分态，不静默回退散落副本——A7）
        for path in event.removed {
            let name = (path as NSString).lastPathComponent
            let dir = (path as NSString).deletingLastPathComponent
            guard let src = try? resolveFromLibrary(name) else {
                failed.append((path, "库中已无该条目，无法回挂（可先 skillctl add 收编后再重试）"))
                continue
            }
            if Self.pathOccupied(path) { restored += 1; continue } // 已在位，视为已恢复
            let outcome = try land(source: src, into: URL(fileURLWithPath: dir), name: name, copy: false)
            if case .created = outcome.status { restored += 1 }
            else { failed.append((path, outcome.reason ?? "回挂失败")) }
        }
        let detail = failed.isEmpty
            ? "已恢复至 \(event.agentId) 装配之前（\(restored)/\(total) 个落点回位）"
            : "\(restored)/\(total) 项已恢复 · \(failed.count) 项未能恢复（已记日志，可重试）"
        try log.append(LogRecord(actor: "智昊", actorKind: .human,
                                 action: failed.isEmpty ? .restore : .restorePartial,
                                 detail: detail, target: event.projectId.isEmpty ? "用户级" : event.projectId,
                                 reversible: false, restoredOf: nil))
        // 凭据先落盘（部分恢复也记），"已恢复"标记只在全部回位时置位
        try events.markRestored(eventId: event.id, links: links, copies: copies, complete: failed.isEmpty)
        return RestoreOutcome(restored: restored, failed: failed)
    }

    /// 撤销「全部恢复原状」＝把当初摘掉的链接按记录的目标重建（D32=B，智昊拍"真做撤销"）。
    ///
    /// 确认框那句「这一步本身也会写进操作日志，同样可以一步撤销」在 2026-09-23 之前是空话：
    /// 恢复写进日志的那条记录 `reversible:false`，回退页的「恢复」按钮又只服务回收站条目，
    /// 于是装配回滚过后再也回不去——把一次成功的恢复渲染成一个没有出口的既成事实。
    ///
    /// 口径：
    /// - 软链按 `restoredLinks` 里存的原样重建（相对就存相对），落点目录不存在就照 `land` 的规矩建目录；
    /// - 目标位已被占用时**不覆盖**，逐条报原因（与 CLI「目标已存在，未覆盖」同一纪律）；
    /// - 复制件按 `restoredCopies` 里的回收站条目 id 走 `TrashManager.restore` 取回；找不到就如实报；
    /// - 全部重建成功才清掉"已恢复"标记（事件仍是已验收态），部分成功则保留标记与剩余凭据。
    @discardableResult
    public func reapplyRestoredAssembly(eventId: String) throws -> RestoreOutcome {
        guard let stored = events.all().first(where: { $0.event.id == eventId }) else {
            return RestoreOutcome(restored: 0, failed: [("", "找不到这条装配记录")])
        }
        let links = stored.restoredLinks ?? [:]
        let copies = stored.restoredCopies ?? [:]
        guard !links.isEmpty || !copies.isEmpty else {
            return RestoreOutcome(restored: 0, failed: [("", "这条恢复没有留下可重建的链接记录")])
        }
        let fm = FileManager.default
        var restored = 0
        var failed: [(path: String, reason: String)] = []
        var doneLinks: [String] = []
        var doneCopies: [String] = []

        for (path, destination) in links.sorted(by: { $0.key < $1.key }) {
            if Self.pathOccupied(path) {
                failed.append((path, "该位置已被占用，未覆盖"))
                continue
            }
            // 严格模式 §2.3 站点 4：链接**目标**落在库根之下时，重建前校验库条目仍在——
            // 不在就如实进 failed，不重建悬空链接（A7：不静默回退）。
            // 校验对象是 destination（落点在项目/Agent 目录里，链接目标才是库路径）；
            // 凭据原样存相对串，先按落点父目录折成绝对再判（否则相对串按 cwd 解析会漏判）。
            let name = (path as NSString).lastPathComponent
            let destAbs = URL(fileURLWithPath: destination,
                              relativeTo: URL(fileURLWithPath: path).deletingLastPathComponent())
                .standardizedFileURL.path
            if SkillLibrary.isLibraryPath(destAbs, home: home), !SkillLibrary(home: home).hasEntry(name) {
                failed.append((path, "库中已无该条目，链接未重建"))
                continue
            }
            do {
                try lock.withLock {
                    try fm.createDirectory(at: URL(fileURLWithPath: path).deletingLastPathComponent(),
                                           withIntermediateDirectories: true)
                    try fm.createSymbolicLink(atPath: path, withDestinationPath: destination)
                }
                restored += 1
                doneLinks.append(path)
            } catch {
                failed.append((path, "重建链接失败：\(error.localizedDescription)"))
            }
        }
        for (path, entryId) in copies.sorted(by: { $0.key < $1.key }) {
            let trash = TrashManager(paths: paths, lock: lock, log: log)
            guard let manifest = trash.listEntries().first(where: { $0.entryId == entryId }) else {
                failed.append((path, "回收站里已找不到这个复制件"))
                continue
            }
            do {
                let outcome = try trash.restore(manifest)
                if outcome.failed.isEmpty {
                    restored += 1
                    doneCopies.append(path)
                } else {
                    failed.append((path, outcome.failed.first?.reason ?? "复制件未能回位"))
                }
            } catch {
                failed.append((path, "回收站恢复失败：\(error.localizedDescription)"))
            }
        }

        let total = links.count + copies.count
        let detail = failed.isEmpty
            ? "撤销恢复：重新挂回 \(restored)/\(total) 个落点（\(stored.event.agentId) 那次装配的结果已回到盘上）"
            : "撤销恢复：\(restored)/\(total) 个落点回位 · \(failed.count) 个未成功（已记日志，可重试）"
        try log.append(LogRecord(actor: "智昊", actorKind: .human,
                                 action: failed.isEmpty ? .mount : .restorePartial,
                                 detail: detail,
                                 target: stored.event.projectId.isEmpty ? "用户级" : stored.event.projectId,
                                 reversible: false, restoredOf: nil))
        // 已重建的从凭据里划掉：重试时不该把成功的再报一遍"已被占用"
        _ = try events.update(eventId: eventId) { s in
            if failed.isEmpty {
                s.restored = false; s.restoredLinks = nil; s.restoredCopies = nil
                return
            }
            if !doneLinks.isEmpty { doneLinks.forEach { s.restoredLinks?.removeValue(forKey: $0) } }
            if !doneCopies.isEmpty { doneCopies.forEach { s.restoredCopies?.removeValue(forKey: $0) } }
            if (s.restoredLinks ?? [:]).isEmpty { s.restoredLinks = nil }
            if (s.restoredCopies ?? [:]).isEmpty { s.restoredCopies = nil }
        }
        return RestoreOutcome(restored: restored, failed: failed)
    }

    /// 冲突行单条重试：对某个之前冲突的落点再试一次（不红、失败留痕）
    @discardableResult
    public func retryLanding(sourcePath: String, intoDir: String, name: String, copy: Bool = false) throws -> WriteOutcome {
        try land(source: sourcePath, into: URL(fileURLWithPath: intoDir), name: name, copy: copy)
    }

    // MARK: - 严格模式源解析（skill-library 批 §2.3，裁决②：不回退散落副本）

    /// 库条目合格 = 目录存在 ∧ 含 SKILL.md（D12 同源；目录在无 SKILL.md 时不解析——
    /// 防止把未收编的杂物目录挂进 Agent）。
    /// pull/mount/恢复链四处源解析的唯一入口：库里没有就抛 notInLibrary（带可照抄补救命令），
    /// **不回退**索引里的散落副本——那就是被裁决②否决的旧语义。
    func resolveFromLibrary(_ name: String) throws -> String {
        let library = SkillLibrary(home: home)
        guard library.hasEntry(name) else {
            throw AssemblyError.notInLibrary(name: name,
                                             remedies: SkillLibrary.remedies(for: name, index: currentIndex()))
        }
        return library.entryURL(named: name).path
    }

    public enum AssemblyError: Error, Equatable {
        case notFound(name: String)
        case unknownAgent(agent: String)
        case notMounted(path: String)
        /// 存在但不是 Skill（MCP 配置项）：mount 只支持 Skill——不把「类型不对」谎报成 notFound
        case notASkill(name: String)
        /// 严格模式缺货：库里没有该条目（remedies = 可照抄的补救命令，A6）
        case notInLibrary(name: String, remedies: [String])
    }
}
