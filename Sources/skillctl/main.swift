// main.swift — skillctl：Agent 的管理接口（story-2/3 写侧入口）
// 设计口径：人不在场、不确认；一切写操作 = 写锁 + 写前落日志 + 可一步恢复。
// 输出默认 JSON（面向 Agent 消费）；退出码 0 成功 / 64 用法错 / 69 写被拒或失败。

import Foundation
import SkillControllerCore

// 版本只能有一处真相：PATH 上装的旧 skillctl 与 App 报同一个 0.2.0，
// 是这次走查把「App 看得见、CLI 拉不到」误判成扫描逻辑 bug 的直接原因。
let version = SkillControllerVersion.string

func emit(_ text: String) { FileHandle.standardOutput.write((text + "\n").data(using: .utf8)!) }
func emitErr(_ text: String) { FileHandle.standardError.write((text + "\n").data(using: .utf8)!) }

func jsonLine<T: Encodable>(_ value: T) -> String {
    let e = JSONEncoder()
    e.outputFormatting = [.sortedKeys]
    return (try? String(data: e.encode(value), encoding: .utf8)) ?? "{}"
}

/// 异构字典（含 Any）走 JSONSerialization
func emitJSON(_ obj: [String: Any]) {
    let data = (try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys])) ?? Data("{}".utf8)
    emit(String(data: data, encoding: .utf8) ?? "{}")
}

func usage() -> Never {
    emit("""
    skillctl \(version) — Skill 控制器 CLI（Agent 管理接口）

    USAGE:
      skillctl search <关键词> [--type skill|mcp]
      skillctl list [--type skill|mcp] [--format tsv|json]
      skillctl info <name>
      skillctl pull <name> --target <项目路径> [--agent <codex|claude|qoder|cursor>] [--copy]
      skillctl mount <name> --on <agent> [--project <项目路径>]
      skillctl unmount <name> --on <agent> [--project <项目路径>]
      skillctl add <本地路径 | owner/repo | https://...git>
                    [--from <路径>] [-s <名1,名2> | -s '*'] [--all] [--force]
      skillctl events

    说明：
      · pull/mount 只从技能库（~/.skill-library）取源（严格模式，缺货报错并给可照抄的
        补救命令，不再回退散落副本）；默认建 symlink（卸装不伤源），--copy 改为复制
      · add 是唯一进库通道：本地收编不联网；owner/repo 与 https URL 走 git clone
        （浅 clone，全应用唯一联网面）；多 skill 仓库未给 -s 时不猜，列清单退出
      · 目标已存在时跳过并在结果里给出原因，不覆盖、不静默（add 更新用 --force，旧件进回收站）
      · 每次写都落结构化日志与装配事件（App「回退」页与验收 Banner 的数据源）
      · list 默认 tsv（一行一条，供批量归类读），首行 # 元信息如实报全集大小、
        自述为空的条数、本次扫了几处位置——偏小的全集会在这里显式露出来，不藏
    """)
    exit(0)
}

// 参数解析
var args = Array(CommandLine.arguments.dropFirst())
guard !args.isEmpty else { usage() }

@MainActor func takeFlag(_ name: String) -> String? {
    guard let i = args.firstIndex(of: name) else { return nil }
    guard i + 1 < args.count else { emitErr("skillctl: \(name) 缺参数值"); exit(64) }
    let v = args[i + 1]
    args.removeSubrange(i...i+1)
    return v
}
@MainActor func takeBool(_ name: String) -> Bool {
    if let i = args.firstIndex(of: name) { args.remove(at: i); return true }
    return false
}

if takeBool("--version") || takeBool("-v") { emit("skillctl \(version)"); exit(0) }
if takeBool("--help") || takeBool("-h") { usage() }

let cmd = args.removeFirst()
let service = AssemblyService()

switch cmd {
case "search":
    guard let q = args.first else { emitErr("skillctl: search 需要关键词"); exit(64) }
    let typeStr = takeFlag("--type")
    let type: ObjectType? = typeStr == "skill" ? .skill : (typeStr == "mcp" ? .mcp : nil)
    let results = service.search(q, type: type)
    emitJSON(["count": results.count, "results": results.map { JSONSafe($0) }])

case "list":
    // 出表趟的读侧：把全集的 name + 作者自述批量吐出来，供 Agent 归类。
    // 为什么默认 tsv 而不是 json：1,445 条 JSON 会把一半上下文预算花在字段名和标点上，
    // 而这一趟的唯一产出就是一张分类表。机读口径仍保留 --format json。
    let typeStr = takeFlag("--type")
    let wantType: ObjectType? = typeStr == "skill" ? .skill : (typeStr == "mcp" ? .mcp : nil)
    let fmt = takeFlag("--format") ?? "tsv"
    let built = service.buildIndex()
    let idx = built.index
    let rows: [InventoryItem]
    if let t = wantType {
        rows = idx.items.filter { $0.type == t }
    } else {
        rows = idx.items
    }
    let sorted = rows.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    if fmt == "json" {
        emitJSON(["count": sorted.count,
                  "totalItems": idx.items.count,
                  "locationsScanned": idx.locationsScanned,
                  "degradedLocations": idx.degraded.count,
                  "scope": JSONSafe(built.scope),
                  "results": sorted.map { JSONSafe($0) }])
    } else {
        // 首行元信息是诚实性条款：偏小的全集（没缓存时只扫 home 两层）必须在这里显式露出来，
        // 不能让 Agent 拿一份小全集当全集去分类。
        let blank = sorted.filter {
            $0.description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }.count
        var chars = 0
        for r in sorted { chars += r.name.count + r.description.count }
        var out = ["# skillctl \(version) · 本次输出 \(sorted.count) 条（全集 \(idx.items.count)）· 自述为空 \(blank) · 位置 \(idx.locationsScanned) · 降级 \(idx.degraded.count) · name+自述合计 \(chars) 字形"]
        if let w = built.scope.warning { out.append("# 警告：\(w)") }
        for r in sorted { out.append("\(r.type.rawValue)\t\(r.name)\t\(flat(r.description))") }
        emit(out.joined(separator: "\n"))
    }

case "info":
    guard let name = args.first else { emitErr("skillctl: info 需要 name"); exit(64) }
    guard let item = service.info(name) else {
        emitJSON(["error": "not-found", "name": name]); exit(69)
    }
    emit(jsonLine(item))

case "pull":
    guard let name = args.first else { emitErr("skillctl: pull 需要 name"); exit(64) }
    guard let target = takeFlag("--target") else { emitErr("skillctl: pull 需要 --target <项目路径>"); exit(64) }
    let agent = takeFlag("--agent") ?? "codex"
    let copy = takeBool("--copy")
    do {
        let r = try service.pull(name: name, target: (target as NSString).expandingTildeInPath, agent: agent, copy: copy)
        emit(reportJSON(r, command: "pull"))
        exit(allBad(r) ? 69 : 0)
    } catch let e as AssemblyService.AssemblyError {
        emitJSON(["error": describe(e), "command": "pull"]); exit(69)
    } catch {
        emitJSON(["error": error.localizedDescription, "command": "pull"]); exit(69)
    }

case "mount":
    guard let name = args.first else { emitErr("skillctl: mount 需要 name"); exit(64) }
    guard let agent = takeFlag("--on") else { emitErr("skillctl: mount 需要 --on <agent>"); exit(64) }
    let project = takeFlag("--project").map { ($0 as NSString).expandingTildeInPath }
    do {
        let r = try service.mount(name: name, on: agent, projectPath: project)
        emit(reportJSON(r, command: "mount"))
        exit(allBad(r) ? 69 : 0)
    } catch let e as AssemblyService.AssemblyError {
        emitJSON(["error": describe(e), "command": "mount"]); exit(69)
    } catch {
        emitJSON(["error": error.localizedDescription, "command": "mount"]); exit(69)
    }

case "unmount":
    guard let name = args.first else { emitErr("skillctl: unmount 需要 name"); exit(64) }
    guard let agent = takeFlag("--on") else { emitErr("skillctl: unmount 需要 --on <agent>"); exit(64) }
    let project = takeFlag("--project").map { ($0 as NSString).expandingTildeInPath }
    do {
        let r = try service.unmount(name: name, on: agent, projectPath: project)
        emit(reportJSON(r, command: "unmount"))
        // 本体拒绝也算 refused → 69
        exit(r.outcomes.contains { if case .refused = $0.status { return true }; if case .failed = $0.status { return true }; return false } ? 69 : 0)
    } catch let e as AssemblyService.AssemblyError {
        emitJSON(["error": describe(e), "command": "unmount"]); exit(69)
    } catch {
        emitJSON(["error": error.localizedDescription, "command": "unmount"]); exit(69)
    }

case "add":
    AddCommand.run(args, service: service)

case "events":
    let all = AssemblyEventStore(paths: service.paths, lock: WriteLock(paths: service.paths)).all()
    emitJSON(["count": all.count, "events": all.map { JSONSafe($0.event) }])

default:
    emitErr("skillctl: 未知子命令 '\(cmd)'")
    usage()
}

// MARK: - helpers

/// 换行与制表符压平：tsv 里「一条一行」是硬约定，
/// SKILL.md 的块标量描述（多行那种）不能把表撑破
func flat(_ s: String) -> String {
    s.replacingOccurrences(of: "\n", with: " ")
     .replacingOccurrences(of: "\r", with: " ")
     .replacingOccurrences(of: "\t", with: " ")
}

/// Encodable → [String: Any]（供异构 JSON 顶层拼装）
func JSONSafe<T: Encodable>(_ value: T) -> Any {
    guard let data = try? JSONEncoder().encode(value),
          let obj = try? JSONSerialization.jsonObject(with: data) else { return [:] }
    return obj
}

struct OutcomeJSON: Codable { var status: String; var path: String; var reason: String? }

func allBad(_ r: AssemblyReport) -> Bool {
    r.outcomes.allSatisfy { o in
        if case .created = o.status { return false }
        return true
    }
}

func reportJSON(_ r: AssemblyReport, command: String) -> String {
    let outcomes: [OutcomeJSON] = r.outcomes.map { o in
        let label: String
        switch o.status {
        case .created: label = "created"
        case .skippedConflict: label = "skipped-conflict"
        case .refused: label = "refused"
        case .failed: label = "failed"
        }
        return OutcomeJSON(status: label, path: o.path, reason: o.reason)
    }
    // #6c：写侧警告如实上抛（锁超时等），非 nil 才进 JSON——Agent 拿到的报告不假装一切正常
    var payload: [String: Any] = [
        "command": command,
        "eventId": r.event.id,
        "agent": r.event.agentId,
        "project": r.event.projectId,
        "added": r.event.added.count,
        "removed": r.event.removed.count,
        "conflicts": r.event.conflicts.count,
        "outcomes": outcomes.map { ["status": $0.status, "path": $0.path, "reason": $0.reason ?? ""] },
        "logged": true,
    ]
    if let w = r.warning { payload["warning"] = w }
    let data = (try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])) ?? Data()
    return String(data: data, encoding: .utf8) ?? "{}"
}

func describe(_ e: AssemblyService.AssemblyError) -> String {
    switch e {
    case .notFound(let n): return "全集里没有 '\(n)'（可先 skillctl search）"
    case .unknownAgent(let a): return "未知 Agent '\(a)'（可用：codex/claude/qoder/cursor）"
    case .notMounted(let p): return "该位置没有挂载：\(p)"
    case .notASkill(let n): return "'\(n)' 是 MCP 配置项，不是 Skill，mount 只支持 Skill"
    case .notInLibrary(let n, let remedies): return AddCommandRender.describeNotInLibrary(name: n, remedies: remedies)
    }
}
