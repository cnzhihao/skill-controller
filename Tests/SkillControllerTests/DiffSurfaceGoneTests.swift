import Testing
import Foundation
@testable import SkillControllerCore

/// G3 验收锁的第二种死法（2026-09-22 真机）：影响面整个从盘上消失后，
/// 范围内的条目集合恒为空，跟当年快照永远对不上 →「关闭并验收」永久禁用，
/// 而 diff Sheet 按裁定①没有"不验收也能退出"的出口，人只能 Esc 走人、Banner 永远挂着待验收。
/// 修法是把"消失"与"变了"分开判：`scopeStillPresent` 为 false 时放行验收。
struct DiffSurfaceGoneTests {
    private func tempDir() throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("sc-scope-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test func emptyScopeIsReportedAsNotPresent() {
        // 空范围走的是另一条分支（旧的全盘口径事件不锁人），这里只钉住函数本身不自欺
        #expect(!AssemblyService.scopeStillPresent([]))
    }

    @Test func vanishedDirsAreReportedAsGone() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let ghost = dir.appendingPathComponent("already-in-trash").path
        #expect(!AssemblyService.scopeStillPresent([ghost]))
    }

    @Test func oneLiveDirIsEnoughToKeepTheLockOn() throws {
        // 混合情形必须仍然锁：只要还有一处影响面在盘上，"你还没看到的变动"就是真命题
        let live = try tempDir()
        defer { try? FileManager.default.removeItem(at: live) }
        let gone = live.appendingPathComponent("nope-not-here").path
        #expect(AssemblyService.scopeStillPresent([live.path]))
        #expect(AssemblyService.scopeStillPresent([gone, live.path]))   // 混合：还剩一处在 → 继续锁
        #expect(!AssemblyService.scopeStillPresent([gone]))             // 全消失 → 放行验收
    }

    @Test func canonicalPathKeysStillResolveToExistingDirs() throws {
        // 影响面存的是 pathKey（canonical）结果，比如 /var → /private/var；
        // 存在性判断必须吃同一种键，否则真机上会把还在的目录判成"已消失"、把锁错误地放开
        let raw = try tempDir()
        defer { try? FileManager.default.removeItem(at: raw) }
        #expect(AssemblyService.scopeStillPresent([AssemblyService.pathKey(raw.path)]))
    }

    @Test func rebasingBaselineUnlocksAcceptanceWithoutRewritingTheFacts() throws {
        // G3 的终点：「重新加载」= 我已看过当前清单，把比对基线刷成现在。
        // 不刷的话，影响面只要真的又变过一次（Agent 还在干活是常态），
        // 那句"重新加载后再验收"就是空头支票——2026-09-23 真机撞上，一条 pull 事件彻底验收不掉。
        let work = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("sc-rebase-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }
        let paths = SkillControllerPaths(supportDir: work)
        let store = AssemblyEventStore(paths: paths, lock: WriteLock(paths: paths))
        let event = AssemblyEvent(id: "e1", date: LogRecord.nowISO(), agentId: "codex", projectId: "proj-x",
                                  added: ["/p/.agents/skills/pdf"], removed: [], conflicts: [], reviewed: false)
        try store.append(StoredAssemblyEvent(event: event, revision: 111, revisionScope: ["/p"]))
        #expect(store.all()[0].revision == 111)

        try store.rebaseRevision(eventId: "e1", to: 222)
        let after = store.all()[0]
        #expect(after.revision == 222)
        // 基线可以刷，事实不能刷：这次装配动了什么是历史，不能被后来的状态覆盖
        #expect(after.event.added == ["/p/.agents/skills/pdf"])
        #expect(after.event.date == event.date)
        #expect(!after.accepted && !after.restored)

        // 查不到的 id：空操作，不崩、也不多写一条
        try store.rebaseRevision(eventId: "nope", to: 999)
        #expect(store.all().count == 1)
    }

    @Test func baselineCoversTheSkillsDirTheAssemblyJustCreated() throws {
        // 根因回归：pull 现场新建的 <项目>/.agents/skills 从没进过发现缓存，
        // 旧实现拿"看不见它"的索引算基线 → 存的是空集哈希 → App 发现该目录后永远对不上，
        // 事件一出生就"已过期"。2026-09-23 真机那条 revision = -3750763034362895579 就是这么来的。
        let work = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("sc-base-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }
        let home = work.appendingPathComponent("home")
        let paths = SkillControllerPaths(supportDir: work.appendingPathComponent("support"))
        // 严格模式：pull 的源只从库解析——夹具种进 ~/.skill-library
        try FileManager.default.createDirectory(
            at: home.appendingPathComponent(".skill-library/pdf"), withIntermediateDirectories: true)
        try "---\nname: pdf\ndescription: src pdf\n---".write(
            to: home.appendingPathComponent(".skill-library/pdf/SKILL.md"), atomically: true, encoding: .utf8)

        let svc = AssemblyService(paths: paths, home: home)
        let project = home.appendingPathComponent("projects/new-proj")   // 全新项目，缓存里必然没有
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        _ = try svc.pull(name: "pdf", target: project.path, agent: "codex")

        let stored = try #require(svc.eventStore.all().last)
        let scope = try #require(stored.revisionScope)
        // 基线不能是空集哈希——那正是旧实现存下来的值（-3750763034362895579 = FNV 初始值）
        #expect(stored.revision != AssemblyService.revision(of: InventoryIndex(), within: scope))
        // 也不是"CLI 那份看不见的索引"算出来的任何值；它必须等于 App 全盘发现之后
        // 按同一范围再算一次的结果——否则一打开就是"已过期"，且永远解不开
        let locations = [
            DiscoveredLocation(path: home.appendingPathComponent(".skill-library").path, kind: .skillDirectory),
            DiscoveredLocation(path: project.appendingPathComponent(".agents/skills").path, kind: .skillDirectory),
        ]
        let fullScope = ScopeBuilder.scope(discovered: locations, home: home)
        let full = InventoryIndex()
        _ = full.rebuild(from: InventoryScanner().scan(scope: fullScope), projects: fullScope.projects)
        #expect(AssemblyService.revision(of: full, within: scope) == stored.revision)
        // 并且这次装配确实被算进去了：全集里能看到落点
        #expect(full.items.contains { $0.name == "pdf" })
    }
}
