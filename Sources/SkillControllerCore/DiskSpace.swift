// DiskSpace.swift — 磁盘空间预检（#1 磁盘满不可逆删除确认的 Core 面）
// 设计档 docs/design/audit-remediation-design.md §1 #1：
//   删除确认点「移入回收站」之后、任何磁盘写之前，同步预检可用空间；
//   不足 → 升级确认（键入条目名）→ destructive 红第一次启用。
//   预检式而非"写入失败再升级"：彻底避免半态——三步齐不是原子的（D14 已经证明），能不进 trash() 就不进。
//
// 三个类型各管一段，接口契约在设计档 §2：
//   DiskSpaceDecision — 纯函数决策（表驱动可测）
//   DiskSpaceProbe    — 系统探测（可注入，App 侧默认 .system）
//   TrashSpaceEstimator — 需要字节的估算（"路径→卷"映射注入，测试造跨卷/同卷形状）

import Foundation

// MARK: - 决策（纯函数）

/// 磁盘满预检决策。探测失败（free == nil）→ .proceed：探测不到不拦人，
/// 真失败由 D14 回滚 + 失败回执兜底；这条不拦人的口径是设计档 §1 #1 明文（edge G5 的探测失败分支）。
public enum DiskSpaceDecision: Sendable, Equatable {
    /// 正常流：空间够，走回收站删除
    case proceed
    /// 空间不足：关闭普通确认框，呈现升级确认 Sheet（键入条目名 → 不可逆删除）
    case requireIrreversible

    /// free/needed 均为原始字节；free = nil 表示探测失败（不拦人）。
    public static func decide(free: Int64?, needed: Int64) -> DiskSpaceDecision {
        guard let free else { return .proceed }
        return free < needed ? .requireIrreversible : .proceed
    }
}

// MARK: - 探测

/// 卷可用空间探测。注入点：App 侧默认 `.system`（主代理已真机预验该 API 在本机可用）；
/// `#if DEBUG` 的环境变量 `SKILLCTL_FAKE_FREE_BYTES` 仅供真机走完整升级链路（Release 不含此分支）。
public struct DiskSpaceProbe: Sendable {
    public enum Impl: Sendable {
        case system
        case custom(@Sendable (String) -> Int64?)
    }

    private let impl: Impl

    public init(_ impl: Impl = .system) { self.impl = impl }

    /// 探测 volumePath 所在卷的可用空间（字节）；失败返回 nil（→ decide 判 .proceed）。
    public func freeBytes(volumePath: String) -> Int64? {
        switch impl {
        case .system:
            // 仅 Debug build 的真机注入（设计档 §1 #1）：磁盘满真机不可复现，
            // 用环境变量 setenv 替换探测值走完整升级链路。Release 不含此分支。
            #if DEBUG
            if let raw = ProcessInfo.processInfo.environment["SKILLCTL_FAKE_FREE_BYTES"],
               let v = Int64(raw) {
                return v
            }
            #endif
            let url = URL(fileURLWithPath: volumePath)
            let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            return values?.volumeAvailableCapacityForImportantUsage
        case .custom(let f):
            return f(volumePath)
        }
    }
}

// MARK: - 需要字节估算

/// 回收站删除的「需要多少可用空间」估算。
///
/// 口径（设计档 §1 #1）：
/// - `needed = Σ(与回收站不同卷的**实体**字节数) + 1 MiB 元数据余量`
///   ——同卷实体是 move 不占新增空间；symlink 落点算 0（只删链接，链接本身不计）；
///   MCP 落点（`#`）不参与（#3 已堵 MCP 删除入口，这是同一口径的 Core 侧守卫）。
/// - 落点体积遍历只发生在「跨卷实体」上（极少），同卷不遍历，避免大目录卡预检。
/// - 路径已消失（烂挂载/竞态）：计 0——它不会进 manifest，也不该把 needed 顶上去。
///   判不出所在卷（volumeOf 返回 nil）同理计 0：真失败由 D14 回滚 + 失败回执兜底，
///   估算器不在预检层拦人。
public enum TrashSpaceEstimator {
    /// 元数据余量：manifest + 日志行的元数据写入余量，1 MiB
    public static let metadataMargin: Int64 = 1 * 1024 * 1024

    /// - Parameters:
    ///   - entityPaths: 条目的全部落点（sourcePath + duplicates 原样传入）。
    ///   - trashVolume: 回收站所在卷的路径。
    ///   - volumeOf: 路径 → 所在卷的映射（注入点：测试用假映射造跨卷/同卷形状）。
    ///   - sizeOf: 路径 → 字节数（注入点：默认实现走系统递归；测试注入假尺寸，免造大目录）。
    public static func neededBytes(entityPaths: [String], trashVolume: String,
                                   volumeOf: (String) -> String?,
                                   sizeOf: (String) -> Int64 = { recursiveSize(atPath: $0) ?? 0 }) -> Int64 {
        var total: Int64 = 0
        for path in entityPaths {
            guard !path.contains("#") else { continue }      // MCP 落点（"file#key"）不参与
            guard let vol = volumeOf(path) else { continue } // 判不出卷 → 计 0，不拦人
            if vol != trashVolume {
                total += sizeOf(path)
            }
        }
        return total + metadataMargin
    }

    /// 递归目录体积（跨卷实体才走这里，量大极少；符号链接不跟随，stat 语义）。
    public static func recursiveSize(atPath path: String) -> Int64? {
        let fm = FileManager.default
        guard let attrs = try? fm.attributesOfItem(atPath: path) else { return nil }
        if (attrs[.type] as? FileAttributeType) == .typeSymbolicLink { return 0 }
        guard let size = (attrs[.size] as? NSNumber)?.int64Value else { return nil }
        guard let children = try? fm.contentsOfDirectory(atPath: path) else { return size }
        var total = size
        for name in children {
            if let child = recursiveSize(atPath: path + "/" + name) { total += child }
        }
        return total
    }
}
