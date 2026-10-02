// SetupGuide.swift — CLI 检测与 Agent 代装引导（Core 面）
//
// 三层一件（设计档 §1）：探测器（本文件）+ 编排与引导 Sheet（App 层 CLIGuide.swift）+ 设置页入口。
// 判定逻辑住在 Sources/ 的理由：App 侧视图不在 `swift test` 覆盖内（D27 确立的既有事实），
// A1/A2/A5 要进单元测试就必须让纯函数面住在 Core（K1/K2）。
//
// 进程调用边界（App 进程第一处 Process 调用，设计档 §2.1）：
// 只 spawn `skillctl --version` 一个命令、只捕获输出、不写盘、零网络、3s 超时不重试、
// 后台执行、单飞不叠加、不落操作日志（探测不是写操作，回退页不收探测噪音）。

import Foundation

// MARK: - 探测器（设计档 §2.1）

/// PATH 上的 skillctl 探测。注入式（DiskSpaceProbe 同构）：App 默认 `.system`；
/// `.custom` 供单元测试与真机验收造态。
public struct SkillctlProbe: Sendable {
    public enum Impl: Sendable {
        case system                                        // 真探测（App 默认）
        case custom(@Sendable () -> ProbeOutcome)          // 测试 / 真机注入
    }

    /// 探测超时（秒）。`--version` 是瞬时命令，超时即环境异常，重试只放大——不重试（设计档 §2.1）。
    public static let timeout: TimeInterval = 3

    public enum ProbeOutcome: Equatable, Sendable {
        case notFound                                      // 候选目录里没有可执行件
        case failed(note: String)                          // 跑不起来 / 超时 / 输出不可解析（带原因）
        case version(String)                               // 解析出的 X.Y.Z
    }

    private let impl: Impl
    private let timeout: TimeInterval

    public init(_ impl: Impl = .system, timeout: TimeInterval = SkillctlProbe.timeout) {
        self.impl = impl
        self.timeout = timeout
    }

    public func probe() -> ProbeOutcome {
        switch impl {
        case .custom(let f):
            return f()
        case .system:
            #if DEBUG
            // 真机注入缝（设计档 §2.1 评审发现③落档的映射表）：`SKILLCTL_FAKE_PROBE` 注入的是
            // 缺口态名而非 ProbeOutcome 词汇；环境变量非空时候选序解析 / spawn / 超时整体不执行。
            // Release 不含此分支。outdated / ahead 为固定字面量（与 A2 单测同值）；
            // App 版本将来若 ≥ 2.0.0，ahead 注入值需同步调整。
            if let raw = ProcessInfo.processInfo.environment["SKILLCTL_FAKE_PROBE"], !raw.isEmpty {
                switch raw {
                case "notInstalled": return .notFound
                case "outdated": return .version("0.9.0")
                case "ahead": return .version("2.0.0")
                case "current": return .version(SkillControllerVersion.string)
                case "failed": return .failed(note: "probe-failed")
                default: break   // 未知取值不注入，按真探测走——不把打错的值伪装成检测态
                }
            }
            #endif
            return probe(home: FileManager.default.homeDirectoryForCurrentUser.path,
                         pathEnv: ProcessInfo.processInfo.environment["PATH"])
        }
    }

    /// system 探测本体。home 与 pathEnv 作参数（真机值作默认）：单测据此造
    /// 「GUI PATH 不含 ~/.local/bin 也能找到已装件」（K3 行为回归）与超时形状，不必动环境变量。
    public func probe(home: String, pathEnv: String?) -> ProbeOutcome {
        guard let exec = Self.candidateDirectories(home: home, pathEnv: pathEnv)
            .map({ $0 + "/skillctl" })
            .first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            return .notFound
        }
        return runVersion(exec: exec)
    }

    /// 候选目录序（K3）：`~/.local/bin` 排第一（产品文档指定安装位）→ PATH 各目录按序去重。
    /// GUI App 从 Finder 启动时 PATH 只有 /usr/bin:/bin:/usr/sbin:/sbin，**不含 ~/.local/bin**——
    /// 漏掉它会把 DMG 用户已装好的 CLI 永远误报成未安装。多版本并存只报第一个命中。
    public static func candidateDirectories(home: String,
                                            pathEnv: String?) -> [String] {
        var dirs = [home + "/.local/bin"]
        if let pathEnv {
            for d in pathEnv.split(separator: ":", omittingEmptySubsequences: true).map(String.init)
            where !dirs.contains(d) {
                dirs.append(d)
            }
        }
        return dirs
    }

    /// spawn `skillctl --version`（main.swift:66 的输出口，输出形如 `skillctl 1.0.0`）并解析。
    private func runVersion(exec: String) -> ProbeOutcome {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exec)
        p.arguments = ["--version"]              // 只这一个命令零参数（设计档 §2.1 只读边界）
        let stdout = Pipe(), stderr = Pipe()
        p.standardOutput = stdout
        p.standardError = stderr
        p.standardInput = FileHandle.nullDevice  // 无 stdin 输入
        do { try p.run() } catch {
            return .failed(note: "无法启动（\(error.localizedDescription)）")
        }
        // 同步等待会阻塞调用线程——契约由编排层保证后台执行（设计档 §2.1 并发与线程）。
        let deadline = Date().addingTimeInterval(timeout)
        while p.isRunning, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.02)
        }
        if p.isRunning {
            // 超时：terminate 后按 failed 分类，不重试
            p.terminate()
            let hardDeadline = Date().addingTimeInterval(0.5)
            while p.isRunning, Date() < hardDeadline { Thread.sleep(forTimeInterval: 0.01) }
            if p.isRunning {
                // kill 是 POSIX 信号不是 Process 成员；pid 有值即可发 SIGKILL，绝不留子进程
                kill(p.processIdentifier, SIGKILL)
            }
            return .failed(note: "超时 \(Int(timeout)) 秒未退出")
        }
        let out = String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        _ = stderr.fileHandleForReading.readDataToEndOfFile()   // 只捕获不使用；排空防管道写端阻塞
        guard p.terminationStatus == 0 else {
            return .failed(note: "退出码 \(p.terminationStatus)")
        }
        guard let v = Self.parseVersionLine(out) else {
            return .failed(note: "输出无法解析为版本号")
        }
        return .version(v)
    }

    /// 解析 `skillctl X.Y.Z` 行：取首个「只含数字与点、且至少含一个数字」的 token。
    /// "garbage" 等无版本输出 → nil（→ failed，设计档 §2.1 失败分类）。
    static func parseVersionLine(_ s: String) -> String? {
        for raw in s.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\r" || $0 == "\t" }) {
            let t = String(raw)
            guard !t.isEmpty, t.contains(where: \.isNumber), t.allSatisfy({ $0.isNumber || $0 == "." })
            else { continue }
            var v = t
            while v.hasSuffix(".") { v.removeLast() }   // 畸形尾点按缺段补 0 的口径照样可判
            if !v.isEmpty { return v }
        }
        return nil
    }
}

// MARK: - 检测态与判定（设计档 §2.1）

/// 四态（需求档 F1 表逐行对应；走查裁定选 A 增 ahead 态）。
public enum CLIStatus: Equatable, Sendable {
    case notInstalled(note: String?)   // note ≠ nil = 探测失败注脚，如实显示、按未检测到分类（裁决④）
    case outdated(installed: String)   // installed < App：标题 C6「skillctl 升级到 {V}」
    case ahead(installed: String)      // installed > App：标题 C13 中性（裁决⑤选 A）；行为与 outdated 一致
    case current

    /// 缺口级别键：跳过持久化与自动呈现判定共用。
    /// ahead 与 outdated 同属「版本不对齐」级（复用 "outdated"，K10）——方向翻转不构成级别变化，不重弹。
    public var gapKey: String? {
        switch self {
        case .notInstalled: return "notInstalled"
        case .outdated, .ahead: return "outdated"
        case .current: return nil
        }
    }
}

public enum CLIGuideDecision {
    /// 纯函数四态判定（需求档 F1 表逐行对应）。installed 与 appVersion 按 X.Y.Z 逐段数值
    /// 比较（major→minor→patch，缺段补 0）：< 为 outdated、> 为 ahead、= 为 current
    public static func decide(_ probe: SkillctlProbe.ProbeOutcome, appVersion: String) -> CLIStatus {
        switch probe {
        case .notFound:
            return .notInstalled(note: nil)
        case .failed(let note):
            // 裁决④：探测跑不起来按「未检测到」如实处理，note 保留上屏——降级不静默吞（K4）
            return .notInstalled(note: note)
        case .version(let installed):
            switch compare(installed, appVersion) {
            case .orderedAscending: return .outdated(installed: installed)
            case .orderedDescending: return .ahead(installed: installed)
            case .orderedSame: return .current
            }
        }
    }

    /// 纯函数自动呈现判定：current → false；缺口级别已被跳过 → false；其余 true
    public static func shouldAutoPresent(status: CLIStatus, skippedLevel: String?) -> Bool {
        guard let gap = status.gapKey else { return false }
        return gap != skippedLevel
    }

    /// X.Y.Z 逐段数值比较，缺段补 0（"1.0" 与 "1.0.0" 一致）
    static func compare(_ a: String, _ b: String) -> ComparisonResult {
        let av = segments(a), bv = segments(b)
        for i in 0..<Swift.max(av.count, bv.count) {
            let x = i < av.count ? av[i] : 0
            let y = i < bv.count ? bv[i] : 0
            if x < y { return .orderedAscending }
            if x > y { return .orderedDescending }
        }
        return .orderedSame
    }

    private static func segments(_ v: String) -> [Int] {
        v.split(separator: ".").map { Int($0) ?? 0 }
    }
}

// MARK: - 提示词常量（设计档 §2.4；K2：文本本体住 Core，A1/A2 单测咬结构）

public enum SetupGuidePrompt {
    /// 提示词全文，一套共用（设计定案）：安装 / 升级差异由第 1 步「先探测现状」内部消化——
    /// 对 Agent 而言都是「装到 PATH」，覆盖即升级。`{V}` = App 版本（版本单源插值，K6）。
    private static let template = """
    请帮我安装（或升级）skillctl——Skill 控制器 的命令行工具。先探测现状再动手：
    1. 运行 `skillctl --version`。若输出已经是 {V}，告诉我「已是 {V}」即可停止，不要重复安装；否则继续。
    2. 下载对应版本的 release 二进制（arm64 / macOS）：
       https://github.com/cnzhihao/skill-controller/releases/download/v{V}/skillctl-v{V}-arm64-macos
    3. 校验完整性：打开 https://github.com/cnzhihao/skill-controller/releases/tag/v{V} ，取官方公布的
       sha256，与下载文件的 sha256 比对；不一致就停下并报告，不要安装。
    4. 给文件加可执行权限（chmod +x），放入 `~/.local/bin/`（目录不存在则创建；确认该目录在你的
       PATH 里，不在则告诉我需要加哪一行）。
    5. 安装本工具的元 skill：`npx skills add cnzhihao/skill-controller`（已装过则按 skills CLI 的
       更新语义处理）。
    6. 自验：重新运行 `skillctl --version`，把输出发给我；应为 {V}。
    """

    public static func text(appVersion: String) -> String {
        template.replacingOccurrences(of: "{V}", with: appVersion)
    }

    /// 弹窗标题分派（设计档 §8）：.notInstalled → C5、.outdated → C6、.ahead → C13。
    /// 超前态不走 C6——「升级到 {V}」会把新版说旧（裁决⑤选 A，2026-09-28）。
    public static func title(for status: CLIStatus, appVersion: String) -> String {
        switch status {
        case .notInstalled:
            return "安装 skillctl"                                          // C5
        case .outdated:
            return "skillctl 升级到 \(appVersion)"                           // C6（落后态）
        case .ahead(let installed):
            return "skillctl \(installed) 与 App（\(appVersion)）不一致"      // C13（超前中性）
        case .current:
            return ""   // K9：current 不进任何弹窗逻辑（Sheet 无 current 变体），此分支不应被调用
        }
    }
}
