import Testing
import Foundation
@testable import SkillControllerCore

/// D19：挂载可观测（读侧）与 CLI 自管（写侧）必须认同一批目录。
/// 真机踩到的形状是——夹具落在 `~/.codex/skills/`，清单显示「Codex 挂载 1 次」，
/// 而 `skillctl unmount --on codex` 只认 `~/.agents/skills`，报「该位置没有挂载」。
/// 等于「App 说挂着、Agent 说自己没挂」，装配闭环直接断在这里。
struct MountDirParityTests {
    private func sb() throws -> (work: URL, paths: SkillControllerPaths, home: URL) {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("sc-parity-dir-\(UUID().uuidString)")
        let home = d.appendingPathComponent("home")
        // 条目本体（实体源）放在共享源 ~/.agents/skills/pdf
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".agents/skills/pdf"), withIntermediateDirectories: true)
        try "---\nname: pdf\ndescription: p\n---".write(to: home.appendingPathComponent(".agents/skills/pdf/SKILL.md"), atomically: true, encoding: .utf8)
        return (d, SkillControllerPaths(supportDir: d.appendingPathComponent("support")), home)
    }

    /// 造一个"某家目录下指向实体源"的 symlink 落点（Agent 自己挂的样子）
    private func link(home: URL, agentDir: String, name: String) throws -> URL {
        let dir = home.appendingPathComponent(agentDir)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dest = dir.appendingPathComponent(name)
        try FileManager.default.createSymbolicLink(atPath: dest.path,
                                                   withDestinationPath: "../../.agents/skills/\(name)")
        return dest
    }

    /// 候选目录：primary 恒在第一位，Codex 的第二个官方目录必须在列（读侧认它，写侧就得认它）
    @Test func candidatesIncludeAllCodexDirsPrimaryFirst() {
        let home = URL(fileURLWithPath: "/Users/test")
        let c = MountTargets.candidates(agent: "codex", projectPath: nil, home: home)
        #expect(c.first?.path == "/Users/test/.agents/skills")
        #expect(c.map(\.path).contains("/Users/test/.codex/skills"))
        // 项目级同理：项目根下的两个目录都算这一家
        let p = MountTargets.candidates(agent: "codex", projectPath: "/Users/test/proj", home: home)
        #expect(p.map(\.path).contains("/Users/test/proj/.codex/skills"))
        // 别家不能混进来
        #expect(!MountTargets.candidates(agent: "claude", projectPath: nil, home: home)
            .map(\.path).contains("/Users/test/.codex/skills"))
    }

    /** 回归：落点在 `~/.codex/skills` 也要能卸下（改前抛 notMounted） */
    @Test func unmountReachesSecondaryCodexMountDir() throws {
        let (work, paths, home) = try sb()
        defer { try? FileManager.default.removeItem(at: work) }
        let svc = AssemblyService(paths: paths, home: home)
        let landed = try link(home: home, agentDir: ".codex/skills", name: "pdf")

        let r = try svc.unmount(name: "pdf", on: "codex")
        #expect(r.event.removed == [landed.path])
        #expect(!FileManager.default.fileExists(atPath: landed.path))
        // 卸下 ≠ 删除：实体源必须还在
        #expect(FileManager.default.fileExists(atPath: home.appendingPathComponent(".agents/skills/pdf").path))
    }

    /** 同一家挂了两个目录时，一次 unmount 要全卸——只卸一个等于清单上还说"挂着"；
        同时不能碰别家的那份（实体源放在 claude 名下） */
    @Test func unmountRemovesEveryLandingOfThatAgent() throws {
        let (work, paths, home) = try sb()
        defer { try? FileManager.default.removeItem(at: work) }
        let svc = AssemblyService(paths: paths, home: home)
        // 把实体源挪到 claude 名下，腾出 codex 的两个目录各挂一个链接
        let entity = home.appendingPathComponent(".agents/skills/pdf")
        let moved = home.appendingPathComponent(".claude/skills/pdf")
        try FileManager.default.createDirectory(at: moved.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: entity, to: moved)
        let a = try link(home: home, agentDir: ".agents/skills", name: "pdf")
        let b = try link(home: home, agentDir: ".codex/skills", name: "pdf")

        let r = try svc.unmount(name: "pdf", on: "codex")
        #expect(Set(r.event.removed) == Set([a.path, b.path]))
        #expect(!FileManager.default.fileExists(atPath: a.path))
        #expect(!FileManager.default.fileExists(atPath: b.path))
        #expect(FileManager.default.fileExists(atPath: moved.path))   // 别家的本体不动
    }

    /** 混合情形：实体源 + 一个链接。链接照卸、本体拒绝——不静默半成功，也不因为有一个拒了就不动另一个 */
    @Test func unmountRemovesLinksAndRefusesEntityBody() throws {
        let (work, paths, home) = try sb()
        defer { try? FileManager.default.removeItem(at: work) }
        let svc = AssemblyService(paths: paths, home: home)
        let entity = home.appendingPathComponent(".agents/skills/pdf")
        let linkURL = try link(home: home, agentDir: ".codex/skills", name: "pdf")

        let r = try svc.unmount(name: "pdf", on: "codex")
        #expect(r.event.removed == [linkURL.path])
        #expect(!FileManager.default.fileExists(atPath: linkURL.path))
        #expect(FileManager.default.fileExists(atPath: entity.path))          // 本体没被碰
        let refused = r.outcomes.first { $0.path == entity.path }
        #expect(refused?.status == .refused)
    }

    /** 表里没有的工具（靠目录名动态归属）也不能"App 说挂着、CLI 说自己没挂" */
    @Test func unmountWorksForDynamicallyDiscoveredAgent() throws {
        let (work, paths, home) = try sb()
        defer { try? FileManager.default.removeItem(at: work) }
        let svc = AssemblyService(paths: paths, home: home)
        let landed = try link(home: home, agentDir: ".thincoder/skills", name: "pdf")
        // 前提：读侧确实把它归到 thincoder（否则这条测试测不到东西）
        #expect(svc.currentIndex().items.first { $0.name == "pdf" }?.mountedBy.contains("thincoder") == true)

        let r = try svc.unmount(name: "pdf", on: "thincoder")
        #expect(r.event.removed == [landed.path])
        #expect(!FileManager.default.fileExists(atPath: landed.path))
    }

    /** 真的没挂过时仍然要报错，且把找过哪些目录说清楚（不再只报一个路径误导人） */
    @Test func unmountStillReportsSearchedDirsWhenAbsent() throws {
        let (work, paths, home) = try sb()
        defer { try? FileManager.default.removeItem(at: work) }
        let svc = AssemblyService(paths: paths, home: home)
        #expect(throws: AssemblyService.AssemblyError.self) { try svc.unmount(name: "pdf", on: "cursor") }
        do {
            _ = try svc.unmount(name: "never-mounted-thing", on: "codex")
            Issue.record("该条目在 codex 名下没有任何落点，应当抛错")
        } catch {
            var searched = ""
            if case let AssemblyService.AssemblyError.notMounted(path) = error { searched = path }
            // 两个官方目录都报出来——只报 primary 正是 D19 误导人的地方
            #expect(searched.contains(".agents/skills/never-mounted-thing"))
            #expect(searched.contains(".codex/skills/never-mounted-thing"))
        }
    }
}
