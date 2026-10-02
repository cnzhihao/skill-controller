// GitClone.swift — add 的联网面（唯一）：进程调用系统 git 浅 clone
//
// 注入式（SkillctlProbe 同构，SetupGuide.swift 先例）：生产 `.system` spawn 系统 git；
// `.custom` 供单元测试注入（A1/A9 的离线测试不走真 spawn 时用；fixture 仓的
// `git clone --depth 1 file://<路径>` 形态走 .system 真实 spawn，形态钉死在设计档 §6）。
//
// 联网边界（需求档 F4）：只发起 git clone（HTTPS git 协议）、无遥测、无其他端点；
// HTTPS 校验放在 add 参数分类层（main.swift/AddCommand.swift）而非这里——
// 这样单元测试可以用本地 fixture 仓直接走 .system 真实 spawn。

import Foundation

public struct GitClone: Sendable {
    public enum Impl: Sendable {
        case system                                                          // 进程调用系统 git（默认）
        case custom(@Sendable (_ url: String, _ into: URL) throws -> Void)   // 测试注入
    }

    /// 浅 clone 超时（秒）。clone 是网络操作给足余量；超时 terminate 后按失败处理、不重试
    /// （设计档 §2.2：重试只会放大半截状态，失败如实上抛让调用方决定）。
    public static let timeout: TimeInterval = 120

    public enum GitError: Error, Equatable {
        /// 找不到 git 可执行（PATH 逐目录 + /usr/bin 兜底都没有）
        case unavailable
        case timeout
        /// clone 退出非零 / 输出不可读——note 带人读原因
        case failed(note: String)
    }

    private let impl: Impl
    private let timeout: TimeInterval

    public init(_ impl: Impl = .system, timeout: TimeInterval = GitClone.timeout) {
        self.impl = impl
        self.timeout = timeout
    }

    /// `git clone --depth 1 <url> <dir>`（dir 必须是 mkdtemp 出来的空临时目录，defer 清理由调用方负责）
    public func clone(_ url: String, into dir: URL) throws {
        switch impl {
        case .custom(let f):
            try f(url, dir)
        case .system:
            try systemClone(url, into: dir)
        }
    }

    // MARK: - system 本体

    private func systemClone(_ url: String, into dir: URL) throws {
        guard let git = Self.resolveGit() else {
            throw GitError.unavailable
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: git)
        p.arguments = ["clone", "--depth", "1", url, dir.path]
        // 环境继承（PATH/代理/git 配置原样）；GIT_TERMINAL_PROMPT=0：面向 Agent 的 CLI 绝不挂起等凭证输入
        var env = ProcessInfo.processInfo.environment
        env["GIT_TERMINAL_PROMPT"] = "0"
        p.environment = env
        let stdout = Pipe(), stderr = Pipe()
        p.standardOutput = stdout
        p.standardError = stderr
        p.standardInput = FileHandle.nullDevice
        do { try p.run() } catch {
            throw GitError.failed(note: "无法启动 git（\(error.localizedDescription)）")
        }
        let deadline = Date().addingTimeInterval(timeout)
        while p.isRunning, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        if p.isRunning {
            p.terminate()
            let hardDeadline = Date().addingTimeInterval(0.5)
            while p.isRunning, Date() < hardDeadline { Thread.sleep(forTimeInterval: 0.01) }
            if p.isRunning {
                kill(p.processIdentifier, SIGKILL)   // 绝不留半截 clone 子进程
            }
            throw GitError.timeout
        }
        _ = stdout.fileHandleForReading.readDataToEndOfFile()
        let err = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        guard p.terminationStatus == 0 else {
            // git 的报错在 stderr；带出末几行人读原因（整段太长，Agent 要的是能看懂的那句）
            let note = err.split(separator: "\n").suffix(3).joined(separator: " / ")
            throw GitError.failed(note: note.isEmpty ? "git 退出码 \(p.terminationStatus)" : note)
        }
    }

    /// git 可执行解析：PATH 环境变量逐目录 → 兜底 /usr/bin/git；找不到如实报 unavailable
    public static func resolveGit(pathEnv: String? = ProcessInfo.processInfo.environment["PATH"]) -> String? {
        var dirs = (pathEnv ?? "").split(separator: ":", omittingEmptySubsequences: true).map(String.init)
        if !dirs.contains("/usr/bin") { dirs.append("/usr/bin") }
        return dirs.map { $0 + "/git" }.first { FileManager.default.isExecutableFile(atPath: $0) }
    }
}

extension GitClone.GitError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .unavailable:
            return "git 不可用：PATH 与 /usr/bin 里都没有 git 可执行，无法 clone。"
        case .timeout:
            return "git clone 超时（120 秒未完成），这次收编没有开始，库与盘上零改动。"
        case .failed(let note):
            return "git clone 失败：\(note)"
        }
    }
}
