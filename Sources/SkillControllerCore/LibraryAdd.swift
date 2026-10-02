// LibraryAdd.swift — `skillctl add` 进库主流程（extension AssemblyService）
//
// 拆分方案：AssemblyService.swift 已 887 行，add 流程独立成文件（extension 同类型跨文件合法），
// 主文件只动严格模式小改（设计档 §4 受影响文件清单）。
//
// 写入纪律（硬规则 8 三步齐）：WriteLock + --force 时旧件经 TrashManager 回收站 + 结构化日志
// 与装配事件。add 不是面向某 Agent 的装配，actor 如实写工具自身（复用 assembly 事件形态，
// 不新增 LogAction、StoredAssemblyEvent 零改动——老二进制混跑窗口解码零风险）。

import Foundation

extension AssemblyService {
    public struct AddOutcome: Sendable {
        public enum Status: Sendable, Equatable {
            case created
            case skippedConflict
            /// --force 后的回执：旧副本已移入回收站、新副本就位（文案⑩）
            case replaced
            case failed(reason: String)
        }
        public var name: String
        public var status: Status
        public var path: String
        /// replaced 时的回收站条目 id（如实告诉人旧件去哪了；不承诺"可一步恢复"——
        /// 新副本占着原位，按 D14「原位被占不覆盖」的恢复纪律，恢复旧件会如实失败，G7 写实）
        public var replacedTrashEntryId: String?
    }

    /// add 完成报告（不与 AssemblyReport 合并：add 不面向某 Agent，无项目/影响面基线语义）
    public struct AddReport: Sendable {
        public var outcomes: [AddOutcome]
        public var created: Int { outcomes.filter { if case .created = $0.status { return true }; return false }.count }
        public var replaced: Int { outcomes.filter { if case .replaced = $0.status { return true }; return false }.count }
        public var skipped: Int { outcomes.filter { if case .skippedConflict = $0.status { return true }; return false }.count }
        public var failed: Int { outcomes.filter { if case .failed = $0.status { return true }; return false }.count }
    }

    /// 多 skill 未选择：CLI 层转成退出 64 + 可照抄命令（A2：写入发生在选择之后，盘上零写入）
    public struct AddNeedsSelection: Error {
        public let discovered: [(name: String, dir: URL)]
    }

    /// add 主流程：来源分类已在 CLI 层做完，这里收 <skill 源目录>。
    /// select: nil = 单 skill 直装；"*" 或 "--all" 由 CLI 层折算成全量 names 再传入。
    /// 全程持 App 级写锁（与 land/unmount 同一把）。
    public func add(sources: [(name: String, dir: URL)], force: Bool) throws -> AddReport {
        let fm = FileManager.default
        let library = SkillLibrary(home: home)
        var outcomes: [AddOutcome] = []

        for source in sources {
            let entry = library.entryURL(named: source.name)
            // lstat 占用判定（与 land 同口径：实体、有效链接、悬空链接都算已占用，不静默覆盖）
            if Self.pathOccupied(entry.path) {
                if !force {
                    outcomes.append(AddOutcome(name: source.name, status: .skippedConflict,
                                               path: entry.path, replacedTrashEntryId: nil))
                    continue
                }
                // --force：更新是显式破坏性动作，旧件必须经回收站（裸删违反硬规则）。
                // TrashManager.trash 的签名吃 InventoryItem；库内条目按同名 skill 造一个描述性 item——
                // 它唯一进 manifest 的字段是 id/name/locations（回收站页回显用），不进清单。
                let item = InventoryItem(id: "skill:\(source.name)", name: source.name,
                                         description: "技能库副本（--force 更新前旧件）", type: .skill,
                                         level: .library, projectId: nil, sourcePath: entry.path,
                                         mountedBy: [], status: .unmounted)
                do {
                    let manifest = try TrashManager(paths: paths, lock: lock).trash(item: item, actor: "skillctl")
                    outcomes.append(AddOutcome(name: source.name, status: .replaced, path: entry.path,
                                               replacedTrashEntryId: manifest.entryId))
                } catch TrashError.nothingToDelete {
                    // 理论不可达（pathOccupied 已确认占用）；真发生就按占用前状态继续拷入，不拦
                    outcomes.append(AddOutcome(name: source.name, status: .replaced, path: entry.path,
                                               replacedTrashEntryId: nil))
                } catch {
                    outcomes.append(AddOutcome(name: source.name,
                                               status: .failed(reason: "旧副本移入回收站失败：\(error.localizedDescription)"),
                                               path: entry.path, replacedTrashEntryId: nil))
                    continue
                }
            }
            do {
                try lock.withLock {
                    try fm.createDirectory(at: library.root, withIntermediateDirectories: true)
                    try SkillLayout.copySkill(from: source.dir, to: entry)
                }
                // replaced 分支的 outcome 已在上面 append（带回收站 id），这里只补 created
                if !outcomes.contains(where: { $0.name == source.name && $0.path == entry.path
                    && $0.status == .replaced }) {
                    outcomes.append(AddOutcome(name: source.name, status: .created, path: entry.path,
                                               replacedTrashEntryId: nil))
                }
            } catch {
                // 拷贝失败：清理半截目标（只在目标是我们这次创建的半成品时清——
                // occupied+force 分支旧件已进回收站，此时删半成品是清自己的痕迹，不是删别人的数据）
                try? fm.removeItem(at: entry)
                // --force 拷贝失败：同一条目不能既记 replaced（算新增、进事件 added）
                // 又记 failed——把 replaced 改写成 failed，回收站 id 保留在 reason 里如实交代
                // （旧副本确实进了回收站，这条事实不能丢；G7 不许回执自相矛盾）
                if let rIdx = outcomes.lastIndex(where: { $0.name == source.name && $0.path == entry.path
                    && $0.status == .replaced }) {
                    let trashId = outcomes[rIdx].replacedTrashEntryId
                    outcomes[rIdx] = AddOutcome(name: source.name,
                                               status: .failed(reason: "拷入技能库失败：\(error.localizedDescription)"
                                                   + (trashId != nil ? "（旧副本已移入回收站：\(trashId!)）" : "")),
                                               path: entry.path, replacedTrashEntryId: trashId)
                } else {
                    outcomes.append(AddOutcome(name: source.name,
                                               status: .failed(reason: "拷入技能库失败：\(error.localizedDescription)"),
                                               path: entry.path, replacedTrashEntryId: nil))
                }
            }
        }

        try finishAdd(outcomes: outcomes)
        return AddReport(outcomes: outcomes)
    }

    /// add 落日志 + 落装配事件（A8；文案⑦ 回执 detail、文案⑧ Banner 呈现的数据源）。
    /// 复用 assembly 形态：actor="skillctl"、projectId 空（add 不面向某 Agent）。
    /// 快照影响面 = 库根 + 各条目目录——事件 revision 与 App 侧比对同口径（不用全盘哈希，D15 教训）。
    private func finishAdd(outcomes: [AddOutcome]) throws {
        let written = outcomes.filter { o in
            switch o.status {
            case .created, .replaced: return true
            case .skippedConflict, .failed: return false
            }
        }
        let conflicts = outcomes.compactMap { o -> AssemblyConflict? in
            guard case .skippedConflict = o.status else { return nil }
            return AssemblyConflict(itemId: o.path, reason: "库内同名已存在，未覆盖（更新用 --force）")
        }
        let failed = outcomes.compactMap { o -> AssemblyConflict? in
            guard case .failed(let why) = o.status else { return nil }
            return AssemblyConflict(itemId: o.path, reason: why)
        }
        let replacedNote = outcomes.contains { if case .replaced = $0.status { return true }; return false }
            ? " · 更新 \(outcomes.filter { if case .replaced = $0.status { return true }; return false }.count)"
            : ""
        let event = AssemblyEvent(
            id: UUID().uuidString,
            date: LogRecord.nowISO(),
            agentId: "skillctl",
            projectId: "",
            added: written.map(\.path),
            removed: [],
            conflicts: conflicts,
            reviewed: false,
        )
        let dirs = [SkillLibrary.canonicalized(SkillLibrary(home: home).root.path)]
            + written.map { SkillLibrary.canonicalized(URL(fileURLWithPath: $0.path).deletingLastPathComponent().path) }
        let idx = indexForBaseline(event: event)
        let itemIds = written.map(\.path) + failed.map(\.itemId)
        // 文案⑦：`skillctl 收编进技能库（新增 N · 跳过 M · 失败 K）`——replaced 计入新增（库内结果都是新副本）
        let record = LogRecord(actor: "skillctl", actorKind: .agent, action: .assembly,
                               detail: "skillctl 收编进技能库（新增 \(written.count) · 跳过 \(conflicts.count) · 失败 \(failed.count)\(replacedNote)）",
                               target: "技能库",
                               reversible: true, itemIds: itemIds)
        try log.append(record)
        try events.append(StoredAssemblyEvent(event: event,
                                             revision: Self.revision(of: idx, within: dirs),
                                             revisionScope: dirs,
                                             failed: failed.isEmpty ? nil : failed))
    }
}
