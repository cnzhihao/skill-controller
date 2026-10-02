import Testing
import Foundation
@testable import SkillControllerCore

/// #9③ 全盘发现真取消的 Core 侧语义（App 侧 `discoveryTask` 句柄在 App 面，由并行 coder 交付；
/// 这里测的是取消传进来之后 ScopeDiscoverer **真的会停**，且停得早）。
///
/// 确定性路径（设计评审 finding 7 的 fix 口径）：不依赖真实 cancel 恰落遍历中途——
/// 用 `shouldStop` **恒 true** 覆盖「中途取消」分支，用**首个目录后停**的同步点路径
/// 断言已走到的部分照常产出、剩余部分不再遍历。避免「遍历快于 cancel」的 flake。
struct DiscoveryCancellationTests {
    /// 造一棵确定的夹具树：root 下 N 个子目录，每个子里 2 个命中 skills 目录。
    private func makeTree(depth: Int) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("sc-cancel-\(UUID().uuidString)")
        for i in 0..<depth {
            for j in 0..<2 {
                let dir = root.appendingPathComponent("proj\(i)/team\(j)/skills")
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            }
        }
        return root
    }

    /// ① shouldStop 恒 true：一个目录都不该被访问——提前返回，不扫完全量。
    @Test func shouldStopAlwaysTrueReturnsImmediately() throws {
        let root = try makeTree(depth: 6)
        defer { try? FileManager.default.removeItem(at: root) }

        let outcome = ScopeDiscoverer(rules: .standard).discover(
            roots: [root], home: root, shouldStop: { true })

        #expect(outcome.stoppedEarly, "shouldStop 命中必须置 stoppedEarly")
        #expect(outcome.dirsVisited == 0, "恒停 = 首个目录前就返回，不消耗遍历")
        #expect(outcome.locations.isEmpty)
    }

    /// ② 首目录后停的同步点：第一批已发现的照常产出，剩余全剪——dirsVisited 严格小于全量。
    @Test func stopAfterFirstDirVisitsStrictlyLessThanFullWalk() throws {
        let root = try makeTree(depth: 6)   // 全量 = 1 root + 6 proj + 12 team = 19 个目录
        defer { try? FileManager.default.removeItem(at: root) }

        let discoverer = ScopeDiscoverer(rules: .standard)
        let full = discoverer.discover(roots: [root], home: root, shouldStop: { false })
        // 同步点计数器（Sendable）：第 2 次检查（访问第 2 个目录前）停
        final class Gate: @unchecked Sendable {
            private let lock = NSLock()
            private var n = 0
            func tripAfterFirst() -> Bool {
                lock.lock(); defer { lock.unlock() }
                n += 1
                return n > 1
            }
        }
        let gate = Gate()
        let stopped = discoverer.discover(roots: [root], home: root,
                                          shouldStop: { gate.tripAfterFirst() })

        #expect(stopped.stoppedEarly)
        #expect(stopped.dirsVisited < full.dirsVisited,
                Comment(rawValue: "中途取消必须比全量少走（\(stopped.dirsVisited) vs \(full.dirsVisited)）"))
        #expect(stopped.locations.count < full.locations.count,
                "停在前半：发现的 skills 目录也严格更少")
        // 全量基线自证：夹具树完整遍历时 stoppedEarly 不置位
        #expect(!full.stoppedEarly)
    }

    /// ③ 取消与发现互不污染：同参数下，未取消那轮的产出与全量一致（取消侧不剪基线的结果）。
    @Test func cancellationDoesNotLeakIntoUnstoppedRuns() throws {
        let root = try makeTree(depth: 4)
        defer { try? FileManager.default.removeItem(at: root) }

        let discoverer = ScopeDiscoverer(rules: .standard)
        let stopper: @Sendable () -> Bool = { true }
        _ = discoverer.discover(roots: [root], home: root, shouldStop: stopper)   // 全停一轮
        let after = discoverer.discover(roots: [root], home: root, shouldStop: { false })

        #expect(!after.stoppedEarly)
        #expect(after.locations.count == 8, "4 proj × 2 team 的 skills 目录应全部发现")
    }
}
