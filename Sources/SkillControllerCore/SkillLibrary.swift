// SkillLibrary.swift — Skill 元位置（中央库）· 识别与条目枚举
//
// 库 = ~/.skill-library，每个 skill 一个子目录（本机唯一权威副本）。
// pull/mount/恢复链的源只从这里解析（严格模式，缺货报 notInLibrary，不回退散落副本）；
// `skillctl add` 是唯一进库通道。
//
// 条目资格与扫描器 D12 同源：目录自己有 SKILL.md。枚举的唯一实现就是下面的
// SkillLayout.enumerate——InventoryScanner 的枚举段与 add 的候选枚举都调它，
// 改一处两边生效（两份表 = D19 的成因形状，不许再犯）。

import Foundation

public struct SkillLibrary: Sendable {
    /// 库根目录（<home>/.skill-library）
    public let root: URL

    /// home 可注入（测试造沙箱；生产传用户主目录）
    public init(home: URL) {
        self.root = home.standardizedFileURL.appendingPathComponent(".skill-library", isDirectory: true)
    }

    /// 生产默认根（无 home 注入场景的便捷出口；纯函数便于单测与分类特判共用）
    public static func defaultRoot(home: URL) -> URL {
        home.standardizedFileURL.appendingPathComponent(".skill-library", isDirectory: true)
    }

    /// 库内条目 URL（名字只取目录名，与扫描器同口径）
    public func entryURL(named name: String) -> URL {
        root.appendingPathComponent(name, isDirectory: true)
    }

    /// D12 同源的库条目合格判定：目录存在 ∧ 含 SKILL.md。
    /// 目录在而无 SKILL.md 时不解析——防止把未收编的杂物目录挂进 Agent。
    public func hasEntry(_ name: String) -> Bool {
        let dir = entryURL(named: name)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: dir.path, isDirectory: &isDir), isDir.boolValue else {
            return false
        }
        return FileManager.default.fileExists(atPath: dir.appendingPathComponent("SKILL.md").path)
    }

    /// 当前索引里同名 Skill 的散落副本 → 可照抄补救命令（≤3 条，MCP `#` 落点剔除）。
    /// remedies 的落点顺序按路径稳定排序（不随索引内部顺序漂移，输出可照抄必须可复现）。
    /// 本体优先取库落点后，库路径自身不会出现在散落副本里（见 InventoryIndex.rebuild 的本体选择）；
    /// 即便同名条目 sourcePath 恰为库路径（极端时序），`--from` 库自身也是无害回环，不特判。
    public static func remedies(for name: String, index: InventoryIndex) -> [String] {
        guard let item = index.items.first(where: { $0.name == name && $0.type == .skill }) else {
            return []
        }
        var candidates = Set<String>()
        candidates.insert(item.sourcePath)
        item.duplicates.forEach { candidates.insert($0) }
        let fsCandidates = candidates.filter { !$0.contains("#") }   // MCP `#` 落点不是文件系统路径
        return fsCandidates.sorted()
            .prefix(3)
            .map { "skillctl add \(name) --from '\($0)'" }
    }

    /// 该路径是否落在库根之下（严格模式恢复链校验用；两侧都先 canonical 再比较，
    /// /var→/private/var 与软链库根的前缀漏判由此避免——D25 的同款陷阱）
    public static func isLibraryPath(_ path: String, home: URL) -> Bool {
        let lib = canonicalized(defaultRoot(home: home).standardizedFileURL.path)
        let p = canonicalized(URL(fileURLWithPath: path).standardizedFileURL.path)
        return p == lib || p.hasPrefix(lib + "/")
    }

    /// isLibraryPath 的无 home 形态：库根从路径自身推导（`/Users/<x>/.skill-library`）。
    /// rebuild 的本体优先判定用它——rebuild 没有 home 参数，逐一注入会改公共签名；
    /// 路径不形如 `/Users/<user>/.skill-library(/**)` 时返回 false（非库路径零误伤）。
    public static func isInsideSkillLibrary(_ path: String) -> Bool {
        let comps = path.split(separator: "/").map(String.init)
        // [<empty?>, "Users", <user>, ".skill-library", ...]
        guard comps.count >= 3, comps[0] == "Users", comps[2] == ".skill-library" else { return false }
        return true
    }

    static func canonicalized(_ path: String) -> String {
        let url = URL(fileURLWithPath: path).standardizedFileURL
        if let c = try? url.resourceValues(forKeys: [.canonicalPathKey]).canonicalPath {
            return URL(fileURLWithPath: c).standardizedFileURL.path
        }
        return url.path
    }
}

// MARK: - 条目枚举（D12 命中即停的唯一实现）

public enum SkillLayout {
    /// 「杂物不进库」的排除清单（设计档 §2.2 评审点 #6 写死）：
    /// 组件级整名匹配，只作用于**拷贝内容**，不影响候选枚举与条目名——
    /// 资格与命名唯 SKILL.md/D12 判定（名为 tests 但含 SKILL.md 的目录仍是 skill，仅其内部清单项被剔除）。
    public static let copyExcludedNames: Set<String> = [
        ".git", "node_modules", "__pycache__", "test", "tests", "__tests__", "spec", "specs",
    ]

    /// D12 命中即停枚举的唯一实现：
    /// root 自身有 SKILL.md → [root]（整仓即 skill，条目名 = 根目录名，不下钻）；
    /// 否则只收直接子目录中含 SKILL.md 者，不下钻。
    ///
    /// includeDanglingSymlinks（默认 false）：无 SKILL.md 但目标已消失的 symlink 是否照收——
    /// - 扫描侧传 true：悬空链接 =「挂上了但目标没了」的磁盘事实，照收
    ///   （InventoryScanner 既有例外，danglingSymlinkStillCountsAsALanding 回归护航）；
    /// - add 侧用默认 false：拷贝悬空链接必然失败，弃收。
    /// 两个消费方的语义分叉由这一个参数同时表达。
    public static func enumerate(root: URL, includeDanglingSymlinks: Bool = false) -> [URL] {
        let fm = FileManager.default
        // 根自身有 SKILL.md → 整仓/整目录就是一条
        if fm.fileExists(atPath: root.appendingPathComponent("SKILL.md").path) {
            return [root.standardizedFileURL]
        }
        guard let children = try? fm.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey]) else {
            return []
        }
        var out: [URL] = []
        for child in children {
            let name = child.lastPathComponent
            guard !name.hasPrefix(".") else { continue }   // 与扫描器同一句式：.system/.temp 等非用户 skill
            let values = try? child.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            let isSymlink = values?.isSymbolicLink ?? false
            let isDir = (values?.isDirectory ?? false) && !isSymlink
            guard isDir || isSymlink else { continue }
            if fm.fileExists(atPath: child.appendingPathComponent("SKILL.md").path) {
                out.append(child.standardizedFileURL)
                continue
            }
            // 悬空 symlink 例外：目标已消失（lstat 在、fileExists 不在）→ 由参数决定收不收
            if includeDanglingSymlinks, isSymlink, !fm.fileExists(atPath: child.path) {
                out.append(child.standardizedFileURL)
            }
        }
        return out.sorted { $0.lastPathComponent.localizedCaseInsensitiveCompare(
            $1.lastPathComponent) == .orderedAscending }
    }

    /// 条目名：枚举根自身 → 根目录名；子目录 → 子目录名
    public static func entryName(of dir: URL, root: URL) -> String {
        dir.standardizedFileURL.path == root.standardizedFileURL.path
            ? root.lastPathComponent
            : dir.lastPathComponent
    }

    /// 把一个 skill 目录整体拷贝进目标位置（add 的写入体；与候选枚举同源的两路共用）。
    /// 排除清单只作用于拷贝内容（copyExcludedNames 组件级整名匹配）。
    public static func copySkill(from src: URL, to dest: URL) throws {
        let fm = FileManager.default
        try fm.copyItem(atPath: src.path, toPath: dest.path)
        // 拷完后剔除清单内条目（逐个删，比"边走边滤"可靠：copyItem 不带过滤钩子）
        for name in copyExcludedNames {
            let junk = dest.appendingPathComponent(name)
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: junk.path, isDirectory: &isDir) {
                try fm.removeItem(atPath: junk.path)
            }
        }
    }
}
