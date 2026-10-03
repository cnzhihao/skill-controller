// SetupGuide.swift — CLI 检测与 Agent 代装引导（Core 面）
//
// 三层一件（设计档 §1）：探测器（本文件）+ 编排与引导 Sheet（App 层 CLIGuide.swift）+ 设置页入口。
// 判定逻辑住在 Sources/ 的理由：App 侧视图不在 `swift test` 覆盖内（D27 确立的既有事实），
// A1/A2/A5 要进单元测试就必须让纯函数面住在 Core（K1/K2）。
//
// 探测边界（设计档 §2.1）：只 spawn `skillctl --version`，并对 GitHub 公共 Releases API 发一条
// 无认证 GET 读取最新稳定版元数据；不下载、不写盘、不发送设备标识或遥测。两项均限时、只读，
// 后台执行、单飞不叠加、不落操作日志。

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
            // Release 不含此分支。outdated / ahead 为固定字面量；current 可与
            // SKILLCTL_FAKE_LATEST_RELEASE 配对，得到独立于 App 版本的一致态。
            if let raw = ProcessInfo.processInfo.environment["SKILLCTL_FAKE_PROBE"], !raw.isEmpty {
                switch raw {
                case "notInstalled": return .notFound
                case "outdated": return .version("0.9.0")
                case "ahead": return .version("2.0.0")
                case "current":
                    let fakeLatest = ProcessInfo.processInfo.environment["SKILLCTL_FAKE_LATEST_RELEASE"]
                    return .version(fakeLatest.flatMap { Self.parseVersionLine($0) } ?? SkillControllerVersion.string)
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

// MARK: - 最新 CLI release 检查（只读联网例外）

/// 查询 GitHub 最新稳定 release 的版本号。App 每次启动独立检查一次；进程内短期复检由
/// CLIGuideModel 缓存，避免前台切换 / Sheet 展示造成重复请求。
public struct SkillctlLatestReleaseProbe: Sendable {
    public enum Outcome: Equatable, Sendable {
        case latest(String)
        case failed(note: String)
    }

    public static let timeout: TimeInterval = 5
    public static let endpoint = URL(string: "https://api.github.com/repos/cnzhihao/skill-controller/releases/latest")!

    public init() {}

    public func probe() async -> Outcome {
        #if DEBUG
        if let fake = ProcessInfo.processInfo.environment["SKILLCTL_FAKE_LATEST_RELEASE"], !fake.isEmpty {
            if fake == "failed" { return .failed(note: "release-check-failed") }
            if Self.isVersion(fake) { return .latest(fake) }
        }
        #endif

        var request = URLRequest(url: Self.endpoint,
                                 cachePolicy: .reloadIgnoringLocalCacheData,
                                 timeoutInterval: Self.timeout)
        request.httpMethod = "GET"
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("SkillController", forHTTPHeaderField: "User-Agent")

        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = Self.timeout
        configuration.timeoutIntervalForResource = Self.timeout
        configuration.urlCache = nil
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }

        do {
            let (data, response) = try await session.data(for: request)
            guard let response = response as? HTTPURLResponse else {
                return .failed(note: "GitHub 返回了无法识别的响应")
            }
            guard response.statusCode == 200 else {
                return .failed(note: "GitHub 返回 HTTP \(response.statusCode)")
            }
            guard let release = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tag = release["tag_name"] as? String,
                  let assets = release["assets"] as? [[String: Any]] else {
                return .failed(note: "GitHub release 元数据格式无法识别")
            }

            let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
            guard Self.isVersion(version) else {
                return .failed(note: "GitHub release 标签不是有效版本号")
            }
            let expectedAsset = "skillctl-v\(version)-arm64-macos"
            guard assets.contains(where: { ($0["name"] as? String) == expectedAsset }) else {
                return .failed(note: "GitHub release 缺少 \(expectedAsset) 二进制")
            }
            return .latest(version)
        } catch {
            return .failed(note: "GitHub release 检查失败（\(error.localizedDescription)）")
        }
    }

    private static func isVersion(_ value: String) -> Bool {
        let pieces = value.split(separator: ".", omittingEmptySubsequences: false)
        return (2...3).contains(pieces.count)
            && pieces.allSatisfy { !$0.isEmpty && $0.allSatisfy(\.isNumber) }
    }
}

// MARK: - 检测态与判定（设计档 §2.1）

/// 四态（需求档 F1 表逐行对应；走查裁定选 A 增 ahead 态）。
public enum CLIStatus: Equatable, Sendable {
    case notInstalled(note: String?)   // note ≠ nil = 探测失败注脚，如实显示、按未检测到分类（裁决④）
    case outdated(installed: String)   // installed < GitHub 最新稳定 release
    case ahead(installed: String)      // installed > GitHub 最新稳定 release；不提供降级安装引导
    case current
    case latestUnavailable(installed: String?, note: String) // 无法查询远端版本，不猜目标版本、不弹安装提示

    /// 是否有可执行的 CLI 安装/升级动作。远端版本查询失败时不猜目标版本，
    /// 已装版本高于最新稳定版时也不生成覆盖安装指令。
    public var canOfferSetupGuide: Bool {
        switch self {
        case .notInstalled, .outdated: return true
        case .ahead, .current, .latestUnavailable: return false
        }
    }

    /// 跳过持久化使用的缺口级别键。
    /// ahead 与 outdated 仍共用 "outdated" 跳过键；但 ahead 不提供安装/升级引导，
    /// 仅保留版本差异状态，避免将较新的 CLI 覆盖为较旧版本。
    public var gapKey: String? {
        switch self {
        case .notInstalled: return "notInstalled"
        case .outdated, .ahead: return "outdated"
        case .current, .latestUnavailable: return nil
        }
    }
}

public enum CLIGuideDecision {
    /// 启动判定：本机 CLI 与 GitHub 最新稳定 release 比较；App 自身版本不参与 CLI 更新判断。
    public static func decide(_ probe: SkillctlProbe.ProbeOutcome,
                              latestRelease: SkillctlLatestReleaseProbe.Outcome) -> CLIStatus {
        switch latestRelease {
        case .failed(let note):
            let installed: String?
            if case .version(let version) = probe { installed = version }
            else { installed = nil }
            return .latestUnavailable(installed: installed, note: note)
        case .latest(let latest):
            return decide(probe, latestVersion: latest)
        }
    }

    /// 本机 CLI 与远端 release 比较。版本按 X.Y.Z 逐段数值比较（major→minor→patch，缺段补 0）。
    public static func decide(_ probe: SkillctlProbe.ProbeOutcome, latestVersion: String) -> CLIStatus {
        switch probe {
        case .notFound:
            return .notInstalled(note: nil)
        case .failed(let note):
            return .notInstalled(note: note)
        case .version(let installed):
            switch compare(installed, latestVersion) {
            case .orderedAscending: return .outdated(installed: installed)
            case .orderedDescending: return .ahead(installed: installed)
            case .orderedSame: return .current
            }
        }
    }

    /// 兼容旧需求档单测的 App 版本比较入口；App 启动流程不再调用。
    @available(*, deprecated, message: "Use latestVersion:; App version is not a CLI update target.")
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

    /// 自动呈现只针对可执行的安装动作：未安装 / 落后可引导，超前 / 一致不引导。
    public static func shouldAutoPresent(status: CLIStatus, skippedLevel: String?) -> Bool {
        guard status.canOfferSetupGuide else { return false }
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
    /// 提示词全文，一套共用（安装 / 落后态）：第 1 步先探测现状，目标版本或更高版本时停止，防止降级。
    /// `{V}` = GitHub 最新稳定 release 版本；App 当前版本不参与 CLI 版本目标判定。
    private static let template = """
    请帮我安装（或升级）skillctl——Skill 控制器 的命令行工具。先探测现状再动手：
    1. 运行 `skillctl --version`。若输出已经是 {V} 或更高版本，告诉我「已是 {V} 或更新版本」即可停止，不要降级或重复安装；若低于 {V} 或未找到命令，再继续。
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

    public static func text(targetVersion: String) -> String {
        template.replacingOccurrences(of: "{V}", with: targetVersion)
    }

    /// 旧调用名的兼容别名；调用参数现在表示目标 CLI 版本，不是 App 版本。
    @available(*, deprecated, message: "Use text(targetVersion:); CLI update targets come from GitHub releases.")
    public static func text(appVersion: String) -> String { text(targetVersion: appVersion) }

    public static func title(for status: CLIStatus, latestVersion: String) -> String {
        switch status {
        case .notInstalled:
            return "安装 skillctl"
        case .outdated:
            return "skillctl 升级到 \(latestVersion)"
        case .ahead(let installed):
            return "skillctl \(installed) 高于 GitHub 最新发布版 \(latestVersion)"
        case .current:
            return "skillctl 已是最新（\(latestVersion)）"
        case .latestUnavailable:
            return "无法检查 skillctl 最新版本"
        }
    }

    /// 弹窗标题分派（设计档 §8）：.notInstalled → C5、.outdated → C6、.ahead → C13。
    /// 超前态不走 C6——「升级到 {V}」会把新版说旧（裁决⑤选 A，2026-09-28）。
    @available(*, deprecated, message: "Use latestVersion:; App version is not a CLI update target.")
    public static func title(for status: CLIStatus, appVersion: String) -> String {
        switch status {
        case .notInstalled:
            return "安装 skillctl"                                          // C5
        case .outdated:
            return "skillctl 升级到 \(appVersion)"                           // C6（落后态）
        case .ahead(let installed):
            return "skillctl \(installed) 与 App（\(appVersion)）不一致"      // C13（超前中性）
        case .current:
            return ""   // current 不会新开 Sheet；已有 Sheet 翻成一致态时仅显示 C3 状态说明
        case .latestUnavailable:
            return "无法检查 skillctl 最新版本"
        }
    }
}
