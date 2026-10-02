// AddCommand.swift — skillctl add 的参数分类与缺货渲染（skill-library 批 §2.2/§2.3/§4）
//
// main.swift 拆分预案（评审点 #4）：add 来源分类、notInLibrary 缺货 describe 渲染、
// add usage 段独立成文件，主文件增量收到 +40（留在 300 行档内）。
//
// 退出码：0 成功（含部分冲突回执）/ 64 用法错 · 多 skill 未选择 / 69 clone 失败 · 全部冲突 · 严格缺货

import Foundation
import SkillControllerCore

/// add 用法错（退出码 64 载体；message 人读）
struct AddUsageError: Error {
    let message: String
    init(_ message: String) { self.message = message }
}

/// add 来源四形态分类（设计 §2.2 表）：
/// 本地路径 / `<name> --from <路径>` / `<owner>/<repo>` / 完整 git URL。
/// HTTPS 校验放在这一层而非 GitClone 内部——单元测试才能用本地 fixture 仓走 .system 真实 spawn。
enum AddSourceClassifier {
    /// 分类结果：clone（含 url）或 local（含目录与候选名）
    enum Source: Equatable {
        case clone(url: String)
        case local(dir: String, suggestedName: String?)
    }

    /// 判定顺序固定：--from 分支优先 → 路径存在 → owner/repo → URL。
    /// `add <名> --from <路径>` 的位置参数是**条目名**（合法）；真正互斥的非法形状是
    /// 位置参数本身是个**存在的本地目录**又给 --from（两个来源同时给了）。
    static func classify(positional: String?, fromFlag: String?, cwd: String) -> Result<Source, AddUsageError> {
        if let from = fromFlag {
            let expanded = (from as NSString).expandingTildeInPath
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: expanded, isDirectory: &isDir), isDir.boolValue else {
                return .failure(AddUsageError("skillctl add：--from 指向的路径不存在或不是目录：\(expanded)"))
            }
            if let p = positional {
                let pExpanded = (p as NSString).expandingTildeInPath
                var pIsDir: ObjCBool = false
                if FileManager.default.fileExists(atPath: pExpanded, isDirectory: &pIsDir), pIsDir.boolValue {
                    return .failure(AddUsageError("skillctl add：本地路径与 --from 不能同时给——"
                                    + "用 `skillctl add <本地路径>` 或 `skillctl add <名> --from <路径>`"))
                }
            }
            return .success(.local(dir: expanded, suggestedName: positional))
        }
        guard let p = positional else {
            return .failure(AddUsageError("skillctl add：需要 <本地路径 | owner/repo | git URL>（--help 看用法）"))
        }
        let expanded = (p as NSString).expandingTildeInPath
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: expanded, isDirectory: &isDir), isDir.boolValue {
            return .success(.local(dir: expanded, suggestedName: nil))
        }
        // 完整 git URL：https（唯一联网协议，需求档 F4）与 file://（本地 fixture 的 clone 形态——
        // 设计 §2.2 钉死 `git clone --depth 1 file://<路径>`，A1/A9 离线验收的入口形状；
        // file:// 不联网，不属联网面放宽）
        if p.lowercased().hasPrefix("https://") {
            return .success(.clone(url: p))
        }
        if p.lowercased().hasPrefix("file://") {
            return .success(.clone(url: p))
        }
        // owner/repo：恰好一段 / 且两端非空 → GitHub 仓库短形
        let parts = p.split(separator: "/", omittingEmptySubsequences: false)
        if parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty {
            return .success(.clone(url: "https://github.com/\(parts[0])/\(parts[1]).git"))
        }
        return .failure(AddUsageError("skillctl add：'\(p)' 不是存在的本地路径，也不是可识别的来源"
                        + "（owner/repo 短形或 https:// git URL；ssh/file 协议不支持）"))
    }
}

/// 缺货错误与多 skill 未选择的 CLI 渲染（文案③⑥，逐字落地待过目）
enum AddCommandRender {
    /// notInLibrary 的多行人读文本（文案③）：
    /// `库里没有 '<名>'——安装只从技能库取源，不再用散落副本。补救（可照抄）：`
    /// + 每副本一行 `  skillctl add <名> --from '<路径>'` + 尾行 `  或从仓库安装：skillctl add <owner>/<repo> -s <名>`
    static func describeNotInLibrary(name: String, remedies: [String]) -> String {
        var lines = ["库里没有 '\(name)'——安装只从技能库取源，不再用散落副本。补救（可照抄）："]
        lines += remedies
        lines.append("  或从仓库安装：skillctl add <owner>/<repo> -s \(name)")
        return lines.joined(separator: "\n")
    }

    /// AddNeedsSelection 的多行人读文本（文案⑥）：
    /// `该仓库含 N 个 skill，未指定要哪些（-s）。发现的 skill：` + 逐行 `  <名>` + `可照抄：…`
    static func describeNeedsSelection(sourceDisplay: String, discovered: [(name: String, dir: URL)]) -> String {
        var lines = ["该仓库含 \(discovered.count) 个 skill，未指定要哪些（-s）。发现的 skill："]
        lines += discovered.map { "  \($0.name)" }
        let names = discovered.map(\.name).joined(separator: ",")
        lines.append("可照抄：skillctl add \(sourceDisplay) -s \(names)")
        return lines.joined(separator: "\n")
    }

    /// add 回执 JSON payload（含文案⑦ detail 字段；全部成功才算 created 全量）
    static func reportJSON(report: AssemblyService.AddReport, warning: String?) -> [String: Any] {
        var payload: [String: Any] = [
            "command": "add",
            "created": report.created,
            "replaced": report.replaced,
            "skipped": report.skipped,
            "failed": report.failed,
            "detail": "skillctl 收编进技能库（新增 \(report.created + report.replaced) · 跳过 \(report.skipped) · 失败 \(report.failed)）",
            "outcomes": report.outcomes.map { o -> [String: Any] in
                let status: String
                switch o.status {
                case .created: status = "created"
                case .replaced: status = "replaced"
                case .skippedConflict: status = "skipped-conflict"
                case .failed: status = "failed"
                }
                var dict: [String: Any] = ["name": o.name, "status": status, "path": o.path]
                if let id = o.replacedTrashEntryId { dict["replacedTrashEntryId"] = id }
                return dict
            },
            "logged": true,
        ]
        if let w = warning { payload["warning"] = w }
        return payload
    }

    /// usage() 的 add 段（文案⑨）
    static let usageSection = """
      skillctl add <本地路径 | owner/repo | https://...git>
                    [--from <路径>] [-s <名1,名2> | -s '*'] [--all] [--force]
    """
}

/// add 子命令完整实现：分类 → 解析源目录（本地直用 / clone 后枚举）→ 选择 → service.add
@MainActor enum AddCommand {
    static func run(_ remaining: [String], service: AssemblyService) -> Never {
        var args = remaining
        let fromFlag = takeFlag("--from", &args)
        var select: String? = takeFlag("-s", &args) ?? takeFlag("--select", &args)
        let all = takeBool("--all", &args)
        let force = takeBool("--force", &args)
        if all { select = "*" }                                  // --all 等价 -s '*'
        // 先摘 flags，剩下的才是位置参数：`add <本地路径>` / `add <名> --from <路径>` 的名
        // 都落在这里（flags 在名之后出现是合法形态，`args.first` 会误咬——先吃 flags 再看剩的）
        let positional = args.first
        if args.count > 1 {
            emitErr("skillctl add：多余参数 '\(args[1])'"); exit(64)
        }
        // flags 摘完后 `-s` 的值可能被误伤（`-s` 吃的是紧跟的名字，不会残留）；此处 args 最多剩 1 个位置参数

        // 1) 来源分类（--from 与位置参数互斥；ssh/file 协议用法错）
        let source: AddSourceClassifier.Source
        switch AddSourceClassifier.classify(positional: positional, fromFlag: fromFlag,
                                            cwd: FileManager.default.currentDirectoryPath) {
        case .failure(let e):
            emitErr(e.message); exit(64)
        case .success(let s):
            source = s
        }

        // 2) 解析出 skill 源目录：本地直枚举；clone 到 mkdtemp 临时目录再枚举（defer 清理，A1）
        let fm = FileManager.default
        var sourceDisplay = positional ?? ""
        var skillDirs: [(name: String, dir: URL)] = []
        let tmp: URL?
        switch source {
        case .local(let dir, let suggestedName):
            tmp = nil
            let root = URL(fileURLWithPath: dir, isDirectory: true)
            let candidates = SkillLayout.enumerate(root: root)
            guard !candidates.isEmpty else {
                emitErr("skillctl add：'\(dir)' 里没有可收编的 skill（资格 = 目录自己有 SKILL.md；"
                        + "整目录即 skill 或直接子目录里有 skill，二选一）")
                exit(69)
            }
            skillDirs = candidates.map { (SkillLayout.entryName(of: $0, root: root), $0) }
            if let suggested = suggestedName {
                // --from <name> 形态：按名过滤（大小写敏感，目录名即条目名）
                guard let hit = skillDirs.first(where: { $0.name == suggested }) else {
                    emitErr("skillctl add：'\(dir)' 里没有名为 '\(suggested)' 的 skill。可选项："
                            + skillDirs.map(\.name).joined(separator: ", "))
                    exit(64)
                }
                skillDirs = [hit]
            }
            sourceDisplay = dir
        case .clone(let url):
            // 本地 fixture（file://）也走这里——测试形态钉死 `git clone --depth 1 file://<路径>`：
            // URL 原样传给 git（剥掉 file:// 会落进「裸本地路径 + --depth」的本地传输漂移形态，
            // 评审点 #5 警告的正是它；file:// 才是浅 clone 的确定形态）
            let git = GitClone()
            do {
                let t = FileManager.default.temporaryDirectory
                    .appendingPathComponent("skillctl-add-\(UUID().uuidString)", isDirectory: true)
                try fm.createDirectory(at: t, withIntermediateDirectories: true)
                try git.clone(url, into: t)
                tmp = t
            } catch let e as GitClone.GitError {
                // clone 失败如实报；失败路径零库写入（A1）。临时目录清理见下面 tmp 变量约定
                emitErr("skillctl add：clone 失败——\(e.localizedDescription)")
                exit(69)
            } catch {
                emitErr("skillctl add：clone 失败——\(error.localizedDescription)")
                exit(69)
            }
            sourceDisplay = url
            // 枚举根 = clone 目标目录本身：git clone 到「已存在的空目录」时内容直接落进去、
            // 不建 URL 末段子目录（真机 DIAG 实测：t/ 下直接是 .git + 各 skill 目录）——
            // 按 URL 推子目录名是第二份表且方向就错（真机 T5 当场抓到恒报「没有可收编的 skill」）。
            let root = tmp!
            let candidates = SkillLayout.enumerate(root: root)
            guard !candidates.isEmpty else {
                try? fm.removeItem(at: tmp!)
                emitErr("skillctl add：仓库里没有可收编的 skill（资格 = 目录自己有 SKILL.md）")
                exit(69)
            }
            skillDirs = candidates.map { (SkillLayout.entryName(of: $0, root: root), $0) }
        }
        // ⚠️ defer 作用域陷阱（真机 DIAG 抓到）：defer 挂在 if-let 语句体上会在 body 结束时
        // 立即执行——tmp 会在「选择/写入」之前被删，clone 链路的拷贝全部扑空。
        // 清理点收进 performSelectionAndWrite（函数作用域 defer，exit() 之外的所有路径覆盖；
        // exit() 路径进程即刻终止、无半截状态，不需要清）。
        let report = performSelectionAndWrite(skillDirs, select: select, sourceDisplay: sourceDisplay,
                                              force: force, service: service, tmp: tmp)
        emitJSON(AddCommandRender.reportJSON(report: report, warning: nil))
        exit(report.created + report.replaced > 0 ? 0 : 69)
    }

    /// 选择（-s / --all / 单 skill 直装）+ 写入；tmp 非空时在本函数退出时清临时目录。
    /// 单独成函数的唯一理由：defer 必须挂在**函数作用域**才能活到写入之后（见上）。
    @MainActor private static func performSelectionAndWrite(
        _ skillDirs: [(name: String, dir: URL)], select: String?, sourceDisplay: String,
        force: Bool, service: AssemblyService, tmp: URL?
    ) -> AssemblyService.AddReport {
        let fm = FileManager.default
        defer { if let t = tmp { try? fm.removeItem(at: t) } }   // 成败都清临时目录（A1：库外无残留）

        // 选择：单 skill 未给 -s → 直装；多 skill 未给 → 列清单退出 64，盘上零写入（A2）
        let isMulti = skillDirs.count > 1
        if isMulti, select == nil {
            try? fm.removeItem(at: tmp!)                          // exit() 不跑 defer，显式清
            emit(AddCommandRender.describeNeedsSelection(sourceDisplay: sourceDisplay, discovered: skillDirs))
            exit(64)
        }
        var chosen = skillDirs
        if let s = select, s != "*" {
            let wanted = s.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            guard !wanted.isEmpty else { emitErr("skillctl add：-s 需要至少一个名字"); exit(64) }
            var picked: [(name: String, dir: URL)] = []
            for w in wanted {
                guard let hit = skillDirs.first(where: { $0.name == w }) else {
                    try? fm.removeItem(at: tmp!)                  // exit() 不跑 defer，显式清
                    emitErr("skillctl add：'\(w)' 不在发现的 skill 里。可选项："
                            + skillDirs.map(\.name).joined(separator: ", "))
                    exit(64)
                }
                picked.append(hit)
            }
            chosen = picked
        }

        // 写入（service.add 持锁、--force 走回收站、落日志与事件）
        do {
            return try service.add(sources: chosen, force: force)
        } catch {
            emitErr("skillctl add：\(error.localizedDescription)")
            exit(69)
        }
    }

    /// add 本地参数提取（与 main.swift 顶层的全局解析同一套退出码纪律：缺值报 64）
    @MainActor private static func takeFlag(_ name: String, _ args: inout [String]) -> String? {
        guard let i = args.firstIndex(of: name) else { return nil }
        guard i + 1 < args.count else { emitErr("skillctl add：\(name) 缺参数值"); exit(64) }
        let v = args[i + 1]
        args.removeSubrange(i...i+1)
        return v
    }
    @MainActor private static func takeBool(_ name: String, _ args: inout [String]) -> Bool {
        if let i = args.firstIndex(of: name) { args.remove(at: i); return true }
        return false
    }
}
