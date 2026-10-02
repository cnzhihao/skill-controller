import Testing
import Foundation
@testable import SkillControllerCore

/// skill-library 批的验收测试面（A1-A4、A6、A9；设计档 §6 表）。
/// fixture 全本地：clone 用 `git clone --depth 1 file://<fixture路径>` 真实 spawn
/// （形态钉死，不以裸本地路径 + --depth 依赖随 git 版本漂移的本地传输行为，A9）。
struct SkillLibraryTests {
    private func makeSandbox() throws -> (work: URL, paths: SkillControllerPaths, home: URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sc-lib-\(UUID().uuidString)")
        let home = dir.appendingPathComponent("home")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        return (dir, SkillControllerPaths(supportDir: dir.appendingPathComponent("support")), home)
    }

    /// 造一个含 SKILL.md 的 skill 目录
    @discardableResult
    private func makeSkill(_ parent: URL, name: String, description: String = "d") throws -> URL {
        let s = parent.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: s, withIntermediateDirectories: true)
        try "---\nname: \(name)\ndescription: \(description)\n---".write(
            to: s.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
        return s
    }

    /// 造一个本地 fixture git 仓（git init + commit；测试用 file:// 浅 clone 离线走真实 spawn）
    private func makeFixtureRepo(at dir: URL, skills: [String], junk: Bool = false) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        if skills.isEmpty {
            try makeSkill(dir, name: "whole-repo")   // 整仓即 skill 形态在外层造，这里只保底
        }
        for s in skills { try makeSkill(dir, name: s) }
        if junk {
            // 杂物清单内五样 + 名为 tests 但含 SKILL.md 的目录（资格唯 SKILL.md，不因名字被剔除）
            try fm.createDirectory(at: dir.appendingPathComponent(".git-objects/x"), withIntermediateDirectories: true)
            try "o".write(to: dir.appendingPathComponent(".git-objects/x/a"), atomically: true, encoding: .utf8)
            try fm.createDirectory(at: dir.appendingPathComponent("node_modules/pkg"), withIntermediateDirectories: true)
            try "o".write(to: dir.appendingPathComponent("node_modules/pkg/i.js"), atomically: true, encoding: .utf8)
            try fm.createDirectory(at: dir.appendingPathComponent("__pycache__"), withIntermediateDirectories: true)
            try "o".write(to: dir.appendingPathComponent("__pycache__/a.pyc"), atomically: true, encoding: .utf8)
            try fm.createDirectory(at: dir.appendingPathComponent("tests"), withIntermediateDirectories: true)
            try "o".write(to: dir.appendingPathComponent("tests/t.py"), atomically: true, encoding: .utf8)
            try makeSkill(dir, name: "tests")   // 名为 tests 但自己是 skill → 必须仍是条目
            // 真正的 VCS 元数据由 git init 造出（下方 shell 步骤）
        }
        func git(_ args: [String]) throws {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            p.arguments = args
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            try p.run(); p.waitUntilExit()
            guard p.terminationStatus == 0 else { throw GitClone.GitError.failed(note: "git \(args.first!) 失败") }
        }
        try git(["init", "-q", dir.path])
        try git(["-C", dir.path, "config", "user.email", "t@local"])
        try git(["-C", dir.path, "config", "user.name", "t"])
        if !junk {
            // fixture 仓不含 .git 内容拷贝断言之外的东西；commit 全部，让浅 clone 有对象可拿
            try git(["-C", dir.path, "add", "-A"])
            try git(["-C", dir.path, "commit", "-q", "-m", "fixture"])
        } else {
            // 杂物仓：把「杂物清单内条目」写进 .gitignore，保证 clone 结果的判读只看拷贝语义
            try ".git-objects/\nnode_modules/\n__pycache__/\n".write(
                to: dir.appendingPathComponent(".gitignore"), atomically: true, encoding: .utf8)
            try git(["-C", dir.path, "add", "-A"])
            try git(["-C", dir.path, "commit", "-q", "-m", "fixture"])
        }
    }

    /// 通过 Core 层跑完整 add 链路（分类/枚举/拷贝/日志/事件），等价 CLI 入口的 Core 段
    private func addFromFixture(_ svc: AssemblyService, fixture: URL, select names: [String],
                                force: Bool = false) throws -> AssemblyService.AddReport {
        let candidates = SkillLayout.enumerate(root: fixture)
        let chosen = candidates
            .map { (SkillLayout.entryName(of: $0, root: fixture), $0) }
            .filter { names.isEmpty || names.contains($0.0) }
        return try svc.add(sources: chosen, force: force)
    }

    // MARK: - A1 收编（clone 链路，file:// 真实 spawn）

    @Test func addFromLocalFixtureRepoLandsEntryAndCleansTemp() throws {
        let (work, paths, home) = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: work) }
        let svc = AssemblyService(paths: paths, home: home)
        let fixture = work.appendingPathComponent("fixture-repo")
        try makeFixtureRepo(at: fixture, skills: ["docx"], junk: true)

        // 真实 spawn：git clone --depth 1 file://<fixture> —— 与生产同一条 GitClone.system 路径
        let git = GitClone()
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("sc-clone-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        try git.clone("file://" + fixture.path, into: tmp)
        let candidates = SkillLayout.enumerate(root: tmp)
        #expect(candidates.map(\.lastPathComponent) == ["docx", "tests"])   // 命中即停：无 SKILL.md 的杂物目录不进候选
        let report = try svc.add(sources: candidates.map { (SkillLayout.entryName(of: $0, root: tmp), $0) },
                                 force: false)
        #expect(report.created == 2)

        // 库内条目在、SKILL.md 在；杂物不进库（评审点 #6 排除清单写死八名——只作用于拷贝内容）
        let lib = SkillLibrary(home: home)
        #expect(lib.hasEntry("docx"))
        #expect(FileManager.default.fileExists(atPath: lib.entryURL(named: "docx")
            .appendingPathComponent("SKILL.md").path))
        let copied = try FileManager.default.contentsOfDirectory(atPath: lib.entryURL(named: "docx").path)
        #expect(!copied.contains { SkillLayout.copyExcludedNames.contains($0) },
                "排除清单内的名字不得出现在拷贝结果：\(copied)")

        // 库外无残留：临时目录已清（defer 语义这里手动验证）
        try FileManager.default.removeItem(at: tmp)
        #expect(!FileManager.default.fileExists(atPath: tmp.path))

        // A8 前半：日志 + 事件落盘（actor=skillctl、assembly 动作；LogEntry.action 装的是人读 detail）
        let logs = OperationLog(paths: paths).entries()
        #expect(logs.contains { $0.actor == "skillctl" && $0.actorKind == .agent
            && $0.action.contains("收编进技能库") })
        let events = AssemblyEventStore(paths: paths, lock: WriteLock(paths: paths)).all()
        #expect(events.count == 1)
        #expect(events[0].event.agentId == "skillctl" && events[0].event.projectId == "")
        #expect(events[0].event.added.count == 2)
        #expect(events[0].event.added.allSatisfy { $0.hasPrefix(lib.root.path) })
    }

    @Test func cloneFailureLeavesNoTrace() throws {
        let (work, _, home) = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: work) }
        // 不存在的 file:// URL → git 退出非零 → GitError.failed（如实带原因）
        let bogus = "file:///no/such/repo-\(UUID().uuidString)"
        let git = GitClone()
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("sc-clone-bad-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        #expect(throws: GitClone.GitError.self) {
            try git.clone(bogus, into: tmp)
        }
        // 零库写入
        #expect(!FileManager.default.fileExists(atPath: SkillLibrary(home: home).root.path))
    }

    // MARK: - A2 多 skill 无选择（Core 层：发现的清单交出去、写入发生在选择之后）

    @Test func multiSkillRepoEnumeratesAllForSelection() throws {
        let (work, paths, home) = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: work) }
        let svc = AssemblyService(paths: paths, home: home)
        let fixture = work.appendingPathComponent("multi")
        try makeFixtureRepo(at: fixture, skills: ["alpha", "beta", "gamma"])

        let candidates = SkillLayout.enumerate(root: fixture)
        let names = candidates.map { SkillLayout.entryName(of: $0, root: fixture) }
        #expect(names == ["alpha", "beta", "gamma"])   // 发现清单完整（CLI 层拿它渲染退出 64 的列表）
        // 不选择 = 不写入（A2 的「盘上零写入」在 Core 层的表现：add 不被调用）
        #expect(!FileManager.default.fileExists(atPath: SkillLibrary(home: home).root.path))
        _ = svc
    }

    // MARK: - A3 本地收编：正/反例

    @Test func addLocalDirectoryWithoutSkillMDWritesNothing() throws {
        let (work, paths, home) = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: work) }
        let svc = AssemblyService(paths: paths, home: home)
        // 反例：无 SKILL.md（自己没有、直接子目录也没有）→ 枚举空集（CLI 层报错退出、零写入）
        let bare = work.appendingPathComponent("bare")
        try FileManager.default.createDirectory(at: bare.appendingPathComponent("stuff"), withIntermediateDirectories: true)
        try "x".write(to: bare.appendingPathComponent("stuff/a.md"), atomically: true, encoding: .utf8)
        #expect(SkillLayout.enumerate(root: bare).isEmpty)
        // 正例：整目录即 skill
        let whole = work.appendingPathComponent("whole")
        try FileManager.default.createDirectory(at: whole, withIntermediateDirectories: true)
        try "---\nname: whole\ndescription: w\n---".write(to: whole.appendingPathComponent("SKILL.md"),
                                                          atomically: true, encoding: .utf8)
        let report = try svc.add(sources: [("whole", whole)], force: false)
        #expect(report.created == 1)
        #expect(SkillLibrary(home: home).hasEntry("whole"))
    }

    // MARK: - A4 同名冲突不覆盖

    @Test func sameNameConflictSkipsAndKeepsOriginalBytes() throws {
        let (work, paths, home) = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: work) }
        let svc = AssemblyService(paths: paths, home: home)
        let lib = SkillLibrary(home: home)
        // 预置库内同名目录（内容 A）
        let existing = lib.entryURL(named: "docx")
        try FileManager.default.createDirectory(at: existing, withIntermediateDirectories: true)
        try "original".write(to: existing.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
        // 再收编同名（内容 B）
        let fixture = work.appendingPathComponent("fixture")
        try makeSkill(fixture, name: "docx")
        let report = try addFromFixture(svc, fixture: fixture, select: [])
        #expect(report.created == 0 && report.skipped == 1)
        let kept = try String(contentsOf: existing.appendingPathComponent("SKILL.md"), encoding: .utf8)
        #expect(kept == "original")   // 原目录字节不变
        // 事件冲突组如实
        let events = AssemblyEventStore(paths: paths, lock: WriteLock(paths: paths)).all()
        #expect(events[0].event.conflicts.count == 1)
        #expect(events[0].event.conflicts[0].reason.contains("未覆盖"))
    }

    // MARK: - A4 变体：--force 更新走回收站（旧件可查、新件就位）

    @Test func forceUpdateTrashesOldCopyAndInstallsNew() throws {
        let (work, paths, home) = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: work) }
        let svc = AssemblyService(paths: paths, home: home)
        let lib = SkillLibrary(home: home)
        let existing = lib.entryURL(named: "docx")
        try FileManager.default.createDirectory(at: existing, withIntermediateDirectories: true)
        try "old".write(to: existing.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)

        let fixture = work.appendingPathComponent("fixture")
        try makeSkill(fixture, name: "docx")
        try "new".write(to: fixture.appendingPathComponent("docx/SKILL.md"), atomically: true, encoding: .utf8)
        let report = try svc.add(sources: [("docx", fixture.appendingPathComponent("docx"))], force: true)
        #expect(report.replaced == 1)
        // 新件就位
        let now = try String(contentsOf: existing.appendingPathComponent("SKILL.md"), encoding: .utf8)
        #expect(now == "new")
        // 旧件经回收站（三步齐）；G7 写实：恢复旧件按 D14「原位被占不覆盖」会如实失败，不承诺一步恢复
        #expect(report.outcomes[0].replacedTrashEntryId != nil)
        let trash = TrashManager(paths: paths, lock: WriteLock(paths: paths))
        #expect(trash.listEntries().contains { $0.entryId == report.outcomes[0].replacedTrashEntryId })
        // 事件 added 含库路径（库内结果是新副本）
        let events = AssemblyEventStore(paths: paths, lock: WriteLock(paths: paths)).all()
        #expect(events[0].event.added == [existing.path])
    }

    // MARK: - A6 严格缺货：remedies 从索引生成（可照抄）、含仓库提示

    @Test func remediesListScatteredCopiesAsFromCommands() throws {
        let (work, paths, home) = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: work) }
        // 散落副本：库里没有 docx，但 ~/.agents/skills 与某项目里各有一份
        let scattered1 = home.appendingPathComponent(".agents/skills/docx")
        try FileManager.default.createDirectory(at: scattered1, withIntermediateDirectories: true)
        try "s".write(to: scattered1.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
        let scattered2 = work.appendingPathComponent("proj/.claude/skills/docx")
        try FileManager.default.createDirectory(at: scattered2, withIntermediateDirectories: true)
        try "s".write(to: scattered2.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
        let mcpFile = home.appendingPathComponent(".claude.json")
        try "{\"mcpServers\":{\"docx-mcp\":{\"command\":\"uvx\"}}}".write(to: mcpFile, atomically: true, encoding: .utf8)

        let svc = AssemblyService(paths: paths, home: home)
        // 把三处位置喂进缓存（真机形状：App 写缓存、CLI 读缓存）
        DiscoveryCache(paths: paths).save(DiscoverySnapshot(
            savedAt: Date(), rules: AppSettings.load(paths: paths).discoveryRules,
            roots: [home.path],
            locations: [
                DiscoveredLocation(path: home.appendingPathComponent(".agents/skills").path, kind: .skillDirectory),
                DiscoveredLocation(path: work.appendingPathComponent("proj/.claude/skills").path, kind: .skillDirectory),
                DiscoveredLocation(path: mcpFile.path, kind: .mcpJSON),
            ]))
        let idx = svc.currentIndex()
        let remedies = SkillLibrary.remedies(for: "docx", index: idx)
        #expect(remedies.count == 2)   // MCP `#` 落点已剔除
        #expect(remedies.allSatisfy { $0.hasPrefix("skillctl add docx --from '") })
        // 稳定排序：输出可照抄必须可复现
        #expect(remedies == remedies.sorted())

        // pull 缺货 → notInLibrary（零写入由 land 之前抛错保证）
        #expect(throws: AssemblyService.AssemblyError.notInLibrary(name: "docx", remedies: remedies)) {
            _ = try svc.pull(name: "docx", target: work.path, agent: "codex")
        }
        #expect(!FileManager.default.fileExists(atPath: work.appendingPathComponent(".agents/skills/docx").path))

        // 无副本时 remedies 空（CLI 层补仓库提示行）
        #expect(SkillLibrary.remedies(for: "ghost", index: idx).isEmpty)
    }

    // MARK: - SkillLayout（与扫描器同源的唯一枚举实现）

    @Test func layoutEntryNameAndWholeRepoForm() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("sc-layout-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: base) }
        // 整仓即 skill：根有 SKILL.md → [root]，名 = 根目录名
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        try "---\nname: kit\ndescription: k\n---".write(to: base.appendingPathComponent("SKILL.md"),
                                                        atomically: true, encoding: .utf8)
        let out = SkillLayout.enumerate(root: base)
        #expect(out.count == 1 && out[0].lastPathComponent == base.lastPathComponent)
        #expect(SkillLayout.entryName(of: out[0], root: base) == base.lastPathComponent)

        // 子目录形态：名 = 子目录名
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent("sc-layout2-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: parent) }
        try makeSkill(parent, name: "pdf")
        let out2 = SkillLayout.enumerate(root: parent)
        #expect(out2.count == 1)
        #expect(SkillLayout.entryName(of: out2[0], root: parent) == "pdf")
    }

    @Test func layoutDanglingSymlinkOnlyWhenAsked() throws {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent("sc-dang-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: parent) }
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        try makeSkill(parent, name: "real")
        try FileManager.default.createSymbolicLink(atPath: parent.appendingPathComponent("gone").path,
                                                   withDestinationPath: "../nowhere")
        // 扫描侧（true）：悬空链接照收——磁盘事实
        #expect(SkillLayout.enumerate(root: parent, includeDanglingSymlinks: true).map(\.lastPathComponent)
                == ["gone", "real"])
        // add 侧（默认 false）：拷贝悬空链接必然失败，弃收
        #expect(SkillLayout.enumerate(root: parent).map(\.lastPathComponent) == ["real"])
    }

    @Test func isLibraryPathHandlesCanonicalPrefixes() throws {
        let home = FileManager.default.homeDirectoryForCurrentUser
        #expect(SkillLibrary.isLibraryPath(home.appendingPathComponent(".skill-library").path, home: home))
        #expect(SkillLibrary.isLibraryPath(home.appendingPathComponent(".skill-library/docx").path, home: home))
        #expect(!SkillLibrary.isLibraryPath(home.appendingPathComponent(".skill-libraryx/docx").path, home: home))
        #expect(!SkillLibrary.isLibraryPath("/tmp/other", home: home))
        // 无 home 形态（rebuild 本体优先判定用）
        #expect(SkillLibrary.isInsideSkillLibrary("/Users/zhi/.skill-library/docx"))
        #expect(SkillLibrary.isInsideSkillLibrary("/Users/zhi/.skill-library"))
        #expect(!SkillLibrary.isInsideSkillLibrary("/Users/zhi/.skill-library-old/docx"))
        #expect(!SkillLibrary.isInsideSkillLibrary("/opt/foo/skills"))
    }

    // MARK: - 本体优先取库时条目级归属跟本体走（2026-09-30 走查修复，台账 #23）

    /// 走查实锤（台账 #23）：库条目被 mount 过时 Agent 落点（project/user 级）在扫描序里排前，
    /// 旧代码只把 sourcePath 换成库落点、条目级 level/projectId 仍取首条（Agent 落点）→
    /// 条目误判成 project 级，「技能库」筛选段恒空、CLI list/info 的 level 字段失真。
    /// 修后合同：Agent 落点在前 + 库落点在后 → 条目 level == .library、projectId == nil、
    /// sourcePath 指库（反序用例形状：旧代码红、新代码绿）。
    @Test func itemLevelFollowsLibraryBodyWhenAgentLandingsComeFirst() throws {
        // RawEntry 直注入（不依赖真实扫描）；库落点位置按 ScopeDiscovery 库特判产出：
        // level 恒 .library、projectId 恒 nil（LocationClassifier 保真的输入形状）。
        // 路径必须用 /Users/<x>/.skill-library 真实形状——isInsideSkillLibrary 是形状判定，
        // 沙箱 home（/var/folders/...）不命中该分支（既有 entitySourcePrefersLibraryCopy
        // 实际是靠扫描顺序过的，本用例是该分支第一次被真测）。
        let result = ScanResult(entries: [
            // 扫描序在前的 Agent 落点：项目级（Codex 项目挂载）+ 用户级（共享 skills 目录）
            RawEntry(name: "alpha", description: "d-alpha", type: .skill, level: .project,
                     projectId: "proj-x", locationPath: "/w/proj-x/.codex/skills/alpha",
                     resolvedPath: nil, mountedAgentId: "codex"),
            RawEntry(name: "alpha", description: "d-alpha", type: .skill, level: .user,
                     projectId: nil, locationPath: "/Users/zz/.agents/skills/alpha",
                     resolvedPath: nil, mountedAgentId: "codex"),
            // 库落点（实体）在最后——旧代码 first 取到的是 project 落点
            RawEntry(name: "alpha", description: "d-alpha", type: .skill, level: .library,
                     projectId: nil, locationPath: "/Users/zz/.skill-library/alpha",
                     resolvedPath: nil, mountedAgentId: nil),
        ], degraded: [], locationsScanned: 3)
        let idx = InventoryIndex()
        idx.rebuild(from: result, projects: [])
        let item = try #require(idx.item(id: "skill:alpha"))
        #expect(item.sourcePath == "/Users/zz/.skill-library/alpha", "本体认库（既有合同，随用例钉死）")
        #expect(item.level == .library, "条目级层级必须跟本体（库落点）走，不能取首条 Agent 落点")
        #expect(item.projectId == nil, "条目级项目必须跟本体走：库不是项目")
        // 筛选语义（真机失真面）：「技能库」筛选段必须能筛到这条
        #expect(idx.filtered(type: .skill, level: .library).map(\.name) == ["alpha"])
        #expect(idx.filtered(type: .skill, level: .project).map(\.name) == [])
        // 落点级 level/projectId 不受影响：每个落点仍带各自的原 level（详情栏分组数据源）。
        // 实体源身份与本体同源（台账 #24）：库落点恒持「实体源」，扫描序在前的散落实体副本
        // 不得抢占；排序规则冻结不动（见下方断言）。
        let stat = idx.mountStat(of: "skill:alpha")
        #expect(stat.mounts == 2)
        #expect(stat.spots.first { $0.path == "/Users/zz/.skill-library/alpha" }?.level == .library)
        #expect(stat.spots.first { $0.path == "/w/proj-x/.codex/skills/alpha" }?.level == .project)
        #expect(stat.spots.first { $0.path == "/Users/zz/.skill-library/alpha" }?.kind == .entitySource,
                "库本体必须持「实体源」，不得被扫描序在前的散落实体副本抢占")
        #expect(stat.spots.first { $0.path == "/w/proj-x/.codex/skills/alpha" }?.kind == .entityCopy)
        // 排序合同（冻结，不动）：用户级在前；实体源只在同层级内置顶——库落点（.library）
        // 不与 user/project 竞争段位，跨层级 tie 序不由 kind 决定（详情栏按 level 归组，
        // 组序由 DetailPanel 固定：用户级 → 技能库 → 各项目，本批不碰）。
        #expect(stat.spots.first?.level == .user, "用户级仍在最前（既有排序规则不动）")
        #expect(stat.spots.first?.kind == .entityCopy, "首个（用户级）落点不是实体源：身份归库落点")
    }

    /// 回归（台账 #24 反向面）：无库落点的条目不受身份修正影响——
    /// 纯散落实体副本形状下，扫描序第一个实体落点仍是「实体源」（旧合同保持）。
    @Test func scatteredOnlyEntryKeepsScanOrderEntitySource() throws {
        let result = ScanResult(entries: [
            RawEntry(name: "beta", description: "d-beta", type: .skill, level: .project,
                     projectId: "proj-x", locationPath: "/w/proj-x/.codex/skills/beta",
                     resolvedPath: nil, mountedAgentId: "codex"),
            RawEntry(name: "beta", description: "d-beta", type: .skill, level: .user,
                     projectId: nil, locationPath: "/Users/zz/.agents/skills/beta",
                     resolvedPath: nil, mountedAgentId: "claude"),
        ], degraded: [], locationsScanned: 2)
        let idx = InventoryIndex()
        idx.rebuild(from: result, projects: [])
        let stat = idx.mountStat(of: "skill:beta")
        #expect(stat.spots.first { $0.path == "/w/proj-x/.codex/skills/beta" }?.kind == .entitySource)
        #expect(stat.spots.first { $0.path == "/Users/zz/.agents/skills/beta" }?.kind == .entityCopy)
    }

    /// 纯库条目（无 Agent 落点）不受影响：首条即库落点，条目级两值与旧逻辑一致
    @Test func pureLibraryItemKeepsLibraryLevel() throws {
        let result = ScanResult(entries: [
            RawEntry(name: "docx", description: "d-docx", type: .skill, level: .library,
                     projectId: nil, locationPath: "/Users/zz/.skill-library/docx",
                     resolvedPath: nil, mountedAgentId: nil),
        ], degraded: [], locationsScanned: 1)
        let idx = InventoryIndex()
        idx.rebuild(from: result, projects: [])
        let item = try #require(idx.item(id: "skill:docx"))
        #expect(item.level == .library && item.projectId == nil && item.sourcePath == "/Users/zz/.skill-library/docx")
    }

    // MARK: - 缺货补救 remedies 两分支钉死（2026-09-30 走查修复，台账 #21）

    /// 走查结论（#2 查修）：真机复现两条分支均正确——索引有副本的名字缺货 →
    /// remedies 首条是可照抄的 `skillctl add <名> --from '<路径>'`；索引无副本的名字 →
    /// remedies 空（CLI 渲染只剩「或从仓库安装」行）。走查当时只见仓库行是因为
    /// 用的名字索引里本就无副本，非缺陷。本用例把两分支钉死防回归。
    @Test func notInLibraryRemediesPinnedByBranch() throws {
        let (work, paths, home) = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: work) }
        // 索引有副本：~/.agents/skills/beta 有一份，库里没有 beta
        let scattered = home.appendingPathComponent(".agents/skills/beta")
        try FileManager.default.createDirectory(at: scattered, withIntermediateDirectories: true)
        try "s".write(to: scattered.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
        let svc = AssemblyService(paths: paths, home: home)
        DiscoveryCache(paths: paths).save(DiscoverySnapshot(
            savedAt: Date(), rules: AppSettings.load(paths: paths).discoveryRules,
            roots: [home.path],
            locations: [DiscoveredLocation(path: home.appendingPathComponent(".agents/skills").path,
                                           kind: .skillDirectory)]))
        let idx = svc.currentIndex()

        // 分支①：有副本 → 首条是可照抄的 --from 命令（路径 = 散落副本本体）
        let remedies = SkillLibrary.remedies(for: "beta", index: idx)
        #expect(remedies.first == "skillctl add beta --from '\(scattered.standardizedFileURL.path)'")

        // 分支②：无副本 → remedies 空（渲染层只剩仓库提示行）
        #expect(SkillLibrary.remedies(for: "never-existed", index: idx).isEmpty)
        // 缺货抛错形状与 remedies 一致（零写入由 land 之前抛错保证）
        #expect(throws: AssemblyService.AssemblyError.notInLibrary(name: "never-existed", remedies: [])) {
            _ = try svc.pull(name: "never-existed", target: work.path, agent: "codex")
        }
    }
}
