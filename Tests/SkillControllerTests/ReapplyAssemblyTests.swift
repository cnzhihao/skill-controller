import Testing
import Foundation
@testable import SkillControllerCore

/// D32=B：「全部恢复原状」这一步本身必须真能一步撤销。
///
/// 确认框那句「同样可以一步撤销」在 2026-09-23 之前是空话——恢复写进日志的那条
/// `reversible:false`，回退页的「恢复」按钮又只服务回收站条目，装配回滚过后再也回不去。
/// 现在恢复时把链接目标记在事件上（restoredLinks / restoredCopies），
/// 「重新挂回」按这张表重建。这组测试钉住四件事：
/// ① 能原样重建（含相对链接写法）；② 目标位被占时不覆盖、逐条如实报；
/// ③ 没有凭据的老记录不该出现这个动作；④ 部分恢复也要把凭据留下，否则那半截链接就丢了。
struct ReapplyAssemblyTests {
    private func makeSandbox() throws -> (work: URL, paths: SkillControllerPaths, home: URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sc-reapply-\(UUID().uuidString)")
        let home = dir.appendingPathComponent("home")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        return (dir, SkillControllerPaths(supportDir: dir.appendingPathComponent("support")), home)
    }

    private func makeSourceSkill(home: URL, name: String) throws -> URL {
        // 严格模式（裁决②）：pull 的源只从库解析——夹具随之种进 ~/.skill-library
        let dir = home.appendingPathComponent(".skill-library/\(name)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try "---\nname: \(name)\ndescription: src \(name)\n---".write(
            to: dir.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
        return dir
    }

    private func store(_ paths: SkillControllerPaths) -> AssemblyEventStore {
        AssemblyEventStore(paths: paths, lock: WriteLock(paths: paths))
    }

    @Test func restoreThenReapplyRebuildsTheSameRelativeLink() throws {
        let (work, paths, home) = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: work) }
        _ = try makeSourceSkill(home: home, name: "pdf")
        let svc = AssemblyService(paths: paths, home: home)
        let project = work.appendingPathComponent("proj-x")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let landed = project.appendingPathComponent(".agents/skills/pdf")

        let report = try svc.pull(name: "pdf", target: project.path, agent: "codex")
        let before = try FileManager.default.destinationOfSymbolicLink(atPath: landed.path)
        // 回看态的真实形状：先验收，再恢复
        try store(paths).markReviewed(eventId: report.event.id)

        let undone = try svc.restoreAssembly(event: report.event)
        #expect(undone.complete)
        #expect(!FileManager.default.fileExists(atPath: landed.path))   // lstat 语义：链接没了
        let afterRestore = store(paths).all()[0]
        #expect(afterRestore.restored)
        #expect(afterRestore.restoredLinks == [landed.path: before])    // 凭据当场记下

        let outcome = try svc.reapplyRestoredAssembly(eventId: report.event.id)
        #expect(outcome.complete)
        #expect(outcome.restored == 1)
        // 原样重建：目标写法（相对就还是相对）与恢复前一字不差
        let rebuilt = try FileManager.default.destinationOfSymbolicLink(atPath: landed.path)
        #expect(rebuilt == before)
        let afterReapply = store(paths).all()[0]
        #expect(!afterReapply.restored)                 // 磁盘回到装配后的样子
        #expect(afterReapply.accepted)                  // 已验收这件事不因撤销而回退
        #expect(afterReapply.restoredLinks == nil)      // 用掉的凭据不留残渣
        // 回执上日志：LogEntry.action 装的是人读那句（见 OperationLog.toEntry）
        let logs = OperationLog(paths: paths).entries()
        #expect(logs.contains(where: { $0.actor == "智昊" && $0.action.contains("重新挂回") }))
    }

    @Test func reapplyRefusesToOverwriteAnOccupiedLanding() throws {
        let (work, paths, home) = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: work) }
        _ = try makeSourceSkill(home: home, name: "pdf")
        let svc = AssemblyService(paths: paths, home: home)
        let project = work.appendingPathComponent("proj-x")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let landed = project.appendingPathComponent(".agents/skills/pdf")

        let report = try svc.pull(name: "pdf", target: project.path, agent: "codex")
        _ = try svc.restoreAssembly(event: report.event)
        // 恢复之后有人在那个位置放了个实体目录（Agent 自己装的、或人手放的）
        try FileManager.default.createDirectory(at: landed, withIntermediateDirectories: true)
        try "mine".write(to: landed.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)

        let outcome = try svc.reapplyRestoredAssembly(eventId: report.event.id)
        #expect(outcome.restored == 0)
        #expect(outcome.failed.count == 1)
        #expect(outcome.failed[0].reason.contains("已被占用"))
        // 不覆盖：那个实体目录还在、内容没被动
        let kept = try String(contentsOf: landed.appendingPathComponent("SKILL.md"), encoding: .utf8)
        #expect(kept == "mine")
        // 没做成就不该清凭据，也不该把"已恢复"标记悄悄改掉
        let stored = store(paths).all()[0]
        #expect(stored.restored)
        #expect(stored.restoredLinks?.keys.contains(landed.path) == true)
    }

    @Test func oldRestoredEventWithoutCredentialsOffersNothingAndStillDecodes() throws {
        let (work, paths, _) = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: work) }
        let svc = AssemblyService(paths: paths, home: work.appendingPathComponent("home"))
        try paths.ensureDirs()
        let event = AssemblyEvent(id: "e-old", date: LogRecord.nowISO(), agentId: "codex", projectId: "proj-x",
                                  added: ["/nope/.agents/skills/pdf"], removed: [], conflicts: [], reviewed: true)
        // 手写一条本次改动之前格式的旧事件：没有 restoredLinks / restoredCopies 两个键
        let legacy = #"{"event":{"id":"e-old","date":"\#(event.date)","agentId":"codex","projectId":"proj-x","added":["/nope/.agents/skills/pdf"],"removed":[],"conflicts":[],"reviewed":true},"revision":7,"revisionScope":["/nope"],"accepted":true,"restored":true}"#
        try (legacy + "\n").data(using: .utf8)!.write(to: paths.assemblyEventsFile)

        let loaded = store(paths).all()
        #expect(loaded.count == 1)                       // 解码没炸，Banner 数据源还在
        #expect(loaded[0].restoredLinks == nil)
        #expect(loaded[0].reapplyableCount == 0)         // 界面据此不出现「重新挂回」

        let outcome = try svc.reapplyRestoredAssembly(eventId: "e-old")
        #expect(outcome.restored == 0)
        #expect(outcome.failed.first?.reason.contains("没有留下可重建") == true)
    }

    @Test func partialRestoreStillKeepsTheCredentialsOfWhatWasRemoved() throws {
        let (work, paths, home) = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: work) }
        _ = try makeSourceSkill(home: home, name: "pdf")
        _ = try makeSourceSkill(home: home, name: "docx")
        let svc = AssemblyService(paths: paths, home: home)
        let project = work.appendingPathComponent("proj-x")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let landedPdf = project.appendingPathComponent(".agents/skills/pdf")
        let landedDocx = project.appendingPathComponent(".agents/skills/docx")

        let report = try svc.pull(name: "pdf", target: project.path, agent: "codex")
        _ = try svc.pull(name: "docx", target: project.path, agent: "codex")
        // 伪造一条"动了两个落点"的事件，其中一个在验收前就被人手工删了
        let two = AssemblyEvent(id: report.event.id, date: report.event.date, agentId: "codex",
                                projectId: report.event.projectId,
                                added: [landedPdf.path, landedDocx.path],
                                removed: [], conflicts: [], reviewed: true)
        try FileManager.default.removeItem(atPath: landedDocx.path)
        // 凭据要在恢复之前取——链接马上就没了
        let pdfDest = try FileManager.default.destinationOfSymbolicLink(atPath: landedPdf.path)

        let outcome = try svc.restoreAssembly(event: two)
        #expect(outcome.restored == 1)
        #expect(outcome.failed.count == 1)               // 那个已经不在的，如实报
        let stored = store(paths).all()[0]
        #expect(!stored.restored)                        // 没全成就还不算"已恢复"
        #expect(stored.restoredLinks == [landedPdf.path: pdfDest])
        // 摘掉的那一半仍然挂得回来
        let back = try svc.reapplyRestoredAssembly(eventId: two.id)
        #expect(back.restored == 1)
        #expect(FileManager.default.fileExists(atPath: landedPdf.path))
    }
}
