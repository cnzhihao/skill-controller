import Testing
import Foundation
@testable import SkillControllerCore

/// #22 问题2（走查裁定 2026-09-30）：`skillctl add --force` 更新库条目时旧副本经回收站
/// 移入，新副本占住原位——App 回退页恢复该件必然按 D14「原位被占不覆盖」如实失败，
/// 但失败原因没说透（为什么失败 / 怎么办），人面对「30 天内可一步恢复」的全局承诺无所适从。
///
/// 分流判定落 Core（TrashManager.isForceReplacedLibraryCopy + restore 的 occupied × isForceCopy
/// 双闸门），三判据只用 manifest 已持久化字段（零新增）：actor == "skillctl" ∧ id 前缀
/// `skill:` ∧ 全部落点在库根下。三处全局「30 天内可一步恢复」文案一字不动（裁决 A 的核心）。
struct ForceReplacedHintTests {
    private func makeSandbox() throws -> (work: URL, paths: SkillControllerPaths, home: URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sc-force-hint-\(UUID().uuidString)")
        let home = dir.appendingPathComponent("home")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        return (dir, SkillControllerPaths(supportDir: dir.appendingPathComponent("support")), home)
    }

    /// 造一个 --force 同形状的回收站件：actor="skillctl"、id="skill:<名>"、落点在库下。
    private func makeForceCopyManifest(paths: SkillControllerPaths, home: URL, name: String) throws -> TrashManifest {
        let fm = FileManager.default
        let trash = TrashManager(paths: paths, home: home)
        let entry = SkillLibrary(home: home).entryURL(named: name)
        try fm.createDirectory(at: entry, withIntermediateDirectories: true)
        try "---\nname: \(name)\ndescription: d\n---".write(to: entry.appendingPathComponent("SKILL.md"),
                                                            atomically: true, encoding: .utf8)
        // 与 LibraryAdd.swift --force 分支同形状的描述性 item（唯一进 manifest 的是 id/name/locations）
        let item = InventoryItem(id: "skill:\(name)", name: name, description: "技能库副本（--force 更新前旧件）",
                                 type: .skill, level: .library, projectId: nil, sourcePath: entry.path,
                                 mountedBy: [], status: .unmounted)
        let manifest = try trash.trash(item: item, actor: "skillctl")
        // 模拟 --force 之后的盘面：新副本立刻占回原位（恢复必然撞占位）
        try fm.createDirectory(at: entry, withIntermediateDirectories: true)
        try "新副本".write(to: entry.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
        return manifest
    }

    /// 主判例：--force 旧副本 × 新副本占位 → restore 如实失败（0/1）且带特例说明，
    /// 说明含「为什么失败」（旧副本/新副本占位）与「怎么办」（先删除库内同名条目）。
    @Test func forceCopyRestoreFailureCarriesHint() throws {
        let (work, paths, home) = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: work) }
        let fm = FileManager.default
        let trash = TrashManager(paths: paths, home: home)
        let m = try makeForceCopyManifest(paths: paths, home: home, name: "docx")

        let out = try trash.restore(m)

        #expect(!out.complete && out.restored == 0)
        #expect(out.failed.count == 1)
        #expect(out.failed[0].reason == "原位置已被占用", Comment(rawValue: "失败原因本体维持原状，特例说明是独立附加行"))
        let hint = try #require(out.forceReplacedHint, Comment(rawValue: "特例说明必须给出"))
        #expect(hint == TrashManager.forceReplacedHintText)
        #expect(hint.contains("旧副本") && hint.contains("新副本"),
                Comment(rawValue: "为什么失败：旧副本 + 新副本占位都要说"))
        #expect(hint.contains("先删除库内同名条目"), Comment(rawValue: "怎么办：给出先移除新副本的出口"))
    }

    /// 普通占位失败（非库路径、人删的件）→ 不带特例说明（回执维持现状）。
    @Test func ordinaryOccupiedFailureStaysUntouched() throws {
        let (work, paths, home) = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: work) }
        let fm = FileManager.default
        let trash = TrashManager(paths: paths, home: home)
        let entity = home.appendingPathComponent(".agents/skills/pdf")
        try fm.createDirectory(at: entity, withIntermediateDirectories: true)
        try "普通件".write(to: entity.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
        let m = try trash.trash(item: InventoryItem(id: "skill:pdf", name: "pdf", description: "", type: .skill,
                                                    level: .user, sourcePath: entity.path, mountedBy: [],
                                                    status: .zeroMount), actor: "智昊")
        // 占位：普通目录里塞回一个目录
        try fm.createDirectory(at: entity, withIntermediateDirectories: true)

        let out = try trash.restore(m)

        #expect(!out.complete && out.failed[0].reason == "原位置已被占用")
        #expect(out.forceReplacedHint == nil, Comment(rawValue: "非特例不加行——普通恢复失败回执零改动"))
    }

    /// skillctl 收编（id 前缀 path:，restoreAssembly copy 分支的形状）× 占位失败 → 不带特例说明。
    @Test func skillctlCopyEntryOccupiedCarriesNoHint() throws {
        let (work, paths, home) = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: work) }
        let fm = FileManager.default
        let trash = TrashManager(paths: paths, home: home)
        let entry = SkillLibrary(home: home).entryURL(named: "alpha")
        try fm.createDirectory(at: entry, withIntermediateDirectories: true)
        try "x".write(to: entry.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
        // restoreAssembly 收 copy 落点进回收站的形状：id = "path:<路径>"（AssemblyService copy 分支）
        let m = try trash.trash(item: InventoryItem(id: "path:\(entry.path)", name: "alpha", description: "",
                                                    type: .skill, level: .project, projectId: "p",
                                                    sourcePath: entry.path, mountedBy: [], status: .mounted),
                                actor: "skillctl")
        try fm.createDirectory(at: entry, withIntermediateDirectories: true)

        let out = try trash.restore(m)

        #expect(!out.complete && out.failed[0].reason == "原位置已被占用")
        #expect(out.forceReplacedHint == nil, Comment(rawValue: "path: 前缀 ≠ --force 旧副本，说明在这里是假话"))
    }

    /// skillctl 收库条目（actor/id 同特例）但原位是空的 → 恢复成功，无失败说明可言。
    @Test func forceCopyRestoreSuccessCarriesNoHint() throws {
        let (work, paths, home) = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: work) }
        let trash = TrashManager(paths: paths, home: home)
        let entry = SkillLibrary(home: home).entryURL(named: "beta")
        try FileManager.default.createDirectory(at: entry, withIntermediateDirectories: true)
        try "x".write(to: entry.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
        let m = try trash.trash(item: InventoryItem(id: "skill:beta", name: "beta", description: "", type: .skill,
                                                    level: .library, projectId: nil, sourcePath: entry.path,
                                                    mountedBy: [], status: .unmounted), actor: "skillctl")

        let out = try trash.restore(m)

        #expect(out.complete)
        #expect(out.forceReplacedHint == nil, Comment(rawValue: "恢复成功没有特例说明可言（outcome 无失败）"))
    }

    /// 判定函数直接验：库路径人删件（actor≠skillctl）与库外 skillctl 件都不判特例；
    /// 特例件判定为真。库路径判定走 isLibraryPath(home 注入)，/var→/private/var 同款陷阱由它挡。
    @Test func isForceReplacedLibraryCopyJudgesByManifestShape() throws {
        let (work, paths, home) = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: work) }
        let fm = FileManager.default
        let trash = TrashManager(paths: paths, home: home)
        let entry = SkillLibrary(home: home).entryURL(named: "gamma")
        try fm.createDirectory(at: entry, withIntermediateDirectories: true)
        try "x".write(to: entry.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)

        // 人删库条目：actor="智昊" → 非特例（App 删除库条目的 actor 一律是人名）
        let humanItem = InventoryItem(id: "skill:gamma", name: "gamma", description: "", type: .skill,
                                      level: .library, projectId: nil, sourcePath: entry.path,
                                      mountedBy: [], status: .unmounted)
        let humanM = try trash.trash(item: humanItem, actor: "智昊")
        #expect(!trash.isForceReplacedLibraryCopy(humanM))
        try fm.createDirectory(at: entry, withIntermediateDirectories: true)
        try "y".write(to: entry.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)

        // skillctl 件但 id 前缀 path: → 非特例
        let pathItem = InventoryItem(id: "path:\(entry.path)", name: "gamma", description: "", type: .skill,
                                     level: .project, projectId: "p", sourcePath: entry.path,
                                     mountedBy: [], status: .mounted)
        let pathM = try trash.trash(item: pathItem, actor: "skillctl")
        #expect(!trash.isForceReplacedLibraryCopy(pathM))
        // 第二次 trash 已把条目搬走，再造回占位内容，第三次 trash 才有落点可收
        try fm.createDirectory(at: entry, withIntermediateDirectories: true)
        try "z".write(to: entry.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)

        // --force 同形状：actor="skillctl" ∧ id 前缀 skill: ∧ 落点在库下 → 特例
        let forceItem = InventoryItem(id: "skill:gamma", name: "gamma", description: "", type: .skill,
                                      level: .library, projectId: nil, sourcePath: entry.path,
                                      mountedBy: [], status: .unmounted)
        let forceM = try trash.trash(item: forceItem, actor: "skillctl")
        #expect(trash.isForceReplacedLibraryCopy(forceM))
    }
}
