import Testing
import Foundation
@testable import SkillControllerCore

/// Phase 1 单元测试：数据模型合并（同名副本/duplicates）、三维归属计算
struct ModelsMergeTests {
    private func raw(_ name: String, agent: String?, level: Level = .user, project: String? = nil,
                     type: ObjectType = .skill, loc: String, resolved: String? = nil) -> RawEntry {
        RawEntry(name: name, description: "d-\(name)", type: type, level: level, projectId: project,
                 locationPath: loc, resolvedPath: resolved, mountedAgentId: agent)
    }

    @Test func sameNameDuplicatesMergeToOneItem() {
        // types.ts：同一 Skill 3 份副本 → 1 条目 + "副本 ×3"，落点并列
        let result = ScanResult(entries: [
            raw("docx", agent: "codex", loc: "/h/.codex/skills/docx"),
            raw("docx", agent: "claude", loc: "/h/.claude/skills/docx"),
            raw("docx", agent: "qoder", loc: "/h/.qwenworkcn/skills/docx"),
        ], degraded: [], locationsScanned: 3)
        let idx = InventoryIndex()
        idx.rebuild(from: result, projects: [])
        #expect(idx.items.count == 1)
        let item = idx.items[0]
        #expect(item.duplicates.count == 2)
        #expect(item.mountedBy == ["claude", "codex", "qoder"]) // 排序后
        #expect(item.status == .mounted)
    }

    @Test func skillAndMcpSameNameDoNotMerge() {
        let result = ScanResult(entries: [
            raw("figma", agent: "codex", type: .skill, loc: "/h/.codex/skills/figma"),
            raw("figma", agent: "cursor", type: .mcp, loc: "/h/.cursor/mcp.json#figma"),
        ], degraded: [], locationsScanned: 2)
        let idx = InventoryIndex()
        idx.rebuild(from: result, projects: [])
        #expect(idx.items.count == 2)
    }

    @Test func symlinkLandpointGoesToDuplicatesSourceWins() {
        // C3：symlink 落点是引用；实体目录优先作 sourcePath
        let result = ScanResult(entries: [
            raw("dbs", agent: "claude", loc: "/h/.claude/skills/dbs", resolved: "/h/.agents/skills/dbs"),
            raw("dbs", agent: nil, loc: "/h/.agents/skills/dbs"),
        ], degraded: [], locationsScanned: 2)
        let idx = InventoryIndex()
        idx.rebuild(from: result, projects: [])
        #expect(idx.items.count == 1)
        let item = idx.items[0]
        // 条目顺序：claude symlink 先到（sourcePath=解析目标），实体目录后到 → 交换
        #expect(item.sourcePath == "/h/.agents/skills/dbs")
        #expect(item.duplicates == ["/h/.claude/skills/dbs"])
        #expect(item.mountedBy == ["claude"])
        // 共享源自身不归属 Agent，但被 claude 挂载 → mounted
        #expect(item.status == .mounted)
    }

    @Test func ownershipThreeDimensions() {
        // 三维归属：Agent × 用户级/项目级 × 项目
        let result = ScanResult(entries: [
            raw("i18n-audit", agent: "codex", level: .project, project: "proj-x", loc: "/w/proj-x/.codex/skills/i18n-audit"),
            raw("archive", agent: "codex", level: .user, loc: "/h/.codex/skills/archive"),
        ], degraded: [], locationsScanned: 2)
        let idx = InventoryIndex()
        let proj = Project(id: "proj-x", name: "proj-x", path: "/w/proj-x")
        idx.rebuild(from: result, projects: [proj])
        let own1 = idx.ownership(of: "skill:i18n-audit")
        #expect(own1?.agents == ["codex"] && own1?.level == .project && own1?.projectId == "proj-x")
        let own2 = idx.ownership(of: "skill:archive")
        #expect(own2?.level == .user && own2?.projectId == nil)
    }

    @Test func zeroMountIsNeutralFact() {
        // 硬规则：从未挂载 = 中性事实态
        let result = ScanResult(entries: [
            raw("seo-grader", agent: nil, loc: "/h/.agents/skills/seo-grader"),
        ], degraded: [], locationsScanned: 1)
        let idx = InventoryIndex()
        idx.rebuild(from: result, projects: [])
        #expect(idx.items[0].status == .zeroMount)
        #expect(idx.items[0].mountedBy.isEmpty)
    }

    @Test func filterAndSearch() {
        let result = ScanResult(entries: [
            raw("docx", agent: "codex", loc: "/a"),
            raw("pdf", agent: "claude", loc: "/b"),
            raw("puppeteer", agent: "cursor", type: .mcp, loc: "/c"),
        ], degraded: [], locationsScanned: 3)
        let idx = InventoryIndex()
        idx.rebuild(from: result, projects: [])
        #expect(idx.filtered(type: .mcp).count == 1)
        #expect(idx.filtered(type: nil, query: "doc").count == 1)
        // 产品筛选：可激活产品交集
        #expect(idx.filtered(type: .skill, agents: ["codex"]).map(\.name) == ["docx"])
        #expect(idx.filtered(type: .skill, agents: ["codex", "claude"]).count == 2)
        #expect(idx.skillCount == 2 && idx.mcpCount == 1)
    }

    @Test func levelFilter() {
        let result = ScanResult(entries: [
            raw("archive", agent: "codex", level: .user, loc: "/h/.codex/skills/archive"),
            raw("i18n", agent: "codex", level: .project, project: "proj-x", loc: "/w/proj-x/.codex/skills/i18n"),
        ], degraded: [], locationsScanned: 2)
        let idx = InventoryIndex()
        idx.rebuild(from: result, projects: [])
        #expect(idx.filtered(type: .skill, level: .user).map(\.name) == ["archive"])
        #expect(idx.filtered(type: .skill, level: .project).map(\.name) == ["i18n"])
        #expect(idx.filtered(type: .skill).count == 2)
    }

    @Test func mountStatsCountLocationsAndProjects() {
        // 落点聚合：1 个实体源 + 2 个项目 symlink → 3 处落点、挂载 2 次、跨 2 个项目
        let result = ScanResult(entries: [
            raw("dbs", agent: "claude", level: .project, project: "proj-x",
                loc: "/w/proj-x/.claude/skills/dbs", resolved: "/h/.agents/skills/dbs"),
            raw("dbs", agent: "codex", level: .project, project: "proj-y",
                loc: "/w/proj-y/.codex/skills/dbs", resolved: "/h/.agents/skills/dbs"),
            raw("dbs", agent: nil, loc: "/h/.agents/skills/dbs"),
        ], degraded: [], locationsScanned: 3)
        let idx = InventoryIndex()
        let proj = Project(id: "proj-x", name: "proj-x", path: "/w/proj-x")
        let proj2 = Project(id: "proj-y", name: "proj-y", path: "/w/proj-y")
        idx.rebuild(from: result, projects: [proj, proj2])
        let stat = idx.mountStat(of: "skill:dbs")
        #expect(stat.locations == 3)
        #expect(stat.mounts == 2)
        #expect(stat.projects == 2)
        let s = idx.summary(for: idx.items)
        #expect(s.items == 1 && s.locations == 3 && s.mounts == 2 && s.projects == 2)
        // 详情栏分组数据：symlink 落点带指向，实体源标 kind
        let kinds = stat.spots.map(\.kind)
        #expect(kinds.contains(.entitySource))
        #expect(kinds.filter { $0 == .symlink }.count == 2)
        #expect(stat.spots.first { $0.kind == .entitySource }?.path == "/h/.agents/skills/dbs")
    }

    @Test func sharedSourceAloneIsZeroMounts_agentDirSourceIsOne() {
        // 口径（D10=A）：挂载次数 = 落在 Agent 挂载目录里的落点数
        // 源在共享目录（无 Agent 归属）→ 真没人挂 = 0 次；源就在某家 skills 目录里 → 那家确实装着它 = 1 次
        let result = ScanResult(entries: [
            raw("orphan", agent: nil, loc: "/h/.agents/skills/orphan"),
            raw("owned", agent: "codex", loc: "/h/.codex/skills/owned"),
        ], degraded: [], locationsScanned: 2)
        let idx = InventoryIndex()
        idx.rebuild(from: result, projects: [])
        #expect(idx.mountStat(of: "skill:orphan").locations == 1)
        #expect(idx.mountStat(of: "skill:orphan").mounts == 0)
        #expect(idx.items.first { $0.name == "orphan" }?.status == .zeroMount)
        #expect(idx.mountStat(of: "skill:owned").mounts == 1)
        #expect(idx.items.first { $0.name == "owned" }?.status == .mounted)
    }

    @Test func entityCopiesInOtherProjectsCountAsMounts() {
        // 重装出来的独立实体目录：第一个是源，其余两处算挂载引用
        let result = ScanResult(entries: [
            raw("dup", agent: "codex", loc: "/h/.codex/skills/dup"),
            raw("dup", agent: "claude", level: .project, project: "p1", loc: "/w/p1/.claude/skills/dup"),
            raw("dup", agent: "qoder", level: .project, project: "p2", loc: "/w/p2/.qoder/skills/dup"),
        ], degraded: [], locationsScanned: 3)
        let idx = InventoryIndex()
        idx.rebuild(from: result, projects: [])
        let stat = idx.mountStat(of: "skill:dup")
        // 三处都落在 Agent 目录里 → 三次挂载；其中两处性质是"实体副本"
        #expect(stat.locations == 3 && stat.mounts == 3 && stat.projects == 2)
        #expect(stat.spots.filter { $0.kind == .entityCopy }.count == 2)
    }

    @Test func symlinkOnlyItemCountsEveryLinkAsMount() {
        // 源在扫描范围外（全盘只见 symlink）：每一处都是真挂载，不能降级成"源"→ 0 次
        let result = ScanResult(entries: [
            raw("ghost", agent: "claude", loc: "/h/.claude/skills/ghost", resolved: "/mnt/vault/skills/ghost"),
            raw("ghost", agent: "codex", loc: "/h/.codex/skills/ghost", resolved: "/mnt/vault/skills/ghost"),
        ], degraded: [], locationsScanned: 2)
        let idx = InventoryIndex()
        idx.rebuild(from: result, projects: [])
        let stat = idx.mountStat(of: "skill:ghost")
        #expect(stat.locations == 2 && stat.mounts == 2)
        #expect(!stat.spots.contains { $0.kind == .entitySource })
    }

    @Test func mcpConfigEntriesAllCountAsMounts() {
        // MCP 没有"实体源"概念：同一 server 配在两家 = 挂了两处
        let result = ScanResult(entries: [
            raw("figma", agent: "codex", type: .mcp, loc: "/h/.codex/config.toml#figma"),
            raw("figma", agent: "cursor", type: .mcp, loc: "/h/.cursor/mcp.json#figma"),
        ], degraded: [], locationsScanned: 2)
        let idx = InventoryIndex()
        idx.rebuild(from: result, projects: [])
        let stat = idx.mountStat(of: "mcp:figma")
        #expect(stat.locations == 2 && stat.mounts == 2)
        #expect(stat.spots.allSatisfy { $0.kind == .configEntry })
    }

    @Test func unclassifiedCopyCountsAsLocationNotMount() {
        // D10=A：归不到 Agent 的副本（别的 skill 内部的同名子目录）只算落点，不算挂载
        let result = ScanResult(entries: [
            raw("references", agent: "workbuddy", loc: "/h/.workbuddy/skills/references"),
            raw("references", agent: nil, loc: "/h/.codex/skills/dbs-write/references"),
            raw("references", agent: nil, loc: "/h/.codex/skills/dbs-read/references"),
        ], degraded: [], locationsScanned: 3)
        let idx = InventoryIndex()
        idx.rebuild(from: result, projects: [])
        let stat = idx.mountStat(of: "skill:references")
        #expect(stat.locations == 3)
        #expect(stat.mounts == 1, "两处副本都归不到 Agent，不该刷出挂载次数")
        #expect(idx.items[0].status == .mounted)
    }

    @Test func sortByMountsAndProjectsWithStableTieBreak() {
        let result = ScanResult(entries: [
            raw("big", agent: "codex", loc: "/a1"),
            raw("big", agent: "claude", loc: "/a2", resolved: "/a1"),
            raw("big", agent: "qoder", loc: "/a3", resolved: "/a1"),
            raw("mid", agent: "codex", loc: "/b1"),
            raw("mid", agent: "claude", level: .project, project: "p1", loc: "/p2/b2", resolved: "/b1"),
            raw("solo", agent: "codex", loc: "/c1"),
        ], degraded: [], locationsScanned: 6)
        let idx = InventoryIndex()
        idx.rebuild(from: result, projects: [])
        #expect(idx.filtered(type: .skill, sort: .mounts, ascending: false).map(\.name) == ["big", "mid", "solo"])
        #expect(idx.filtered(type: .skill, sort: .mounts, ascending: true).map(\.name) == ["solo", "mid", "big"])
        // 同按名称排序时升降序互为反转（严格弱序，不出现相等误判）
        let asc = idx.filtered(type: .skill, sort: .name, ascending: true).map(\.name)
        let desc = idx.filtered(type: .skill, sort: .name, ascending: false).map(\.name)
        #expect(asc == desc.reversed())
    }

    @Test func agentCountsReportsItemsPerAgent() {
        let result = ScanResult(entries: [
            raw("one", agent: "codex", loc: "/h/.codex/skills/one"),
            raw("two", agent: "codex", loc: "/h/.codex/skills/two"),
            raw("two", agent: "claude", loc: "/h/.claude/skills/two", resolved: "/h/.codex/skills/two"),
            raw("mcp1", agent: "codex", type: .mcp, loc: "/h/.codex/config.toml#mcp1"),
        ], degraded: [], locationsScanned: 4)
        let idx = InventoryIndex()
        idx.rebuild(from: result, projects: [])
        #expect(idx.agentCounts(type: .skill) == ["codex": 2, "claude": 1])
        #expect(idx.agentCounts(type: .mcp) == ["codex": 1])
    }
}
