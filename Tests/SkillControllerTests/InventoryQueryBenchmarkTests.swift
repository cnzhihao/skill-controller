import Testing
import Foundation
@testable import SkillControllerCore

/// 清单渲染热路径基准（2026-09-21 加）：
/// 真机 1970 条目 / 5049 落点 / 76 家产品时，排序比较器里若去取带 spots 的聚合，
/// SwiftUI 每个事务都会把主线程打满（sample 显示 100% CPU 全在 updateGraph）。
/// 计数与排序必须走 MountTotals（三个 Int），此测试就是那条红线。
struct InventoryQueryBenchmarkTests {
    /// 造 N 个条目 × M 处落点（1 处实体源 + 若干 symlink/副本），贴近真机分布
    private func syntheticEntries(items: Int, spots: Int) -> [RawEntry] {
        var out: [RawEntry] = []
        out.reserveCapacity(items * spots)
        for i in 0..<items {
            let name = String(format: "skill-%05d", i)
            out.append(RawEntry(name: name, description: "d", type: .skill, level: .user,
                                projectId: nil, locationPath: "/h/.agents/skills/\(name)",
                                resolvedPath: nil, mountedAgentId: "codex"))
            for j in 1..<spots {
                let project = "p\((i + j) % 40)"
                out.append(RawEntry(name: name, description: "d", type: .skill,
                                    level: j % 4 == 0 ? .user : .project, projectId: project,
                                    locationPath: "/w/\(project)/.claude/skills/\(name)",
                                    resolvedPath: "/h/.agents/skills/\(name)",
                                    mountedAgentId: "claude"))
            }
        }
        return out
    }

    @Test func sortAndSummaryStayFastOnFullInventory() {
        let idx = InventoryIndex()
        let started = ContinuousClock.now
        idx.rebuild(from: ScanResult(entries: syntheticEntries(items: 2000, spots: 25),
                                     degraded: [], locationsScanned: 50_000),
                    projects: (0..<40).map { Project(id: "p\($0)", name: "p\($0)", path: "/w/p\($0)") },
                    discoveredAgents: [Agent(id: "codex", name: "Codex", homeDir: "~/.codex"),
                                       Agent(id: "claude", name: "Claude Code", homeDir: "~/.claude")])
        let rebuild = started.duration(to: .now)
        #expect(idx.items.count == 2000)

        // 一屏渲染至少跑：筛选+排序、汇总条、产品计数、升降序翻转
        let began = ContinuousClock.now
        for _ in 0..<12 {
            let visible = idx.filtered(type: .skill, agents: [], level: nil, query: "",
                                       sort: .mounts, ascending: false)
            _ = idx.summary(for: visible)
            _ = idx.filtered(type: .skill, sort: .projects, ascending: true)
            _ = idx.agentCounts(type: .skill)
        }
        let renders = began.duration(to: .now)
        // 阈值按真机量级留足余量：正常实现 ~百毫秒级，回归实现会到秒级甚至更久
        #expect(seconds(renders) < 3.0, "12 屏清单查询用了 \(renders)，热路径又去碰 spots 了")
        // 重建本身也不该退化（spots 只在 rebuild 里算一次）
        #expect(seconds(rebuild) < 5.0, "索引重建用了 \(rebuild)")
    }

    /// Duration → 秒，便于比较与失败信息可读
    private func seconds(_ d: Duration) -> Double {
        let c = d.components
        return Double(c.seconds) + Double(c.attoseconds) / 1e18
    }
}
