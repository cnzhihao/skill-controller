// TrashManager.swift — 回收站（写操作三步齐之二；一切删除文件级可回滚）
// 删除语义（C3 已裁决）：
//  - 实体目录落点 → 整目录移入回收站（保留内部结构）
//  - symlink 落点 → 只删链接（源永不自动删）
//  - 同名多副本：删除动作作用于条目全部落点（"各 Agent 挂载将同时卸下"，story-4 GWT）
// 恢复 = 一步、按清单精确回位；目标被占 → 该项失败留日志可重试（G4 部分恢复）
// 回收站被 Finder 清空 → 恢复置灰"目标已不存在"（G7），日志仅作审计

import Foundation

public struct TrashLocation: Codable, Sendable {
    public var originalPath: String
    public var isSymlink: Bool
    /// 回收站内相对路径：trash/<entryId>/files/<n>/...
    public var storedRelativePath: String
    /// symlink 的指向（恢复时重建链接用）
    public var linkTarget: String?

    public init(originalPath: String, isSymlink: Bool, storedRelativePath: String, linkTarget: String? = nil) {
        self.originalPath = originalPath
        self.isSymlink = isSymlink
        self.storedRelativePath = storedRelativePath
        self.linkTarget = linkTarget
    }
}

public struct TrashManifest: Codable, Sendable {
    public var id: String // = 条目 id（skill:name / mcp:name）
    /// 回收站目录名（UUID，与条目 id 分离——同名条目可多次删除）
    public var entryId: String
    public var itemName: String
    public var deletedAt: String // ISO8601
    public var actor: String
    public var locations: [TrashLocation]
    /// 关联日志记录 id（恢复时写审计链）
    public var logRecordId: String?

    public init(id: String, entryId: String, itemName: String, deletedAt: String, actor: String,
                locations: [TrashLocation], logRecordId: String? = nil) {
        self.id = id; self.entryId = entryId; self.itemName = itemName; self.deletedAt = deletedAt
        self.actor = actor; self.locations = locations; self.logRecordId = logRecordId
    }
}

public enum TrashError: Error, Equatable {
    case nothingToDelete
    case targetVanished(path: String) // G7：回收站里已不存在
    /// D14：删除中途失败并已尝试回滚，但有落点没能放回原位——把细节原样交出去，不假装什么都没发生
    case rollbackFailed(detail: String)
}

/// 回执上屏时不能出现「TrashError error 2」这种天书（真机见过 WriteLock.LockError error 1）：
/// 每个失败都要能直接读成人话，否则"失败如实报"只是形式上报了。
extension TrashError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .nothingToDelete: return "这个条目在磁盘上已经没有落点了。"
        case .targetVanished(let path): return "回收站里已经找不到 \(path)，无法恢复。"
        case .rollbackFailed(let detail): return "删除未完成，且部分落点没能自动放回原位——\(detail)"
        }
    }
}

/// 恢复结果（G4：部分恢复如实报）
public struct RestoreOutcome: Sendable {
    public var restored: Int
    public var failed: [(path: String, reason: String)]
    public var complete: Bool { failed.isEmpty }
    /// 特例说明（#22 问题2，走查裁定 2026-09-30）：该件是 `skillctl add --force`
    /// 更新库条目时移入回收站的旧副本，恢复因新副本占位而失败——「30 天内可一步恢复」
    /// 的全局承诺不动，仅在此场景把话说全（G7 收尾：为什么失败、怎么办）。
    /// nil = 非特例，回执不加行（普通占位/归档缺失等维持现状）。
    public var forceReplacedHint: String?

    public init(restored: Int, failed: [(path: String, reason: String)], forceReplacedHint: String? = nil) {
        self.restored = restored
        self.failed = failed
        self.forceReplacedHint = forceReplacedHint
    }
}

public final class TrashManager: @unchecked Sendable {
    private let lock: WriteLock
    private let log: OperationLog
    private let paths: SkillControllerPaths
    /// 库位置判定用（#22 问题2 特例识别）；生产默认用户主目录，测试注入沙箱 home。
    /// 仅用于只读判定，不参与任何写入路径。
    private let home: URL
    private var trashRoot: URL { paths.trashDir }

    public init(paths: SkillControllerPaths = SkillControllerPaths(), lock: WriteLock? = nil, log: OperationLog? = nil,
                home: URL? = nil) {
        self.paths = paths
        self.home = home ?? FileManager.default.homeDirectoryForCurrentUser
        let lock = lock ?? WriteLock(paths: paths)
        self.lock = lock
        self.log = log ?? OperationLog(paths: paths, lock: lock)
    }

    /// 该回收站件是否可识别为 `--force` 更新的旧副本（#22 问题2 特例判定）。
    ///
    /// 三条判据全部只用 manifest 上**已持久化**的数据（零新增字段）：
    ///  - `actor == "skillctl"`：全仓以该 actor 落回收站的调用点只有 LibraryAdd（--force）；
    ///  - `id` 前缀 `skill:`：LibraryAdd 造的描述性 item 是 `skill:<名>`，把
    ///    restoreAssembly 撤销 add 事件时收进回收站的新副本（`id = "path:<路径>"`，
    ///    AssemblyService.swift copy 分支）干净排除——那份件恢复时原位通常已空，
    ///    即便被占也不是「旧副本」语义，加了说明反而是撒谎；
    ///  - 全部落点都在库根下：App 里人删库条目（actor="智昊"）不进此分支。
    /// 措辞按可照抄纪律写全命令名；为什么失败（旧副本+新副本占位）、
    /// 怎么办（先移除新副本）两句都要在。
    public static let forceReplacedHintText =
        "这个件是「skillctl add --force」更新技能库时移入的旧副本——新副本正占着原位。先删除库内同名条目，再回来恢复。"

    public func isForceReplacedLibraryCopy(_ manifest: TrashManifest) -> Bool {
        guard manifest.actor == "skillctl", manifest.id.hasPrefix("skill:") else { return false }
        return !manifest.locations.isEmpty && manifest.locations.allSatisfy {
            SkillLibrary.isLibraryPath($0.originalPath, home: home)
        }
    }

    // MARK: - 删除（入回收站）

    /// 把一个条目的全部落点移入回收站。返回 manifest；0 落点抛 nothingToDelete。
    /// `additionalPaths`（#15 / D36）：App 侧传入的全量挂载落点（MountStat.spots）——
    /// 「挂载」的真相是 spots，symlink 落点不在 duplicates 里（duplicates 只收物理副本），
    /// 不并进来，确认框承诺的「各 Agent 的挂载将同时卸下」就只兑现一半。
    @discardableResult
    public func trash(item: InventoryItem, actor: String, additionalPaths: [String] = []) throws -> TrashManifest {
        let fm = FileManager.default
        var allPaths = [item.sourcePath] + item.duplicates + additionalPaths
        // MCP 落点是 "file#key"，Phase 2 写侧未开（story-6），此处只处理文件系统条目
        allPaths.removeAll { $0.contains("#") }
        // 去重：duplicates 与 spots 可能交叉（同一路径两个来源都算过）
        var seen = Set<String>()
        allPaths.removeAll { !seen.insert($0).inserted }
        guard !allPaths.isEmpty else { throw TrashError.nothingToDelete }

        let entryId = UUID().uuidString
        let entryDir = trashRoot.appendingPathComponent(entryId)
        let filesDir = entryDir.appendingPathComponent("files")

        return try lock.withLock {
            try paths.ensureDirs()
            try fm.createDirectory(at: filesDir, withIntermediateDirectories: true)

            var locations: [TrashLocation] = []

            /// 原位是否已被占用（lstat 语义：实体、有效链接、悬空链接都算，绝不覆盖别人的东西）
            func occupied(_ path: String) -> Bool {
                var st = stat()
                return lstat(path, &st) == 0
            }

            /// D14 全有或全无：把已经搬走/删掉的落点原样放回，再清掉这次没写完的 entryDir。
            /// 此前第 116 行的注释写着"日志失败则整体回滚"，但代码根本没做——
            /// 真机上就留下了"文件已在回收站、manifest 已写、日志里没有那条删除"的半态，
            /// 而 UI 当时说的是「删除失败」。三步齐不是原子的，就必须显式收尾。
            func restore(_ loc: TrashLocation) -> String? {
                let original = loc.originalPath
                if loc.isSymlink {
                    guard let target = loc.linkTarget else {
                        return "\(original)：链接目标未记录，无法重建链接"
                    }
                    guard !occupied(original) else { return "\(original)：原位已被占用，未覆盖" }
                    do { try fm.createSymbolicLink(atPath: original, withDestinationPath: target); return nil }
                    catch { return "\(original)：重建链接失败（\(error.localizedDescription)）" }
                }
                let dest = entryDir.appendingPathComponent(loc.storedRelativePath)
                guard !occupied(original) else { return "\(original)：原位已被占用，未覆盖" }
                do {
                    try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try fm.moveItem(atPath: dest.path, toPath: original)
                    return nil
                } catch { return "\(original)：放回失败（\(error.localizedDescription)）" }
            }
            /// 把这次已经动过的落点全部放回，返回放不回去的说明。
            /// #6b（并发模型 §6）：**放不回去的落点存在时，整个 entryDir 必须保留**——
            /// manifest + files/ 是后续重试恢复（occupied 守卫防重复放回）的唯一凭据；
            /// 无条件 removeItem 等于在失败路径上再销毁一次存档。全部放回成功才清。
            func undoAll() -> [String] {
                var leftovers: [String] = []
                for loc in locations {
                    if let problem = restore(loc) { leftovers.append(problem) }
                }
                if leftovers.isEmpty {
                    try? fm.removeItem(at: entryDir)
                }
                return leftovers
            }

            /// 一次删除的全部动作。任何一步抛错，外层都会把已搬的落点放回原位——
            /// 三步齐（搬文件 / 写 manifest / 落日志）不是原子的，就得显式收尾。
            func perform() throws -> TrashManifest {
                for (n, path) in allPaths.enumerated() {
                    // lstat 语义（#15 落地时补）：symlink 本身算存在，哪怕目标已消失
                    // ——可能是天生的悬空链接（C3：悬空也算"挂过"，照卸不误），
                    // 更可能是同批实体源先被搬走所致（additionalPaths 的链接正指向实体源）。
                    // 改前用 fileExists（跟随链接），这种链接被静默跳过 = 承诺"同时卸下"又只兑现一半。
                    // 彻底消失的路径（lstat 都不存在）才跳过——已消失的落点不算失败。
                    guard occupied(path) else { continue }
                    let isSymlink = (try? fm.destinationOfSymbolicLink(atPath: path)) != nil
                    if isSymlink {
                        // C3：只删链接，不碰源
                        let linkTarget = try? fm.destinationOfSymbolicLink(atPath: path)
                        try fm.createDirectory(at: entryDir.appendingPathComponent("links"), withIntermediateDirectories: true)
                        // 链接元数据存 manifest 即可，物理链接直接移除
                        try fm.removeItem(atPath: path)
                        locations.append(TrashLocation(originalPath: path, isSymlink: true,
                                                       storedRelativePath: "links/\(n)", linkTarget: linkTarget))
                    } else {
                        let stored = "files/\(n)/\(URL(fileURLWithPath: path).lastPathComponent)"
                        let dest = entryDir.appendingPathComponent(stored)
                        try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
                        try fm.moveItem(atPath: path, toPath: dest.path)
                        locations.append(TrashLocation(originalPath: path, isSymlink: false, storedRelativePath: stored))
                    }
                }
                guard !locations.isEmpty else { throw TrashError.nothingToDelete }

                // 顺序：先定日志记录 id → 写 manifest（已含 logRecordId）→ 追加日志。
                // 这样任一步失败都不会出现"文件动了、日志没有"或"日志有了、manifest 没记锚点"。
                let record = LogRecord(id: UUID().uuidString, actor: actor, actorKind: .human, action: .delete,
                                       detail: "删除 \(item.name)（\(locations.count) 个落点移入回收站，\(AppSettings.load(paths: paths).trashRetentionDays) 天内可一步恢复）",
                                       target: item.id, reversible: true)
                let manifest = TrashManifest(id: item.id, entryId: entryId, itemName: item.name,
                                             deletedAt: LogRecord.nowISO(), actor: actor,
                                             locations: locations, logRecordId: record.id)
                let manifestData = try JSONEncoder().encode(manifest)
                try manifestData.write(to: entryDir.appendingPathComponent("manifest.json"))
                try log.append(record)
                return manifest
            }

            do {
                return try perform()
            } catch let cause {
                let leftovers = undoAll()
                guard !leftovers.isEmpty else { throw cause }
                // 回滚本身失败时把细节原样交出去，绝不假装"什么都没发生"
                throw TrashError.rollbackFailed(
                    detail: "\(cause.localizedDescription)；另有 \(leftovers.count) 个落点没能放回原位：\(leftovers.joined(separator: "、"))")
            }
        }
    }

    // MARK: - 查询

    public func listEntries() -> [TrashManifest] {
        let fm = FileManager.default
        guard let dirs = try? fm.contentsOfDirectory(at: trashRoot, includingPropertiesForKeys: nil) else { return [] }
        return dirs.compactMap { dir in
            guard let data = try? Data(contentsOf: dir.appendingPathComponent("manifest.json")),
                  let m = try? JSONDecoder().decode(TrashManifest.self, from: data) else { return nil }
            return m
        }
        .sorted { $0.deletedAt > $1.deletedAt }
    }

    /// 条目是否仍可恢复（G7：被 Finder 清空后不可恢复）
    ///
    /// #14（D41）：实体落点原来只查 `fileExists(storedRelativePath 壳)`——归档**内容**被移走、
    /// 空壳还在时照样返回 true，S12 真机「恢复」按钮仍可点。改为 enumerator 验非空内容
    /// （第一个对象存在即可，短路枚举，不做全量遍历）。
    /// symlink 落点维持 manifest 检查不变：链接重建只凭 manifest 里记的 linkTarget，
    /// 不依赖归档内容——给它加内容检查反而会把「本来能恢复」判成不能（另一种撒谎）。
    public func isRestorable(_ manifest: TrashManifest) -> Bool {
        let entryDir = trashRoot.appendingPathComponent(manifest.entryId)
        let fm = FileManager.default
        guard fm.fileExists(atPath: entryDir.appendingPathComponent("manifest.json").path) else { return false }
        return manifest.locations.allSatisfy { loc in
            guard !loc.isSymlink else { return true }
            let storedDir = entryDir.appendingPathComponent(loc.storedRelativePath).path
            guard fm.fileExists(atPath: storedDir) else { return false }
            guard let it = fm.enumerator(atPath: storedDir) else { return false }
            return it.nextObject() != nil   // 非空内容即算在档（短路）
        }
    }

    // MARK: - 一步恢复（G4：部分失败如实报）

    @discardableResult
    public func restore(_ manifest: TrashManifest) throws -> RestoreOutcome {
        let fm = FileManager.default
        let entryDir = trashRoot.appendingPathComponent(manifest.entryId)
        guard fm.fileExists(atPath: entryDir.appendingPathComponent("manifest.json").path) else {
            throw TrashError.targetVanished(path: manifest.id) // G7
        }

        return try lock.withLock {
            var restored = 0
            var failed: [(path: String, reason: String)] = []
            // #22 问题2 特例判定：占位失败 × --force 旧副本 → 回执补特例说明一行。
            // 特例只在占位失败时成立——链接目标消失/归档缺失等其他失败原因
            // 不该挂这句话（那句话里"新副本正占着原位"就成了假话）。
            var occupied = false
            for loc in manifest.locations {
                if loc.isSymlink {
                    // 重建链接（目标已消失则失败留痕；destination 可能是相对路径，按原父目录解析）
                    if let target = loc.linkTarget {
                        let parent = (loc.originalPath as NSString).deletingLastPathComponent
                        let resolved = URL(fileURLWithPath: target, relativeTo: URL(fileURLWithPath: parent)).standardizedFileURL.path
                        guard fm.fileExists(atPath: resolved) else {
                            failed.append((loc.originalPath, "链接目标已不存在"))
                            continue
                        }
                        do {
                            try fm.createDirectory(at: URL(fileURLWithPath: parent), withIntermediateDirectories: true)
                            // 原样重建（相对保持相对）
                            try fm.createSymbolicLink(atPath: loc.originalPath, withDestinationPath: target)
                            restored += 1
                        } catch {
                            failed.append((loc.originalPath, "重建链接失败"))
                        }
                    } else {
                        failed.append((loc.originalPath, "链接目标已不存在"))
                    }
                    continue
                }
                let stored = entryDir.appendingPathComponent(loc.storedRelativePath).path
                guard fm.fileExists(atPath: stored) else {
                    failed.append((loc.originalPath, "目标已不在回收站，无法恢复")) // G7 行内
                    continue
                }
                // #14（D41）：与 isRestorable 同口径的空壳守卫——归档内容被外部移走只剩空目录时，
                // 不能把「空壳搬回原位」渲染成恢复成功（isRestorable 在 API 层不许撒谎）。
                if let walker = fm.enumerator(atPath: stored), walker.nextObject() == nil {
                    failed.append((loc.originalPath, "归档内容缺失"))
                    continue
                }
                var isDir: ObjCBool = false
                if fm.fileExists(atPath: loc.originalPath, isDirectory: &isDir) {
                    failed.append((loc.originalPath, "原位置已被占用")) // 目录被占
                    occupied = true
                    continue
                }
                do {
                    try fm.createDirectory(at: URL(fileURLWithPath: loc.originalPath).deletingLastPathComponent(),
                                           withIntermediateDirectories: true)
                    try fm.moveItem(atPath: stored, toPath: loc.originalPath)
                    restored += 1
                } catch {
                    failed.append((loc.originalPath, "移动失败"))
                }
            }

            // 全部恢复 → 清掉回收站条目并闭合审计链；部分 → 保留可重试
            let record: LogRecord
            if failed.isEmpty {
                try? fm.removeItem(at: entryDir)
                record = LogRecord(actor: "智昊", actorKind: .human, action: .restore,
                                   detail: "已恢复 \(manifest.itemName)（\(restored) 个落点回位，磁盘状态与删除前一致）",
                                   target: manifest.id, reversible: false, restoredOf: manifest.logRecordId)
            } else {
                record = LogRecord(actor: "智昊", actorKind: .human, action: .restorePartial,
                                   detail: "\(restored)/\(manifest.locations.count) 项已恢复 · \(failed.count) 项未能恢复（已记日志，可重试）",
                                   target: manifest.id, reversible: false, restoredOf: manifest.logRecordId)
            }
            try log.append(record)
            // #22 问题2（走查拍板）：特例说明只在「占位失败 × --force 旧副本」同时成立时给出——
            // 三处全局「30 天内可一步恢复」文案一字不动（裁决 A 的核心），仅此处把话说全。
            let isForceCopy = isForceReplacedLibraryCopy(manifest)
            return RestoreOutcome(
                restored: restored,
                failed: failed,
                forceReplacedHint: (occupied && isForceCopy) ? Self.forceReplacedHintText : nil
            )
        }
    }

    /// 保留窗外的过期条目（仅手动调用——无后台常驻服务，禁区清单）
    public func expiredEntries(now: Date = Date()) -> [TrashManifest] {
        let days = AppSettings.load(paths: paths).trashRetentionDays
        let cutoff = now.addingTimeInterval(-Double(days) * 86400)
        let f = ISO8601DateFormatter()
        return listEntries().filter { m in
            guard let d = f.date(from: m.deletedAt) else { return false }
            return d < cutoff
        }
    }
}
