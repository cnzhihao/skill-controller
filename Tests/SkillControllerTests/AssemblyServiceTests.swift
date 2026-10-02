import Testing
import Foundation
@testable import SkillControllerCore

/// skillctl 写侧测试：落位语义、卸载≠删除、日志与装配事件、双进程并发写锁（G3/R3）
struct AssemblyServiceTests {
    private func makeSandbox() throws -> (work: URL, paths: SkillControllerPaths, home: URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sc-cli-\(UUID().uuidString)")
        let home = dir.appendingPathComponent("home")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        return (dir, SkillControllerPaths(supportDir: dir.appendingPathComponent("support")), home)
    }

    /// 造一个库里的 skill（严格模式：pull/mount 的源只从 ~/.skill-library 解析）
    private func makeSourceSkill(home: URL, name: String) throws -> URL {
        let dir = home.appendingPathComponent(".skill-library/\(name)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try "---\nname: \(name)\ndescription: src \(name)\n---".write(
            to: dir.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
        return dir
    }

    @Test func pullCreatesRelativeSymlinkAndLogsEvent() throws {
        let (work, paths, home) = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: work) }
        let src = try makeSourceSkill(home: home, name: "pdf")
        let svc = AssemblyService(paths: paths, home: home)

        let project = work.appendingPathComponent("proj-x")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let report = try svc.pull(name: "pdf", target: project.path, agent: "codex")

        let landed = project.appendingPathComponent(".agents/skills/pdf")
        #expect(FileManager.default.fileExists(atPath: landed.path))
        let dest = try FileManager.default.destinationOfSymbolicLink(atPath: landed.path)
        // 相对链接：从 proj-x/.agents/skills 上跳到库（严格模式源 = ~/.skill-library/pdf）
        #expect(dest.hasSuffix(".skill-library/pdf") && dest.contains(".."))
        #expect(report.event.added == [landed.path])
        #expect(report.event.reviewed == false)   // 待验收 → Banner 未验收态
        #expect(report.conflictsSummary == 0)

        // 事件与日志都落盘（App Banner / 回退页数据源）
        #expect(AssemblyEventStore(paths: paths, lock: WriteLock(paths: paths)).all().count == 1)
        let logs = OperationLog(paths: paths).entries()
        #expect(logs.contains { $0.action.contains("pull") && $0.actorKind == .agent })
        _ = src
    }

    @Test func pullTwiceSkipsConflictWithoutOverwrite() throws {
        let (work, paths, home) = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: work) }
        _ = try makeSourceSkill(home: home, name: "docx")
        let svc = AssemblyService(paths: paths, home: home)
        let project = work.appendingPathComponent("proj-y")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)

        _ = try svc.pull(name: "docx", target: project.path, agent: "codex")
        let second = try svc.pull(name: "docx", target: project.path, agent: "codex")
        guard case .skippedConflict = second.outcomes[0].status else {
            Issue.record("第二次 pull 应为冲突跳过，实际 \(second.outcomes[0].status)")
            return
        }
        #expect(second.event.conflicts.count == 1)
        // 不覆盖：落点仍是链接
        let landed = project.appendingPathComponent(".agents/skills/docx")
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: landed.path).contains(".."))
    }

    @Test func unmountRemovesLinkButRefusesSourceBody() throws {
        let (work, paths, home) = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: work) }
        _ = try makeSourceSkill(home: home, name: "dbs")   // 本体在库（严格模式源）
        let svc = AssemblyService(paths: paths, home: home)

        // 1) 挂到 claude 用户级 → 是链接 → unmount 只删链接，源仍在（C3）
        _ = try svc.mount(name: "dbs", on: "claude")
        let link = home.appendingPathComponent(".claude/skills/dbs")
        #expect(FileManager.default.fileExists(atPath: link.path))
        _ = try svc.unmount(name: "dbs", on: "claude")
        #expect(!FileManager.default.fileExists(atPath: link.path))
        #expect(FileManager.default.fileExists(atPath: home.appendingPathComponent(".skill-library/dbs").path))

        // 2) 对本体（实体目录落点）unmount → 拒绝，不静默半成功。
        //    严格模式下本体在库（库不是 Agent 目录，不在 unmount 候选里）；
        //    Agent 候选目录里的实体目录（人手放的/别的工具装的）同样拒绝——卸下会使其脱离全集。
        try FileManager.default.createDirectory(
            at: home.appendingPathComponent(".agents/skills/dbs"), withIntermediateDirectories: true)
        let r = try svc.unmount(name: "dbs", on: "codex")
        guard case .refused = r.outcomes[0].status else {
            Issue.record("卸下本体应被拒绝，实际 \(r.outcomes[0].status)")
            return
        }
        #expect(r.outcomes[0].reason?.contains("脱离全集") == true)
        #expect(FileManager.default.fileExists(atPath: home.appendingPathComponent(".agents/skills/dbs").path))
        #expect(FileManager.default.fileExists(atPath: home.appendingPathComponent(".skill-library/dbs").path))
    }

    @Test func unknownAgentAndMissingNameAreExplicitErrors() throws {
        let (work, paths, home) = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: work) }
        let svc = AssemblyService(paths: paths, home: home)
        // 严格模式：全集中不存在（更不在库里）的 skill → notInLibrary（A6 口径取代 notFound）
        #expect(throws: AssemblyService.AssemblyError.notInLibrary(name: "nope", remedies: [])) {
            _ = try svc.pull(name: "nope", target: work.path, agent: "codex")
        }
        #expect(throws: AssemblyService.AssemblyError.unknownAgent(agent: "vim")) {
            _ = try svc.pull(name: "pdf", target: work.path, agent: "vim")   // 未知 Agent 先失败
        }
    }

    @Test func copyModeProducesRealDirectory() throws {
        let (work, paths, home) = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: work) }
        _ = try makeSourceSkill(home: home, name: "pdf")
        let svc = AssemblyService(paths: paths, home: home)
        let project = work.appendingPathComponent("proj-z")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        _ = try svc.pull(name: "pdf", target: project.path, agent: "codex", copy: true)
        let landed = project.appendingPathComponent(".agents/skills/pdf")
        var isDir: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: landed.path, isDirectory: &isDir) && isDir.boolValue)
        let isLink = (try? landed.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) ?? false
        #expect(isLink == false)   // copy 模式：实体目录，不是链接
        #expect(FileManager.default.fileExists(atPath: landed.appendingPathComponent("SKILL.md").path))
    }

    @Test func twoProcessesWritingConcurrentlySerialize() throws {
        // 集成：双进程并发写（R3 锁生效）——两进程各 pull 不同 skill 到同一项目
        let (work, paths, home) = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: work) }
        _ = try makeSourceSkill(home: home, name: "aaa")
        _ = try makeSourceSkill(home: home, name: "bbb")
        let project = work.appendingPathComponent("proj-c")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)

        // 用两个线程模拟两进程写同一日志/事件文件（各自独立 WriteLock 实例 = 独立 fd）
        let group = DispatchGroup()
        for name in ["aaa", "bbb"] {
            group.enter()
            DispatchQueue.global().async {
                let svc = AssemblyService(paths: paths, home: home)
                _ = try? svc.pull(name: name, target: project.path, agent: "codex")
                group.leave()
            }
        }
        group.wait()

        // 两个落点都在、无覆盖损坏；事件 2 条；日志 2 条
        #expect(FileManager.default.fileExists(atPath: project.appendingPathComponent(".agents/skills/aaa").path))
        #expect(FileManager.default.fileExists(atPath: project.appendingPathComponent(".agents/skills/bbb").path))
        let evs = AssemblyEventStore(paths: paths, lock: WriteLock(paths: paths)).all()
        #expect(evs.count == 2)
        let (records, corrupt) = OperationLog(paths: paths).readAll()
        #expect(corrupt == 0 && records.count == 2)
    }

    /// #5（审计整改批）：mount 的类型守卫——MCP 不是可挂载对象（story-6 写侧未开）。
    /// 旧守卫只查名字不查类型，mount 一个 MCP 名会 land 成死链（挂上的链接指向不存在的实体）。
    /// 类型化报错 notASkill：只加守卫会把「存在但不是 Skill」谎报成 notFound（另一种假话）。
    @Test func mountRejectsMCPNameWithNotASkill() throws {
        let (work, paths, home) = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: work) }
        // 集合里放一个 skill 和一个 MCP：同名场景分开造，两个断言各自对照
        let src = try makeSourceSkill(home: home, name: "pdf")
        let mcpJSON = home.appendingPathComponent(".claude/mcp.json")
        try FileManager.default.createDirectory(at: mcpJSON.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "{\"mcpServers\":{\"pdfmcp\":{\"command\":\"uvx\"}}}".write(to: mcpJSON, atomically: true, encoding: .utf8)
        let locs = [DiscoveredLocation(path: src.deletingLastPathComponent().path, kind: .skillDirectory),
                    DiscoveredLocation(path: mcpJSON.path, kind: .mcpJSON)]
        DiscoveryCache(paths: paths).save(DiscoverySnapshot(
            savedAt: Date(), rules: AppSettings.load(paths: paths).discoveryRules,
            roots: [home.path], locations: locs))

        let svc = AssemblyService(paths: paths, home: home)
        // 前提自检：MCP 条目确实进了全集（夹具失效时这条先红，不假装测到了）
        #expect(svc.currentIndex().items.contains { $0.id == "mcp:pdfmcp" },
                "MCP 夹具必须先进索引，否则 notASkill 分支测不到")

        // ① mount MCP 名 → notASkill（不是 notFound，也不是假成功）
        #expect(throws: AssemblyService.AssemblyError.notASkill(name: "pdfmcp")) {
            _ = try svc.mount(name: "pdfmcp", on: "codex")
        }
        // ② mount Skill 名照旧成功（守卫不误伤）：mount 到 claude——
        // codex 用户级（.agents/skills）正是本体所在目录，落点自撞只会 skippedConflict
        let r = try svc.mount(name: "pdf", on: "claude")
        #expect(FileManager.default.fileExists(atPath: home.appendingPathComponent(".claude/skills/pdf").path))
        #expect(r.event.added.count == 1)
    }
}

extension AssemblyReport {
    var conflictsSummary: Int { event.conflicts.count }
}

/// 回归：项目根在符号链接目录下（如 /tmp → /private/tmp）时，相对链接必须仍可解析
struct SymlinkedAncestorRegressionTests {
    @Test func relativeLinkResolvesUnderSymlinkedTmp() throws {
        let real = FileManager.default.temporaryDirectory.appendingPathComponent("sc-sym-\(UUID().uuidString)")
        // real 在 /var/folders（本身经 /private 符号链接）下
        let home = real.appendingPathComponent("home")
        // 严格模式：pull 的源只从库解析——夹具种进 ~/.skill-library
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".skill-library/pdf"), withIntermediateDirectories: true)
        try "---\nname: pdf\ndescription: p\n---".write(to: home.appendingPathComponent(".skill-library/pdf/SKILL.md"), atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: real) }

        let svc = AssemblyService(paths: SkillControllerPaths(supportDir: real.appendingPathComponent("support")), home: home)
        // 造 /tmp→/private/tmp 同类场景：别名目录比真实路径少一层（符号链接会加层数）
        try FileManager.default.createDirectory(at: real.appendingPathComponent("long/sub"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: real.appendingPathComponent("up").path,
                                                   withDestinationPath: "long/sub")
        let project = real.appendingPathComponent("up/proj")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        _ = try svc.pull(name: "pdf", target: project.path, agent: "codex")

        let landed = project.appendingPathComponent(".agents/skills/pdf")
        // 关键断言：链接可解析到实体（悬空链接会让这里失败）
        var isDir: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: landed.path, isDirectory: &isDir) && isDir.boolValue)
        #expect(FileManager.default.fileExists(atPath: landed.appendingPathComponent("SKILL.md").path))
        // 重复 pull → 冲突跳过（不是 failed）
        let again = try svc.pull(name: "pdf", target: project.path, agent: "codex")
        guard case .skippedConflict = again.outcomes[0].status else {
            Issue.record("应为 skipped-conflict，实际 \(again.outcomes[0].status)")
            return
        }
    }
}

/// 验收面：装配→恢复往返、事件状态机（待验收/已验收/已恢复）
struct AssemblyReviewTests {
    private func sandbox() throws -> (work: URL, paths: SkillControllerPaths, home: URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sc-rev-\(UUID().uuidString)")
        let home = dir.appendingPathComponent("home")
        // 严格模式：pull 的源只从库解析——夹具种进 ~/.skill-library
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".skill-library/pdf"), withIntermediateDirectories: true)
        try "---\nname: pdf\ndescription: p\n---".write(to: home.appendingPathComponent(".skill-library/pdf/SKILL.md"), atomically: true, encoding: .utf8)
        return (dir, SkillControllerPaths(supportDir: dir.appendingPathComponent("support")), home)
    }

    @Test func acceptMarksReviewedWithoutTouchingDisk() throws {
        let (work, paths, home) = try sandbox()
        defer { try? FileManager.default.removeItem(at: work) }
        let svc = AssemblyService(paths: paths, home: home)
        let proj = work.appendingPathComponent("p"); try FileManager.default.createDirectory(at: proj, withIntermediateDirectories: true)
        let r = try svc.pull(name: "pdf", target: proj.path, agent: "codex")
        let landed = proj.appendingPathComponent(".agents/skills/pdf")
        let store = svc.eventStore
        #expect(store.all().first { $0.event.id == r.event.id }?.accepted == false)
        try store.markReviewed(eventId: r.event.id)
        let after = store.all().first { $0.event.id == r.event.id }
        #expect(after?.accepted == true && after?.event.reviewed == true)
        // 验收不动磁盘：链接仍在
        #expect(FileManager.default.fileExists(atPath: landed.path))
    }

    @Test func restoreAssemblyRemovesLandingAndMarksRestored() throws {
        let (work, paths, home) = try sandbox()
        defer { try? FileManager.default.removeItem(at: work) }
        let svc = AssemblyService(paths: paths, home: home)
        let proj = work.appendingPathComponent("p"); try FileManager.default.createDirectory(at: proj, withIntermediateDirectories: true)
        let r = try svc.pull(name: "pdf", target: proj.path, agent: "codex")
        let landed = proj.appendingPathComponent(".agents/skills/pdf")
        #expect(FileManager.default.fileExists(atPath: landed.path))

        let out = try svc.restoreAssembly(event: r.event)
        #expect(out.complete && out.restored == 1)
        #expect(!FileManager.default.fileExists(atPath: landed.path))     // 落点已卸下
        #expect(FileManager.default.fileExists(atPath: home.appendingPathComponent(".skill-library/pdf").path)) // 源在库里
        #expect(svc.eventStore.all().first { $0.event.id == r.event.id }?.restored == true)
        // 恢复本身也落日志（可再撤销的审计）
        #expect(OperationLog(paths: paths).entries().contains { $0.action.contains("恢复至") })
    }

    /// D15 口径：快照只覆盖这次装配的影响面。
    /// 原来哈希整盘条目 id，别家目录多出一个无关 skill 也会把这次验收锁死——
    /// 真机上「清单已更新」几乎必然出现，人根本点不下去「关闭并验收」。
    @Test func revisionIsScopedToAffectedDirs() throws {
        let (work, paths, home) = try sandbox()
        defer { try? FileManager.default.removeItem(at: work) }
        let proj = work.appendingPathComponent("p")
        let projSkills = proj.appendingPathComponent(".agents/skills")
        try FileManager.default.createDirectory(at: projSkills, withIntermediateDirectories: true)
        let shared = home.appendingPathComponent(".agents/skills")   // sandbox() 已在此放好 pdf

        // 真机上是 App 写发现缓存、CLI 读缓存；这里如法炮制，让两处目录都进 CLI 全集
        func seed(_ extra: [URL]) {
            var locs = [shared, projSkills].map { DiscoveredLocation(path: $0.path, kind: .skillDirectory) }
            locs += extra.map { DiscoveredLocation(path: $0.path, kind: .skillDirectory) }
            DiscoveryCache(paths: paths).save(DiscoverySnapshot(
                savedAt: Date(), rules: AppSettings.load(paths: paths).discoveryRules,
                roots: ["/"], locations: locs))
        }
        seed([])

        let svc = AssemblyService(paths: paths, home: home)
        let r = try svc.pull(name: "pdf", target: proj.path, agent: "codex")
        let stored = svc.eventStore.all().first { $0.event.id == r.event.id }!
        let scope = try #require(stored.revisionScope)   // 新事件必须带影响面
        #expect(scope.contains(proj.path))

        // 刚写入时影响面内版本一致（未过期）
        #expect(svc.currentRevision(within: scope) == stored.revision)
        // 跨实例（模拟另一个进程）读同一磁盘状态必须一致——不能用随机加盐的 hashValue
        #expect(AssemblyService(paths: paths, home: home).currentRevision(within: scope) == stored.revision)

        // 影响面**之外**变动：别家 Agent 在另一个目录装了东西 → 不该作废这次验收
        let elsewhere = work.appendingPathComponent("other/.agents/skills")
        try FileManager.default.createDirectory(at: elsewhere.appendingPathComponent("zzz"), withIntermediateDirectories: true)
        try "---\nname: zzz\ndescription: z\n---".write(to: elsewhere.appendingPathComponent("zzz/SKILL.md"), atomically: true, encoding: .utf8)
        seed([elsewhere])
        #expect(svc.currentRevision(within: scope) == stored.revision)

        // 影响面**之内**变动：同一个项目里又被挂了别的东西 → 快照过期，G3 该禁用验收
        let inside = projSkills.appendingPathComponent("inside")
        try FileManager.default.createDirectory(at: inside, withIntermediateDirectories: true)
        try "---\nname: inside\ndescription: i\n---".write(to: inside.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
        #expect(svc.currentRevision(within: scope) != stored.revision)
    }

    /// 影响面 = 项目根 + 每个落点所在目录（都取 canonical 键，/var 与软链项目才不会漏判）；
    /// 空事件（只检查没带东西）也要有可比的口径
    @Test func affectedDirsCoversProjectAndLandingParents() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sc-dirs-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let proj = dir.appendingPathComponent("p")
        let skills = proj.appendingPathComponent(".agents/skills")
        try FileManager.default.createDirectory(at: skills, withIntermediateDirectories: true)
        let landing = skills.appendingPathComponent("pdf").path

        let ev = AssemblyEvent(id: "e", date: "2026-09-22T00:00:00+08:00", agentId: "codex",
                               projectId: "proj-p", added: [landing],
                               removed: [skills.appendingPathComponent("docx").path],
                               conflicts: [], reviewed: false)
        let dirs = AssemblyService.affectedDirs(event: ev, projectPath: proj.path)
        #expect(dirs.contains(AssemblyService.pathKey(proj.path)))
        #expect(dirs.contains(AssemblyService.pathKey(skills.path)))
        #expect(dirs.count == 2)   // 两个落点同目录，不该重复计两份
        // 无项目（用户级挂载）时只剩落点目录
        let userLevel = AssemblyService.affectedDirs(event: AssemblyEvent(
            id: "e2", date: ev.date, agentId: "codex", projectId: "", added: [landing],
            removed: [], conflicts: [], reviewed: false), projectPath: nil)
        #expect(userLevel == [AssemblyService.pathKey(skills.path)])
    }
}

/// D7：unmount 必须进 diff 的"卸下"组（不是"挂上"）；恢复能撤销卸下（回挂）
struct UnmountDirectionTests {
    private func sb() throws -> (work: URL, paths: SkillControllerPaths, home: URL) {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("sc-dir-\(UUID().uuidString)")
        let home = d.appendingPathComponent("home")
        // 严格模式：pull 的源只从库解析——夹具种进 ~/.skill-library
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".skill-library/pdf"), withIntermediateDirectories: true)
        try "---\nname: pdf\ndescription: p\n---".write(to: home.appendingPathComponent(".skill-library/pdf/SKILL.md"), atomically: true, encoding: .utf8)
        return (d, SkillControllerPaths(supportDir: d.appendingPathComponent("support")), home)
    }

    @Test func unmountLandsInRemovedGroupNotAdded() throws {
        let (work, paths, home) = try sb()
        defer { try? FileManager.default.removeItem(at: work) }
        let svc = AssemblyService(paths: paths, home: home)
        // 先挂到 claude 用户级，再卸下
        _ = try svc.mount(name: "pdf", on: "claude")
        let link = home.appendingPathComponent(".claude/skills/pdf")
        let r = try svc.unmount(name: "pdf", on: "claude")
        #expect(r.event.removed == [link.path])          // 进"卸下"组
        #expect(r.event.added.isEmpty)                   // 不在"挂上"组
        #expect(!FileManager.default.fileExists(atPath: link.path))

        // 恢复该 unmount 事件 → 链接回挂
        let out = try svc.restoreAssembly(event: r.event)
        #expect(out.complete && out.restored == 1)
        #expect(FileManager.default.fileExists(atPath: link.path))
    }
}
