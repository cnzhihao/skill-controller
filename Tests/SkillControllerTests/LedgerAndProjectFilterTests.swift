import Testing
import Foundation
@testable import SkillControllerCore

/// 挂载账视图② + 项目维度筛选（2026-09-22 P2 补件）的口径回归。
/// 重点盯两件事：① 单位是"条目数（去重）"，不能把跨作用域重复挂算成规模；
/// ② 项目维度只认真项目（.git 祖先发现），伪归属不进筛选项。
struct LedgerAndProjectFilterTests {
    private func raw(_ name: String, agent: String?, level: Level = .user, project: String? = nil,
                     type: ObjectType = .skill, loc: String, resolved: String? = nil) -> RawEntry {
        RawEntry(name: name, description: "d-\(name)", type: type, level: level, projectId: project,
                 locationPath: loc, resolvedPath: resolved, mountedAgentId: agent)
    }

    private let projX = Project(id: "proj-x", name: "proj-x", path: "/w/proj-x")

    /// 造一份"同一 Skill 挂在 codex 用户级 + proj-x 项目级，另有孤本零挂载"的索引
    private func makeIndex() -> InventoryIndex {
        let idx = InventoryIndex()
        _ = idx.rebuild(from: ScanResult(entries: [
            raw("docx", agent: "codex", loc: "/h/.codex/skills/docx"),
            raw("docx", agent: "codex", level: .project, project: "proj-x",
                loc: "/w/proj-x/.codex/skills/docx", resolved: "/h/.agents/skills/docx"),
            raw("pdf", agent: "claude", loc: "/h/.claude/skills/pdf"),
            // 孤本：躺在共享目录里，归不到任何 Agent → 零挂载
            raw("lonely", agent: nil, loc: "/h/.agents/skills/lonely"),
        ], degraded: [], locationsScanned: 4), projects: [projX])
        return idx
    }

    @Test func mountRowCountsDistinctItemsNotLandings() throws {
        let idx = makeIndex()
        let codex = try #require(idx.agentMountRows(type: .skill).first { $0.agentId == "codex" })
        // docx 在用户级和项目级各挂一次：合计必须是 1，不是 2 —— 写成 2 就是把规模虚报
        #expect(codex.userLevel == 1 && codex.projectLevel == 1)
        #expect(codex.total == 1)
        #expect(codex.projects == 1)
        let claude = try #require(idx.agentMountRows(type: .skill).first { $0.agentId == "claude" })
        #expect(claude.total == 1 && claude.projectLevel == 0)
        // 排序默认按合计降序；两家同为 1 时按 id 收口，保证确定性
        #expect(idx.agentMountRows(type: .skill).map(\.agentId) == ["claude", "codex"])
    }

    @Test func zeroMountListHoldsOnlyUnattributedItems() {
        let idx = makeIndex()
        let zero = idx.zeroMountItems(type: .skill)
        // 只有躺在共享目录、没有任何 Agent 落点的 lonely 算零挂载；docx/pdf 都被挂着
        #expect(zero.map(\.name) == ["lonely"])
    }

    @Test func projectFilterPicksItemsWithALandingInThatProject() {
        let idx = makeIndex()
        #expect(idx.filtered(type: .skill, projects: ["proj-x"]).map(\.name) == ["docx"])
        #expect(idx.filtered(type: .skill, projects: []).count == 3)   // 空集 = 全部，不改变展示口径
        #expect(idx.projectCounts(type: .skill) == ["proj-x": 1])
    }

    @Test func searchNowMatchesProjectNameAndLandingPath() {
        let idx = makeIndex()
        // 人记不住 skill 叫什么，记得住"它在 proj-x 里"和"它在 .codex/skills 下"
        #expect(idx.filtered(type: .skill, query: "proj-x").map(\.name) == ["docx"])
        #expect(idx.filtered(type: .skill, query: "/w/proj-x").map(\.name) == ["docx"])
        #expect(idx.filtered(type: .skill, query: ".claude/skills").map(\.name) == ["pdf"])
        // 名字/描述命中的老口径不能被搜索扩展弄坏
        #expect(idx.filtered(type: .skill, query: "d-lonely").map(\.name) == ["lonely"])
        #expect(idx.filtered(type: .skill, query: "不存在的关键词").isEmpty)
    }
}
