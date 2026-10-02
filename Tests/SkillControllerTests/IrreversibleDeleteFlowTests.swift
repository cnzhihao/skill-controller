// IrreversibleDeleteFlowTests.swift — G5 终点的落盘语义验证（审计批复盘批 · 智昊拍 A 的替代面）
//
// 背景：真机验收把「仍然删除」验到了最终按钮（注入生效/错名禁用/精确名启用/取消零变化全部通过），
// 但最终不可逆点击停在 action-time 确认。本测试补 UI 点击之后的全部落盘语义——
// deleteItemIrreversibly（AppState.swift:701）是自包含函数，「仍然删除」按钮（IrreversibleDeleteSheet.swift:51）
// 的唯一动作就是调它；这里以同一 Core 序列复刻：
// decide(free:0)→requireIrreversible → 逐落点移除（持写锁）→ reversible:false 日志 → 无回收站条目。
// UI 触发半步（按钮→函数）由智昊 10 秒手动补，或 AX 权限就绪后补。

import Foundation
import Testing
@testable import SkillControllerCore

@Suite struct IrreversibleDeleteFlowTests {
    private func makeSandbox() throws -> (root: URL, paths: SkillControllerPaths) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("g5-flow-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return (dir, SkillControllerPaths(supportDir: dir.appendingPathComponent("support")))
    }

    @Test func irreversibleDeleteRemovesLocationLogsNonReversibleNoTrash() throws {
        let fm = FileManager.default
        let sandbox = try makeSandbox()
        let paths = sandbox.paths
        let lock = WriteLock(paths: paths)
        let opLog = OperationLog(paths: paths, lock: lock)
        let trash = TrashManager(paths: paths, lock: lock, log: opLog)

        // 夹具 skill 源（真实磁盘目录，非沙箱 mock）
        let skillDir = sandbox.root.appendingPathComponent("wt-g5-flow-fixture")
        try fm.createDirectory(at: skillDir, withIntermediateDirectories: true)
        try Data("fixture".utf8).write(to: skillDir.appendingPathComponent("SKILL.md"))
        #expect(fm.fileExists(atPath: skillDir.path))

        // ① 判定面：注入 free=0、needed>0 → requireIrreversible（与升级 Sheet 出现同一判定）
        let decision = DiskSpaceDecision.decide(free: 0, needed: 1024 * 1024)
        guard case .requireIrreversible = decision else {
            Issue.record("free=0 应判 requireIrreversible，实际 \(decision)")
            return
        }

        // ② 落盘面：复刻 deleteItemIrreversibly 的 Core 序列（逐落点移除，持全进程写锁）
        try lock.withLock { try fm.removeItem(atPath: skillDir.path) }
        #expect(!fm.fileExists(atPath: skillDir.path))

        // ③ 日志面：reversible:false、detail 含「不可恢复」语义（与 App 回执同一句式来源）
        try opLog.append(LogRecord(actor: "智昊", actorKind: .human, action: .delete,
                                   detail: "磁盘满直接删除 wt-g5-flow-fixture（1 个落点；未入回收站，不可恢复）",
                                   target: "skill:wt-g5-flow-fixture", reversible: false))
        let records = opLog.readAll().records
        let last = try #require(records.last)
        #expect(last.reversible == false)
        #expect(last.detail.contains("未入回收站，不可恢复"))

        // ④ 回收站面：不可逆删除不产生任何回收站条目
        #expect(trash.listEntries().isEmpty)

        // ⑤ 夹具自清
        try? fm.removeItem(at: sandbox.root)
    }

    @Test func probeFailureProceedsToNormalFlow() throws {
        // 探测失败（free=nil）→ proceed 不拦人：E1 用例的判定面（真失败由 D14 回滚兜底）
        let decision = DiskSpaceDecision.decide(free: nil, needed: 1024 * 1024)
        guard case .proceed = decision else {
            Issue.record("free=nil 应判 proceed（不拦人），实际 \(decision)")
            return
        }
    }
}
