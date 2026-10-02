import Testing
import Foundation
@testable import SkillControllerCore

/// 发现驱动扫描范围：发现器剪枝、分类器层级/归属、不存在位置不进范围、缓存往返
/// （2026-09-20 整改：设置页大量「该路径不存在」空行 → 范围改由磁盘发现得出）
struct ScopeDiscoveryTests {

    /// 造一棵假 home：内含用户级 Agent 目录、带 .git 的项目、各类该被剪掉的噪音目录
    private func makeFixture() throws -> (home: URL, cleanup: URL) {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("sc-disco-\(UUID().uuidString)")
        let home = base.appendingPathComponent("home")
        func touch(_ rel: String) throws {
            let dir = home.appendingPathComponent(rel)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try "---\nname: x\ndescription: y\n---".write(
                to: dir.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
        }
        // 用户级
        try touch(".codex/skills/alpha")
        try touch(".agents/skills/shared-one")
        try touch(".config/devin/skills/deep-devin")
        try touch(".thincoder/skills/mystery")
        try touch(".grok/skills/grok-one")
        try touch(".qwenworkcn/plugins/doodle/skills/plug-skill")
        // 项目级（.git 定项目根）
        try touch("repoA/.claude/skills/in-repo")
        try FileManager.default.createDirectory(at: home.appendingPathComponent("repoA/.git"),
                                                 withIntermediateDirectories: true)
        try touch("repoB/skills/at-root")
        try FileManager.default.createDirectory(at: home.appendingPathComponent("repoB/.git"),
                                                withIntermediateDirectories: true)
        // home 直属、非 Agent 目录、无 .git → 用户级（智昊规则：home 直属 = 用户级）
        try touch("plain/skills/plain-one")
        // 无 .git 也非 home 直属 → 其他位置
        try touch("workspace/nested-kit/skills/loose")
        // 该被剪掉的噪音
        try touch("proj/node_modules/left-pad/skills/noise")
        try touch("Library/Deep/foo/skills/noise")
        try touch("Some.app/Contents/Resources/skills/noise")
        try touch(".grok/marketplace-cache/hash/skills/noise")
        try touch("trae/builtin/design/skills/noise")
        try touch(".cache/volatile/skills/noise")
        // MCP 配置
        try "{\"mcpServers\":{}}".write(to: home.appendingPathComponent(".claude.json"), atomically: true, encoding: .utf8)
        try "x".write(to: home.appendingPathComponent(".codex/config.toml"), atomically: true, encoding: .utf8)
        try "x".write(to: home.appendingPathComponent("repoB/.mcp.json"), atomically: true, encoding: .utf8)
        // 通用文件名在深处不算 MCP（config.toml 只认 home 两层内）
        try "x".write(to: home.appendingPathComponent("workspace/nested-kit/config.toml"), atomically: true, encoding: .utf8)
        return (home, base)
    }

    private func discover(_ home: URL) -> [DiscoveredLocation] {
        ScopeDiscoverer().discover(roots: [home], home: home, maxDepth: 24).locations
    }

    // MARK: - 发现与剪枝

    @Test func discoveryFindsSkillsDirsAndPrunesNoise() throws {
        let (home, base) = try makeFixture()
        defer { try? FileManager.default.removeItem(at: base) }
        let found = Set(discover(home).filter { $0.kind == .skillDirectory }.map(\.path))

        let expected: Set<String> = [
            home.appendingPathComponent(".codex/skills").path,
            home.appendingPathComponent(".agents/skills").path,
            home.appendingPathComponent(".config/devin/skills").path,
            home.appendingPathComponent(".thincoder/skills").path,
            home.appendingPathComponent(".grok/skills").path,
            home.appendingPathComponent(".qwenworkcn/plugins/doodle/skills").path,
            home.appendingPathComponent("repoA/.claude/skills").path,
            home.appendingPathComponent("repoB/skills").path,
            home.appendingPathComponent("plain/skills").path,
            home.appendingPathComponent("workspace/nested-kit/skills").path,
        ]
        #expect(found == expected, "发现结果不符：多了 \(found.subtracting(expected))，少了 \(expected.subtracting(found))")
        // 噪音目录一个都不能进来
        #expect(!found.contains { $0.contains("node_modules") || $0.contains("Library/Deep")
            || $0.contains(".app/") || $0.contains("marketplace-cache")
            || $0.contains("/builtin/") || $0.contains("/.cache/") })
    }

    @Test func discoveryFindsMCPFilesWithDepthGate() throws {
        let (home, base) = try makeFixture()
        defer { try? FileManager.default.removeItem(at: base) }
        let mcp = Set(discover(home).filter { $0.kind != .skillDirectory }.map(\.path))

        #expect(mcp.contains(home.appendingPathComponent(".claude.json").path))
        #expect(mcp.contains(home.appendingPathComponent(".codex/config.toml").path))
        #expect(mcp.contains(home.appendingPathComponent("repoB/.mcp.json").path))
        // config.toml 太通用：home 两层之外不收
        #expect(!mcp.contains(home.appendingPathComponent("workspace/nested-kit/config.toml").path))
    }

    @Test func discoveryRespectsMaxDepth() throws {
        let (home, base) = try makeFixture()
        defer { try? FileManager.default.removeItem(at: base) }
        let shallow = Set(ScopeDiscoverer().discover(roots: [home], home: home, maxDepth: 2).locations
                            .filter { $0.kind == .skillDirectory }.map(\.path))
        // maxDepth 2 内可达：~/.codex/skills、~/plain/skills、~/repoB/skills
        #expect(shallow.contains(home.appendingPathComponent(".codex/skills").path))
        #expect(shallow.contains(home.appendingPathComponent("plain/skills").path))
        // 更深的 Agent 插件树与项目内 .claude/skills 不在浅扫里
        #expect(!shallow.contains(home.appendingPathComponent(".qwenworkcn/plugins/doodle/skills").path))
        #expect(!shallow.contains(home.appendingPathComponent("repoA/.claude/skills").path))
    }

    @Test func discoveryDoesNotFollowSymlinks() throws {
        let (home, base) = try makeFixture()
        defer { try? FileManager.default.removeItem(at: base) }
        let outside = base.appendingPathComponent("outside/skills")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: home.appendingPathComponent("link-to-outside"),
                                                   withDestinationURL: outside)
        let found = Set(discover(home).filter { $0.kind == .skillDirectory }.map(\.path))
        #expect(!found.contains(outside.path), "符号链接目标被跟随，全盘有环风险")
    }

    // MARK: - 分类：层级 × 归属 × 项目

    @Test func classificationLevelsAndAgents() throws {
        let (home, base) = try makeFixture()
        defer { try? FileManager.default.removeItem(at: base) }
        func cls(_ rel: String, kind: ScanLocation.Kind = .skillDirectory) -> LocationClassification {
            LocationClassifier.classify(
                DiscoveredLocation(path: home.appendingPathComponent(rel).path, kind: kind), home: home)
        }

        // 官方映射（C1/C2）与发现出的新工具目录
        let codex = cls(".codex/skills")
        #expect(codex.agentId == "codex" && codex.level == .user && codex.projectId == nil)
        let shared = cls(".agents/skills")
        #expect(shared.agentId == "codex" && shared.level == .user)
        let qoder = cls(".qwenworkcn/plugins/doodle/skills")
        #expect(qoder.agentId == "qoder" && qoder.level == .user, "D6：Agent 点目录树内仍算用户级")

        // 智昊裁决：未知归属直接用父目录名（.thincoder → thincoder；.config 可看穿一层）
        #expect(cls(".thincoder/skills").agentId == "thincoder")
        #expect(cls(".config/devin/skills").agentId == "devin")
        #expect(cls(".grok/skills").agentId == "grok")

        // 项目级由 .git 定根
        let inRepo = cls("repoA/.claude/skills")
        #expect(inRepo.level == .project && inRepo.projectId == "proj-repoA" && inRepo.agentId == "claude")
        let atRoot = cls("repoB/skills")
        #expect(atRoot.level == .project && atRoot.projectId == "proj-repoB", "仓库根直属 skills 应算项目级")

        // home 直属且无 .git → 用户级；两层以下且无 .git → 其他位置
        #expect(cls("plain/skills").level == .user)
        let loose = cls("workspace/nested-kit/skills")
        #expect(loose.level == .project && loose.projectId == nil, "判不出项目的位置必须落进其他位置")
    }

    @Test func classificationOfMCPFiles() throws {
        let (home, base) = try makeFixture()
        defer { try? FileManager.default.removeItem(at: base) }
        // home 本身的裸配置文件：层级用户级，归属从文件名推
        let claudeJSON = LocationClassifier.classify(
            DiscoveredLocation(path: home.appendingPathComponent(".claude.json").path, kind: .mcpJSON), home: home)
        #expect(claudeJSON.level == .user && claudeJSON.agentId == "claude")
        let repoMCP = LocationClassifier.classify(
            DiscoveredLocation(path: home.appendingPathComponent("repoB/.mcp.json").path, kind: .mcpJSON), home: home)
        #expect(repoMCP.level == .project && repoMCP.projectId == "proj-repoB")
    }

    // MARK: - 范围构建（回归：设置页空行）

    @Test func scopeDropsLocationsThatNoLongerExist() throws {
        let (home, base) = try makeFixture()
        defer { try? FileManager.default.removeItem(at: base) }
        let stale = DiscoveredLocation(path: home.appendingPathComponent("gone/skills").path, kind: .skillDirectory)
        let live = DiscoveredLocation(path: home.appendingPathComponent(".codex/skills").path, kind: .skillDirectory)
        let scope = ScopeBuilder.scope(discovered: [stale, live], home: home)
        // skill-library 批：库根按设计决策①无条件收录（不存在也进——首库出现前 App 才有监听根），
        // 其余不存在的位置仍剔除（「该路径不存在」空行的来源）。断言随新合同更新：
        // 剔掉的只有 gone，进范围的是 live(.codex/skills) + 库根(.skill-library)。
        #expect(scope.locations.map(\.url.lastPathComponent) == ["skills", ".skill-library"])
        #expect(!scope.locations.contains { $0.url.path.contains("gone") },
                "不存在的位置必须剔除——这正是「该路径不存在」空行的来源")
    }

    @Test func scopeBuildsProjectListFromGitRoots() throws {
        let (home, base) = try makeFixture()
        defer { try? FileManager.default.removeItem(at: base) }
        let scope = ScopeBuilder.scope(discovered: discover(home), home: home)
        #expect(Set(scope.projects.map(\.id)) == ["proj-repoA", "proj-repoB"])
        // 用户级与其他位置不应产生项目
        #expect(scope.projects.allSatisfy { $0.path.hasPrefix(home.path) })
    }

    @Test func ignoredLocationsAreExcludedAndOthersFlagged() throws {
        let (home, base) = try makeFixture()
        defer { try? FileManager.default.removeItem(at: base) }
        let all = discover(home)
        let ignoredPath = home.appendingPathComponent(".codex/skills").path
        let scope = ScopeBuilder.scope(discovered: all, home: home, ignored: [ignoredPath])
        #expect(!scope.locations.contains { $0.url.path == ignoredPath })
        #expect(scope.locations.contains { $0.isUnclassified }, "fixture 里 workspace/nested-kit/skills 应是其他位置")
    }

    // MARK: - 缓存

    @Test func discoveryCacheRoundTrips() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("sc-cache-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let paths = SkillControllerPaths(supportDir: tmp)
        let cache = DiscoveryCache(paths: paths)
        #expect(cache.load() == nil)

        let snap = DiscoverySnapshot(savedAt: Date(timeIntervalSince1970: 1_800_000_000),
                                     rules: .standard, roots: ["/"],
                                     locations: [DiscoveredLocation(path: "/Users/x/.codex/skills", kind: .skillDirectory),
                                                 DiscoveredLocation(path: "/Users/x/.claude.json", kind: .mcpJSON)],
                                     dirsVisited: 98173, unreadableCount: 230)
        cache.save(snap)
        let back = try #require(cache.load())
        #expect(back.locations == snap.locations)
        #expect(back.rules == .standard, "规则一致性用于判定缓存是否可用")
        #expect(back.dirsVisited == 98173)

        cache.clear()
        #expect(cache.load() == nil)
    }

    @Test func oldCacheWithoutNewFieldsStillDecodes() throws {
        // 给快照加字段时必须是可选：旧缓存缺字段若声明成非可选，整个 load() 会失败，
        // 用户就白等一次 44 秒全盘重扫
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("sc-oldcache-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let paths = SkillControllerPaths(supportDir: tmp)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        try Data("""
        {"savedAt":700000000,"roots":["/"],"dirsVisited":81204,"unreadableCount":226,
         "rules":{"prunedCategories":["dependency","cache"],"skillsDirNames":["skills"],
                  "mcpFileNames":["mcp.json"],"fullDiskRoots":["/"],"maxDepth":24},
         "locations":[{"path":"/Users/x/.codex/skills","kind":"skillDirectory"}]}
        """.utf8).write(to: paths.discoveryCacheFile)

        let back = try #require(DiscoveryCache(paths: paths).load())
        #expect(back.locations.count == 1)
        #expect(back.typedPrunedCounts.isEmpty, "缺字段就当没统计，不要编造数字")
    }

    @Test func discoveryOutcomeIDsAreStableAcrossProcesses() {
        // 缓存与跨进程比对用 path 而非 hashValue（Swift 哈希每进程加盐）
        let a = DiscoveredLocation(path: "/Users/x/.codex/skills", kind: .skillDirectory)
        let b = DiscoveredLocation(path: "/Users/x/.codex/skills", kind: .skillDirectory)
        #expect(a.id == b.id && a.id == "skillDirectory:/Users/x/.codex/skills")
    }

    // MARK: - 性能护栏（全盘遍历不进首屏关键路径）

    @Test func standardRulesPruneKnownMirrorsAndVolumes() {
        // 真机回归：全盘发现曾把整棵 home 树扫两遍（/Users 与 /.nofollow/Users 是 firmlink 镜像），
        // 命中数从 897 直接翻倍到 1802。镜像前缀 + inode 去重两道防线都要在。
        let rules = DiscoveryRules.standard
        #expect(rules.category(forPath: "/.nofollow/Users/x/.codex", home: "/Users/x") == .systemDirs)
        #expect(rules.category(forPath: "/System/Volumes/Data", home: "/Users/x") == .systemDirs)
        #expect(rules.category(forName: "node_modules") == .dependency)
        #expect(rules.category(forName: "Library") == .systemDirs)
        #expect(rules.category(forName: "builtin") == .builtin)
        #expect(rules.category(forName: "QwenWorkCN.app") == .appBundle)
        #expect(rules.category(forName: "marketplace-cache") == .cache)
        // 工具自己的回收站/备份副本：本机实测 902 处里有 154 处在这些树下
        #expect(rules.category(forName: "trash") == .copy)
        #expect(rules.category(forName: "Trash") == .copy)
        #expect(rules.category(forName: "backup") == .copy)
        // 反过来：可能真写了 skill 的位置不能被顺手剪掉
        #expect(rules.category(forName: "vendor") == nil)
        #expect(rules.category(forName: "tests") == nil)
        #expect(rules.category(forName: "fixtures") == nil)
        // skill-library 批守护断言（评审 fix 轮新增）：库根不被剪枝名单吃掉——
        // `.skill-library` 对整名/后缀/前缀三张表都必须零命中；名单扩充引入误剪时这里先红
        #expect(rules.category(forName: ".skill-library") == nil,
                ".skill-library 被剪枝名单误伤——库整层不可见，add 后 App 永远看不见")
        let home = "/Users/x"
        #expect(rules.category(forPath: home + "/.skill-library", home: home) == nil)
        #expect(rules.category(forPath: home + "/.skill-library/docx", home: home) == nil)
    }

    @Test func pruneCategoriesAreUserToggleable() {
        // 智昊裁决：剪枝按类可选。媒体库默认剪（本机命中 0），桌面/下载默认留（可能解压了 skill 包）
        let rules = DiscoveryRules.standard
        #expect(rules.isCategoryPruned(.mediaLibraries))
        #expect(!rules.isCategoryPruned(.personalFolders))
        let home = "/Users/x"
        #expect(rules.category(forPath: home + "/Music/Extras/skills", home: home) == .mediaLibraries)
        #expect(rules.category(forPath: home + "/Downloads/kit/skills", home: home) == nil)

        // 关掉一类后该类的名字与前缀都不再生效
        var loosened = rules
        loosened.prunedCategories.remove(.dependency)
        #expect(loosened.category(forName: "node_modules") == nil)
        loosened.prunedCategories.insert(.personalFolders)
        #expect(loosened.category(forPath: home + "/Desktop/x", home: home) == .personalFolders)
    }

    @Test func agentOriginDistinguishesRealAgentsFromProjectNames() throws {
        // 智昊裁决：项目名冒充的归属要能和真 Agent 分开，且不计进 Agents 计数
        let (home, base) = try makeFixture()
        defer { try? FileManager.default.removeItem(at: base) }
        func origin(_ rel: String) -> AgentOrigin {
            LocationClassifier.classify(
                DiscoveredLocation(path: home.appendingPathComponent(rel).path, kind: .skillDirectory),
                home: home).agentOrigin
        }
        #expect(origin(".codex/skills") == .officialAgentDir)          // 官方四家
        #expect(origin(".thincoder/skills") == .toolDir)               // 其他工具的点目录
        #expect(origin(".config/devin/skills") == .toolDir)            // 通用容器看穿一层
        #expect(origin("plain/skills") == .containerName)              // 所在目录名兜底 = 项目名
        #expect(origin("workspace/nested-kit/skills") == .containerName)
        #expect(!AgentOrigin.containerName.isRealAgent)
        #expect(AgentOrigin.toolDir.isRealAgent && AgentOrigin.officialAgentDir.isRealAgent)
    }

    @Test func pruneIndexAgreesWithComputedLookups() {
        // 索引是热路径实现，计算属性是权威定义，两者结论必须一致
        let rules = DiscoveryRules.standard
        let home = "/Users/x"
        let index = rules.pruneIndex(home: home)
        let names = ["node_modules", ".git", "Library", "builtin", ".cache", "Caches", "trash",
                     "Trash", "backup", "DerivedData", "Foo.app", "x.framework", "marketplace-cache",
                     "vendor", "tests", "fixtures", "skills", "src"]
        for n in names {
            #expect(index.category(name: n, path: home + "/" + n) == rules.category(forName: n),
                    "索引与计算属性在 \(n) 上不一致")
        }
        let paths = ["/.nofollow/Users/x", "/System/Volumes/Data", home + "/Music/a", home + "/Downloads/b"]
        for p in paths {
            #expect(index.category(name: (p as NSString).lastPathComponent, path: p)
                    == rules.category(forPath: p, home: home), "路径判定在 \(p) 上不一致")
        }
    }

    @Test func discoveryOverWideTreeStaysFast() throws {
        // 回归护栏：剪枝判断曾写成每条目重建 8 个类别数组的计算属性，
        // 把 CLI 冷启动从 0.7s 拖到 357s（真机实测）。这里用一棵够宽的树卡住时间预算。
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("sc-wide-\(UUID().uuidString)")
        let fm = FileManager.default
        defer { try? fm.removeItem(at: base) }
        for i in 0..<200 {
            let parent = base.appendingPathComponent("pkg\(i)")
            for j in 0..<15 {
                try fm.createDirectory(at: parent.appendingPathComponent("sub\(j)"),
                                       withIntermediateDirectories: true)
            }
            try fm.createDirectory(at: parent.appendingPathComponent("node_modules/dep/skills"),
                                   withIntermediateDirectories: true)
        }
        let start = Date()
        let outcome = ScopeDiscoverer().discover(roots: [base], home: base, maxDepth: 24)
        let elapsed = Date().timeIntervalSince(start)
        #expect(outcome.locations.isEmpty, "node_modules 下的 skills 不该被发现")
        #expect(elapsed < 5.0, "3,200 个目录的发现耗时 \(elapsed)s，剪枝判断又退化成计算属性了")
    }

    @Test func homeShallowDiscoveryIsFastEnoughForFirstPaint() throws {
        let (home, base) = try makeFixture()
        defer { try? FileManager.default.removeItem(at: base) }
        let start = Date()
        _ = ScopeDiscoverer().discover(roots: [home], home: home, maxDepth: 2).locations
        #expect(Date().timeIntervalSince(start) < 1.0, "首屏前的快扫必须远小于 1s（本机实测约 1s）")
    }
}
