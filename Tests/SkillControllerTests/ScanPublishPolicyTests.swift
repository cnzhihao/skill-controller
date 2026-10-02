import Testing
import Foundation
@testable import SkillControllerCore

/// D16 回归：重扫期间页头数字不得先跌再涨（真机 1,973 → 1,398 → 1,973），
/// 且详情栏/确认框不能被"半截索引"打断。发布时机见 ScanPublishPolicy。
struct ScanPublishPolicyTests {
    private func raw(_ name: String, agent: String? = "codex", loc: String) -> RawEntry {
        RawEntry(name: name, description: "d-\(name)", type: .skill, level: .user, projectId: nil,
                 locationPath: loc, resolvedPath: nil, mountedAgentId: agent)
    }

    @Test func coldStartPublishesEachBatchSoFirstPaintIsNotBlocked() {
        // 冷启动：手上还没有任何一版清单 → 每批都要出结果（edge loading-initial >3s 增量态）
        let p = ScanPublishPolicy(previousItemCount: 0)
        #expect(p.publishesEachBatch)
        #expect(p.publishesAtEnd)
    }

    @Test func warmPassNeverPublishesHalfBuiltIndexMidBatch() {
        // 已有上一版全量 → 中途一次都不发布，只在收尾发布一次。
        // 这一条就是页头抖动的直接断言：中途发布 = 把清单拆了再拼回去。
        let p = ScanPublishPolicy(previousItemCount: 1_973)
        #expect(!p.publishesEachBatch)
        #expect(p.publishesAtEnd)
    }

    @Test func growingAccumulationNeverRegressesDisplayedTotals() {
        // 冷启动既然会多次发布，那多次发布之间必须单调不降——否则同一个病只是换了条路。
        // 这里模拟"按批累积"：每一版都是上一版加上新一批，条数/落点数只许涨。
        let idx = InventoryIndex()
        var accumulated: [RawEntry] = []
        var lastSkills = 0, lastLocations = 0
        for batch in 0..<4 {
            for i in 0..<5 {
                let name = "skill-\(batch)-\(i)"
                accumulated.append(raw(name, loc: "/h/.codex/skills/\(name)"))
            }
            // 同名副本也进来了：落点数比条目数涨得快，同样不许回头
            accumulated.append(raw("shared", loc: "/h/.claude/skills/shared-\(batch)"))
            accumulated.append(raw("shared", loc: "/h/.codex/skills/shared-\(batch)"))
            let result = ScanResult(entries: accumulated, degraded: [], locationsScanned: accumulated.count)
            _ = idx.rebuild(from: result, projects: [])
            #expect(idx.skillCount >= lastSkills, "第 \(batch) 批之后条目数回退了：\(lastSkills) → \(idx.skillCount)")
            #expect(idx.summary(for: idx.items).locations >= lastLocations,
                    "第 \(batch) 批之后落点数回退了：\(lastLocations) → \(idx.summary(for: idx.items).locations)")
            lastSkills = idx.skillCount
            lastLocations = idx.summary(for: idx.items).locations
        }
    }

    @Test func removeOnlyOurOwnWrittenItemLeavesTheRestIntact() {
        // 删除回执上屏后，那一行必须当场从清单摘掉（重扫改成收尾一次发布，等它落定要一两秒）。
        // 边界：只能摘我们自己写完的那一条，摘不到就返回 false，绝不顺手改别的数字。
        let idx = InventoryIndex()
        _ = idx.rebuild(from: ScanResult(entries: [
            raw("docx", loc: "/h/.codex/skills/docx"),
            raw("pdf", loc: "/h/.codex/skills/pdf"),
            raw("pdf", agent: "claude", loc: "/h/.claude/skills/pdf"),
        ], degraded: [], locationsScanned: 3), projects: [])
        #expect(idx.skillCount == 2 && idx.summary(for: idx.items).locations == 3)

        #expect(idx.removeItem(id: "skill:docx"))
        #expect(idx.skillCount == 1)
        #expect(idx.item(id: "skill:docx") == nil)
        #expect(idx.totals(of: "skill:docx") == .zero)          // 计数索引也跟着走，不留孤儿
        let pdf = idx.summary(for: idx.items)
        #expect(pdf.items == 1 && pdf.locations == 2)           // 没被摘的条目一个数都不能变

        #expect(!idx.removeItem(id: "skill:不存在的条目"))       // 空操作，不崩也不改
        #expect(idx.skillCount == 1)
    }
}
