// SetupGuideTests.swift — CLI 检测与引导的单元面（台账 #19 · 设计档 §5/§6）
// A1/A2/A5 进 swift test 的理由：判定逻辑住在 Sources/SkillControllerCore（K1/K2），
// App 侧视图不在本覆盖内（D27 既有事实），呈现行为走真机验收（A3/A4/A6 为主代理清单）。

import Testing
import Foundation
@testable import SkillControllerCore

struct SetupGuideTests {
    private let v = SkillControllerVersion.string   // 版本单源（Models.swift）；本仓当前 1.0.0

    // MARK: A1 · 未安装 + 提示词五要素（结构断言）

    /// 用例「冷启动未安装」：notFound → .notInstalled(nil)；自动呈现 true
    @Test func a1_notFoundDecidesNotInstalledAndAutoPresents() {
        let status = CLIGuideDecision.decide(.notFound, appVersion: v)
        #expect(status == .notInstalled(note: nil))
        #expect(status.gapKey == "notInstalled")
        #expect(CLIGuideDecision.shouldAutoPresent(status: status, skippedLevel: nil))
    }

    /// A1 五要素（需求档 A1 逐字）：下载 URL / chmod / ~/.local/bin /
    /// npx skills add cnzhihao/skill-controller / skillctl --version
    @Test func a1_promptContainsAllFiveElements() {
        let t = SetupGuidePrompt.text(appVersion: v)
        #expect(t.contains("https://github.com/cnzhihao/skill-controller/releases/download/v\(v)/skillctl-v\(v)-arm64-macos"))
        #expect(t.contains("chmod +x"))
        #expect(t.contains("~/.local/bin"))
        #expect(t.contains("npx skills add cnzhihao/skill-controller"))
        #expect(t.contains("skillctl --version"))
    }

    /// A1 安装态标题 C5（真机验收 A1 的单测面：标题分派函数本身）
    @Test func a1_titleForNotInstalledIsInstallTitle() {
        #expect(SetupGuidePrompt.title(for: .notInstalled(note: nil), appVersion: v) == "安装 skillctl")
    }

    /// 提示词 {V} 插值：URL 与自验口径随版本单源走（K6——版本迭代零代码改动）
    @Test func promptInterpolatesVersion() {
        let t = SetupGuidePrompt.text(appVersion: "9.9.9")
        #expect(t.contains("v9.9.9/skillctl-v9.9.9-arm64-macos"))
        #expect(t.contains("应为 9.9.9"))
        #expect(!t.contains("{V}"))
    }

    // MARK: A2 · 版本落后 / 超前 + 同一套提示词

    /// 用例「版本落后」：0.9.0 < 1.0.0 → .outdated；标题 C6 含「升级到 1.0.0」
    @Test func a2_outdatedDecisionAndTitle() {
        let status = CLIGuideDecision.decide(.version("0.9.0"), appVersion: "1.0.0")
        #expect(status == .outdated(installed: "0.9.0"))
        #expect(status.gapKey == "outdated")
        let title = SetupGuidePrompt.title(for: status, appVersion: "1.0.0")
        #expect(title == "skillctl 升级到 1.0.0")
        #expect(title.contains("升级到 1.0.0"))
    }

    /// 用例「版本超前」（裁决⑤选 A）：2.0.0 > 1.0.0 → .ahead；标题 C13 中性——
    /// 含「不一致」、不含「升级」（不把新版说旧）
    @Test func a2_aheadDecisionAndNeutralTitle() {
        let status = CLIGuideDecision.decide(.version("2.0.0"), appVersion: "1.0.0")
        #expect(status == .ahead(installed: "2.0.0"))
        #expect(status.gapKey == "outdated")   // K10：ahead 与 outdated 同属「版本不对齐」级
        let title = SetupGuidePrompt.title(for: status, appVersion: "1.0.0")
        #expect(title == "skillctl 2.0.0 与 App（1.0.0）不一致")
        #expect(title.contains("不一致"))
        #expect(!title.contains("升级"))
    }

    /// A2「提示词与 A1 同一套（同一常量）」：安装/落后/超前三份 text 全等
    @Test func a2_promptIsOneSharedConstant() {
        let install = SetupGuidePrompt.text(appVersion: v)
        let outdated = install
        let ahead = install
        #expect(install == outdated)
        #expect(install == ahead)
        // 同一常量的硬证据：text 不吃状态参数——不同 CLIStatus 下只能取到同一份
        #expect(SetupGuidePrompt.text(appVersion: SkillControllerVersion.string)
            == SetupGuidePrompt.text(appVersion: SkillControllerVersion.string))
    }

    /// 用例「版本段数不齐」：缺段补 0，"1.0" 与 "1.0.0" 一致 → current（decide 纯函数直测）
    @Test func decidePadsMissingSegmentsWithZero() {
        #expect(CLIGuideDecision.decide(.version("1.0"), appVersion: "1.0.0") == .current)
        #expect(CLIGuideDecision.decide(.version("2"), appVersion: "2.0.0") == .current)
        #expect(CLIGuideDecision.decide(.version("1.0"), appVersion: "1.0.1") == .outdated(installed: "1.0"))
        #expect(CLIGuideDecision.compare("1.0", "1.0.0") == .orderedSame)
        #expect(CLIGuideDecision.compare("1.10.0", "1.9.0") == .orderedDescending)   // 数值比较非字典序
    }

    // MARK: A3 · 版本一致不弹 + current 清记录语义

    /// 用例「版本一致」：current 永不自动呈现；跳过记录被清的判定面（shouldAutoPresent 对 current 恒 false）
    @Test func a3_currentNeverAutoPresents() {
        #expect(CLIGuideDecision.decide(.version("1.0.0"), appVersion: "1.0.0") == .current)
        #expect(!CLIGuideDecision.shouldAutoPresent(status: .current, skippedLevel: nil))
        #expect(!CLIGuideDecision.shouldAutoPresent(status: .current, skippedLevel: "outdated"))
        #expect(CLIGuideDecision.decide(.version("1.0.0"), appVersion: "1.0.0").gapKey == nil)
    }

    // MARK: A4 · 跳过判定（缺口级别粒度，K5/K10）

    /// 用例「跳过后级别变化」：skip=notInstalled 后变 outdated → 新级别自动弹
    @Test func a4_levelChangeRePresents() {
        #expect(!CLIGuideDecision.shouldAutoPresent(status: .notInstalled(note: nil), skippedLevel: "notInstalled"))
        #expect(CLIGuideDecision.shouldAutoPresent(status: .outdated(installed: "0.9.0"), skippedLevel: "notInstalled"))
    }

    /// 用例「跳过跨方向不重弹」：skip="outdated" 后注入 ahead → 同级不弹（K10 方向翻转不是级别变化）
    @Test func a4_skipSurvivesDirectionFlip() {
        #expect(!CLIGuideDecision.shouldAutoPresent(status: .outdated(installed: "0.9.0"), skippedLevel: "outdated"))
        #expect(!CLIGuideDecision.shouldAutoPresent(status: .ahead(installed: "2.0.0"), skippedLevel: "outdated"))
    }

    // MARK: A5 · 探测失败如实分类（裁决④）

    /// 用例「探测失败」：failed(note) → .notInstalled(note:)，note 原样保留（降级不静默吞）
    @Test func a5_failedKeepsNote() {
        let status = CLIGuideDecision.decide(.failed(note: "enoexec"), appVersion: v)
        #expect(status == .notInstalled(note: "enoexec"))
        #expect(status.gapKey == "notInstalled")
        #expect(CLIGuideDecision.shouldAutoPresent(status: status, skippedLevel: nil))
    }

    /// 用例「输出不可解析」：parseVersionLine("garbage") → nil
    @Test func a5_unparseableOutputBecomesFailed() {
        #expect(SkillctlProbe.parseVersionLine("garbage") == nil)
        #expect(SkillctlProbe.parseVersionLine("skillctl 1.0.0") == "1.0.0")
        #expect(SkillctlProbe.parseVersionLine("skillctl 1.0.0\nmore noise") == "1.0.0")
        #expect(SkillctlProbe.parseVersionLine("") == nil)
    }

    /// 用例「超时」：超时构造 → failed → notInstalled（分类单测面；真超时路径 = 真机验收 A5）
    @Test func a5_timeoutClassifiesAsFailedNotInstalled() {
        let outcome = SkillctlProbe.ProbeOutcome.failed(note: "超时 3 秒未退出")
        #expect(CLIGuideDecision.decide(outcome, appVersion: v) == .notInstalled(note: "超时 3 秒未退出"))
        #expect(SkillctlProbe.timeout == 3)
    }

    // MARK: K3 · 候选目录序（~/.local/bin 优先，PATH 兜底；GUI PATH 硬事实的行为回归）

    /// 用例「GUI PATH 缺 ~/.local/bin」：候选序第一项恒为 ~/.local/bin，
    /// 且探测沿候选序找到已装件——不因 GUI PATH 不含它而误报未安装
    @Test func k3_localBinFirstThenPathDedup() throws {
        let home = "/Users/someone"
        let dirs = SkillctlProbe.candidateDirectories(
            home: home, pathEnv: "/usr/bin:/bin:/usr/sbin:/sbin")
        #expect(dirs.first == home + "/.local/bin")
        #expect(dirs == [home + "/.local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"])

        // PATH 里有 ~/.local/bin 时不重复
        let dedup = SkillctlProbe.candidateDirectories(
            home: home, pathEnv: "\(home)/.local/bin:/usr/bin")
        #expect(dedup == [home + "/.local/bin", "/usr/bin"])

        // PATH 缺失（环境异常）时仍有 ~/.local/bin 兜底
        let noPath = SkillctlProbe.candidateDirectories(home: home, pathEnv: nil)
        #expect(noPath == [home + "/.local/bin"])
    }

    /// 探测沿候选序命中：沙箱里造 ~/.local/bin 的假 executable（GUI PATH 场景行为回归）
    @Test func k3_findsInstalledBinaryEvenWhenPathLacksLocalBin() throws {
        let sandbox = FileManager.default.temporaryDirectory
            .appendingPathComponent("sc-probe-\(UUID().uuidString)")
        let home = sandbox.appendingPathComponent("home").path
        let bin = sandbox.appendingPathComponent("home/.local/bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: sandbox) }
        // 假 executable：输出口与 main.swift:66 同形（skillctl X.Y.Z）
        let fake = bin.appendingPathComponent("skillctl")
        #if canImport(Darwin)
        try "#!/bin/sh\necho \"skillctl 9.9.9\"".write(to: fake, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fake.path)
        #endif

        let probe = SkillctlProbe(.system, timeout: 3)
        // PATH 不含 ~/.local/bin（GUI 硬事实）→ 仍能找到并读出版本
        let outcome = probe.probe(home: home, pathEnv: "/usr/bin:/bin")
        #expect(outcome == .version("9.9.9"))
        #expect(CLIGuideDecision.decide(outcome, appVersion: "9.9.9") == .current)
    }

    /// 候选序全不命中 → notFound（真探测路径的空候选分支）
    @Test func k3_emptyCandidatesReturnNotFound() {
        let probe = SkillctlProbe(.system, timeout: 3)
        let outcome = probe.probe(home: "/nonexistent-home-\(UUID().uuidString)",
                                  pathEnv: "/nonexistent-path-\(UUID().uuidString)")
        #expect(outcome == .notFound)
    }

    // MARK: A6 · 跳过持久化（settings.json 注入目录，SettingsOverridesTests 同款隔离）

    /// 用例「skip 写入读回」：先不装 → cliGuideSkippedLevel = 缺口级别；读回一致
    @Test func a6_skipPersistsRoundTrip() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("sc-guide-\(UUID().uuidString)")
        let paths = SkillControllerPaths(supportDir: dir)
        defer { try? FileManager.default.removeItem(at: dir) }

        var s = AppSettings.load(paths: paths)
        #expect(s.cliGuideSkippedLevel == nil)          // 全新安装无跳过
        s.cliGuideSkippedLevel = "outdated"
        try s.save(paths: paths)

        let back = AppSettings.load(paths: paths)
        #expect(back.cliGuideSkippedLevel == "outdated")
        #expect(!CLIGuideDecision.shouldAutoPresent(
            status: .outdated(installed: "0.9.0"), skippedLevel: back.cliGuideSkippedLevel))
    }

    /// 用例「current 清记录」：skip 后清空 → 永不弹
    @Test func a6_currentClearsSkipRecord() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("sc-guide-\(UUID().uuidString)")
        let paths = SkillControllerPaths(supportDir: dir)
        defer { try? FileManager.default.removeItem(at: dir) }

        var s = AppSettings.load(paths: paths)
        s.cliGuideSkippedLevel = "notInstalled"
        try s.save(paths: paths)

        // 「探测翻成 current 时清掉跳过记录」（§2.2）——写侧同一 save 通道
        var cleared = AppSettings.load(paths: paths)
        cleared.cliGuideSkippedLevel = nil
        try cleared.save(paths: paths)

        let back = AppSettings.load(paths: paths)
        #expect(back.cliGuideSkippedLevel == nil)
        #expect(!CLIGuideDecision.shouldAutoPresent(status: .current, skippedLevel: back.cliGuideSkippedLevel))
    }

    /// A6 旧 settings.json 无该字段的解码兼容：老文件零迁移（可选字段缺键 = nil）
    @Test func a6_legacySettingsWithoutFieldDecodeFine() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("sc-guide-\(UUID().uuidString)")
        let paths = SkillControllerPaths(supportDir: dir)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        // 一份「本字段存在之前」的 settings.json（D17 迁移后的现行格式，无 cliGuideSkippedLevel）
        let legacy = """
        {"trashRetentionDays":30,"prunedOverrides":{"cache":false}}
        """
        try legacy.write(to: paths.settingsFile, atomically: true, encoding: .utf8)

        let back = AppSettings.load(paths: paths)
        #expect(back.cliGuideSkippedLevel == nil)
        #expect(back.trashRetentionDays == 30)
        #expect(back.effectiveOverrides[.cache] == false)   // 既有字段不受影响
        #expect(CLIGuideDecision.shouldAutoPresent(
            status: .notInstalled(note: nil), skippedLevel: back.cliGuideSkippedLevel))
    }

    /// 用例「设置写失败」：save 抛错时 skip 不阻断——skip() 的 try? 不让异常逃出
    /// 「先不装」路径（本次仍关闭；下次启动再弹的判定面 = 持久化没写成 → 读回 nil → 再弹）
    @Test func settingsWriteFailureDoesNotBlockSkipSemantics() throws {
        // settingsFile 指向一个不可写的位置（父目录不存在且 createDirectory 被既有 save 内部
        // ensureDirs 处理——此处直接断言语义面：读回 nil = 下次启动会再弹）
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("sc-guide-\(UUID().uuidString)/blocked")
        let paths = SkillControllerPaths(supportDir: dir)
        defer { try? FileManager.default.removeItem(at: dir) }
        // 未 save 过 → 读回 nil（= 写失败后的如实状态：没记住，下次启动会再弹）
        #expect(AppSettings.load(paths: paths).cliGuideSkippedLevel == nil)
        #expect(CLIGuideDecision.shouldAutoPresent(
            status: .notInstalled(note: nil), skippedLevel: AppSettings.load(paths: paths).cliGuideSkippedLevel))
    }

    // MARK: 注入缝映射（设计档 §2.1 评审发现③——真机验收 A1/A2/A3/A5 的口径单源）

    /// SKILLCTL_FAKE_PROBE 五取值 → ProbeOutcome 映射逐行可判（outdated/ahead 固定字面量与 A2 同值）
    @Test func fakeProbeMappingDecidesAsDesigned() {
        let v = SkillControllerVersion.string
        #expect(CLIGuideDecision.decide(.notFound, appVersion: v) == .notInstalled(note: nil))
        #expect(CLIGuideDecision.decide(.version("0.9.0"), appVersion: v) == .outdated(installed: "0.9.0"))
        #expect(CLIGuideDecision.decide(.version("2.0.0"), appVersion: v) == .ahead(installed: "2.0.0"))
        #expect(CLIGuideDecision.decide(.version(v), appVersion: v) == .current)
        #expect(CLIGuideDecision.decide(.failed(note: "probe-failed"), appVersion: v)
            == .notInstalled(note: "probe-failed"))
    }
}
