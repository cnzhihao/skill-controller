import Testing
import Foundation
@testable import SkillControllerCore

/// #1 磁盘满预检（edge G5 must）：决策与估算两组用例。
/// 决策是纯函数（表驱动）；估算把「路径→卷」映射与尺寸都注入——
/// 磁盘满真机不可复现，Core 面的证据全在这里（设计档 §5 #1①）。
struct DiskSpaceDecisionTests {
    // MARK: 决策（DiskSpaceDecision.decide）

    /// 表驱动：free < needed → 升级确认；free ≥ needed → 正常流；探测失败（nil）→ 不拦人
    @Test func decideCoversAllThreeBranches() {
        let needed: Int64 = 10 * 1024 * 1024   // 10 MiB
        let table: [(free: Int64?, expected: DiskSpaceDecision, why: String)] = [
            (0, .requireIrreversible, "可用 0 < 需要 10MiB → 升级确认"),
            (needed - 1, .requireIrreversible, "差 1 字节也是不足"),
            (needed, .proceed, "恰好够 → 正常流"),
            (needed + 1, .proceed, "富余 → 正常流"),
            (nil, .proceed, "探测失败不拦人（D14 回滚兜底）"),
        ]
        for row in table {
            #expect(DiskSpaceDecision.decide(free: row.free, needed: needed) == row.expected,
                    Comment(rawValue: row.why))
        }
    }

    // MARK: 估算（TrashSpaceEstimator.neededBytes）

    /// 体积口径：跨卷实体计入 needed；同卷实体/symlink 计 0；MCP `#` 落点不参与；余量 1MiB。
    /// 同卷大条目不遍历（needed 只含余量）由「sizeOf 不被调用」证明——同卷绝不触发体积遍历。
    @Test func neededBytesCountsCrossVolumeEntitiesOnly() throws {
        func size(_ p: String) -> Int64 { 5 * 1024 * 1024 }   // 任何被询问的实体都 5 MiB

        // 跨卷实体：只有 /usb 上的实体与回收站（/disk）不同卷 → 5MiB + 1MiB 余量
        // （/disk 上的那条同卷，move 不占新增空间 → 计 0）
        var vol: [String: String] = [
            "/disk/skills/a": "/disk",
            "/usb/skills/b": "/usb",
        ]
        var needed = TrashSpaceEstimator.neededBytes(
            entityPaths: ["/disk/skills/a", "/usb/skills/b"],
            trashVolume: "/disk", volumeOf: { vol[$0] }, sizeOf: size)
        #expect(needed == 5 * 1024 * 1024 + TrashSpaceEstimator.metadataMargin,
                Comment(rawValue: "跨卷实体计入 needed，同卷实体计 0：actual=\(needed)"))

        // 同卷实体：move 不占新增空间 → needed 只有 1MiB 余量，且不触发体积遍历
        var asked: [String] = []
        needed = TrashSpaceEstimator.neededBytes(
            entityPaths: ["/disk/skills/a"],
            trashVolume: "/disk",
            volumeOf: { _ in "/disk" },
            sizeOf: { asked.append($0); return 5 * 1024 * 1024 })
        #expect(needed == TrashSpaceEstimator.metadataMargin)
        #expect(asked.isEmpty, Comment(rawValue: "同卷实体不遍历体积（避免大目录卡预检）"))

        // symlink 落点计 0：体积口径按「实体字节」算，链接只删不搬。
        // 盘面事实由 App 侧传参保证（只传实体落点）；这里对默认实现 recursiveSize
        // 造一个真 symlink 验证它对链接返回 0（不跟随链接统计目标体积）
        let linkDir = FileManager.default.temporaryDirectory.appendingPathComponent("sc-diskprobe-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: linkDir.appendingPathComponent("real"), withIntermediateDirectories: true)
        try "0123456789".write(to: linkDir.appendingPathComponent("real/SKILL.md"), atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(atPath: linkDir.appendingPathComponent("link-a").path,
                                                   withDestinationPath: "real")
        defer { try? FileManager.default.removeItem(at: linkDir) }
        needed = TrashSpaceEstimator.neededBytes(
            entityPaths: [linkDir.appendingPathComponent("link-a").path],
            trashVolume: "/disk",
            volumeOf: { _ in "/usb" })   // 不注入 sizeOf → 走默认 recursiveSize
        #expect(needed == TrashSpaceEstimator.metadataMargin,
                Comment(rawValue: "symlink 走默认 recursiveSize 也必须计 0：actual=\(needed)"))

        // MCP `#` 落点不参与（#3 堵入口的同一口径）：即便判成跨卷也不计
        needed = TrashSpaceEstimator.neededBytes(
            entityPaths: ["/usb/.claude.json#server-a"],
            trashVolume: "/disk",
            volumeOf: { vol[$0] },
            sizeOf: { _ in 5 * 1024 * 1024 })
        #expect(needed == TrashSpaceEstimator.metadataMargin)

        // 判不出卷（volumeOf → nil）：计 0 不拦人；路径消失（sizeOf → 0/nil）同理不顶高 needed
        vol["/disk/skills/a"] = nil
        needed = TrashSpaceEstimator.neededBytes(
            entityPaths: ["/disk/skills/a"],
            trashVolume: "/disk",
            volumeOf: { vol[$0] },
            sizeOf: { _ in 5 * 1024 * 1024 })
        #expect(needed == TrashSpaceEstimator.metadataMargin)
    }
}
