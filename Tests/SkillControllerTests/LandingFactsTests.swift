import Testing
import Foundation
@testable import SkillControllerCore

/// #13（D40）：CLI 卸下后清单滞后到重启的收口——事件文件驱动的定向行更新。
/// 信任锚 = 自家 CLI 写的 assembly-events.jsonl（与 removeItem「只用于我们自己刚做完写操作」同级）；
/// 单条目重derive 必须与 rebuild 的 spots(for:) 同文件同源（两份口径 = D19 的成因）。
struct LandingFactsTests {
    /// 用 rebuild 起一个含实体源 + 两处 symlink 的索引（与扫描期同一入口，保证口径同源）
    private func makeIndex(entries: [RawEntry]) -> InventoryIndex {
        let idx = InventoryIndex()
        _ = idx.rebuild(from: ScanResult(entries: entries, degraded: [], locationsScanned: entries.count),
                        projects: [])
        return idx
    }

    private func raw(_ name: String, loc: String, resolved: String? = nil,
                     agent: String? = "codex", level: Level = .user) -> RawEntry {
        RawEntry(name: name, description: "d-\(name)", type: .skill, level: level, projectId: nil,
                 locationPath: loc, resolvedPath: resolved, mountedAgentId: agent)
    }

    @Test func removedSymlinkLandingDropsDuplicatesAndRederivesTotals() throws {
        let source = "/h/.agents/skills/docx"
        let linkA = "/h/.claude/skills/docx"
        let linkB = "/h/.codex/skills/docx"
        let idx = makeIndex(entries: [
            raw("docx", loc: source, agent: "codex"),
            raw("docx", loc: linkA, resolved: source, agent: "claude"),
            raw("docx", loc: linkB, resolved: source, agent: "codex"),
        ])
        #expect(idx.mountStat(of: "skill:docx").mounts == 3)
        #expect(idx.totals(of: "skill:docx").locations == 3)

        // claude 的链接被 CLI 卸下 → duplicates 减一、mountedBy/totals 同步重算
        let changed = idx.applyLandingFacts(added: [], removed: [linkA],
                                            home: URL(fileURLWithPath: "/h"))
        #expect(changed)
        let stat = idx.mountStat(of: "skill:docx")
        #expect(stat.mounts == 2 && stat.locations == 2)
        #expect(!stat.spots.contains { $0.path == linkA })
        let item = try #require(idx.item(id: "skill:docx"))
        #expect(!item.duplicates.contains(linkA))
        #expect(item.mountedBy == ["codex"])   // claude 已不在挂载名单
        // 条目整行还在（unmount 摘不掉实体源）——D16 的模态作废形状在此路径不可达
        #expect(idx.item(id: "skill:docx") != nil)
    }

    /// 幂等重放：同一批 removed 再来一次 → 零变化、返回 false
    @Test func replayingSameFactsIsANoop() throws {
        let source = "/h/.agents/skills/docx"
        let link = "/h/.claude/skills/docx"
        let idx = makeIndex(entries: [
            raw("docx", loc: source),
            raw("docx", loc: link, resolved: source, agent: "claude"),
        ])
        #expect(idx.applyLandingFacts(added: [], removed: [link], home: URL(fileURLWithPath: "/h")))
        let afterFirst = idx.mountStat(of: "skill:docx")
        #expect(!idx.applyLandingFacts(added: [], removed: [link], home: URL(fileURLWithPath: "/h")))
        #expect(idx.mountStat(of: "skill:docx") == afterFirst)
    }

    /// `#` MCP 路径跳过、未知条目跳过（重扫兜底）——no-op 且不崩
    @Test func MCPPathsAndUnknownEntriesAreSkipped() throws {
        let idx = makeIndex(entries: [raw("docx", loc: "/h/.agents/skills/docx")])
        #expect(!idx.applyLandingFacts(added: [], removed: ["/h/.claude/mcp.json#pdfmcp"],
                                       home: URL(fileURLWithPath: "/h")))
        #expect(!idx.applyLandingFacts(added: [], removed: ["/nowhere/.claude/skills/ghost"],
                                       home: URL(fileURLWithPath: "/h")))
        #expect(!idx.applyLandingFacts(added: ["/h/.claude/skills/ghost"], removed: [],
                                       home: URL(fileURLWithPath: "/h")))
        #expect(idx.skillCount == 1)
    }

    /// added 对称：已索引条目新增 symlink 落点 → duplicates 增一、mountedBy 并入新家
    @Test func addedSymlinkLandingJoinsItemAndCounts() throws {
        let source = "/h/.agents/skills/docx"
        let idx = makeIndex(entries: [raw("docx", loc: source)])
        #expect(idx.mountStat(of: "skill:docx").mounts == 1)
        let newLink = "/h/.claude/skills/docx"
        #expect(idx.applyLandingFacts(added: [newLink], removed: [], home: URL(fileURLWithPath: "/h")))
        let stat = idx.mountStat(of: "skill:docx")
        #expect(stat.mounts == 2)
        let item = try #require(idx.item(id: "skill:docx"))
        #expect(item.mountedBy == ["claude", "codex"])
        // 归属判定走 LocationClassifier：用户级
        #expect(stat.spots.first { $0.path == newLink }?.level == .user)
    }

    /// 事件条目已被删的形状（用例 E4）：removed 路径无属主条目 → 跳过（返回 false），条目行不动
    @Test func removedLandingWithoutOwnerLeavesIndexAlone() throws {
        let idx = makeIndex(entries: [raw("docx", loc: "/h/.agents/skills/docx")])
        let before = idx.mountStat(of: "skill:docx")
        #expect(!idx.applyLandingFacts(added: [], removed: ["/h/.codex/skills/docx"],
                                       home: URL(fileURLWithPath: "/h")))
        #expect(idx.mountStat(of: "skill:docx") == before)
    }

    /// 实体落点不摘（unmount 对实体一律 refused，removed 恒为 symlink）——
    /// 万一事件里出现实体路径，守卫必须拒绝，条目整行不许因此消失
    @Test func entityLandingIsNeverRemoved() throws {
        let source = "/h/.agents/skills/docx"
        let idx = makeIndex(entries: [raw("docx", loc: source)])
        #expect(!idx.applyLandingFacts(added: [], removed: [source], home: URL(fileURLWithPath: "/h")))
        #expect(idx.item(id: "skill:docx") != nil)
        #expect(idx.mountStat(of: "skill:docx").mounts == 1)
    }
}
