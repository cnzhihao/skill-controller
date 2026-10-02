// InventoryScanner.swift — 全盘扫描引擎
// 产出 RawEntry（落点级事实），由 InventoryIndex 合并同名多副本（types.ts duplicates 语义）。
// 降级：读不到的位置如实记入 DegradedLocation（edge error-partial-degrade 数据源）。

import Foundation

public struct RawEntry: Sendable {
    public var name: String
    public var description: String
    public var type: ObjectType
    public var level: Level
    public var projectId: String?
    /// 该落点路径（symlink 或实体目录）
    public var locationPath: String
    /// 若该落点是 symlink，其解析后的目标路径
    public var resolvedPath: String?
    /// 该落点所在的挂载目录归属 Agent（nil = 共享源 / 配置文件）
    public var mountedAgentId: String?
}

public struct DegradedLocation: Hashable, Identifiable, Sendable {
    public var path: String
    public var reason: String
    public var id: String { path }
}

public struct ScanResult: Sendable {
    public var entries: [RawEntry]
    public var degraded: [DegradedLocation]
    /// 实际参与构建的位置数（横幅句式"M 个位置"）
    public var locationsScanned: Int

    public init(entries: [RawEntry], degraded: [DegradedLocation], locationsScanned: Int) {
        self.entries = entries
        self.degraded = degraded
        self.locationsScanned = locationsScanned
    }
}

public final class InventoryScanner: @unchecked Sendable {
    public init() {}

    public func scan(scope: ScanScope) -> ScanResult {
        var entries: [RawEntry] = []
        var degraded: [DegradedLocation] = []
        var scanned = 0

        for loc in scope.locations {
            switch loc.kind {
            case .skillDirectory:
                scanned += 1
                scanSkillDirectory(loc, into: &entries, degraded: &degraded)
            case .mcpJSON:
                scanned += 1
                scanMCPJSON(loc, into: &entries, degraded: &degraded)
            case .mcpTOML:
                scanned += 1
                scanMCPTOML(loc, into: &entries, degraded: &degraded)
            }
        }
        return ScanResult(entries: entries, degraded: degraded, locationsScanned: scanned)
    }

    // MARK: - Skills

    private func scanSkillDirectory(_ loc: ScanLocation, into entries: inout [RawEntry], degraded: inout [DegradedLocation]) {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: loc.url.path, isDirectory: &isDir), isDir.boolValue else {
            // 不存在的位置不算降级（Cursor 未装属正常态）；存在但读不了才是降级
            if fm.fileExists(atPath: loc.url.path) {
                degraded.append(DegradedLocation(path: loc.url.path, reason: "无权限"))
            }
            return
        }
        // D12 之一：这个 skills 目录自己就是一个 skill
        // （~/.workbuddy/connectors-marketplace/connectors/<name>/skills/ 里直接放着 SKILL.md，
        //  旧逻辑把它的 references/ scripts/ 当成一个个 skill，本机 39 处误判）
        if fm.fileExists(atPath: loc.url.appendingPathComponent("SKILL.md").path) {
            let owner = loc.url.deletingLastPathComponent().lastPathComponent
            scanSkillEntry(at: loc.url, isSymlink: false, loc: loc, into: &entries, forcedName: owner)
            return
        }
        // D6 深层模式（保留兼容入口）：child/<skills>/<skill> 两层结构（QoderWork 插件）。
        // 这条路不走 SkillLayout——内层 skills 自身有 SKILL.md 时语义特殊（没有 forcedName 可用），
        // 保持既有循环，行为不变。
        if loc.depth == 2 {
            do {
                let children = try fm.contentsOfDirectory(at: loc.url,
                                                          includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                for child in children {
                    guard !child.lastPathComponent.hasPrefix(".") else { continue }
                    let skillsDir = child.appendingPathComponent("skills")
                    if fm.fileExists(atPath: skillsDir.path) {
                        scanSkillEntries(at: skillsDir, loc: loc, into: &entries)
                    }
                }
            } catch {
                degraded.append(DegradedLocation(path: loc.url.path, reason: "无权限"))
            }
            return
        }
        // D12 命中即停枚举：唯一实现在 SkillLayout（库内发现与扫描器从此同一条规则，
        // 改一处两边生效——两份表 = D19 的成因形状，不许再犯）。
        // includeDanglingSymlinks: true——悬空链接 =「挂上了但目标没了」的磁盘事实，照收
        // （既有例外；SkillQualificationTests.danglingSymlinkStillCountsAsALanding 回归护航）。
        let candidates = SkillLayout.enumerate(root: loc.url, includeDanglingSymlinks: true)
        if candidates.isEmpty {
            // SkillLayout.enumerate 把「读不了」折成空集（纯函数不吃错误）；
            // 降级语义在扫描器这侧保住：空集时探针一次，区分「真空」与「无权限」
            // （edge error-partial-degrade——存在但读不了必须如实进降级清单）。
            if fm.fileExists(atPath: loc.url.path),
               (try? fm.contentsOfDirectory(at: loc.url, includingPropertiesForKeys: nil)) == nil {
                degraded.append(DegradedLocation(path: loc.url.path, reason: "无权限"))
            }
            return
        }
        for candidate in candidates {
            let isLink = (try? candidate.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) ?? false
            scanSkillEntry(at: candidate, isSymlink: isLink, loc: loc, into: &entries)
        }
    }

    /// 枚举一个 skill 挂载目录的直接子目录
    private func scanSkillEntries(at dir: URL, loc: ScanLocation, into entries: inout [RawEntry]) {
        let fm = FileManager.default
        guard let children = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey]) else { return }
        for child in children {
            let values = (try? child.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]))
            guard (values?.isDirectory ?? false) || (values?.isSymbolicLink ?? false) else { continue }
            guard !child.lastPathComponent.hasPrefix(".") else { continue }
            scanSkillEntry(at: child, isSymlink: values?.isSymbolicLink ?? false, loc: loc, into: &entries)
        }
    }

    /// 单个 skill 落点 → RawEntry
    ///
    /// D12 判定：**没有 SKILL.md 的目录不成为 skill 条目**。
    /// 旧逻辑只要是个子目录就收，于是 skill 自带的 `references/`、`scripts/`、`assets/`、
    /// `__pycache__` 全成了独立条目（本机 387 处落点 / 35 个假名字，也是"被挂 5049 次"虚高的主因）。
    /// 例外：悬空 symlink 仍然收录——那是"挂上了但目标已不存在"的磁盘事实，
    /// 不能因为读不到 SKILL.md 就当它没发生过。
    private func scanSkillEntry(at child: URL, isSymlink: Bool, loc: ScanLocation,
                                into entries: inout [RawEntry], forcedName: String? = nil) {
        let fm = FileManager.default
        let name = forcedName ?? child.lastPathComponent
        let skillMD = child.appendingPathComponent("SKILL.md")
        let hasManifest = fm.fileExists(atPath: skillMD.path)
        let targetGone = isSymlink && !fm.fileExists(atPath: child.path)
        guard hasManifest || targetGone else { return }
        let desc = SkillFrontmatter.description(at: skillMD) ?? ""
        var resolved: String?
        if isSymlink {
            resolved = (try? fm.destinationOfSymbolicLink(atPath: child.path)).map {
                URL(fileURLWithPath: $0).standardizedFileURL.path
            }
        }
        entries.append(RawEntry(
            name: name,
            description: desc,
            type: .skill,
            level: loc.level,
            projectId: loc.projectId,
            locationPath: child.path,
            resolvedPath: resolved,
            mountedAgentId: loc.agentId,
        ))
    }

    // MARK: - MCP（Phase 1 只读取示；写侧为 story-6）

    private func scanMCPJSON(_ loc: ScanLocation, into entries: inout [RawEntry], degraded: inout [DegradedLocation]) {
        guard let data = try? Data(contentsOf: loc.url) else {
            if FileManager.default.fileExists(atPath: loc.url.path) {
                degraded.append(DegradedLocation(path: loc.url.path, reason: "无权限"))
            }
            return
        }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            // JSON 语法非法（用户手改坏）→ edge "无法解析"中性态的数据源
            degraded.append(DegradedLocation(path: loc.url.path, reason: "JSON 解析失败"))
            return
        }
        // ~/.claude.json：顶层 mcpServers（user）+ projects[path].mcpServers（local scope）
        if loc.projectId == nil, let servers = obj["mcpServers"] as? [String: Any] {
            for (name, v) in servers {
                entries.append(mcpEntry(name: name, value: v, loc: loc))
            }
        }
        if let projects = obj["projects"] as? [String: Any] {
            for (path, pv) in projects {
                guard let pdict = pv as? [String: Any], let servers = pdict["mcpServers"] as? [String: Any] else { continue }
                let name = (path as NSString).lastPathComponent
                let pid = "proj-" + name
                for (sname, v) in servers {
                    var e = mcpEntry(name: sname, value: v, loc: loc)
                    e.level = .project
                    e.projectId = pid
                    entries.append(e)
                }
            }
        }
        // 项目 .mcp.json / .cursor/mcp.json：{"mcpServers": {...}}
        if loc.projectId != nil, let servers = obj["mcpServers"] as? [String: Any] {
            for (name, v) in servers {
                entries.append(mcpEntry(name: name, value: v, loc: loc))
            }
        }
    }

    private func mcpEntry(name: String, value: Any, loc: ScanLocation) -> RawEntry {
        var desc = ""
        if let d = value as? [String: Any] {
            if let cmd = d["command"] as? String { desc = cmd }
            else if let url = d["url"] as? String { desc = url }
        }
        return RawEntry(name: name, description: desc, type: .mcp, level: loc.level,
                        projectId: loc.projectId, locationPath: loc.url.path + "#" + name,
                        resolvedPath: nil, mountedAgentId: loc.agentId)
    }

    private func scanMCPTOML(_ loc: ScanLocation, into entries: inout [RawEntry], degraded: inout [DegradedLocation]) {
        guard let text = try? String(contentsOf: loc.url, encoding: .utf8) else {
            if FileManager.default.fileExists(atPath: loc.url.path) {
                degraded.append(DegradedLocation(path: loc.url.path, reason: "无权限"))
            }
            return
        }
        // 最小 TOML 段解析：只认 [mcp_servers.<name>]；描述取段内第一个 command/url 值
        var current: (name: String, desc: String)? = nil
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let l = line.trimmingCharacters(in: .whitespaces)
            if l.hasPrefix("[") {
                if let c = current { emitMCP(c, loc: loc, into: &entries) }
                current = nil
                let inner = l.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
                let parts = inner.split(separator: ".").map(String.init)
                // 仅 [mcp_servers.<name>] 是 server 条目；子表（.env/.oauth 等）归属其父条目，不新建
                if parts.count == 2, parts[0] == "mcp_servers" {
                    current = (parts[1], "")
                }
            } else if current != nil, current!.desc.isEmpty {
                if l.hasPrefix("command"), let v = l.split(separator: "=", maxSplits: 1).last {
                    current!.desc = v.trimmingCharacters(in: CharacterSet(charactersIn: "\" "))
                } else if l.hasPrefix("url"), let v = l.split(separator: "=", maxSplits: 1).last {
                    current!.desc = v.trimmingCharacters(in: CharacterSet(charactersIn: "\" "))
                }
            }
        }
        if let c = current { emitMCP(c, loc: loc, into: &entries) }
    }

    private func emitMCP(_ c: (name: String, desc: String), loc: ScanLocation, into entries: inout [RawEntry]) {
        entries.append(RawEntry(name: c.name, description: c.desc, type: .mcp, level: loc.level,
                                projectId: loc.projectId, locationPath: loc.url.path + "#mcp." + c.name,
                                resolvedPath: nil, mountedAgentId: loc.agentId))
    }
}

// MARK: - SKILL.md frontmatter（最小解析：只取 name/description）

public enum SkillFrontmatter {
    public static func description(at url: URL) -> String? {
        parse(at: url).description
    }

    public static func parse(at url: URL) -> (name: String?, description: String?) {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return (nil, nil) }
        guard text.hasPrefix("---") else { return (nil, nil) }
        var name: String?
        var desc: String?
        let lines = text.dropFirst(3).split(separator: "\n", omittingEmptySubsequences: false)
        var i = 0
        while i < lines.count {
            let l = lines[i].trimmingCharacters(in: .whitespaces)
            if l == "---" { break }
            // YAML 块标量：description: | 或 > —— 收集后续更缩进行，拼接为单行
            if let m = blockScalarKey(in: lines[i]), (m == "name" || m == "description") {
                var collected: [String] = []
                var j = i + 1
                while j < lines.count {
                    let raw = lines[j]
                    let trimmed = raw.trimmingCharacters(in: .whitespaces)
                    if trimmed.isEmpty { collected.append(""); j += 1; continue }
                    // 块标量内容行：比键行缩进更深
                    if raw.first == " " || raw.first == "\t" {
                        collected.append(trimmed)
                        j += 1
                    } else { break }
                }
                let joined = (m == "description" ? collected.joined(separator: " ") : collected.first ?? "")
                    .trimmingCharacters(in: .whitespaces)
                if m == "name", name == nil { name = joined.isEmpty ? nil : joined }
                if m == "description", desc == nil { desc = joined.isEmpty ? nil : joined }
                i = j
                continue
            }
            if let v = value(of: "name", in: l), name == nil { name = v }
            if let v = value(of: "description", in: l), desc == nil { desc = v }
            if name != nil, desc != nil { break }
            i += 1
        }
        return (name, desc)
    }

    /// 识别 "key: |" / "key: >" / "key: |-"/">-" 形式的块标量键
    private static func blockScalarKey(in line: Substring) -> String? {
        let l = line.trimmingCharacters(in: .whitespaces)
        for key in ["name", "description"] {
            let prefix = key + ":"
            if l.hasPrefix(prefix) {
                let rest = l.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces)
                if rest == "|" || rest == ">" || rest == "|-" || rest == ">-" || rest == "|+" || rest == ">+" {
                    return key
                }
            }
        }
        return nil
    }

    private static func value(of key: String, in line: String) -> String? {
        guard line.hasPrefix(key), line.dropFirst(key.count).hasPrefix(":") else { return nil }
        let v = line.dropFirst(key.count + 1).trimmingCharacters(in: .whitespaces)
        return v.isEmpty ? nil : v
    }
}
