// WriteLock.swift — 全局写锁（R3 缓解：多 Agent 并发经 CLI 装配时写操作串行化）
// 锁文件与数据目录同址；App 与 skillctl 共用（同机同用户）。

import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// 数据目录解析（App 与 skillctl 共用；测试经 init(supportDir:) 注入隔离目录）
public struct SkillControllerPaths: Sendable {
    public let supportDir: URL

    /// 本地数据根目录：~/Library/Application Support/cn.zhihao.SkillController（纯本地零云端）
    public init(supportDir: URL? = nil) {
        self.supportDir = supportDir ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/cn.zhihao.SkillController")
    }

    public var logFile: URL { supportDir.appendingPathComponent("operation-log.jsonl") }
    /// 装配事件（CLI 写、App 读；Banner 与 diff Sheet 的数据源）
    public var assemblyEventsFile: URL { supportDir.appendingPathComponent("assembly-events.jsonl") }
    public var trashDir: URL { supportDir.appendingPathComponent("trash") }
    public var lockFile: URL { supportDir.appendingPathComponent("write.lock") }
    public var settingsFile: URL { supportDir.appendingPathComponent("settings.json") }
    /// 全盘发现的位置清单缓存（App 写、CLI 读；只存路径列表，不存内容）
    public var discoveryCacheFile: URL { supportDir.appendingPathComponent("scan-scope-cache.json") }

    public func ensureDirs() throws {
        try FileManager.default.createDirectory(at: supportDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: trashDir, withIntermediateDirectories: true)
    }
}

/// 设置（回收站保留窗 ≥30 天，配置可调大——PRD story-4）
public struct AppSettings: Codable {
    public var trashRetentionDays: Int
    /// 旧格式（D17 之前）：一份**绝对**剪枝列表。只保留解码能力用于迁移，不再写入。
    /// 它的致命问题：分不清"这个类别被关掉了"和"这个类别当时还不存在"，
    /// 于是以后每新增一个剪枝类别，对所有碰过开关的老用户都默认不生效（2026-09-22 真机实测中招）。
    public var prunedCategories: [String]?
    /// 现行格式：**对默认值的逐项覆盖**。有效集 = 默认 ⊕ 覆盖。
    /// 没被用户明确动过的类别一律跟随默认，新增类别因此对所有人自动生效。
    public var prunedOverrides: [String: Bool]?
    /// CLI 引导跳过记录：值为跳过时的缺口级别（"notInstalled" / "outdated"；ahead 与 outdated 同级，
    /// K10）；nil = 无跳过。语义是「同一缺口级别不再自动弹」（裁决①+需求档边界 5），不是全局布尔——
    /// 跳过「版本落后」后再变成「未安装」（或反向），级别变了要重新弹。
    public var cliGuideSkippedLevel: String?

    public init(trashRetentionDays: Int = 30, prunedCategories: [String]? = nil,
                prunedOverrides: [String: Bool]? = nil, cliGuideSkippedLevel: String? = nil) {
        self.trashRetentionDays = max(30, trashRetentionDays)
        self.prunedCategories = prunedCategories
        self.prunedOverrides = prunedOverrides
        self.cliGuideSkippedLevel = cliGuideSkippedLevel
    }

    /// 用户实际动过的那几项（其余跟随默认）
    public var effectiveOverrides: [PruneCategory: Bool] {
        if let ov = prunedOverrides {
            var out: [PruneCategory: Bool] = [:]
            for (k, v) in ov { if let c = PruneCategory(rawValue: k) { out[c] = v } }
            return out
        }
        // 旧绝对列表迁移：**多出来的项视为用户主张，缺项一律跟随默认**。
        // 旧列表分不清"这个类别被关掉了"和"这个类别当时还不存在"——
        // 两者在文件里长得一模一样（都不在列表中）。
        // 取"缺项 = 无主张"这一侧，代价与理由见上面的注释与内部待办 D17。
        guard let raw = prunedCategories else { return [:] }
        let set = Set(raw.compactMap(PruneCategory.init(rawValue:)))
        var out: [PruneCategory: Bool] = [:]
        for c in set where !c.defaultPruned { out[c] = true }
        return out
    }

    /// 当前生效的发现规则（设置页逐类开关即改这里，规则变了扫描缓存自动失效）
    public var discoveryRules: DiscoveryRules {
        var pruned = Set(PruneCategory.allCases.filter(\.defaultPruned))
        for (category, on) in effectiveOverrides {
            if on { pruned.insert(category) } else { pruned.remove(category) }
        }
        return DiscoveryRules(prunedCategories: pruned,
                              skillsDirNames: DiscoveryRules.standard.skillsDirNames,
                              mcpFileNames: DiscoveryRules.standard.mcpFileNames,
                              fullDiskRoots: DiscoveryRules.standard.fullDiskRoots,
                              maxDepth: DiscoveryRules.standard.maxDepth)
    }

    /// 把"有效集"折算回覆盖表写入设置（等于默认的项不落盘，保持跟随默认）
    public mutating func setPrunedCategories(_ pruned: Set<PruneCategory>) {
        var overrides: [String: Bool] = [:]
        for c in PruneCategory.allCases where pruned.contains(c) != c.defaultPruned {
            overrides[c.rawValue] = pruned.contains(c)
        }
        prunedOverrides = overrides.isEmpty ? [:] : overrides
        prunedCategories = nil      // 迁移完成，旧字段不再写
    }

    public static func load(paths: SkillControllerPaths = SkillControllerPaths()) -> AppSettings {
        guard let data = try? Data(contentsOf: paths.settingsFile),
              let s = try? JSONDecoder().decode(AppSettings.self, from: data) else { return AppSettings() }
        return s
    }

    public func save(paths: SkillControllerPaths = SkillControllerPaths()) throws {
        try paths.ensureDirs()
        let data = try JSONEncoder().encode(self)
        try data.write(to: paths.settingsFile)
    }

}

public final class WriteLock: @unchecked Sendable {
    private let path: URL
    private let inProcess = NSRecursiveLock() // 进程内互斥（同实例多线程）+ 同线程可重入
    private var fd: Int32 = -1                 // 跨进程互斥（flock，fd 只开一次）

    public init(path: URL) { self.path = path }

    public convenience init(paths: SkillControllerPaths = SkillControllerPaths()) {
        self.init(path: paths.lockFile)
    }

    public enum LockError: Error, Equatable {
        case openFailed(errno: Int32)
        case timeout
    }

    /// 加锁：先进程内递归锁，再 flock（同一 fd 上阻塞等待，带超时）
    public func lock(timeout: TimeInterval = 10) throws {
        inProcess.lock()
        do {
            try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
            if fd < 0 {
                fd = open(path.path, O_CREAT | O_RDWR, 0o644)
                guard fd >= 0 else {
                    inProcess.unlock()
                    throw LockError.openFailed(errno: errno)
                }
            }
            let deadline = Date().addingTimeInterval(timeout)
            while flock(fd, LOCK_EX | LOCK_NB) != 0 {
                if Date() > deadline {
                    inProcess.unlock()
                    throw LockError.timeout
                }
                usleep(20_000)
            }
        } catch {
            inProcess.unlock()
            throw error
        }
    }

    public func unlock() {
        if fd >= 0 { flock(fd, LOCK_UN) }
        inProcess.unlock()
    }

    /// 便捷：持锁执行临界区（同线程可重入）
    public func withLock<T>(timeout: TimeInterval = 10, _ body: () throws -> T) throws -> T {
        try lock(timeout: timeout)
        defer { unlock() }
        return try body()
    }

    deinit {
        if fd >= 0 { close(fd) }
    }
}

/// 真机上写失败回执曾直接显示「SkillControllerCore.WriteLock.LockError error 1」——
/// 等于把失败报了个没人看得懂的码。给它配人话（extension 必须在文件作用域，不能嵌在类型里）。
extension WriteLock.LockError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .openFailed(let e):
            return "打不开写锁文件（errno \(e)）——本工具的写入目录可能不可写或磁盘已满。"
        case .timeout:
            return "另一个写入操作（skillctl 或本 App）占着写锁超过 10 秒；这次写入没有开始，磁盘未被改动。"
        }
    }
}
