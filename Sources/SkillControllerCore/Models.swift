// Models.swift — 统一数据模型
// 1:1 翻译自 skill-controller-proto/src/flows/shared/types.ts（架构裁定：字段不许增删改）
// 两类对象 (skill | mcp) × 归属三维 (agent / level / project)

import Foundation

public enum ObjectType: String, Codable, Sendable {
    case skill
    case mcp
}

/// App 与 skillctl 是同仓库、同次构建的两个产物，版本号必须同源。
/// 真机踩过的坑：PATH 上还是前一天装的 skillctl，App 已经换了扫描口径——
/// Agent 拉不到「App 里看得见」的条目，而两边都不报错（2026-09-21 走查抓到）。
/// 版本戳现在写进发现缓存，CLI 读缓存时对不上会如实警告，不再静默降级。
///
/// **0.2.4（2026-09-24）**：D25（基线并入这次动过的 skills 目录 + rebaseRevision）和
/// D32=B（恢复时记链接凭据 + 重新挂回）都改了 **CLI 进程内**的行为，装配事件的存储结构也多了字段，
/// 但当时没往前走版本号——结果 PATH 上 9-22 装的旧 skillctl 与新 App 都自称 0.2.3，
/// 那道"版本不一致就警告"的护栏形同不存在，我因此把一次"旧二进制在跑"误判成新代码有洞（D34）。
/// 纪律：**改 CLI 行为必须同一次提交里 bump 这里，并按 README 重装。**
/// **0.2.5（2026-09-24）**：D35=B——CLI 装配时会把"这次动过、还没进发现缓存"的 skills 目录写回缓存
/// （一处真相：App 的轻量重扫只读这份缓存）。这是 CLI 进程内的行为变化，按上面那条纪律往前走版本号。
/// **0.2.6（2026-09-26）**：#5 mount 类型守卫——MCP 名 mount 抛 notASkill（audit-remediation 批）。
/// **0.2.7（2026-09-26）**：#12 装配失败组（D37）——StoredAssemblyEvent 加可选 failed 数组，
/// finishAssembly 把 .failed outcome 归组落盘、日志 detail/itemIds 如实记失败（审计批复盘批）。
/// CLI 进程内行为变化，按上面的纪律同一次提交 bump 并重装。
/// **1.0.0（2026-09-27）**：开源发布版——版本线随公开 tag v1.0.0 对齐（公开历史第一版起
/// tag=builderVersion=`skillctl --version` 三者一致），无 CLI 行为变更。
/// **1.1.0（2026-09-29）**：Skill 元位置（中央库）批——pull/mount/恢复链改只从 ~/.skill-library
/// 解析源（严格模式，缺货报 notInLibrary 不回退散落副本）；新增 `skillctl add` 进库通道
/// （本地收编 / clone 后只取 skill）。全是 CLI 进程内行为变化，按上面的纪律同一次提交 bump 并重装。
/// **1.1.1（2026-09-30）**：走查修复（台账 #23）——rebuild 本体优先取库落点时条目级
/// level/projectId 一并取库落点值（此前仍取分组首条，库条目被 mount 过即被误判成
/// project/user 级，「技能库」筛选恒空、CLI list/info 的 level 字段失真）。
/// CLI JSON 输出值变化，按上面的纪律同一次提交 bump 并重装。
public enum SkillControllerVersion {
    public static let string = "1.1.1"
}

public enum Level: String, Codable, Sendable {
    case user
    case project
    /// Skill 元位置（中央库 ~/.skill-library）：本机唯一权威副本所在层级。
    /// 设计明确这是对 types.ts 1:1 模型的显式扩展（原型没有库概念）；Level 不落盘，
    /// 受影响的只有 JSON 输出值域（list/info 的 level 字段多一个取值），消费方读字符串天然兼容。
    case library
}

public enum ItemStatus: String, Codable, Sendable {
    case mounted
    case unmounted
    case zeroMount = "zero-mount"
}

public struct Agent: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var name: String
    /// 挂载目录展示，纯本地路径
    public var homeDir: String

    public init(id: String, name: String, homeDir: String) {
        self.id = id
        self.name = name
        self.homeDir = homeDir
    }
}

public struct Project: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var path: String

    public init(id: String, name: String, path: String) {
        self.id = id
        self.name = name
        self.path = path
    }
}

public struct MountRecord: Codable, Hashable, Sendable {
    public var at: String // ISO date
    public var action: MountAction
    public var agentId: String
    public var scope: Level
    public var projectId: String?

    public init(at: String, action: MountAction, agentId: String, scope: Level, projectId: String? = nil) {
        self.at = at
        self.action = action
        self.agentId = agentId
        self.scope = scope
        self.projectId = projectId
    }
}

public enum MountAction: String, Codable, Sendable {
    case mount
    case unmount
}

public struct InventoryItem: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var description: String
    public var type: ObjectType
    public var level: Level
    public var projectId: String?
    /// 实际文件落点
    public var sourcePath: String
    /// 当前被哪些 Agent 挂载
    public var mountedBy: [String] // agent ids
    /// 同名多副本落点（合并展示）
    public var duplicates: [String]
    /// 静态触发词重叠对（基于 SKILL.md 文案，工具拿不到的调用数据不做）
    public var triggerOverlapWith: [String] // item ids
    public var mounts: [MountRecord]
    public var status: ItemStatus

    public init(id: String, name: String, description: String, type: ObjectType, level: Level,
                projectId: String? = nil, sourcePath: String, mountedBy: [String],
                duplicates: [String] = [], triggerOverlapWith: [String] = [],
                mounts: [MountRecord] = [], status: ItemStatus) {
        self.id = id
        self.name = name
        self.description = description
        self.type = type
        self.level = level
        self.projectId = projectId
        self.sourcePath = sourcePath
        self.mountedBy = mountedBy
        self.duplicates = duplicates
        self.triggerOverlapWith = triggerOverlapWith
        self.mounts = mounts
        self.status = status
    }
}

public struct AssemblyConflict: Codable, Hashable, Sendable {
    public var itemId: String
    public var reason: String

    public init(itemId: String, reason: String) {
        self.itemId = itemId
        self.reason = reason
    }
}

public struct AssemblyEvent: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var date: String
    public var agentId: String
    public var projectId: String
    public var added: [String] // item ids
    public var removed: [String] // item ids
    public var conflicts: [AssemblyConflict]
    public var reviewed: Bool

    public init(id: String, date: String, agentId: String, projectId: String,
                added: [String], removed: [String], conflicts: [AssemblyConflict], reviewed: Bool) {
        self.id = id
        self.date = date
        self.agentId = agentId
        self.projectId = projectId
        self.added = added
        self.removed = removed
        self.conflicts = conflicts
        self.reviewed = reviewed
    }
}

public enum ActorKind: String, Codable, Sendable {
    case agent
    case human
}

public struct LogEntry: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var at: String
    public var actor: String // agent id 或 '智昊'
    public var actorKind: ActorKind
    public var action: String
    public var target: String
    public var reversible: Bool
    public var restored: Bool?

    public init(id: String, at: String, actor: String, actorKind: ActorKind,
                action: String, target: String, reversible: Bool, restored: Bool? = nil) {
        self.id = id
        self.at = at
        self.actor = actor
        self.actorKind = actorKind
        self.action = action
        self.target = target
        self.reversible = reversible
        self.restored = restored
    }
}
