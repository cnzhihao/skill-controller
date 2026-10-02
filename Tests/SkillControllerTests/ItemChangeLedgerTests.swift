import Testing
import Foundation
@testable import SkillControllerCore

/// 详情栏「挂载变动」与增量监听根的数据口径测试
/// （这两处此前是写死的：变动恒显示"近 90 天无变动"、监听根里没有 skillctl 的事件文件）
struct ItemChangeLedgerTests {
    private func makePaths() throws -> (work: URL, paths: SkillControllerPaths) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sc-ledger-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return (dir, SkillControllerPaths(supportDir: dir.appendingPathComponent("support")))
    }

    /// 删除记录以 item.id 为 target；回收站恢复也是（manifest.id == 条目 id）
    @Test func deleteAndRestoreRecordsMatchItemById() throws {
        let (sandbox, paths) = try makePaths()
        defer { try? FileManager.default.removeItem(at: sandbox) }
        let log = OperationLog(paths: paths)

        try log.append(LogRecord(actor: "智昊", actorKind: .human, action: .delete,
                                 detail: "删除 docx（2 个落点移入回收站）", target: "skill:docx", reversible: true))
        let delId = log.readAll().records[0].id
        try log.append(LogRecord(actor: "智昊", actorKind: .human, action: .restore,
                                  detail: "已恢复 docx（2 个落点回位）", target: "skill:docx",
                                  reversible: false, restoredOf: delId))
        try log.append(LogRecord(actor: "智昊", actorKind: .human, action: .delete,
                                 detail: "删除 pdf（1 个落点移入回收站）", target: "skill:pdf", reversible: true))

        let hits = log.entries(involvingItemId: "skill:docx", landingPaths: [])
        #expect(hits.count == 2)
        #expect(hits.first?.action.contains("已恢复") == true)          // 倒序：恢复在前
        #expect(hits.contains(where: { $0.restored == true }) == true)   // 审计链推导仍生效
        #expect(log.entries(involvingItemId: "skill:mcp:x", landingPaths: []).isEmpty)
    }

    /// 装配记录 target 是项目 id、itemIds 是磁盘落点路径 —— 只能按落点命中
    @Test func assemblyRecordsMatchByLandingPathNotItemId() throws {
        let (sandbox, paths) = try makePaths()
        defer { try? FileManager.default.removeItem(at: sandbox) }
        let log = OperationLog(paths: paths)
        let landing = "/Users/test/proj/.agents/skills/docx"

        try log.append(LogRecord(actor: "codex", actorKind: .agent, action: .assembly,
                                 detail: "为 proj 装配 1 项", target: "proj",
                                 reversible: true, itemIds: [landing]))
        // 同名不同路径（另一个项目里的 docx）不该串台
        try log.append(LogRecord(actor: "codex", actorKind: .agent, action: .assembly,
                                 detail: "为 other 装配 1 项", target: "other",
                                 reversible: true, itemIds: ["/Users/test/other/.agents/skills/docx"]))

        #expect(log.entries(involvingItemId: "skill:docx", landingPaths: [landing]).count == 1)
        let rec = log.entries(involvingItemId: "skill:docx", landingPaths: [landing]).first
        #expect(rec?.actor == "codex")
        #expect(log.entries(involvingItemId: "skill:docx", landingPaths: []).isEmpty)
    }

    /// 监听根：Skills 目录 + 本工具数据目录收进来；MCP 配置文件的父目录故意不收
    /// （收了会把 ~/.codex 这类高频写目录变成事件风暴源，一次事件 = 一次秒级全量重扫）
    @Test func watchRootsCoversSkillDirsAndSupportDirButNotMcpParents() throws {
        let (sandbox, paths) = try makePaths()
        defer { try? FileManager.default.removeItem(at: sandbox) }
        let codexSkills = sandbox.appendingPathComponent(".codex/skills")
        let claudeConfig = sandbox.appendingPathComponent(".claude.json")
        let locations = [
            ScanLocation(url: codexSkills, kind: .skillDirectory, agentId: "codex",
                         agentOrigin: .officialAgentDir, level: .user),
            ScanLocation(url: claudeConfig, kind: .mcpJSON, agentId: "claude",
                         agentOrigin: .officialAgentDir, level: .user),
            ScanLocation(url: codexSkills, kind: .skillDirectory, agentId: "codex",
                         agentOrigin: .officialAgentDir, level: .user),   // 重复：必须收一次
        ]
        let roots = FSEventWatcher.watchRoots(for: locations, supportDir: paths.supportDir)
        let set = Set(roots.map(\.path))
        #expect(set.contains(codexSkills.path))
        #expect(set.contains(paths.supportDir.path))
        #expect(!set.contains(claudeConfig.deletingLastPathComponent().path))
        #expect(roots.count == 2)
    }

    /// App 侧写锁回归（2026-09-21 真机验收抓到）：
    /// TrashManager 删除时先持锁搬文件、再写操作日志。若 opLog / trash / assembly 各自 new 一把
    /// WriteLock，就是同一文件多个 fd 的 flock——同进程嵌套加锁也会互斥，删除必然卡到超时，
    /// 而且留下半态（文件已进回收站、日志里没有那条删除）。App 现在全进程共用一把锁。
    @Test func sharedWriteLockMakesDeleteLeaveCompleteLog() throws {
        let (sandbox, paths) = try makePaths()
        defer { try? FileManager.default.removeItem(at: sandbox) }
        let skills = sandbox.appendingPathComponent("agents/skills")
        let skill = skills.appendingPathComponent("wt-fixture")
        try FileManager.default.createDirectory(at: skill, withIntermediateDirectories: true)
        try "# fixture".write(to: skill.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)

        let lock = WriteLock(paths: paths)                      // ← 一把锁，AppState 就是这么接的
        let log = OperationLog(paths: paths, lock: lock)
        let trash = TrashManager(paths: paths, lock: lock, log: log)
        let assembly = AssemblyService(paths: paths, lock: lock)
        _ = assembly                                                // 同锁可构造，不额外持锁

        let item = InventoryItem(id: "skill:wt-fixture", name: "wt-fixture", description: "",
                                 type: .skill, level: .user, sourcePath: skill.path,
                                 mountedBy: [], status: .zeroMount)
        let manifest = try trash.trash(item: item, actor: "智昊")
        #expect(!FileManager.default.fileExists(atPath: skill.path))

        // 三步齐：日志必须有那条删除，且 manifest 记下了审计链锚点
        let records = log.readAll().records
        #expect(records.contains { $0.action == .delete && $0.target == "skill:wt-fixture" })
        #expect(manifest.logRecordId != nil)
        // 恢复往返：磁盘回来 + 日志追加恢复记录
        let outcome = try trash.restore(manifest)
        #expect(outcome.complete && FileManager.default.fileExists(atPath: skill.path))
        #expect(log.entries(involvingItemId: "skill:wt-fixture", landingPaths: [skill.path]).count == 2)
    }
}
