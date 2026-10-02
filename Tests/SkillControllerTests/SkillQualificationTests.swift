import Testing
import Foundation
@testable import SkillControllerCore

/// D12 判定收口：没有 SKILL.md 的目录不成为 skill 条目；
/// skills 目录自己就是 skill 时只算一个，不再枚举它的子目录。
/// 旧逻辑下本机 387 处 `references/`、`scripts/`、`__pycache__` 被当成独立 skill，
/// 既是"1970 Skills"虚高的主因，也是 D10=A 空转的根因。
struct SkillQualificationTests {
    private func sandbox() throws -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("sc-qual-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    @discardableResult
    private func makeSkill(_ dir: URL, name: String, description: String = "d") throws -> URL {
        let s = dir.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: s, withIntermediateDirectories: true)
        try "---\nname: \(name)\ndescription: \(description)\n---".write(
            to: s.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
        return s
    }

    private func scan(_ locations: [ScanLocation], home: URL) -> [RawEntry] {
        InventoryScanner().scan(scope: ScanScope(locations: locations, projects: [])).entries
    }

    private func loc(_ url: URL, depth: Int = 1) -> ScanLocation {
        ScanLocation(url: url, kind: .skillDirectory, agentId: "codex",
                     agentOrigin: .officialAgentDir, level: .user, depth: depth)
    }

    /// ① 真 skill 收，文档子目录 / 缓存目录不收
    @Test func onlyDirectoryWithManifestIsASkill() throws {
        let root = try sandbox(); defer { try? FileManager.default.removeItem(at: root) }
        let skills = root.appendingPathComponent("skills")
        try makeSkill(skills, name: "docx")
        let src = try makeSkill(skills, name: "pdf")
        for junk in ["references", "scripts", "assets", "__pycache__"] {
            let d = src.appendingPathComponent(junk)                       // skill 自带的子目录
            try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
            try "x".write(to: d.appendingPathComponent("a.md"), atomically: true, encoding: .utf8)
            let peer = skills.appendingPathComponent(junk)                  // 直接躺在 skills 下的同名目录
            try FileManager.default.createDirectory(at: peer, withIntermediateDirectories: true)
        }
        let names = Set(scan([loc(skills)], home: root).map(\.name))
        #expect(names == ["docx", "pdf"])
    }

    /// ② skills 目录自己就是 skill：只出一条，名字取所属工具/连接器名，不枚举子目录
    @Test func skillsDirThatIsItselfASkillYieldsOneEntry() throws {
        let root = try sandbox(); defer { try? FileManager.default.removeItem(at: root) }
        let connector = root.appendingPathComponent("connectors/deep-research")
        let skills = connector.appendingPathComponent("skills")
        try FileManager.default.createDirectory(at: skills, withIntermediateDirectories: true)
        try "---\nname: deep-research\ndescription: 连接器本体\n---".write(
            to: skills.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
        for junk in ["references", "scripts"] {
            try FileManager.default.createDirectory(at: skills.appendingPathComponent(junk),
                                                    withIntermediateDirectories: true)
        }
        let entries = scan([loc(skills)], home: root)
        #expect(entries.count == 1)
        #expect(entries.first?.name == "deep-research")          // 取父目录名，不叫 "skills"
        #expect(entries.first?.description == "连接器本体")
        #expect(entries.first?.locationPath == skills.path)
    }

    /// ③ 悬空 symlink 仍然收录：那是"挂上了但目标已不存在"的磁盘事实
    @Test func danglingSymlinkStillCountsAsALanding() throws {
        let root = try sandbox(); defer { try? FileManager.default.removeItem(at: root) }
        let skills = root.appendingPathComponent("skills")
        try FileManager.default.createDirectory(at: skills, withIntermediateDirectories: true)
        try makeSkill(skills, name: "docx")
        let link = skills.appendingPathComponent("gone")
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "../nowhere")
        let names = Set(scan([loc(skills)], home: root).map(\.name))
        #expect(names.contains("docx"))
        #expect(names.contains("gone"))
    }

    /// ④ 深层模式（插件 plugins/<x>/skills/<skill>）不能被误伤成"整个 skills 是一个 skill"
    @Test func deepPluginLayoutStillEnumerates() throws {
        let root = try sandbox(); defer { try? FileManager.default.removeItem(at: root) }
        let plugins = root.appendingPathComponent("plugins")
        let inner = plugins.appendingPathComponent("pack/skills")
        try FileManager.default.createDirectory(at: inner, withIntermediateDirectories: true)
        try makeSkill(inner, name: "real-one")
        try makeSkill(inner, name: "real-two")
        let entries = scan([loc(plugins, depth: 2)], home: root)
        #expect(Set(entries.map(\.name)) == ["real-one", "real-two"])
    }

    /// ⑤ SkillLayout 同源断言（skill-library 批）：扫描器枚举段与库内发现共用同一个
    /// SkillLayout.enumerate（D12 命中即停的唯一实现）——同一盘形两边结论必须一致
    @Test func scannerAndSkillLayoutAgreeOnQualification() throws {
        let root = try sandbox(); defer { try? FileManager.default.removeItem(at: root) }
        let skills = root.appendingPathComponent("skills")
        try makeSkill(skills, name: "docx")
        try makeSkill(skills, name: "pdf")
        for junk in ["references", "__pycache__", "node_modules"] {
            try FileManager.default.createDirectory(at: skills.appendingPathComponent(junk),
                                                    withIntermediateDirectories: true)
        }
        // 直接对照：扫描器产出的条目集合 == SkillLayout 枚举的名字集合
        let scanned = Set(scan([loc(skills)], home: root).map(\.name))
        let layout = Set(SkillLayout.enumerate(root: skills, includeDanglingSymlinks: true)
            .map { SkillLayout.entryName(of: $0, root: skills) })
        #expect(scanned == layout && scanned == ["docx", "pdf"])
    }
}
