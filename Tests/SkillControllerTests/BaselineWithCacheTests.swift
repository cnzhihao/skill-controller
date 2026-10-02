import Testing
import Foundation
@testable import SkillControllerCore

/// D25 / D35 的回归：装配基线必须"App 拿同一份发现缓存立刻重算，能得到同一个值"。
///
/// D25 那轮补的是"CLI 别用一份看不见新目录的索引算基线"；D35 补的是另一半——
/// **CLI 与 App 必须看同一份真相**。两件事合起来才是这条不变量：
/// 存下的 revision == 紧接着用共享缓存重算出来的 revision。
/// 只要两边看的目录集不同，事件一出生就被判"已过期"，人得先点一次「重新加载」才能验收。
struct BaselineWithCacheTests {
    @Test func cachedLocationsPlusFreshLandingMustNotYieldEmptyBaseline() throws {
        let fm = FileManager.default
        let work = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("sc-d34b-\(UUID().uuidString)")
        let home = work.appendingPathComponent("home")
        try fm.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: work) }
        let paths = SkillControllerPaths(supportDir: work.appendingPathComponent("support"))
        try paths.ensureDirs()

        // 源：库目录（严格模式 pull 只从 ~/.skill-library 解析；路径形态与真机 .qwenworkcn 一样非 .agents）
        let srcDir = home.appendingPathComponent(".skill-library/docx")
        try fm.createDirectory(at: srcDir, withIntermediateDirectories: true)
        try "---\nname: docx\ndescription: src docx\n---".write(
            to: srcDir.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)

        // 目标项目：pull 之前不存在 skills 目录（这正是必现场新建的形状）
        let project = home.appendingPathComponent("sc-wt-probe")
        try fm.createDirectory(at: project, withIntermediateDirectories: true)

        // 关键差异：写一份发现缓存，内容里有源、没有那个还没诞生的落点目录
        DiscoveryCache(paths: paths).save(DiscoverySnapshot(
            savedAt: Date(), rules: AppSettings.load(paths: paths).discoveryRules,
            roots: [home.path],
            locations: [DiscoveredLocation(path: srcDir.deletingLastPathComponent().path, kind: .skillDirectory)]))

        let svc = AssemblyService(paths: paths, home: home)
        let report = try svc.pull(name: "docx", target: project.path, agent: "codex")
        let stored = try #require(svc.eventStore.all().last)
        let scope = try #require(stored.revisionScope)
        let empty = AssemblyService.revision(of: InventoryIndex(), within: scope)

        // 取证用：把三份数字都摊开，失败时一眼看见是哪一步空的
        let baselineIdx = svc.indexForBaseline(event: stored.event)
        let keys = scope.map(AssemblyService.pathKey)
        let hits = baselineIdx.items.filter { AssemblyService.item($0, touches: keys) }
        #expect(stored.revision != empty,
                """
                基线算成了空集哈希 → 事件一出生就"已过期"。
                基线索引条目总数=\(baselineIdx.items.count) 范围内命中=\(hits.count)
                落点=\(report.event.added) 缓存位置=\(DiscoveryCache(paths: paths).load()?.locations.map(\.path) ?? [])
                """)
    }

    /// D35=B：pull 之后，**不做任何一次全盘发现**，App 用同一份发现缓存重算必须得到同一个 revision。
    /// 旧写法（只把新目录并进 CLI 自己那份内存索引）在这里必然红——缓存里没有那个目录，
    /// App 的轻量重扫只看缓存，于是算出空集，事件一出生就"清单已更新"。
    @Test func storedBaselineMustMatchWhatAppRecomputesFromTheSharedCache() throws {
        let fm = FileManager.default
        let work = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("sc-d35-\(UUID().uuidString)")
        let home = work.appendingPathComponent("home")
        try fm.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: work) }
        let paths = SkillControllerPaths(supportDir: work.appendingPathComponent("support"))
        try paths.ensureDirs()

        let srcDir = home.appendingPathComponent(".skill-library/pdf")
        try fm.createDirectory(at: srcDir, withIntermediateDirectories: true)
        try "---\nname: pdf\ndescription: src pdf\n---".write(
            to: srcDir.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
        let project = home.appendingPathComponent("sc-wt-parity")
        try fm.createDirectory(at: project, withIntermediateDirectories: true)

        let cache = DiscoveryCache(paths: paths)
        let snapshot = DiscoverySnapshot(
            savedAt: Date(), rules: AppSettings.load(paths: paths).discoveryRules,
            roots: [home.path],
            locations: [DiscoveredLocation(path: srcDir.deletingLastPathComponent().path, kind: .skillDirectory)])
        cache.save(snapshot)

        let svc = AssemblyService(paths: paths, home: home)
        _ = try svc.pull(name: "pdf", target: project.path, agent: "codex")
        let stored = try #require(svc.eventStore.all().last)
        let scope = try #require(stored.revisionScope)

        // App 侧：只读缓存，不做全盘发现
        let recomputed = svc.currentRevision(within: scope)
        #expect(stored.revision == recomputed,
                """
                CLI 存下的基线与 App 用同一份缓存重算的值不一致 → 事件一出生就"已过期"。
                stored=\(stored.revision) recomputed=\(recomputed)
                缓存目录=\(cache.load()?.locations.map(\.path).sorted() ?? [])
                """)
        // 写回缓存不能伪装成一次新的全盘发现：发现元数据必须保持原样
        let after = try #require(cache.load())
        #expect(after.savedAt.timeIntervalSince(snapshot.savedAt) < 1)
        #expect(after.dirsVisited == snapshot.dirsVisited)
        #expect(after.unreadableCount == snapshot.unreadableCount)
        // 但这次动过的目录要进去，App 才看得见同一个集合
        #expect(after.locations.contains { $0.path == project.appendingPathComponent(".agents/skills").path })
    }
}
