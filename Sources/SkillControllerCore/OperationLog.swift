// OperationLog.swift — 结构化操作日志（JSONL 追加式，写操作三步齐之一）
// 每条读写必落日志（PRD §3 硬规则 8）；恢复不覆盖原记录——追加"恢复"事件，
// 原条目的 restored 在读取时由审计链推导（日志保留仅作审计，story-4 GWT）。

import Foundation

public enum LogAction: String, Codable, Sendable {
    case assembly   // Agent 装配（pull）
    case mount
    case unmount
    case delete     // 删除入回收站
    case restore    // 一步恢复
    case restorePartial
}

/// 落盘记录（含关联字段；UI 消费的 LogEntry 由它转换，保持 types.ts 1:1）
public struct LogRecord: Codable, Sendable {
    public var id: String
    public var at: String // ISO8601
    public var actor: String // agent id 或 '智昊'
    public var actorKind: ActorKind
    public var action: LogAction
    public var detail: String // 人读描述（copy 来自 PRD/edge）
    public var target: String // 路径或条目 id
    public var reversible: Bool
    public var restoredOf: String? // action==restore 时指向被恢复的原记录 id
    public var itemIds: [String]? // 关联条目（装配事件用）

    public init(id: String = UUID().uuidString, at: String = LogRecord.nowISO(), actor: String,
                actorKind: ActorKind, action: LogAction, detail: String, target: String,
                reversible: Bool, restoredOf: String? = nil, itemIds: [String]? = nil) {
        self.id = id; self.at = at; self.actor = actor; self.actorKind = actorKind
        self.action = action; self.detail = detail; self.target = target
        self.reversible = reversible; self.restoredOf = restoredOf; self.itemIds = itemIds
    }

    public static func nowISO() -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.string(from: Date())
    }

    /// 转换为 1:1 数据模型（restored 由审计链推导后注入）
    public func toEntry(restoredIds: Set<String>) -> LogEntry {
        LogEntry(id: id, at: at, actor: actor, actorKind: actorKind,
                 action: detail, target: target, reversible: reversible,
                 restored: restoredIds.contains(id) ? true : nil)
    }
}

public final class OperationLog: @unchecked Sendable {
    private let lock: WriteLock
    private let paths: SkillControllerPaths
    private let fileURL: URL

    public init(paths: SkillControllerPaths = SkillControllerPaths(), lock: WriteLock? = nil) {
        self.paths = paths
        self.fileURL = paths.logFile
        self.lock = lock ?? WriteLock(paths: paths)
    }

    /// 追加一条（持写锁；写失败如实抛出，不吞）
    @discardableResult
    public func append(_ record: LogRecord) throws -> LogRecord {
        try paths.ensureDirs()
        let line = try JSONEncoder.encodeLine(record) + "\n"
        try lock.withLock {
            // 并发模型 §4 追加自愈：文件尾缺换行（上一行写了一半）时先补一个 \n，
            // 否则新记录拼在半行上、两条一起报废（readAll 读不到 = 日志条目凭空消失）
            let prefix = fileTailNeedsNewline(fileURL) ? "\n" : ""
            if let handle = try? FileHandle(forWritingTo: fileURL) {
                defer { try? handle.close() }
                handle.seekToEndOfFile()
                handle.write((prefix + line).data(using: .utf8)!)
            } else {
                try (prefix + line).data(using: .utf8)!.write(to: fileURL)
            }
        }
        return record
    }

    /// 读全量（损坏行跳过但计数——诚实原则）
    public func readAll() -> (records: [LogRecord], corruptLines: Int) {
        guard let data = try? Data(contentsOf: fileURL),
              let text = String(data: data, encoding: .utf8) else { return ([], 0) }
        var records: [LogRecord] = []
        var corrupt = 0
        for line in text.split(separator: "\n") {
            if let r = try? JSONDecoder().decode(LogRecord.self, from: line.data(using: .utf8)!) {
                records.append(r)
            } else {
                corrupt += 1
            }
        }
        return (records, corrupt)
    }

    /// 供 UI 的条目流（按时间倒序；restored 由审计链推导）
    public func entries() -> [LogEntry] {
        let (records, _) = readAll()
        let restoredIds = Set(records.compactMap(\.restoredOf))
        return records.map { $0.toEntry(restoredIds: restoredIds) }.reversed()
    }

    /// 按 Agent 过滤（actor 即 agent id 或人名）
    public func entries(actor: String?) -> [LogEntry] {
        guard let actor else { return entries() }
        return entries().filter { $0.actor == actor }
    }

    /// 某个条目的「挂载变动」（详情栏用；账本从记录里查，不写死事实）
    ///
    /// 命中规则与落盘语义对齐，三种都算：
    /// - `target == itemId`：删除（TrashManager 以 item.id 为 target）与回收站恢复（manifest.id == 条目 id）
    /// - `itemIds` 含该条目任一落点：Agent 装配（itemIds 存的是挂/卸的磁盘路径）
    /// - `target` 是某条落点的路径：单条 mount/unmount
    /// 只读既有字段，不给 LogEntry 加列（types.ts 1:1 裁定不动）。
    public func entries(involvingItemId itemId: String, landingPaths: [String]) -> [LogEntry] {
        let (records, _) = readAll()
        let paths = Set(landingPaths)
        let restoredIds = Set(records.compactMap(\.restoredOf))
        return records.filter { r in
            if r.target == itemId { return true }
            if let ids = r.itemIds, !Set(ids).isDisjoint(with: paths) { return true }
            return false
        }
        .map { $0.toEntry(restoredIds: restoredIds) }
        .reversed()
    }
}

extension JSONEncoder {
    static func encodeLine<T: Encodable>(_ value: T) throws -> String {
        let data = try JSONEncoder().encode(value)
        return String(data: data, encoding: .utf8)!
    }
}

/// 并发模型 §4「追加自愈」判定：文件存在且末字节不是 `\n`（上一行写了一半）→ true。
/// 追加方据此先补一个换行再写，保证**自己追加的**记录独立成行；
/// 半行碎片本身按 §4 损坏行口径原样保留（不删、不计数、等写方自愈或人工裁决）。
/// 读不到文件（不存在）返回 false——首建分支不需要自愈。
func fileTailNeedsNewline(_ url: URL) -> Bool {
    guard let h = try? FileHandle(forReadingFrom: url) else { return false }
    defer { try? h.close() }
    h.seekToEndOfFile()
    let size = h.offsetInFile
    guard size > 0 else { return false }
    h.seek(toFileOffset: size - 1)
    return h.readData(ofLength: 1).first != UInt8(ascii: "\n")
}
