import Testing
import Foundation
@testable import SkillControllerCore

/// Phase 2 底线件测试：日志↔回收站恢复往返（磁盘状态 diff 为空）、并发写锁、
/// G4 部分恢复、G7 二次删除（恢复按钮不撒谎的数据源）
struct RollbackTests {
    private func makeSandbox() throws -> (work: URL, paths: SkillControllerPaths) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sc-rb-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return (dir, SkillControllerPaths(supportDir: dir.appendingPathComponent("support")))
    }

    /// 造一个含嵌套结构的 skill 目录
    private func makeSkill(root: URL, name: String, files: [String: String]) throws -> URL {
        let dir = root.appendingPathComponent(name)
        for (rel, content) in files {
            let f = dir.appendingPathComponent(rel)
            try FileManager.default.createDirectory(at: f.deletingLastPathComponent(), withIntermediateDirectories: true)
            try content.write(to: f, atomically: true, encoding: .utf8)
        }
        return dir
    }

    private func snapshot(_ dir: URL) throws -> [String: String] {
        let fm = FileManager.default
        let base = dir.standardizedFileURL.path
        guard let en = fm.enumerator(at: dir, includingPropertiesForKeys: nil) else { return [:] }
        var out: [String: String] = [:]
        for case let f as URL in en {
            let rel = f.path.replacingOccurrences(of: base + "/", with: "")
            if (try? f.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true { continue }
            out[rel] = (try? String(contentsOf: f, encoding: .utf8)) ?? "<unread>"
        }
        return out
    }

    private func item(name: String, path: String, dup: [String] = []) -> InventoryItem {
        InventoryItem(id: "skill:\(name)", name: name, description: "", type: .skill, level: .user,
                      sourcePath: path, mountedBy: ["codex"], duplicates: dup, status: .mounted)
    }

    @Test func deleteRestoreRoundTripKeepsDiskIdentical() throws {
        let (sandbox, paths) = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox) }
        let skills = sandbox.appendingPathComponent("skills")
        try FileManager.default.createDirectory(at: skills, withIntermediateDirectories: true)
        let skillDir = try makeSkill(root: skills, name: "docx",
                                     files: ["SKILL.md": "---\nname: docx\n---", "scripts/a.sh": "echo hi", "references/x.md": "深一层"])
        let before = try snapshot(skillDir)
        #expect(before.count == 3)

        let trash = TrashManager(paths: paths)
        let m = try trash.trash(item: item(name: "docx", path: skillDir.path), actor: "codex")
        #expect(!FileManager.default.fileExists(atPath: skillDir.path)) // 已入回收站
        #expect(m.locations.count == 1)

        let out = try trash.restore(m)
        #expect(out.complete && out.restored == 1)
        let after = try snapshot(skillDir)
        #expect(after == before) // 磁盘状态 diff 为空（硬规则 8）

        // 审计链闭合：原删除记录 restored==true，且存在恢复记录
        let entries = OperationLog(paths: paths).entries()
        #expect(entries.contains { $0.action.contains("删除") && $0.restored == true })
        #expect(entries.contains { $0.action.contains("已恢复") })
    }

    @Test func symlinkLandingOnlyRemovesLink() throws {
        let (sandbox, paths) = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox) }
        let fm = FileManager.default
        let source = try makeSkill(root: sandbox, name: "dbs", files: ["SKILL.md": "---\nname: dbs\n---"])
        let link = sandbox.appendingPathComponent("claude-skills/dbs")
        try fm.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
        // 真实数据里 symlink 多为相对路径（如 ../../.agents/skills/x）
        try fm.createSymbolicLink(atPath: link.path, withDestinationPath: "../dbs")

        let trash = TrashManager(paths: paths)
        let m = try trash.trash(item: item(name: "dbs", path: link.path), actor: "claude")
        #expect(m.locations[0].isSymlink)
        #expect(!fm.fileExists(atPath: link.path))          // 链接没了
        #expect(fm.fileExists(atPath: source.path))          // C3：源还在

        let out = try trash.restore(m)
        #expect(out.complete)
        let dest = try? fm.destinationOfSymbolicLink(atPath: link.path)
        #expect(dest == "../dbs")                            // 相对链接原样复原
        #expect(fm.fileExists(atPath: source.path))           // 源完好
    }

    @Test func partialRestoreReportsHonestly() throws {
        // G4：恢复时原位置被占 → 该项失败留日志可重试，Banner 进"部分恢复"态
        let (sandbox, paths) = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox) }
        let fm = FileManager.default
        let a = try makeSkill(root: sandbox, name: "item-a", files: ["SKILL.md": "a"])
        let b = try makeSkill(root: sandbox, name: "item-b", files: ["SKILL.md": "b"])
        let trash = TrashManager(paths: paths)
        let m = try trash.trash(item: item(name: "multi", path: a.path, dup: [b.path]), actor: "codex")
        #expect(m.locations.count == 2)

        // 占位：在 b 原位置放一个同名目录
        try fm.createDirectory(at: b, withIntermediateDirectories: true)
        try "occupant".write(to: b.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)

        let out = try trash.restore(m)
        #expect(out.restored == 1)
        #expect(out.failed.count == 1)
        #expect(out.failed[0].reason == "原位置已被占用")
        // 部分恢复：回收站条目保留（可重试）
        #expect(trash.listEntries().contains { $0.entryId == m.entryId })
        let entries = OperationLog(paths: paths).entries()
        #expect(entries.contains { $0.action.contains("项已恢复") })
    }

    @Test func emptiedTrashReportsVanished() throws {
        // G7：回收站被 Finder 清空 → 恢复不可用 + 行内"目标已不存在"
        let (sandbox, paths) = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox) }
        let skill = try makeSkill(root: sandbox, name: "gone", files: ["SKILL.md": "g"])
        let trash = TrashManager(paths: paths)
        let m = try trash.trash(item: item(name: "gone", path: skill.path), actor: "codex")

        // 模拟 Finder 清空回收站
        try FileManager.default.removeItem(at: paths.trashDir.appendingPathComponent(m.entryId))
        #expect(!trash.isRestorable(m))
        #expect(throws: TrashError.targetVanished(path: m.id)) {
            _ = try trash.restore(m)
        }
        // 日志保留仅作审计
        #expect(OperationLog(paths: paths).entries().contains { $0.action.contains("删除") })
    }

    @Test func concurrentWritesSerializeViaLock() throws {
        // R3：双进程/双线程并发写 → 锁生效，全部落盘不丢行
        let (sandbox, paths) = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox) }
        let log = OperationLog(paths: paths)
        let iterations = 50
        let barrier = DispatchBarrier(count: 2)
        let queue1 = DispatchQueue(label: "w1"), queue2 = DispatchQueue(label: "w2")
        let group = DispatchGroup()
        for actor in ["codex", "claude"] {
            group.enter()
            let q = actor == "codex" ? queue1 : queue2
            q.async {
                barrier.wait()
                for i in 0..<iterations {
                    try? log.append(LogRecord(actor: actor, actorKind: .agent, action: .mount,
                                              detail: "m\(i)", target: "t\(i)", reversible: true))
                }
                group.leave()
            }
        }
        group.wait()
        let (records, corrupt) = log.readAll()
        #expect(corrupt == 0)
        #expect(records.count == iterations * 2) // 无丢行 = 锁串行化生效
        print("GOT:", records.count, "codex:", records.filter{$0.actor=="codex"}.count, "claude:", records.filter{$0.actor=="claude"}.count, "corrupt:", corrupt)
    }

    @Test func retentionWindowIsAtLeast30Days() throws {
        let (sandbox, _) = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox) }
        // 默认 30 天；配置只可放大（"宁长勿短"）
        #expect(AppSettings().trashRetentionDays == 30)
        #expect(AppSettings(trashRetentionDays: 7).trashRetentionDays == 30)
        #expect(AppSettings(trashRetentionDays: 90).trashRetentionDays == 90)
    }
}

/// 简易两方屏障（并发测试用）
final class DispatchBarrier: @unchecked Sendable {
    private let group: DispatchGroup = .init()
    private var arrived = 0
    private let lock = NSLock()
    private let target: Int

    init(count: Int) { target = count }

    func wait() {
        lock.lock()
        arrived += 1
        let done = arrived >= target
        lock.unlock()
        if !done {
            // 自旋等待另一线程到达（测试专用，量小）
            while true {
                lock.lock(); let a = arrived; lock.unlock()
                if a >= target { break }
                usleep(500)
            }
        }
    }
}
