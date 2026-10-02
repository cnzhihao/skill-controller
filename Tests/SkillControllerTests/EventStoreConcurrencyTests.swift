import Testing
import Foundation
@testable import SkillControllerCore

/// #6 事件存储并发三修（语义唯一权威：docs/design/concurrency-model.md §2/§3/§4/§5）。
/// 同进程第二把 WriteLock 实例 = 同一锁文件两个 fd = 互斥（正是当年死锁的形状），
/// 配 `timeout: 0.1` 造超时——并发模型 §5 明文认可的测试注入形状。
struct EventStoreConcurrencyTests {
    private func makeSandbox() throws -> (work: URL, paths: SkillControllerPaths, home: URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sc-evconc-\(UUID().uuidString)")
        let home = dir.appendingPathComponent("home")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        return (dir, SkillControllerPaths(supportDir: dir.appendingPathComponent("support")), home)
    }

    private func event(_ id: String) -> StoredAssemblyEvent {
        StoredAssemblyEvent(event: AssemblyEvent(id: id, date: "2026-09-26T00:00:00+08:00",
                                                 agentId: "codex", projectId: "proj-x",
                                                 added: [], removed: [], conflicts: [], reviewed: false),
                            revision: 1, accepted: false, restored: false)
    }

    private func rawLines(_ paths: SkillControllerPaths) -> [String] {
        guard let data = try? Data(contentsOf: paths.assemblyEventsFile),
              let s = String(data: data, encoding: .utf8) else { return [] }
        return s.components(separatedBy: "\n")
    }

    /// ① 损坏行**逐字节**保留：重写目标行之后，损坏行必须原样在文件里——
    /// 它可能是并发方写了一半的行，删掉等于替别人销毁数据（并发模型 §4：原样保留、计数上抛）。
    @Test func corruptLinesArePreservedByteForByte() throws {
        let (work, paths, _) = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: work) }
        let store = AssemblyEventStore(paths: paths, lock: WriteLock(paths: paths))
        try store.append(event("e-1"))
        try store.append(event("e-2"))

        // 文件尾插一行坏数据（半行：并发方写了一半的形状）
        let corrupt = "{\"event\":{\"id\":\"e-half\""
        let url = paths.assemblyEventsFile
        let current = try String(contentsOf: url, encoding: .utf8)
        try (current + corrupt + "\n").write(to: url, atomically: true, encoding: .utf8)

        let stats = try store.update(eventId: "e-1") { $0.accepted = true }

        #expect(stats.corruptPreserved == 1, Comment(rawValue: "损坏行计数上抛，绝不静默清除"))
        #expect(stats.eventsRewritten == 1)
        #expect(stats.linesRead == 3)
        let lines = rawLines(paths).filter { !$0.isEmpty }
        #expect(lines.count == 3)
        #expect(lines.contains(corrupt), Comment(rawValue: "损坏行原样保留（逐字节，不是重新编码的替代品）"))
        let after = store.all()
        #expect(after.count == 2)
        #expect(after.first { $0.event.id == "e-1" }?.accepted == true)
        #expect(after.first { $0.event.id == "e-2" }?.accepted == false)
    }

    /// ② 计数口径：正常文件 linesRead = 行数、eventsRewritten = 1、corruptPreserved = 0。
    @Test func rewriteStatsCountsAreAccurate() throws {
        let (work, paths, _) = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: work) }
        let store = AssemblyEventStore(paths: paths, lock: WriteLock(paths: paths))
        try store.append(event("a"))
        try store.append(event("b"))
        try store.append(event("c"))

        let stats = try store.update(eventId: "b") { $0.accepted = true }

        #expect(stats == RewriteStats(linesRead: 3, eventsRewritten: 1, corruptPreserved: 0))
        let after = store.all()
        #expect(after.count == 3)
        #expect(after.first { $0.event.id == "b" }?.accepted == true)
    }

    /// ③ 全程持锁的确定性证明（并发模型 §2 判定线：「方法体（含首行读）整体位于 lock.withLock 之内」）：
    /// update 的 mutate 闭包执行时，**第二把锁实例（同文件第二个 fd）必须拿不到锁**。
    /// 旧实现在锁外读、锁外 mutate（只有写回在锁内）→ 这里 lockB 一定能拿到 → 断言必红。
    /// （NSRecursiveLock 不挡：lockB 是另一实例，走 flock 争同一锁文件。）
    @Test func updateHoldsTheLockAcrossTheWholeReadModifyWrite() throws {
        let (work, paths, _) = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: work) }
        let lockA = WriteLock(paths: paths)
        let lockB = WriteLock(paths: paths)
        let store = AssemblyEventStore(paths: paths, lock: lockA)
        try store.append(event("e-1"))

        var acquiredInsideMutate = true
        _ = try store.update(eventId: "e-1") { s in
            s.accepted = true
            do {
                try lockB.lock(timeout: 0.05)
                lockB.unlock()
            } catch {
                acquiredInsideMutate = false   // 拿不到 = update 全程持锁（期望）
            }
        }
        #expect(acquiredInsideMutate == false,
                Comment(rawValue: "mutate 窗口内第二把锁还能拿到 = 读—改—写没有全程持锁（#6a 的洞）"))
        #expect(store.all().first { $0.event.id == "e-1" }?.accepted == true)
    }

    /// 先 append 后 update 无丢失：update 必须从盘上读（含别的实例刚 append 的行），
    /// 改写后两条都在——锁外读旧快照的旧实现会把 update 没看见的行整体抹掉。
    @Test func appendBeforeUpdateIsNotLost() throws {
        let (work, paths, _) = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: work) }
        let writer = AssemblyEventStore(paths: paths, lock: WriteLock(paths: paths))
        try writer.append(event("e-1"))
        try writer.append(event("e-2"))

        // 另一实例（模拟另一进程的读—改—写）：只改 e-1
        let updater = AssemblyEventStore(paths: paths, lock: WriteLock(paths: paths))
        let stats = try updater.update(eventId: "e-1") { $0.accepted = true }

        #expect(stats == RewriteStats(linesRead: 2, eventsRewritten: 1, corruptPreserved: 0))
        let lines = rawLines(paths).filter { !$0.isEmpty }
        #expect(lines.count == 2, Comment(rawValue: "未被 update 触及的 e-2 必须存活：\(lines)"))
        let after = writer.all()
        #expect(after.count == 2)
        #expect(after.first { $0.event.id == "e-1" }?.accepted == true)
        #expect(after.first { $0.event.id == "e-2" }?.accepted == false)
    }

    /// 追加自愈（并发模型 §4）：文件尾缺换行（上一行写了一半）时，下一次 append
    /// 必须先补一个 \n——否则新记录拼在半行上、两条一起解码失败，all() 读不到 =
    /// 待验收 Banner 凭空消失。§4 口径：新记录独立成行可解码（不再陪葬）；
    /// 旧撕裂碎片原样保留（不清除、不修复，等写方自愈或人工裁决）。
    @Test func appendSelfHealsTornTailWithoutNewline() throws {
        let (work, paths, _) = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: work) }
        let store = AssemblyEventStore(paths: paths, lock: WriteLock(paths: paths))
        try store.append(event("e-1"))

        // 造一个**无尾换行**的撕裂尾：e-1 与半行碎片同占一行（进程被杀半行的真实形状）
        let torn = "{\"event\":{\"id\":\"e-half\""
        let url = paths.assemblyEventsFile
        var current = try String(contentsOf: url, encoding: .utf8)
        while current.hasSuffix("\n") { current.removeLast() }
        try (current + torn).write(to: url, atomically: true, encoding: .utf8)

        try store.append(event("e-2"))   // 自愈点：不补 \n 就会把 e-2 拼进撕裂行、三条一起报废

        let lines = rawLines(paths).filter { !$0.isEmpty }
        // 撕裂行（e-1+碎片，不可解码）保留原样；e-2 独立成行
        #expect(lines.count == 2, Comment(rawValue: "撕裂行原样 + e-2 新行：\(lines)"))
        #expect(lines[0].hasSuffix(torn), Comment(rawValue: "撕裂碎片原样保留（§4：不清除、不重写）"))
        let after = store.all()
        #expect(after.count == 1, Comment(rawValue: "e-2 必须可解码（改前会拼进撕裂行一起报废）；撕裂行按 §4 留置待裁决"))
        #expect(after.contains { $0.event.id == "e-2" })
    }

    /// 追加自愈的正常路径回归：文件尾本就有换行时，append 不多补空行（文件形状不变）。
    @Test func appendKeepsCleanTailClean() throws {
        let (work, paths, _) = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: work) }
        let store = AssemblyEventStore(paths: paths, lock: WriteLock(paths: paths))
        try store.append(event("a"))
        try store.append(event("b"))
        #expect(store.all().count == 2)
        let raw = try String(contentsOf: paths.assemblyEventsFile, encoding: .utf8)
        #expect(!raw.contains("\n\n"), Comment(rawValue: "正常追加不得引入空行"))
        #expect(raw.hasSuffix("\n"))
    }

    /// ④/#6c 锁超时失败可见、数据未动（并发模型 §5）：另一实例（同文件第二个 fd）占住锁 +
    /// `timeout: 0.1`，mergeLocationsIntoCache 不再 try? 吞——超时如实返回 warning，缓存保持原样。
    @Test func lockTimeoutSurfacesWarningAndLeavesCacheUntouched() throws {
        let (work, paths, home) = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: work) }
        let serviceLock = WriteLock(paths: paths)     // 服务用这把
        let blocker = WriteLock(paths: paths)         // 占锁的是另一实例（第二个 fd，真互斥）
        let svc = AssemblyService(paths: paths, lock: serviceLock, home: home)

        // 先写一份有内容的缓存：超时后它必须分毫未动
        let cachedDir = home.appendingPathComponent(".agents/skills")
        let snapshot = DiscoverySnapshot(savedAt: Date(),
                                         rules: AppSettings.load(paths: paths).discoveryRules,
                                         roots: [home.path],
                                         locations: [DiscoveredLocation(path: cachedDir.path, kind: .skillDirectory)])
        DiscoveryCache(paths: paths).save(snapshot)

        try blocker.lock(timeout: 5)
        defer { blocker.unlock() }
        let freshDir = home.appendingPathComponent(".qwenworkcn/skills/pdf")
        let warning = svc.mergeLocationsIntoCache(
            [DiscoveredLocation(path: freshDir.path, kind: .skillDirectory)], timeout: 0.1)

        #expect(warning != nil, Comment(rawValue: "锁超时必须如实上抛警告，不许静默（#6c / 并发模型 §5）"))
        #expect(warning?.contains("发现缓存没能更新") == true)
        // 缓存未动：新目录没进去，元数据保持原样（合并根本没发生）
        let after = try #require(DiscoveryCache(paths: paths).load())
        #expect(after.locations.count == 1)
        #expect(after.locations.first?.path == cachedDir.path)
        #expect(after.savedAt.timeIntervalSince(snapshot.savedAt) < 1)
        #expect(after.dirsVisited == snapshot.dirsVisited)
    }
}
