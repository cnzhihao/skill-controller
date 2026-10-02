import Testing
import Foundation
@testable import SkillControllerCore

/// D14：删除的三步（搬落点 / 写 manifest / 落日志）不是原子的。
/// 真机踩到的形状是"文件已进回收站、manifest 已写、日志里没有那条删除"，
/// 而 UI 当时说的是「删除失败」——三步齐要么全成，要么把动过的原样放回去。
///
/// #6b（并发模型 §6，审计整改批）：undoAll 在放不回的落点存在时必须**保留整个 entryDir**——
/// manifest + files/ 是后续重试恢复的唯一凭据（occupied 守卫防重复放回）；
/// 全部放回成功（leftovers 为空）才清 entryDir。
struct TrashRollbackTests {
    private func makeSandbox() throws -> (work: URL, paths: SkillControllerPaths, home: URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sc-rb2-\(UUID().uuidString)")
        let home = dir.appendingPathComponent("home")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        return (dir, SkillControllerPaths(supportDir: dir.appendingPathComponent("support")), home)
    }

    private func writeSkill(_ url: URL, name: String) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try "---\nname: \(name)\ndescription: d\n---".write(to: url.appendingPathComponent("SKILL.md"),
                                                            atomically: true, encoding: .utf8)
    }

    /// 注入故障：把日志文件做成一个目录 → `log.append` 必然抛错
    private func breakLogFile(_ paths: SkillControllerPaths) throws {
        try paths.ensureDirs()
        try FileManager.default.createDirectory(at: paths.logFile, withIntermediateDirectories: false)
    }

    @Test func deleteRollsBackEverythingWhenLoggingFails() throws {
        let (work, paths, home) = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: work) }
        let fm = FileManager.default

        // 一个实体源 + 一个指向它的 symlink 落点（两种落点都要能放回去）
        let entity = home.appendingPathComponent(".agents/skills/docx")
        try writeSkill(entity, name: "docx")
        let linkDir = home.appendingPathComponent(".claude/skills")
        try fm.createDirectory(at: linkDir, withIntermediateDirectories: true)
        let link = linkDir.appendingPathComponent("docx")
        try fm.createSymbolicLink(atPath: link.path, withDestinationPath: "../../.agents/skills/docx")
        let entityBefore = try Data(contentsOf: entity.appendingPathComponent("SKILL.md"))

        try breakLogFile(paths)
        let trash = TrashManager(paths: paths)
        let item = InventoryItem(id: "skill:docx", name: "docx", description: "", type: .skill,
                                 level: .user, sourcePath: entity.path, mountedBy: ["codex"],
                                 duplicates: [link.path], status: .mounted)

        #expect(throws: (any Error).self) { _ = try trash.trash(item: item, actor: "智昊") }

        // 全有或全无：两个落点都还在原样，回收站里不留半成品
        #expect(fm.fileExists(atPath: entity.path))
        #expect(try Data(contentsOf: entity.appendingPathComponent("SKILL.md")) == entityBefore)
        #expect(try fm.destinationOfSymbolicLink(atPath: link.path) == "../../.agents/skills/docx")
        #expect(trash.listEntries().isEmpty)
    }

    /// `rollbackFailed`（回滚自己也失败）分支的覆盖方式（2026-09-26 #6b 起以用例为证）：
    /// 它要求"落点已搬走、原位又被别人占住"——失败分支没有纯同步注入点（perform 刚搬走落点、
    /// 原位必然空），见下方 failedRollbackKeepsArchiveEntryDir：后台占位线程与回滚窗口竞争，
    /// 排队拉宽窗口 + 3 次重试；占位没挤进窗口时判定线没测到，如实用 withKnownIssue 标注，
    /// 不把「没测到」渲染成红或绿。该分支本身只做一件事——把放不回去的路径拼进错误里交出去，绝不静默。
    /// 正常路径不受影响：日志能写时，manifest 一开始就带上 logRecordId（不再二次改写）
    @Test func happyPathWritesManifestWithLogAnchorInOneGo() throws {
        let (work, paths, home) = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: work) }
        let entity = home.appendingPathComponent(".agents/skills/pdf")
        try writeSkill(entity, name: "pdf")
        let trash = TrashManager(paths: paths)
        let m = try trash.trash(item: InventoryItem(id: "skill:pdf", name: "pdf", description: "",
                                                    type: .skill, level: .user, sourcePath: entity.path,
                                                    mountedBy: [], status: .zeroMount), actor: "智昊")
        #expect(m.logRecordId != nil)
        #expect(OperationLog(paths: paths).entries().contains { $0.target == "skill:pdf" })
        let out = try trash.restore(m)
        #expect(out.complete && FileManager.default.fileExists(atPath: entity.path))
    }

    // MARK: - #6b（并发模型 §6）：回滚存档保留
    // 用例自 UndoAllArchiveTests 迁入（AC #6② 的锚点文件 = TrashRollbackTests）；
    // undoAll 是 trash() 的嵌套局部函数，测试边界见上段注释与用例内标注。

    /** 失败路径：回滚撞原位占位 → rollbackFailed，且 **entryDir 保留**（存档不二次销毁）。
        改前 undoAll 无条件 removeItem(entryDir)，失败路径上把 manifest+files 也清了——
        重试恢复的唯一凭据被销毁。改后 entryDir 留着，且 restore 重试在 occupied 守卫下
        不覆盖原位新文件、如实报部分失败（并发模型 §6 的「保留」前提）。 */
    @Test func failedRollbackKeepsArchiveEntryDir() throws {
        let (work, paths, home) = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: work) }
        let fm = FileManager.default

        // 24 个实体落点（同一条目），最后一个是我们等它被占住的目标
        let dirBase = home.appendingPathComponent(".agents/skills")
        var allPaths: [String] = []
        for i in 0..<24 {
            let d = dirBase.appendingPathComponent("chunk\(i)")
            try writeSkill(d, name: "chunk\(i)")
            allPaths.append(d.path)
        }
        let entity = dirBase.appendingPathComponent("chunk23")
        let 占位完成 = DispatchSemaphore(value: 0)
        let stop = NSLock()
        var stopFlag = false

        let trash = TrashManager(paths: paths)
        let item = InventoryItem(id: "skill:docx", name: "docx", description: "", type: .skill,
                                 level: .user, sourcePath: dirBase.appendingPathComponent("chunk0").path,
                                 mountedBy: [], duplicates: Array(allPaths.dropFirst()), status: .mounted)

        // 占位线程：目标落点一消失就占住原位（目录 + 同名 SKILL.md）
        let contender = DispatchQueue.global().async {
            while true {
                stop.lock(); let done = stopFlag; stop.unlock()
                if done { break }
                if !fm.fileExists(atPath: entity.path) {
                    try? fm.createDirectory(at: entity, withIntermediateDirectories: true)
                    try? "占位".write(toFile: entity.appendingPathComponent("SKILL.md").path,
                                      atomically: true, encoding: .utf8)
                    占位完成.signal()
                    break
                }
                usleep(200)
            }
        }
        defer {
            stop.lock(); stopFlag = true; stop.unlock()
            _ = 占位完成.wait(timeout: .now() + 2)
            _ = contender
        }

        // 竞争没挤进窗口时重试（最多 3 次）；仍未中就如实标注「没测到」，不渲染成败
        var archived: TrashManifest?
        var detail = ""
        var attempts = 0
        while attempts < 3 {
            attempts += 1
            // 重置 support 面（含上一轮的故障日志目录）再重新注入故障（重置失败不致命，try? 兜底）
            if fm.fileExists(atPath: paths.logFile.path) {
                try? fm.removeItem(at: paths.logFile)
            }
            try? fm.removeItem(at: paths.trashDir)
            try? paths.ensureDirs()
            try? fm.createDirectory(at: paths.logFile, withIntermediateDirectories: false)
            do {
                _ = try trash.trash(item: item, actor: "智昊")
                continue                                       // 占位没赶上 → 回滚全成 → 重试
            } catch {
                if case let TrashError.rollbackFailed(d) = error {
                    detail = d
                    archived = trash.listEntries().first { $0.itemName == "docx" }
                    break
                }
                continue
            }
        }

        guard let m = archived else {
            Testing.withKnownIssue {
                Issue.record(Comment(rawValue: "竞争 3 次未挤进回滚窗口——失败分支本轮没测到（不渲染成败）"))
            }
            return
        }

        #expect(detail.contains("没能放回原位"), Comment(rawValue: "错误信息列全放不回的路径（既有行为）"))

        // #6b 的核心断言：存档保留——manifest 与 files/ 都还在 entryDir 里
        let entryDir = paths.trashDir.appendingPathComponent(m.entryId)
        #expect(fm.fileExists(atPath: entryDir.appendingPathComponent("manifest.json").path),
                Comment(rawValue: "回滚失败后 manifest 必须保留（改前被 undoAll 无条件清掉）"))
        #expect(!m.locations.isEmpty)
        let filesCount = (try? fm.contentsOfDirectory(atPath: entryDir.appendingPathComponent("files").path))?.count ?? 0
        #expect(filesCount > 0, Comment(rawValue: "entryDir 保留的 files/ 里还有没放回的落点实体"))

        // 保留的意义可兑现：occupied 守卫下重试 restore 不覆盖原位占位文件、部分失败如实报。
        // （先修好日志面：restore 也要落日志，带着故障目录去 restore 会把 512 抛出测试体外）
        try? fm.removeItem(at: paths.logFile)
        try? paths.ensureDirs()
        let out = try trash.restore(m)
        #expect(!out.complete)
        #expect(out.failed.contains { $0.reason.contains("占用") })
        #expect(fm.fileExists(atPath: entity.appendingPathComponent("SKILL.md").path),
                Comment(rawValue: "原位占位文件未被覆盖"))
    }

    /** 成功路径（leftovers 为空）：entryDir 照旧清掉——保留语义不得让正常回滚留下垃圾目录。 */
    @Test func successfulRollbackStillClearsEntryDir() throws {
        let (work, paths, home) = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: work) }
        let fm = FileManager.default

        let entity = home.appendingPathComponent(".agents/skills/pdf")
        try writeSkill(entity, name: "pdf")

        try breakLogFile(paths)
        let trash = TrashManager(paths: paths)
        let item = InventoryItem(id: "skill:pdf", name: "pdf", description: "",
                                 type: .skill, level: .user, sourcePath: entity.path, mountedBy: [],
                                 status: .mounted)

        // 没有竞争者 → 回滚全部放回成功（leftovers 为空）→ 抛原始错误、entryDir 清掉
        #expect(throws: (any Error).self) { _ = try trash.trash(item: item, actor: "智昊") }

        #expect(fm.fileExists(atPath: entity.path), Comment(rawValue: "实体已放回原位"))
        #expect(trash.listEntries().isEmpty, Comment(rawValue: "成功回滚不残留 entryDir"))
        let trashRoot = try #require(try? fm.contentsOfDirectory(atPath: paths.trashDir.path))
        #expect(trashRoot.isEmpty, Comment(rawValue: "回收站根目录为空（无半成品）"))
    }

    // MARK: - #14（D41）：归档缺失时恢复按钮不撒谎

    /** 实体归档内容被外部移走（空壳还在）→ isRestorable false；内容在 → true。
        改前只查 `fileExists(壳)`——S12 真机移走内容后「恢复」仍可点。 */
    @Test func emptiedArchiveIsNotRestorable() throws {
        let (work, paths, home) = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: work) }
        let fm = FileManager.default
        let entity = home.appendingPathComponent(".agents/skills/pdf")
        try writeSkill(entity, name: "pdf")
        let trash = TrashManager(paths: paths)
        let m = try trash.trash(item: InventoryItem(id: "skill:pdf", name: "pdf", description: "",
                                                    type: .skill, level: .user, sourcePath: entity.path,
                                                    mountedBy: [], status: .zeroMount), actor: "智昊")
        #expect(trash.isRestorable(m))   // 内容在 → 可恢复

        // 外部把归档内容移走，只留空壳目录
        let storedDir = paths.trashDir.appendingPathComponent(m.entryId)
            .appendingPathComponent("files/0/pdf")
        try #require(fm.fileExists(atPath: storedDir.path))
        try fm.removeItem(at: storedDir)
        try fm.createDirectory(at: storedDir, withIntermediateDirectories: true)
        #expect(!trash.isRestorable(m), Comment(rawValue: "空壳必须判不可恢复（改前返回 true）"))
    }

    /** 空壳 restore → 该落点 failed「归档内容缺失」且 outcome 如实（G4 部分失败如实报）。
        isRestorable 在 API 层不许撒谎：按钮禁用了，restore 也不能把空壳「恢复成功」搬回原位。 */
    @Test func restoringEmptiedArchiveReportsFailureNotSuccess() throws {
        let (work, paths, home) = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: work) }
        let fm = FileManager.default
        let entity = home.appendingPathComponent(".agents/skills/pdf")
        try writeSkill(entity, name: "pdf")
        let trash = TrashManager(paths: paths)
        let m = try trash.trash(item: InventoryItem(id: "skill:pdf", name: "pdf", description: "",
                                                    type: .skill, level: .user, sourcePath: entity.path,
                                                    mountedBy: [], status: .zeroMount), actor: "智昊")
        let storedDir = paths.trashDir.appendingPathComponent(m.entryId)
            .appendingPathComponent("files/0/pdf")
        try fm.removeItem(at: storedDir)
        try fm.createDirectory(at: storedDir, withIntermediateDirectories: true)

        let out = try trash.restore(m)
        #expect(!out.complete)
        #expect(out.restored == 0)
        #expect(out.failed.count == 1)
        #expect(out.failed[0].reason == "归档内容缺失")
        #expect(out.failed[0].path == entity.path)
        #expect(fm.fileExists(atPath: storedDir.path), Comment(rawValue: "空壳保留（可重试/人工处置的凭据）"))
    }

    /** 纯 symlink 落点 + manifest 在 → isRestorable true（链接重建凭据是 linkTarget，
        不依赖归档内容——给 symlink 加内容检查会把「本来能恢复」判成不能）；manifest 缺 → false。 */
    @Test func symlinkLocationsJudgeByManifestNotArchiveContent() throws {
        let (work, paths, home) = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: work) }
        let fm = FileManager.default
        let link = home.appendingPathComponent(".claude/skills/pdf")
        try fm.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.createSymbolicLink(atPath: link.path, withDestinationPath: "/somewhere/real/pdf")
        let trash = TrashManager(paths: paths)
        let m = try trash.trash(item: InventoryItem(id: "skill:pdf", name: "pdf", description: "",
                                                    type: .skill, level: .user, sourcePath: link.path,
                                                    mountedBy: ["claude"], status: .mounted), actor: "智昊")
        #expect(trash.isRestorable(m), Comment(rawValue: "symlink 只看 manifest，不看归档内容"))
        // manifest 消失 → 不可恢复
        try fm.removeItem(at: paths.trashDir.appendingPathComponent(m.entryId)
            .appendingPathComponent("manifest.json"))
        #expect(!trash.isRestorable(m))
    }

    // MARK: - #15（D36）：全量落点并入删除清单

    /** 实体源 + 物理副本 + symlink 落点（additionalPaths 传入）→ manifest 3 项；
        restore 后磁盘 diff 为空、symlink 按 linkTarget 重建（恢复分母随之变全，S13 翻转）。 */
    @Test func additionalPathsLandInManifestAndRestoreRebuildsEverything() throws {
        let (work, paths, home) = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: work) }
        let fm = FileManager.default
        let entity = home.appendingPathComponent(".agents/skills/docx")
        try writeSkill(entity, name: "docx")
        // 物理副本（duplicates）
        let copy = home.appendingPathComponent(".cursor/skills/docx")
        try writeSkill(copy, name: "docx")
        // symlink 落点（只在 spots 里，duplicates 没有它——正是 S13 的形状）
        let link = home.appendingPathComponent(".claude/skills/docx")
        try fm.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.createSymbolicLink(atPath: link.path, withDestinationPath: "../../.agents/skills/docx")

        let trash = TrashManager(paths: paths)
        let m = try trash.trash(
            item: InventoryItem(id: "skill:docx", name: "docx", description: "", type: .skill,
                                level: .user, sourcePath: entity.path, mountedBy: ["codex"],
                                duplicates: [copy.path], status: .mounted),
            actor: "智昊",
            additionalPaths: [link.path])
        #expect(m.locations.count == 3, Comment(rawValue: "manifest 必须含全部三类落点"))
        #expect(m.locations.contains { $0.originalPath == link.path && $0.isSymlink && $0.linkTarget != nil })
        #expect(!fm.fileExists(atPath: link.path), Comment(rawValue: "symlink 已卸下"))
        // 实体已整体移入回收站（删除语义）；C3「源未伤」的判定点在恢复后（下面 diff 为空 + 链接复原）
        #expect(!fm.fileExists(atPath: entity.appendingPathComponent("SKILL.md").path))

        // 恢复：磁盘 diff 为空——实体、副本回位，链接按 linkTarget 重建
        let out = try trash.restore(m)
        #expect(out.complete && out.restored == 3)
        #expect(fm.fileExists(atPath: entity.appendingPathComponent("SKILL.md").path))
        #expect(fm.fileExists(atPath: copy.appendingPathComponent("SKILL.md").path))
        #expect(try fm.destinationOfSymbolicLink(atPath: link.path) == "../../.agents/skills/docx")
        #expect(trash.listEntries().isEmpty)
    }

    /** additionalPaths 与 duplicates 交叉（同一路径两个来源都算过）→ 去重，manifest 不重复计。 */
    @Test func overlappingAdditionalPathsAreDeduped() throws {
        let (work, paths, home) = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: work) }
        let entity = home.appendingPathComponent(".agents/skills/pdf")
        try writeSkill(entity, name: "pdf")
        let trash = TrashManager(paths: paths)
        let m = try trash.trash(
            item: InventoryItem(id: "skill:pdf", name: "pdf", description: "", type: .skill,
                                level: .user, sourcePath: entity.path, mountedBy: [], status: .zeroMount),
            actor: "智昊",
            additionalPaths: [entity.path])   // 与 sourcePath 相同——只许计一次
        #expect(m.locations.count == 1)
    }

    /** D14 全有或全无覆盖 additionalPaths 形状的 symlink（AC #15①：回滚覆盖新增落点）。
        日志故障注入 → 中途失败 → 已卸下的 symlink 必须按 linkTarget 原样重建，不留半态。 */
    @Test func rollbackRebuildsSymlinksPassedViaAdditionalPaths() throws {
        let (work, paths, home) = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: work) }
        let fm = FileManager.default
        let entity = home.appendingPathComponent(".agents/skills/docx")
        try writeSkill(entity, name: "docx")
        let link = home.appendingPathComponent(".claude/skills/docx")
        try fm.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.createSymbolicLink(atPath: link.path, withDestinationPath: "../../.agents/skills/docx")

        try breakLogFile(paths)   // 日志必然失败 → perform 抛错 → undoAll 全量回滚
        let trash = TrashManager(paths: paths)
        let item = InventoryItem(id: "skill:docx", name: "docx", description: "", type: .skill,
                                 level: .user, sourcePath: entity.path, mountedBy: ["codex"],
                                 status: .mounted)
        #expect(throws: (any Error).self) {
            _ = try trash.trash(item: item, actor: "智昊", additionalPaths: [link.path])
        }
        // 全有或全无：symlink 原样回位（additionalPaths 与 duplicates 落点在回滚路径上无差别）
        #expect(try fm.destinationOfSymbolicLink(atPath: link.path) == "../../.agents/skills/docx")
        #expect(fm.fileExists(atPath: entity.appendingPathComponent("SKILL.md").path))
        #expect(trash.listEntries().isEmpty)
    }
}
