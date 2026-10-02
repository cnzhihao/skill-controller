import Testing
import Foundation
@testable import SkillControllerCore

/// #12（D37）：CLI 写失败被 App 呈成 0/0/0 no-op 的收口。
/// 事件 schema 只增不改不删——StoredAssemblyEvent.failed 为可选字段，
/// 旧事件文件必须照常解码（D15 同款兼容判据）。
struct AssemblyEventFailedGroupTests {
    private func makeSandbox() throws -> (work: URL, paths: SkillControllerPaths, home: URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sc-fail-\(UUID().uuidString)")
        let home = dir.appendingPathComponent("home")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        return (dir, SkillControllerPaths(supportDir: dir.appendingPathComponent("support")), home)
    }

    /// 造一个库里的 skill（严格模式：pull 的源只从 ~/.skill-library 解析）
    private func makeSourceSkill(home: URL, name: String) throws -> URL {
        let dir = home.appendingPathComponent(".skill-library/\(name)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try "---\nname: \(name)\ndescription: src \(name)\n---".write(
            to: dir.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
        return dir
    }

    /// 只读目标目录 → land 落点必失败（S10 形状）：事件 failed 全量、added/removed 空、
    /// 日志 detail 含「失败 N」且 itemIds 含失败路径
    @Test func readOnlyTargetPullProducesFailedGroupNotNoOp() throws {
        let (work, paths, home) = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: work) }
        _ = try makeSourceSkill(home: home, name: "docx")
        let svc = AssemblyService(paths: paths, home: home)

        let project = work.appendingPathComponent("proj-readonly")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        // 只读目录：land 里 createDirectory + createSymbolicLink 必抛 → .failed outcome
        var isDir: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: project.path, isDirectory: &isDir))
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: project.path)
        // 清理前恢复写权限，否则 defer 删不掉
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: project.path) }

        let report = try svc.pull(name: "docx", target: project.path, agent: "codex")
        guard case .failed = report.outcomes[0].status else {
            Issue.record("只读目录下 pull 应产生 .failed outcome，实际 \(report.outcomes[0].status)")
            return
        }

        // 事件三组全空但 failed 全量——这正是原来被呈成 no-op 的形状
        let stored = try #require(AssemblyEventStore(paths: paths, lock: WriteLock(paths: paths))
            .all().first { $0.event.id == report.event.id })
        #expect(stored.event.added.isEmpty && stored.event.removed.isEmpty && stored.event.conflicts.isEmpty)
        #expect(stored.failed?.count == 1)
        #expect(stored.failed?.first?.itemId == report.outcomes[0].path)
        #expect(stored.failed?.first?.reason.isEmpty == false)

        // 日志如实：detail 含「失败 1」、itemIds 含失败路径（D3 口径按落点命中变动史）
        let logs = OperationLog(paths: paths).readAll().records
        let record = try #require(logs.last { $0.action == .assembly && $0.itemIds?.contains(report.outcomes[0].path) == true })
        #expect(record.detail.contains("失败 1"))
    }

    /// 旧事件（无 failed 键）解码成功且 failed == nil——schema 只增不改不删的兼容判据（D15 同款）
    @Test func legacyEventWithoutFailedKeyDecodesWithNilFailed() throws {
        let legacyLine = """
        {"event":{"id":"legacy-1","date":"2026-09-20T10:00:00+08:00","agentId":"codex","projectId":"proj-p","added":["/p/.agents/skills/x"],"removed":[],"conflicts":[],"reviewed":false},"revision":42,"revisionScope":["/p"],"accepted":false,"restored":false}
        """
        let stored = try JSONDecoder().decode(StoredAssemblyEvent.self, from: Data(legacyLine.utf8))
        #expect(stored.failed == nil)
        #expect(stored.event.added.count == 1)
        #expect(stored.revision == 42)
    }

    /// 含 failed 的事件 encode→decode roundtrip 相等
    @Test func failedFieldRoundTripsThroughJSON() throws {
        let event = AssemblyEvent(id: "e1", date: "2026-09-26T12:00:00+08:00", agentId: "codex",
                                  projectId: "proj-p", added: [], removed: [], conflicts: [], reviewed: false)
        let stored = StoredAssemblyEvent(event: event, revision: 7, revisionScope: ["/p"],
                                         failed: [AssemblyConflict(itemId: "/p/.agents/skills/x",
                                                                   reason: "Permission denied")])
        let data = try JSONEncoder().encode(stored)
        let back = try JSONDecoder().decode(StoredAssemblyEvent.self, from: data)
        #expect(back.event == stored.event)
        #expect(back.revision == stored.revision)
        #expect(back.revisionScope == stored.revisionScope)
        #expect(back.failed == stored.failed)
        #expect(back.failed?.count == 1)
        #expect(back.failed?.first?.reason == "Permission denied")
    }

    /// 空失败组也存 nil——新旧事件形状不无谓分叉
    @Test func emptyFailedGroupIsStoredAsNil() throws {
        let (work, paths, home) = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: work) }
        _ = try makeSourceSkill(home: home, name: "pdf")
        let svc = AssemblyService(paths: paths, home: home)
        let project = work.appendingPathComponent("proj-ok")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        _ = try svc.pull(name: "pdf", target: project.path, agent: "codex")
        let stored = try #require(AssemblyEventStore(paths: paths, lock: WriteLock(paths: paths)).all().first)
        #expect(stored.failed == nil)
        // 成功路径的日志不带失败段
        let record = try #require(OperationLog(paths: paths).readAll().records.last { $0.action == .assembly })
        #expect(!record.detail.contains("失败"))
    }

    /// 混合结果验证（用例 N1 形状）：可写目标 pull 全成（failed=nil）、只读目标 pull 全败
    /// （added 空 + failed 全量 + 日志「失败 1」），两类事件互不污染
    @Test func partialFailureKeepsBothGroups() throws {
        let (work, paths, home) = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: work) }
        _ = try makeSourceSkill(home: home, name: "aaa")
        _ = try makeSourceSkill(home: home, name: "bbb")
        let svc = AssemblyService(paths: paths, home: home)
        let project = work.appendingPathComponent("proj-mix")
        let skills = project.appendingPathComponent(".agents/skills")
        try FileManager.default.createDirectory(at: skills, withIntermediateDirectories: true)
        let store = AssemblyEventStore(paths: paths, lock: WriteLock(paths: paths))

        // 可写目标：成功事件
        let good = try svc.pull(name: "aaa", target: project.path, agent: "codex")
        let goodStored = try #require(store.all().first { $0.event.id == good.event.id })
        #expect(goodStored.event.added.count == 1 && goodStored.failed == nil)

        // 只读目标：全失败事件（skills 目录本身置只读 → createSymbolicLink 必抛）
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: skills.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: skills.path) }
        let bad = try svc.pull(name: "bbb", target: project.path, agent: "codex")
        let badStored = try #require(store.all().first { $0.event.id == bad.event.id })
        #expect(badStored.event.added.isEmpty && badStored.event.removed.isEmpty)
        #expect(badStored.failed?.count == 1)
        #expect(badStored.failed?.first?.itemId == bad.outcomes[0].path)

        // 两条日志各自如实：成功条不带失败段、失败条带「失败 1」
        let logs = OperationLog(paths: paths).readAll().records.filter { $0.action == .assembly }
        #expect(logs.contains { $0.detail.contains("挂上 1 ·") && !$0.detail.contains("失败") })
        #expect(logs.contains { $0.detail.contains("失败 1") })
        // 失败条目的变动史可按落点路径命中（D3 口径）
        #expect(logs.contains { $0.itemIds?.contains(bad.outcomes[0].path) == true })
    }
}

/// skill-library 批严格模式（裁决②）：pull/mount/恢复链只从库解析，缺货不回退（A5/A6/A7）
struct StrictLibrarySourceTests {
    private func makeSandbox() throws -> (work: URL, paths: SkillControllerPaths, home: URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sc-strict-\(UUID().uuidString)")
        let home = dir.appendingPathComponent("home")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        return (dir, SkillControllerPaths(supportDir: dir.appendingPathComponent("support")), home)
    }

    private func makeLibrarySkill(home: URL, name: String) throws -> URL {
        let dir = home.appendingPathComponent(".skill-library/\(name)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try "---\nname: \(name)\ndescription: lib \(name)\n---".write(
            to: dir.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
        return dir
    }

    private func makeScatteredSkill(home: URL, name: String) throws -> URL {
        let dir = home.appendingPathComponent(".agents/skills/\(name)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try "---\nname: \(name)\ndescription: scattered \(name)\n---".write(
            to: dir.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
        return dir
    }

    /// A5：库有货 pull → 落点 symlink 指向库（readlink 断言）；--copy 行为不变
    @Test func pullResolvesFromLibraryAndReadlinkPointsIntoIt() throws {
        let (work, paths, home) = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: work) }
        // 同名：库有、散落也有——严格模式必须认库，不许摸散落那份
        try makeLibrarySkill(home: home, name: "pdf")
        try makeScatteredSkill(home: home, name: "pdf")
        let svc = AssemblyService(paths: paths, home: home)
        let project = work.appendingPathComponent("proj")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)

        _ = try svc.pull(name: "pdf", target: project.path, agent: "codex")
        let landed = project.appendingPathComponent(".agents/skills/pdf")
        let dest = try FileManager.default.destinationOfSymbolicLink(atPath: landed.path)
        let resolved = URL(fileURLWithPath: dest, relativeTo: landed.deletingLastPathComponent())
            .standardizedFileURL.path
        #expect(resolved == home.appendingPathComponent(".skill-library/pdf").standardizedFileURL.path,
                "落点必须指库（实际 \(dest)）")
        #expect(!resolved.contains(".agents/skills"), "不许回退散落副本")

        // --copy 行为不变：实体目录拷自库
        let project2 = work.appendingPathComponent("proj2")
        try FileManager.default.createDirectory(at: project2, withIntermediateDirectories: true)
        _ = try svc.pull(name: "pdf", target: project2.path, agent: "codex", copy: true)
        let copied = project2.appendingPathComponent(".agents/skills/pdf")
        let isLink = (try? copied.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) ?? true
        #expect(!isLink)
        #expect(FileManager.default.fileExists(atPath: copied.appendingPathComponent("SKILL.md").path))
    }

    /// A6：库无货 pull → notInLibrary 含可照抄补救、盘上零写入、不回退散落副本
    @Test func pullWithoutLibraryEntryErrorsWithRemediesAndWritesNothing() throws {
        let (work, paths, home) = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: work) }
        // 只有散落副本：旧语义会拿它当源——严格模式必须报缺货
        try makeScatteredSkill(home: home, name: "docx")
        let svc = AssemblyService(paths: paths, home: home)
        let project = work.appendingPathComponent("proj")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)

        do {
            _ = try svc.pull(name: "docx", target: project.path, agent: "codex")
            Issue.record("库缺货必须抛 notInLibrary")
        } catch let e as AssemblyService.AssemblyError {
            guard case .notInLibrary(let n, let remedies) = e else {
                Issue.record("错误类型应是 notInLibrary，实际 \(e)")
                return
            }
            #expect(n == "docx")
            #expect(remedies.contains { $0.contains("skillctl add docx --from '") },
                    "remedies 必须含可照抄的 --from 命令：\(remedies)")
        }
        // 盘上零写入（错误在 land 之前抛出）
        #expect(!FileManager.default.fileExists(atPath: project.appendingPathComponent(".agents/skills").path))
    }

    /// A7 前半：恢复链回挂从库解析；库缺 → 该落点进 failed 组，整体部分态，不静默回退
    @Test func restoreWithMissingLibraryEntryReportsPartialNotFallback() throws {
        let (work, paths, home) = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: work) }
        try makeLibrarySkill(home: home, name: "pdf")
        try makeScatteredSkill(home: home, name: "pdf")   // 散落副本在场——不许被拿来回挂
        let svc = AssemblyService(paths: paths, home: home)
        let project = work.appendingPathComponent("proj")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let r = try svc.pull(name: "pdf", target: project.path, agent: "codex")
        let landed = project.appendingPathComponent(".agents/skills/pdf")

        // unmount 造一条"卸下"事件，然后删库条目，再恢复——回挂必须失败（不回退散落副本）
        let u = try svc.unmount(name: "pdf", on: "codex", projectPath: project.path)
        try FileManager.default.removeItem(at: home.appendingPathComponent(".skill-library/pdf"))
        let out = try svc.restoreAssembly(event: u.event)
        #expect(out.restored == 0)
        #expect(out.failed.count == 1)
        #expect(out.failed[0].path == landed.path)
        #expect(out.failed[0].reason.contains("库中已无该条目"))
        // 盘上事实：落点没有借散落副本回挂
        #expect(!FileManager.default.fileExists(atPath: landed.path))
    }

    /// A7 后半：reapply 对库根之下的落点先校验库条目仍在，不在就如实报、不重建悬空链接
    @Test func reapplyValidatesLibraryEntryStillExists() throws {
        let (work, paths, home) = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: work) }
        try makeLibrarySkill(home: home, name: "pdf")
        let svc = AssemblyService(paths: paths, home: home)
        let project = work.appendingPathComponent("proj")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let r = try svc.pull(name: "pdf", target: project.path, agent: "codex")
        let landed = project.appendingPathComponent(".agents/skills/pdf")
        let before = try FileManager.default.destinationOfSymbolicLink(atPath: landed.path)

        _ = try svc.restoreAssembly(event: r.event)
        #expect(!FileManager.default.fileExists(atPath: landed.path))
        // 恢复后删库条目 → 重新挂回必须拒绝（不重建指向不存在条目的链接）
        try FileManager.default.removeItem(at: home.appendingPathComponent(".skill-library/pdf"))
        let out = try svc.reapplyRestoredAssembly(eventId: r.event.id)
        #expect(out.restored == 0)
        #expect(out.failed.count == 1)
        #expect(out.failed[0].reason.contains("库中已无该条目"))
        #expect(!FileManager.default.fileExists(atPath: landed.path))
        _ = before
    }

    /// D21（决策⑤）：库条目天然零挂载——库落点 agentId 必须是 nil（不是空串），
    /// 否则 MountStat 按 != nil 计数会把库落点算成挂载，「在库里但零挂载」信号失真
    @Test func libraryLandingIsNotCountedAsAMount() throws {
        let (work, paths, home) = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: work) }
        try makeLibrarySkill(home: home, name: "pdf")
        let homeLib = home.appendingPathComponent(".skill-library")
        let scope = ScopeBuilder.scope(discovered: [DiscoveredLocation(path: homeLib.path, kind: .skillDirectory)],
                                       home: home)
        #expect(scope.locations.count == 1)
        let loc = scope.locations[0]
        #expect(loc.agentOrigin == .skillLibrary)
        #expect(loc.agentId == nil, "库位置 agentId 必须折成 nil（classify 的空串在 ScopeBuilder 收口）")
        #expect(loc.level == .library)

        let idx = InventoryIndex()
        _ = idx.rebuild(from: InventoryScanner().scan(scope: scope), projects: [])
        let item = try #require(idx.items.first)
        let stat = idx.mountStat(of: item.id)
        #expect(stat.mounts == 0, "库本体落点不计挂载（D21）")
        #expect(item.status == .zeroMount)
    }

    /// 本体优先认库（设计 §2.1）：库副本 + 散落同名并存 → 一条目、sourcePath = 库路径
    @Test func entitySourcePrefersLibraryCopy() throws {
        let (work, paths, home) = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: work) }
        try makeLibrarySkill(home: home, name: "pdf")
        // 散落副本（实体）也放一份——旧规则下本体随扫描顺序漂移
        try makeScatteredSkill(home: home, name: "pdf")
        let scope = ScopeBuilder.scope(discovered: [
            DiscoveredLocation(path: home.appendingPathComponent(".skill-library").path, kind: .skillDirectory),
            DiscoveredLocation(path: home.appendingPathComponent(".agents/skills").path, kind: .skillDirectory),
        ], home: home)
        let idx = InventoryIndex()
        _ = idx.rebuild(from: InventoryScanner().scan(scope: scope), projects: [])
        let item = try #require(idx.items.first)
        #expect(item.sourcePath == home.appendingPathComponent(".skill-library/pdf").standardizedFileURL.path,
                "本体必须优先认库（实际 \(item.sourcePath)）")
        #expect(item.duplicates.contains(home.appendingPathComponent(".agents/skills/pdf").standardizedFileURL.path))
    }
}
