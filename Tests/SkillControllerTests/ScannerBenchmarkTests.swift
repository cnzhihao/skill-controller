import Testing
import Foundation
@testable import SkillControllerCore

/// 扫描引擎 + fixture 1000 skill 目录冷启动 ≤5s 基准（测试纪律：CI 断言，不达标即红）
struct ScannerBenchmarkTests {
    /// 造 fixture：root/skills/<name>/SKILL.md
    @discardableResult
    private func makeFixture(count: Int, root: URL, prefix: String = "skill") throws -> URL {
        let skillsDir = root.appendingPathComponent("skills")
        try FileManager.default.createDirectory(at: skillsDir, withIntermediateDirectories: true)
        for i in 0..<count {
            let dir = skillsDir.appendingPathComponent("\(prefix)-\(String(format: "%04d", i))")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let md = """
            ---
            name: \(prefix)-\(String(format: "%04d", i))
            description: fixture skill number \(i)
            ---
            # \(prefix) \(i)
            """
            try md.write(to: dir.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
        }
        return skillsDir
    }

    @Test func scannerReadsFixtureAndParsesFrontmatter() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("sc-fix-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let skillsDir = try makeFixture(count: 5, root: tmp)
        let loc = ScanLocation(url: skillsDir, kind: .skillDirectory, agentId: "codex", level: .user)
        let result = InventoryScanner().scan(scope: ScanScope(locations: [loc]))
        #expect(result.entries.count == 5)
        #expect(result.degraded.isEmpty)
        #expect(result.entries.allSatisfy { $0.type == .skill && $0.level == .user })
        // 目录枚举顺序不保证，按名字找
        let zero = result.entries.first { $0.name == "skill-0000" }!
        #expect(zero.description == "fixture skill number 0")
    }

    @Test func benchmarkColdScan1000SkillsUnder5s() throws {
        // PRD §4 health：冷启动首版清单 ≤5s（fixture 1000 目录，CI 断言）
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("sc-bench-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmp) }
        _ = try makeFixture(count: 1000, root: tmp)
        let skillsDir = tmp.appendingPathComponent("skills")
        let loc = ScanLocation(url: skillsDir, kind: .skillDirectory, agentId: "codex", level: .user)
        let scanner = InventoryScanner()

        let start = Date()
        let result = scanner.scan(scope: ScanScope(locations: [loc]))
        let idx = InventoryIndex()
        idx.rebuild(from: result, projects: [])
        let elapsed = Date().timeIntervalSince(start)

        #expect(idx.items.count == 1000)
        #expect(elapsed < 5.0, "冷扫描 1000 skills 用时 \(elapsed)s，超过 5s 预算")
    }

    @Test func unreadableLocationIsDegradedNotFatal() throws {
        // edge error-partial-degrade：读不到的位置如实报，不中断
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("sc-deg-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let skillsDir = try makeFixture(count: 1, root: tmp)
        let missing = tmp.appendingPathComponent("no-such-dir")
        let noReadPerm = tmp.appendingPathComponent("locked")
        try FileManager.default.createDirectory(at: noReadPerm, withIntermediateDirectories: true)
        // 000 权限模拟无权限（仅本进程 owner 场景生效）
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: noReadPerm.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: noReadPerm.path) }

        let locs = [
            ScanLocation(url: skillsDir, kind: .skillDirectory, agentId: "codex", level: .user),
            ScanLocation(url: missing, kind: .skillDirectory, agentId: "claude", level: .user),
            ScanLocation(url: noReadPerm, kind: .skillDirectory, agentId: "cursor", level: .user),
        ]
        let result = InventoryScanner().scan(scope: ScanScope(locations: locs))
        #expect(result.entries.count == 1)
        // missing 不算降级（不存在≠读不了）；locked 算降级
        #expect(result.degraded.map(\.path) == [noReadPerm.path])
        #expect(result.locationsScanned == 3)
    }

    @Test func blockScalarDescriptionIsJoined() throws {
        // 真实 SKILL.md 常见 YAML 块标量：description: | —— 不能只读出 "|"
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sc-block-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try """
        ---
        name: dbs
        description: |
          第一行说明。
          第二行说明。
        ---
        # body
        """.write(to: dir.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
        let (name, desc) = SkillFrontmatter.parse(at: dir.appendingPathComponent("SKILL.md"))
        #expect(name == "dbs")
        #expect(desc == "第一行说明。 第二行说明。")
    }

    @Test func deepModeScansPluginSkills() throws {
        // D6：plugins/<plugin>/skills/<skill> 两层结构计入清单
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sc-deep-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("plugins/doodle/skills/audit"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try "---\nname: audit\ndescription: deep audit skill\n---".write(
            to: root.appendingPathComponent("plugins/doodle/skills/audit/SKILL.md"), atomically: true, encoding: .utf8)
        try "# not a skill".write(
            to: root.appendingPathComponent("plugins/doodle/README.md"), atomically: true, encoding: .utf8)
        let loc = ScanLocation(url: root.appendingPathComponent("plugins"), kind: .skillDirectory,
                               agentId: "qoder", level: .user, depth: 2)
        let result = InventoryScanner().scan(scope: ScanScope(locations: [loc]))
        #expect(result.entries.count == 1)
        #expect(result.entries[0].name == "audit")
        #expect(result.entries[0].description == "deep audit skill")
        #expect(result.entries[0].mountedAgentId == "qoder")
    }

    @Test func codexTOMLParsesServersIgnoringSubtables() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("sc-toml-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let toml = tmp.appendingPathComponent("config.toml")
        try """
        model = "x"
        [mcp_servers.chrome-devtools]
        command = "npx"
        [mcp_servers.chrome-devtools.env]
        FOO = "bar"
        [mcp_servers.docs]
        url = "https://example.com/mcp"
        """.write(to: toml, atomically: true, encoding: .utf8)
        let loc = ScanLocation(url: toml, kind: .mcpTOML, agentId: "codex", level: .user)
        let result = InventoryScanner().scan(scope: ScanScope(locations: [loc]))
        #expect(result.entries.count == 2)
        #expect(result.entries[0].name == "chrome-devtools")
        #expect(result.entries[0].description == "npx")
        #expect(result.entries[1].name == "docs")
        #expect(result.entries[1].description == "https://example.com/mcp")
    }

    @Test func claudeJSONUserAndProjectScopeMCP() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("sc-json-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let json = tmp.appendingPathComponent(".claude.json")
        try """
        {"mcpServers":{"context7":{"command":"npx"}},
         "projects":{"/w/proj-x":{"mcpServers":{"puppeteer":{"url":"ws://x"}}}}}
        """.write(to: json, atomically: true, encoding: .utf8)
        let locUser = ScanLocation(url: json, kind: .mcpJSON, agentId: "claude", level: .user)
        let result = InventoryScanner().scan(scope: ScanScope(locations: [locUser]))
        #expect(result.entries.count == 2)
        #expect(Set(result.entries.map(\.name)) == ["context7", "puppeteer"])
        let p = result.entries.first { $0.name == "puppeteer" }!
        #expect(p.level == .project && p.projectId == "proj-proj-x")
    }
}
