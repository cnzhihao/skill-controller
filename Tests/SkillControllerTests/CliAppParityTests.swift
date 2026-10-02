import Testing
import Foundation
@testable import SkillControllerCore

/// App 与 skillctl 是同一仓库、同次构建的两个产物，两边看到的"全集"必须是同一份。
/// 2026-09-21/22 走查抓到的三件事都在这里锁住：
/// ① PATH 上残留旧 skillctl，两边都自称 0.2.0，无从分辨 → 版本戳 + 如实警告；
/// ② `.tmp` 里的临时检出被当成挂载位收录 → 剪枝类别默认生效且影响数可见；
/// ③ 同缓存下 App 侧与 CLI 侧的条目集合必须一致（"App 看得见、CLI 拉不到"就是闭环断裂）。
struct CliAppParityTests {
    private func sandbox() throws -> (work: URL, paths: SkillControllerPaths, home: URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sc-parity-\(UUID().uuidString)")
        let home = dir.appendingPathComponent("home")
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".agents/skills/pdf"), withIntermediateDirectories: true)
        try "---\nname: pdf\ndescription: p\n---".write(to: home.appendingPathComponent(".agents/skills/pdf/SKILL.md"), atomically: true, encoding: .utf8)
        return (dir, SkillControllerPaths(supportDir: dir.appendingPathComponent("support")), home)
    }

    private func seed(_ paths: SkillControllerPaths, _ locs: [DiscoveredLocation], builder: String?) {
        DiscoveryCache(paths: paths).save(DiscoverySnapshot(
            savedAt: Date(), rules: AppSettings.load(paths: paths).discoveryRules,
            roots: ["/"], locations: locs, builderVersion: builder))
    }

    /// ① 缓存不是同一次构建写的 → CLI 必须自述并警告，而不是静默给一份偏小的全集
    @Test func cliWarnsWhenCacheCameFromAnotherBuild() throws {
        let (work, paths, home) = try sandbox()
        defer { try? FileManager.default.removeItem(at: work) }
        let shared = home.appendingPathComponent(".agents/skills")
        let svc = AssemblyService(paths: paths, home: home)

        seed(paths, [DiscoveredLocation(path: shared.path, kind: .skillDirectory)], builder: "0.0.1-other")
        let stale = svc.buildIndex()
        #expect(stale.scope.source == .appCache)
        #expect(stale.scope.warning?.contains("不是同一次构建") == true)

        seed(paths, [DiscoveredLocation(path: shared.path, kind: .skillDirectory)], builder: SkillControllerVersion.string)
        #expect(svc.buildIndex().scope.warning == nil)

        // 没有缓存时走 home 两层兜底：也必须如实说"这份比 App 看到的少"，不许冒充全集
        DiscoveryCache(paths: paths).clear()
        let fallback = svc.buildIndex()
        #expect(fallback.scope.source == .homeShallowFallback)
        #expect(fallback.scope.warning?.contains("比 App 里看到的少") == true)
    }

    /// ② `.tmp` 临时检出默认不收录，且"跳过多少个"要能报出来（设置页逐项带数）
    @Test func tempCheckoutsAreNotMountPoints() throws {
        let (work, _, home) = try sandbox()
        defer { try? FileManager.default.removeItem(at: work) }
        let tmpSkills = home.appendingPathComponent("tool/.tmp/plugins/foo/skills")
        let realSkills = home.appendingPathComponent("tool/skills")
        for dir in [tmpSkills, realSkills] {
            try FileManager.default.createDirectory(at: dir.appendingPathComponent("one"), withIntermediateDirectories: true)
            try "---\nname: one\ndescription: o\n---".write(to: dir.appendingPathComponent("one/SKILL.md"), atomically: true, encoding: .utf8)
        }
        let out = ScopeDiscoverer(rules: .standard).discover(roots: [home], home: home)
        #expect(out.locations.allSatisfy { !$0.path.contains("/.tmp/") })
        #expect(out.locations.contains { $0.path == realSkills.path })
        #expect((out.prunedDirsByCategory[.temp] ?? 0) > 0)
        // 取消勾选这一类就该收回来（范围是用户可切换的设定，不是代码里的默认值）
        let unpruned = ScopeDiscoverer(rules: DiscoveryRules(
            prunedCategories: Set(PruneCategory.allCases.filter { $0.defaultPruned }.filter { $0 != .temp })))
            .discover(roots: [home], home: home)
        #expect(unpruned.locations.contains { $0.path == tmpSkills.path })
    }

    /// ③ 同一份发现缓存下，App 侧口径与 CLI 侧口径必须给出同一批条目
    @Test func sameCacheYieldsSameItemsOnBothSides() throws {
        let (work, paths, home) = try sandbox()
        defer { try? FileManager.default.removeItem(at: work) }
        let shared = home.appendingPathComponent(".agents/skills")
        let proj = work.appendingPathComponent("p")
        let projSkills = proj.appendingPathComponent(".agents/skills")
        try FileManager.default.createDirectory(at: projSkills, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: proj.appendingPathComponent(".git"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: projSkills.appendingPathComponent("docx"), withIntermediateDirectories: true)
        try "---\nname: docx\ndescription: d\n---".write(to: projSkills.appendingPathComponent("docx/SKILL.md"), atomically: true, encoding: .utf8)
        let locs = [DiscoveredLocation(path: shared.path, kind: .skillDirectory),
                    DiscoveredLocation(path: projSkills.path, kind: .skillDirectory)]
        seed(paths, locs, builder: SkillControllerVersion.string)

        // CLI 侧
        let cliIds = Set(AssemblyService(paths: paths, home: home).currentIndex().items.map(\.id))
        // App 侧：同一条链路（发现结果 → ScopeBuilder → Scanner → Index）
        let appIdx = InventoryIndex()
        let scope = ScopeBuilder.scope(discovered: locs, home: home)
        _ = appIdx.rebuild(from: InventoryScanner().scan(scope: scope), projects: scope.projects)
        let appIds = Set(appIdx.items.map(\.id))

        #expect(!cliIds.isEmpty)
        #expect(cliIds == appIds)   // 谁都不许比对方少一项："App 看得见、CLI 拉不到"就是闭环断裂
    }
}
