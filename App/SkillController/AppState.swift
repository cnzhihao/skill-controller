// AppState.swift — App 状态编排：授权门 → 发现扫描 → 索引 → FSEvents 增量
// 分层加载规则（edge loading-initial）：<1.5s Skeleton；>3s 增量出结果 + "索引持续更新中"
//
// 扫描范围是「发现驱动」而非硬编码注册表（2026-09-20 整改，详见 docs/scan-scope-redesign.md）：
// 先找出盘上真实存在的 skills 目录与 MCP 配置，再判定用户级/项目级/归属。
// 不存在的路径不进范围——设置页不再有「该路径不存在」的空行。

import SwiftUI
import SkillControllerCore

@MainActor
final class AppState: ObservableObject {
    enum GateState: Equatable {
        case ask
        case granted
        case denied
    }

    enum GatePhase: Equatable {
        case idle
        case scanning
    }

    /// 三段式扫描的当前段（设置页进度文案用；不影响清单可用性）
    enum ScanPhase: Equatable {
        case idle
        case preparing     // 已授权、尚未开始定位位置
        case quick       // 段 1：home 两层内，秒级
        case backfill     // 段 2：全盘缓存余量
        case discovering  // 段 3：全盘发现校核（慢，后台）
    }

    @Published var gate: GateState = .ask
    @Published var gatePhase: GatePhase = .idle
    /// 当前页。放在 AppState 而不是 RootView 的 @State：挂载账的零挂载清单要能"点一行跳到清单并选中它"，
    /// 页码留在 RootView 里就跨不过去（跳页 + 选中必须一次做完，否则跳过去是空选中）
    @Published var page: NavPage = .inventory
    @Published var index = InventoryIndex()
    @Published var selectedItemId: String? {
        didSet { if selectedItemId != oldValue { loadItemChanges() } }
    }
    /// 清单筛选（2026-09-21 整改）：类型一级分段（默认 Skill）；产品多选（空集=全部）；层级（nil=全部）。
    /// 原「视角切换（按 Agent/项目/层级）」退役——筛选器链取代它。
    @Published var typeFilter: ObjectType = .skill
    @Published var agentFilter: Set<String> = []
    /// 项目维度筛选（2026-09-22 补）：与产品多选同构，空集 = 全部
    @Published var projectFilter: Set<String> = []
    @Published var levelFilter: Level? = nil
    /// 表头排序（2026-09-21 整改）：名称 / 挂载次数 / 跨项目数，点同一列翻转升降
    @Published var sortKey: InventorySortKey = .name
    @Published var sortAscending: Bool = true
    @Published var query: String = ""
    /// 扫描已耗时（秒）——驱动 Skeleton/增量切换。
    /// **不是 @Published**：它每 200ms 变一次，一旦可观察，清单页每次 tick 都会重算
    /// agentCounts / projectCounts / filtered / summary 这些全量聚合——真机实测直接把主线程
    /// 吃满 40% CPU 跑不完重扫（重扫完不了 → tick 继续 → 自锁）。发布的是下面的档位。
    private var scanElapsed: TimeInterval = 0
    /// 扫描时钟的档位：只在跨过 1.5s / 3s 两条线时变一次（一轮 pass 最多 2 次发布）
    enum ScanClock: Equatable { case early, skeletonGone, hint }
    @Published private(set) var scanClock: ScanClock = .early
    /// 设置页数据源：当前范围内真实存在的位置
    @Published var scopeLocations: [ScanLocation] = []
    /// 靠目录名兜底出来的"归属"——是项目名而非可引用的 Agent（清单/详情据此打中性标签）
    @Published var pseudoAgentIds: Set<String> = []
    @Published var scanPhase: ScanPhase = .idle
    /// 每处位置收录的条目数（设置页行尾计数）
    @Published var locationEntryCounts: [String: Int] = [:]
    /// 全盘发现元信息（设置页如实展示，不做进度承诺）
    @Published var lastFullDiscovery: Date?
    @Published var discoveryDirsVisited: Int = 0
    @Published var discoveryUnreadable: Int = 0
    /// 每类剪枝跳过的目录数（设置页据此说明"关掉这一类会多走多少路"）
    @Published var prunedDirsByCategory: [PruneCategory: Int] = [:]
    /// 账本起点（诚实展示：此前的挂载无从得知）
    @Published var ledgerStartDate: Date
    /// 操作日志流（回退页数据源，按时间倒序）
    @Published var logEntries: [LogEntry] = []
    /// 回收站条目
    @Published var trashEntries: [TrashManifest] = []
    /// 恢复结果（G4 部分恢复如实报；Banner 三态之一）
    @Published var lastRestoreOutcome: RestoreOutcome?
    /// 「撤销这次恢复」（重新挂回）的回执。不复用 lastRestoreOutcome：
    /// 那句"磁盘状态与操作前一致"对挂回动作是反的（操作前落点不在、现在在了），
    /// 复用一条回执文案等于让界面撒谎（G7）。
    @Published var lastReapplyOutcome: RestoreOutcome?
    /// 装配事件流（Banner + diff Sheet 数据源）
    @Published var assemblyEvents: [StoredAssemblyEvent] = []
    /// diff 打开时的事件（G3 快照版本比对）
    @Published var diffEventId: String?
    @Published var diffStale: Bool = false
    /// 这次装配的影响面已经整个从盘上消失（项目被移走/目录被删）——
    /// 与"清单又变了"是两回事：没有可比的对象，锁验收会把人关死在出口外（2026-09-22 真机）
    @Published var diffSurfaceGone: Bool = false
    /// 已经按过「重新加载」并看完当前清单 → 基线已刷新，验收放行（G3 的终点）
    @Published var diffRebased: Bool = false
    /// 选中条目的「挂载变动」（详情栏数据源；账本落地后不再写死）
    @Published var itemChanges: [LogEntry] = []

    /// 本地数据根目录：监听根、日志、回收站共用同一份，避免各处默认值漂移
    let paths = SkillControllerPaths()
    /// 全进程一把写锁。TrashManager 删除时会先持锁再写日志，若 opLog 与 trash 各自 new 一个
    /// WriteLock，就是同一文件两个 fd 的 flock——同进程也会互斥，删除必然卡到超时
    /// （2026-09-21 真机验收抓到：报 WriteLock.LockError，写回执如实显示"删除失败"）。
    let writeLock: WriteLock
    let opLog: OperationLog
    let trash: TrashManager
    let assembly: AssemblyService
    /// 磁盘空间探测（#1 预检式删除流）。注入点：默认 `.system`（真探测）；
    /// 仅 Debug build 可经环境变量 `SKILLCTL_FAKE_FREE_BYTES` 注入假值走真机升级链路。
    let diskSpaceProbe: DiskSpaceProbe
    /// CLI 检测与引导编排（台账 #19）。CLIGuideModel 是嵌套 ObservableObject——它的 @Published
    /// 不经 AppState 转发，RootView 与设置页须对 `app.cliGuide` 直持观察（@ObservedObject），
    /// 否则「探测翻成 current」「跳过后 wantsAutoPresent 翻转」不会触发视图重算（评审发现②）。
    let cliGuide: CLIGuideModel

    private let defaults = UserDefaults.standard
    private let discoveryCache: DiscoveryCache
    private var watcher: FSEventWatcher?
    private var scanTask: Task<Void, Never>?
    /// #16（D39）：轻量重扫 Task 的句柄——cancelScan 要能显式取消它（匿名 Task 没有把手）。
    private var rescanTask: Task<Void, Never>?
    /// #16（D39）：用户取消出口。协作取消（Task.isCancelled 感知），**不 bump scanGeneration**——
    /// 代际号语义是「新 pass 接管」，bump 会让在跑 pass 在代际守卫处跳过尾部归位，
    /// scanPhase/gatePhase 卡忙碌永久死（D20 修「裸 return 丢事件」守住的同一条尾巴）。
    /// 管线中途的取消感知点全部现成：段边界 :234/:247/:253、chunk 循环顶（每 120 处一查）、
    /// 发现段 shouldStop: { Task.isCancelled }。被取消的 pass 没有磁盘事实可发布（零发布），
    /// 与 D16 相容：ScanPublishPolicy 管的是 pass 自己走完时的收尾发布。
    func cancelScan() {
        scanTask?.cancel()
        rescanTask?.cancel()
        discoveryTask?.cancel()   // detached 句柄，父任务 cancel 传不进去，必须显式
    }
    /// #13（D40）：已反映进索引的最新装配事件 id。初始化为当前最新事件 id——
    /// 存量历史早已反映在盘上，不回放。
    private var appliedLandingEventId: String?
    /// 重扫合流：正在重扫时到来的事件只记一次「待重扫」，扫完补一轮——
    /// 绝不取消在跑的扫描（取消会让 Agent 批量装配期间每轮都从头开始，永远扫不完）
    @Published private var rescanning = false
    private var rescanQueued = false
    /// 轻量重扫期间点了「重新扫描全盘」→ 记下来，本轮扫完立刻接上，不丢用户动作
    private var pendingFullRescan = false
    /// diff Sheet 的「重新加载」：等重扫真跑完再比对快照（G3 唯一出口，此前是立刻比对，永远解不开锁）
    @Published private(set) var reloadingDiff = false
    /// 9①：diff 基线比对正在后台算（一轮检查只发布两次：开始/结束）。
    /// UI 据此禁用「关闭并验收」「重新加载」并显「正在比对清单…」——
    /// 不做的话比对那 2-5s 里主线程卡死（beachball），窗口拖不动。
    @Published private(set) var diffRevisionPending = false
    /// 9① 代际守卫：openDiff / reloadDiff / 每次 refreshDiffStaleness 进入时 +1；
    /// 后台算完回来先验代际，过期即弃（与扫描代际守卫同一形状——D16 的教训不许在新地方重犯）。
    private var diffCheckGeneration = 0
    private var activeObserver: NSObjectProtocol?

    /// 扫描耗时计时任务（冷启动与轻量重扫共用，见 startTicker / stopTicker）
    private var tickerTask: Task<Void, Never>?
    /// 扫描代际：每开一轮 pass 加一。被打断的旧 pass 一律不许再发布结果——
    /// 否则「⌘⇧R 打断在跑的轻量重扫」时，旧 pass 会把只扫了一半的索引盖到新 pass 上（D16）
    private var scanGeneration = 0
    /// 9③：段 3 全盘发现的 detached 句柄。`Task.isCancelled` 在 detached 块里看的是
    /// **detached 自己**，外层 `scanTask.cancel()` 传不进去——这是"全盘发现不可取消"的真根因
    /// （44s 遍历只能等它跑完）。存下句柄，`beginPass()`（startScan 与 requestRescan 的唯一汇合点）
    /// 单点 cancel，`shouldStop: { Task.isCancelled }` 现在真的会停。
    private var discoveryTask: Task<DiscoveryOutcome, Never>?
    /// 本轮是否逐批发布。只在**冷启动**（手上还没有任何一版全量）时逐批出结果；
    /// 已有一版全量时一轮 pass 只在收尾发布一次（D16，见 publish）
    private var publishIncrementally = false
    /// 本轮 pass 的暂存位置与每位置计数：发布前绝不写进展示属性（D16）
    private var stagedLocations: [ScanLocation] = []
    private var stagedEntryCounts: [String: Int] = [:]

    /// 发现到的原始位置（分类前的路径列表）；重扫只基于它，绝不隐式触发全盘遍历
    private var lastDiscovered: [DiscoveredLocation] = []
    /// 已并入索引的位置路径——增量扫描时跳过，避免重复扫全盘
    private var scannedPaths: Set<String> = []
    private var accumulatedEntries: [RawEntry] = []
    private var accumulatedDegraded: [DegradedLocation] = []
    private var accumulatedScanned = 0

    var rules: DiscoveryRules

    static let ignoredKey = "ignoredLocations"
    static let ledgerStartKey = "ledgerStartDate"

    init(diskSpaceProbe: DiskSpaceProbe = DiskSpaceProbe(.system),
         cliGuideProbe: SkillctlProbe = SkillctlProbe(.system)) {
        // 剪枝类别是用户设置项（设置页逐类开关），规则变了发现缓存自动失效
        // 必须先于任何 self 访问赋值：rules 无默认值，Swift 要求存储属性全部就位后才允许用 self
        rules = AppSettings.load().discoveryRules
        writeLock = WriteLock(paths: paths)
        opLog = OperationLog(paths: paths, lock: writeLock)
        trash = TrashManager(paths: paths, lock: writeLock, log: opLog)
        assembly = AssemblyService(paths: paths, lock: writeLock)
        self.diskSpaceProbe = diskSpaceProbe
        self.cliGuide = CLIGuideModel(probe: cliGuideProbe)
        discoveryCache = DiscoveryCache(paths: paths)
        ledgerStartDate = defaults.object(forKey: Self.ledgerStartKey) as? Date ?? Date()
        defaults.set(ledgerStartDate, forKey: Self.ledgerStartKey)
        let snap = discoveryCache.load()
        // 只在规则一致时沿用上次发现的时间与计数：规则变了这些数字就属于另一套范围，
        // 显示出来会误导（宁可空着，等本次扫描完成回填）
        if let snap, snap.rules == rules {
            lastFullDiscovery = snap.savedAt
            discoveryDirsVisited = snap.dirsVisited
            discoveryUnreadable = snap.unreadableCount
            prunedDirsByCategory = snap.typedPrunedCounts
        }
        refreshRollback()
        // #13（D40）：marker 初始化为当前最新事件 id——存量历史早已反映在盘上，不回放。
        appliedLandingEventId = assembly.eventStore.all().last?.event.id
        // 回到前台补一轮轻量重扫：MCP 配置文件故意不进 FSEvents（理由见 FSEventWatcher.watchRoots），
        // 用这一步保证「Agent 刚改完 MCP，切回 App 就是新的」，而不是假装实时。
        activeObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.requestRescan(reason: .foreground) }
        }
        // AppState 与进程同生命周期，故不摘观察者。
    }

    // MARK: - 授权门（flow1 Screen1）

    func grant() {
        gate = .granted
        startScan()
    }

    func deny() {
        gate = .denied
    }

    // MARK: - 扫描编排（三段式）
    //
    // 段 1 快扫：home 两层内的位置（本机实测 53 处 Agent 目录 + home 层 MCP 配置）→ 秒级出首版清单
    // 段 2 补扫：上次全盘缓存里的其余位置（本机 ~844 处，枚举+解析实测 5.2s）→ 近全量
    // 段 3 校核：全盘发现（实测 44s）→ 仅扫新出现的位置 → 结果写回缓存
    // 三段都不阻塞首屏；慢的那段后台跑完即止（不做常驻扫描，见硬规则禁区清单）。

    func startScan() {
        gatePhase = .scanning
        scanPhase = .preparing   // 立刻置位：否则扫描期间设置页会显示「扫描已完成」
        index.setUpdating(true)
        scanTask?.cancel()
        let myGen = beginPass()
        scanTask = Task { [weak self] in
            guard let self else { return }
            let home = FileManager.default.homeDirectoryForCurrentUser
            let rules = self.rules

            // 位置来源：缓存命中即省掉 44s 的发现遍历；无缓存则现做 home 两层快扫
            let cached = self.discoveryCache.load()
            var prior: [DiscoveredLocation]
            if let cached, cached.rules == rules {
                prior = self.sanitize(cached.locations)
            } else {
                prior = await Task.detached(priority: .userInitiated) {
                    ScopeDiscoverer(rules: rules).discover(roots: [home], home: home, maxDepth: 2).locations
                }.value
            }
            guard myGen == self.scanGeneration else { return }   // 等发现期间被别轮打断 → 整轮作废
            self.lastDiscovered = prior
            let parts = self.split(prior, home: home)

            // 段 1：home 两层内
            self.scanPhase = .quick
            await self.scan(parts.shallow, home: home, generation: myGen)
            // D20：段 1 一落地把监听起来。此前监听要等三段全跑完（本机 5–8 分钟），
            // 那段时间里 Agent 挂/卸的东西**根本没有事件**——不是被合流吃掉，是压根没在听。
            // 段 3 收尾会用完整位置清单再起一次（startWatching 自带 stop，重复调用安全）。
            self.startWatching()

            // 段 2：缓存余量（home 外的项目级与全盘深层工具目录）
            if !Task.isCancelled, myGen == self.scanGeneration, !parts.deep.isEmpty {
                self.scanPhase = .backfill
                await self.scan(parts.deep, home: home, generation: myGen)
            }

            // 段 3：全盘发现校核 → 只扫新位置 → 写回缓存
            if !Task.isCancelled, myGen == self.scanGeneration {
                self.scanPhase = .discovering
                // 9③：句柄存 discoveryTask——beginPass 对它单点 cancel，
                // shouldStop 里的 Task.isCancelled 看的是这个 detached 自己，现在真的会停
                let handle = Task.detached(priority: .utility) {
                    ScopeDiscoverer(rules: rules).discover(
                        roots: rules.fullDiskRoots.map { URL(fileURLWithPath: $0) },
                        home: home, maxDepth: rules.maxDepth, batchSize: 60,
                        shouldStop: { Task.isCancelled })
                }
                self.discoveryTask = handle
                let fresh = await handle.value
                if !Task.isCancelled, myGen == self.scanGeneration {
                    self.discoveryDirsVisited = fresh.dirsVisited
                    self.discoveryUnreadable = fresh.unreadableCount
                    self.prunedDirsByCategory = fresh.prunedDirsByCategory
                    let merged = self.sanitize(prior + fresh.locations)
                    self.lastDiscovered = merged
                    let now = Date()
                    self.lastFullDiscovery = now
                    self.discoveryCache.save(DiscoverySnapshot(savedAt: now, rules: rules,
                                                               roots: rules.fullDiskRoots,
                                                               locations: merged,
                                                               dirsVisited: fresh.dirsVisited,
                                                               unreadableCount: fresh.unreadableCount,
                                                               prunedDirsByCategory: Dictionary(
                                                                    uniqueKeysWithValues: fresh.prunedDirsByCategory
                                                                        .map { ($0.key.rawValue, $0.value) }),
                                                               // 版本戳必须真写进去：CLI 靠它分辨
                                                               // 「这份缓存是不是同一次构建扫出来的」
                                                               builderVersion: SkillControllerVersion.string))
                    // 已扫过的位置会被 scannedPaths 跳过
                    await self.scan(merged, home: home, generation: myGen)
                }
            }

            guard myGen == self.scanGeneration else { return }
            // #16（D39）取消归位：冷启动三段式被「停止扫描」取消时**零发布**——
            // 清单停在点停前最后一批已发布的（首批发布前取消 = 留空），两种都是用户显式选择。
            // 归位动作照常：忙碌态干净退出、diff 等待链交代（G3 不锁死）、FSEvents 继续听。
            // rescanQueued 照旧结转——扫描期间攒下的事件不能凭空消失（D20）。
            if Task.isCancelled {
                self.stopTicker()
                self.index.setUpdating(false)
                self.gatePhase = .idle
                self.scanPhase = .idle
                self.startWatching()
                self.finishDiffReload()
                if self.rescanQueued {
                    self.rescanQueued = false
                    self.requestRescan(reason: .fileEvent)
                }
                return
            }
            self.stopTicker()
            self.publish(generation: myGen, stillUpdating: false)
            self.gatePhase = .idle
            self.scanPhase = .idle
            self.startWatching()
            self.finishDiffReload()   // 三段式期间等的「重新加载」也要有个交代
            // 扫描期间攒下来的事件补一轮：那几分钟里 Agent 挂/卸的东西不能凭空消失
            if self.rescanQueued {
                self.rescanQueued = false
                self.requestRescan(reason: .fileEvent)
            }
        }
    }

    /// 开一轮 pass：清零累积器与计时、领取代际号；顺手取消上一轮的全盘发现（9③ 单点取消）。
    /// 返回值必须在每个 await 之后复查——代际变了就说明有别轮扫描接管了，本轮该原地退出。
    @discardableResult
    private func beginPass() -> Int {
        scanGeneration += 1
        discoveryTask?.cancel()   // 9③：旧发现传不进 cancel 的病根在这里断掉
        discoveryTask = nil
        resetAccumulators()
        publishIncrementally = ScanPublishPolicy(previousItemCount: index.items.count).publishesEachBatch
        startTicker()
        return scanGeneration
    }

    /// 扫描耗时计时（edge loading-initial 的 >3s 判据）。
    /// 冷启动和轻量重扫都要有：此前只有三段式带计时，重扫期间 scanElapsed 停在上一轮的值，
    /// "索引持续更新中"于是每次秒级重扫都闪一下——那是标签在撒谎，不是提示。
    private func startTicker() {
        stopTicker()
        let started = Date()
        scanElapsed = 0
        scanClock = .early
        tickerTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 200_000_000)
                guard let self else { return }
                self.scanElapsed = Date().timeIntervalSince(started)
                // 只在跨过 1.5s / 3s 两条线时发布一次。每 200ms 发布 = 清单页每一屏都要重算
                // agentCounts / projectCounts / filtered / summary 这些全量聚合，
                // 主线程被自己的渲染吃满，扫描续体排不上队 → 重扫永远跑不完（真机 40% CPU 卡 15 分钟）。
                let next: ScanClock = self.scanElapsed < 1.5 ? .early
                    : (self.scanElapsed > 3 ? .hint : .skeletonGone)
                if next != self.scanClock { self.scanClock = next }
            }
        }
    }

    private func stopTicker() {
        tickerTask?.cancel()
        tickerTask = nil
    }

    /// 设置页「重新扫描全盘」：清掉发现缓存后重走三段（用户显式动作，不做静默增量）
    /// 轻量重扫正在进行时不硬插一脚（两条扫描共用同一批累积器会互相写脏）——
    /// 记成待办，本轮秒级扫完就接上，用户动作不丢。
    func rescanFullDiskFromScratch() {
        guard gate == .granted else { return }
        if rescanning {
            pendingFullRescan = true
            return
        }
        discoveryCache.clear()
        lastDiscovered = []
        startScan()
    }

    /// 逐类开关剪枝：落盘的是「对默认值的逐项覆盖」，不是绝对列表（D17）——
    /// 与默认一致的项不落盘，这样以后新增的剪枝类别对老用户也能自动生效。
    func setPruned(_ category: PruneCategory, _ on: Bool) {
        guard rules.isCategoryPruned(category) != on else { return }
        if on { rules.prunedCategories.insert(category) } else { rules.prunedCategories.remove(category) }
        var settings = AppSettings.load()
        settings.setPrunedCategories(rules.prunedCategories)
        try? settings.save()
        rescanFullDiskFromScratch()
    }

    /// home 两层内 = 浅位置（用户级 Agent 配置树）；其余 = 深位置（项目级、全盘角落）
    private func split(_ locations: [DiscoveredLocation], home: URL) -> (shallow: [DiscoveredLocation], deep: [DiscoveredLocation]) {
        var shallow: [DiscoveredLocation] = [], deep: [DiscoveredLocation] = []
        for loc in locations {
            let rel = LocationClassifier.relativeComponents(of: loc.containerDir, to: home)
            if let rel, rel.count <= 2 { shallow.append(loc) } else { deep.append(loc) }
        }
        return (shallow, deep)
    }

    /// 去重 + 剔除已消失的位置（缓存可能过期——这正是设置页出现空行的根因）
    private func sanitize(_ raw: [DiscoveredLocation]) -> [DiscoveredLocation] {
        let fm = FileManager.default
        var seen = Set<String>()
        var out: [DiscoveredLocation] = []
        for loc in raw {
            guard seen.insert(loc.id).inserted else { continue }
            guard fm.fileExists(atPath: loc.url.standardizedFileURL.path) else { continue }
            out.append(loc)
        }
        return out
    }

    private func resetAccumulators() {
        scannedPaths = []
        accumulatedEntries = []
        accumulatedDegraded = []
        accumulatedScanned = 0
        // 注意：这里清的是**暂存**，展示用的 scopeLocations / locationEntryCounts 不动。
        // 之前它们跟着清零，设置页会在每轮重扫的头一瞬间看到「0 处位置」，
        // 然后一路涨回来——和页头数字缩水是同一个病根（D16）。
        stagedLocations = []
        stagedEntryCounts = [:]
        projectsAccumator = ProjectAccumulator()
    }

    /// 扫描一批位置并累积。**唯一**写进展示属性的地方是 publish，这里绝不直接改索引（D16）
    private func scan(_ locations: [DiscoveredLocation], home: URL, generation: Int) async {
        let ignored = ignoredPaths()
        let pending = locations.filter { !scannedPaths.contains($0.url.standardizedFileURL.path) }
        guard !pending.isEmpty, generation == scanGeneration else { return }
        let built = ScopeBuilder.scope(discovered: pending, home: home, ignored: ignored)
        stagedLocations += built.locations
        projectsAccumator.merge(with: built.projects)
        let scanner = InventoryScanner()
        // 批量要够大：全盘发现后有上千处位置，按 24 一批会在主线程重建上百次索引，
        // 真机验收时直接把 UI 卡到点不动（点击超时）。120 一批把全程重建次数压到十几次。
        let chunks = built.locations.chunked(into: 120)
        for chunk in chunks {
            if Task.isCancelled || generation != scanGeneration { return }
            let chunkScope = ScanScope(locations: chunk, projects: built.projects)
            let r = await Task.detached(priority: .userInitiated) {
                scanner.scan(scope: chunkScope)
            }.value
            guard generation == scanGeneration else { return }   // 期间被打断：结果别再往展示层写
            accumulatedEntries += r.entries
            accumulatedDegraded += r.degraded
            accumulatedScanned += r.locationsScanned
            for loc in chunk { scannedPaths.insert(loc.url.standardizedFileURL.path) }
            stagedEntryCounts = Self.countsPerLocation(accumulatedEntries)
            // D16：只有冷启动（手上还没有任何一版清单）才逐批发布，让首屏边扫边出——
            // 累积器只增不减，所以逐批发布时数字单调上涨，不会回头。
            // 已有一版全量时**不在中途发布**：那等于先把清单拆了再拼回去，页头会先跌一截
            // （真机实测 1,973 → 1,834 → 1,398 → 1,767 → 1,973），而跌下去的那一瞬间
            // 详情栏里的条目直接不存在了，正开着的「移入回收站」确认框跟着一起被系统作废。
            if publishIncrementally {
                publish(generation: generation, stillUpdating: true)
            }
        }
    }

    /// 把本轮暂存的扫描结果一次性发布到界面——展示层的唯一写入口（D16）
    private func publish(generation: Int, stillUpdating: Bool) {
        guard generation == scanGeneration else { return }
        let home = FileManager.default.homeDirectoryForCurrentUser
        pseudoAgentIds = Set(stagedLocations.filter { $0.agentOrigin == .containerName }.compactMap(\.agentId))
        scopeLocations = stagedLocations
        locationEntryCounts = stagedEntryCounts
        let result = ScanResult(entries: accumulatedEntries, degraded: accumulatedDegraded,
                                locationsScanned: accumulatedScanned)
        index.rebuild(from: result, projects: projectsAccumator.all,
                      discoveredAgents: Self.agents(in: stagedLocations, home: home))
        if stillUpdating { index.setUpdating(true) }
        // InventoryIndex 是 class，就地 rebuild 不会触发 @Published；本轮又不再顺手改别的展示属性
        // 来"捎带"刷新，所以显式发一次——否则数字落定了界面还停在旧值
        objectWillChange.send()
    }

    private var projectsAccumator = ProjectAccumulator()

    /// 跨段累积项目清单（同 id 同路径合并，不同路径同名时加确定性后缀）
    struct ProjectAccumulator {
        private(set) var all: [Project] = []
        private var byPath: Set<String> = []
        mutating func merge(with projects: [Project]) {
            for p in projects where !byPath.contains(p.path) {
                if all.contains(where: { $0.id == p.id }) {
                    let unique = Project(id: p.id + "-" + String(LocationClassifier.fnv64(p.path), radix: 16),
                                         name: p.name, path: p.path)
                    all.append(unique)
                } else {
                    all.append(p)
                }
                byPath.insert(p.path)
            }
            all.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        }
    }

    /// 每处位置收录到多少条目（设置页行尾计数）；一次聚合，避免 O(位置×条目)
    private static func countsPerLocation(_ entries: [RawEntry]) -> [String: Int] {
        var counts: [String: Int] = [:]
        for e in entries {
            let owner = URL(fileURLWithPath: e.locationPath).deletingLastPathComponent().standardizedFileURL.path
            counts[owner, default: 0] += 1
        }
        return counts
    }

    /// 归属清单按实际发现动态生成（注册表只有 4 家；全盘发现会带出 trae-cn / grok / devin…）
    /// 只收真 Agent：靠所在目录名兜底的（多半是项目名）不算 Agent，另走 pseudoAgentIds 标注
    private static func agents(in locations: [ScanLocation], home: URL) -> [Agent] {
        var byId: [String: Agent] = [:]
        for loc in locations where loc.agentOrigin.isRealAgent {
            guard let id = loc.agentId, byId[id] == nil else { continue }
            let shown = loc.url.path.hasPrefix(home.path)
                ? "~" + loc.url.path.dropFirst(home.path.count)
                : loc.url.path
            byId[id] = Agent(id: id, name: AgentRegistry.agentName(id), homeDir: shown)
        }
        return Array(byId.values)
    }

    /// FSEvents 增量：范围内变更 → 防抖重扫（只按已知位置重扫，绝不触发全盘发现）
    /// 监听根 = Skills 目录 + 本工具数据目录（后者才有 skillctl 写的装配事件与日志；
    /// 不监听它，Agent 装配后 Banner 就得等别的事件才跳）
    private func startWatching() {
        watcher?.stop()
        let roots = FSEventWatcher.watchRoots(for: scopeLocations, supportDir: paths.supportDir)
        guard !roots.isEmpty else { return }
        let w = FSEventWatcher(paths: roots) { [weak self] in
            Task { @MainActor [weak self] in
                self?.requestRescan(reason: .fileEvent)
            }
        }
        w.start()
        watcher = w
    }

    /// 轻量重扫的合流入口：在跑就排队、跑完补一轮；绝不取消在跑的扫描
    enum RescanReason {
        case foreground   // 回到前台
        case fileEvent    // FSEvents（含 skillctl 写的装配事件/日志）
        case userAction   // 清单页刷新按钮 / ⌘R
        case afterWrite   // 本 App 自己的删除、恢复、忽略位置
    }

    /// 重扫 = 对已知位置重新分类 + 清空累积重扫（秒级量级，不含全盘遍历）
    func requestRescan(reason: RescanReason = .userAction) {
        guard gate == .granted else { return }
        // #13（D40）：定向行更新先行——忙碌判定**之前**跑，任何原因的 requestRescan 都先做这一步。
        // 三段式在跑时下面会排队（收尾 40s+），CLI 卸下的落点只能靠这一步即时回落（S11）。
        // 幂等、毫秒级（事件文件十几行）；无论成败 marker 都推进到最新——定向更新只是加速器，
        // 权威兜底永远是后面的重扫。
        applyLandingFacts()
        // 三段式扫描在跑时不硬插（两条扫描共用同一批累积器会互相写脏），
        // 但必须记一次待办：此前这里是裸 return，导致启动后那几分钟里 Agent 干的活
        // 全部看不见——真机上 unmount 完清单还挂着那条，要等下一次别的事件。
        if scanPhase != .idle || rescanning {
            rescanQueued = true
            return
        }
        rescanning = true
        index.setUpdating(true)
        let home = FileManager.default.homeDirectoryForCurrentUser
        let known = lastDiscovered
        let myGen = beginPass()
        rescanTask = Task { [weak self] in
            guard let self else { return }
            await self.scan(self.sanitize(known), home: home, generation: myGen)
            self.finishRescan(generation: myGen)
        }
    }

    /// #13（D40）：把 skillctl 装配事件里新出现的落点事实（added/removed）就地反映进索引。
    /// 信任锚 = 自家 CLI 写的事件文件（assembly-events.jsonl 在 FSEvents 监听根里）——
    /// 与 removeItem「只用于我们自己刚做完写操作」同一信任级别，不是拿猜测改索引。
    /// marker 之前的事件全部跳过（已反映过）；单条目重derive 在 Core（InventoryIndex.applyLandingFacts），
    /// 归属判定与扫描期 rebuild 同源（两份口径 = D19 的成因）。
    private func applyLandingFacts() {
        let events = assembly.eventStore.all()
        // 从尾部找 marker：它之后的才是没反映过的新事件
        guard let marker = appliedLandingEventId else {
            appliedLandingEventId = events.last?.event.id
            return
        }
        guard let markerIdx = events.lastIndex(where: { $0.event.id == marker }) else {
            // marker 失效（文件被清/重装）：跳到最新，等重扫兜底，不猜中间发生什么
            appliedLandingEventId = events.last?.event.id
            return
        }
        let fresh = events[(events.index(after: markerIdx))...]
        guard !fresh.isEmpty else { return }
        var added: [String] = [], removed: [String] = []
        for stored in fresh {
            added += stored.event.added
            removed += stored.event.removed
        }
        guard !added.isEmpty || !removed.isEmpty else {
            appliedLandingEventId = events.last?.event.id
            return
        }
        let home = FileManager.default.homeDirectoryForCurrentUser
        if index.applyLandingFacts(added: added, removed: removed, home: home) {
            // 与 removeItem 同款：InventoryIndex 是 class，就地改不触发 @Published，显式发一次
            objectWillChange.send()
        }
        appliedLandingEventId = events.last?.event.id
    }

    private func finishRescan(generation: Int) {
        stopTicker()
        rescanning = false
        // #16（D39）取消归位：被用户「停止扫描」取消的 pass **零发布**——不发布半截累积器
        // （累积器是暂存，展示索引从未被拆，D16 的保障原样成立）。归位动作照常做：
        // 忙碌态必须干净退出、diff 等待链要交代（G3 不锁死）。非取消路径一字不动。
        if Task.isCancelled {
            index.setUpdating(false)
            refreshRollback()
            finishDiffReload()
            // 取消窗内排队的重扫不能被吞（评审轮 1 点修）：与 startScan 尾部同一结转——
            // D20 的教训是「扫描期间的事件不能凭空消失」，取消分支不豁免这条纪律
            if rescanQueued {
                rescanQueued = false
                requestRescan(reason: .fileEvent)
            }
            return
        }
        // 被别轮接管时绝不发布（半截结果会盖掉新扫描），也不改"更新中"标记——
        // 但上面的 rescanning 必须交还，否则整App 永远卡在忙碌态
        guard generation == scanGeneration else { return }
        publish(generation: generation, stillUpdating: false)
        index.setUpdating(false)
        // D33（2026-09-23 ③a 首跑抓到）：扫描收尾原来只刷装配事件与选中条目的变动，
        // 不刷回退页的日志列表——于是 CLI（外部进程）写下的那条操作，要等 App 自己做一次
        // 写操作或重启才会出现在回退页上。监听根本来就包含本工具数据目录，事件到了就该重读。
        // refreshRollback 内部含 refreshAssemblyEvents + loadItemChanges，原来那两行并入它。
        refreshRollback()
        finishDiffReload()
        if pendingFullRescan {
            pendingFullRescan = false
            rescanFullDiskFromScratch()
            return
        }
        if rescanQueued {
            rescanQueued = false
            requestRescan(reason: .fileEvent)
        }
    }

    /// 兼容既有调用点的名字（写操作后、diff 重新加载都走轻量重扫）
    func rescan() { requestRescan(reason: .userAction) }

    /// 详情栏「挂载变动」的真数据：按条目 id 与它的落点路径查操作日志。
    /// 读文件不能进每屏渲染热路径，故在选中/重扫/写操作后各刷一次。
    func loadItemChanges() {
        if let item = selectedItem {
            itemChangesForId = item.id
            itemChangesPaths = [item.sourcePath] + item.duplicates
            itemChanges = opLog.entries(involvingItemId: item.id, landingPaths: itemChangesPaths)
            return
        }
        // 条目已被移走：用上一次已知的 id + 落点再查一次，把"谁干的"留给消失态说（D3）
        if let id = selectedItemId, id == itemChangesForId {
            itemChanges = opLog.entries(involvingItemId: id, landingPaths: itemChangesPaths)
            return
        }
        itemChangesForId = nil
        itemChangesPaths = []
        itemChanges = []
    }

    // MARK: - 忽略位置（edge G1：横幅每行出口；设置页可逆）

    func ignoredPaths() -> Set<String> {
        Set(defaults.stringArray(forKey: Self.ignoredKey) ?? [])
    }

    func ignoreLocation(_ path: String) {
        var arr = defaults.stringArray(forKey: Self.ignoredKey) ?? []
        if !arr.contains(path) { arr.append(path) }
        defaults.set(arr, forKey: Self.ignoredKey)
        rescan()
    }

    func restoreLocation(_ path: String) {
        var arr = defaults.stringArray(forKey: Self.ignoredKey) ?? []
        arr.removeAll { $0 == path }
        defaults.set(arr, forKey: Self.ignoredKey)
        rescan()
    }

    // MARK: - 写操作（GUI 封顶：删除/恢复——story-4）

    /// 删除成功回执（D18）：删除是不可逆感最强的动作，不能只靠"行消失"表达结果
    @Published var lastDeleteReceipt: DeleteReceipt?

    /// 磁盘满直接删除的回执（#1）：name + 落点数。
    /// 独立字段而非复用 DeleteReceipt——那句"30 天内可恢复"对直接删除是假话（G7）。
    struct IrreversibleDeleteReceipt: Equatable {
        var name: String
        var locations: Int
        /// 日志没写成时如实带上：不假装落了日志（设计 §1#1 / 用例 E2）
        var logFailed: Bool = false
    }
    @Published var lastIrreversibleDeleteReceipt: IrreversibleDeleteReceipt?

    /// 详情栏消失态的 actor 来源：条目被移走后仍保留它上一次查到的变动记录与已知落点，
    /// 否则"日志里明明写着谁干的，界面却说不出"（D3）。
    /// 落点必须留着，因为 CLI 的装配记录 target 是项目 id，只能按落点路径命中。
    private var itemChangesForId: String?
    private var itemChangesPaths: [String] = []

    struct DeleteReceipt: Equatable {
        var name: String
        var locations: Int
        var days: Int
    }

    func deleteItem(_ item: InventoryItem) {
        do {
            // #15（D36）：传入全量挂载落点（MountStat.spots）——「各 Agent 的挂载将同时卸下」
            // 的承诺按 spots 兑现，symlink 落点只删链接、源不动（C3 红线不破，恢复按 linkTarget 重建）
            let manifest = try trash.trash(item: item, actor: "智昊",
                                           additionalPaths: index.mountStat(of: item.id).spots.map(\.path))
            lastError = nil
            lastRestoreOutcome = nil
            lastDeleteReceipt = DeleteReceipt(name: item.name, locations: manifest.locations.count,
                                              days: AppSettings.load().trashRetentionDays)
            // 回执说"已移入回收站"，行就得真的没了——不能等重扫收尾才发布（那要一两秒，
            // 期间那一行还能再点一次删除）。重扫照跑，扫完会用磁盘事实复核这一条。
            index.removeItem(id: item.id)
            objectWillChange.send()
            refreshRollback()
            rescan()
        } catch {
            // 硬规则 8：写操作三步齐之外还要「失败如实报」——这里落 lastError，
            // 由清单页的 WriteOutcomeBanner 上屏（此前只赋值，永远看不见）
            lastRestoreOutcome = nil
            lastDeleteReceipt = nil
            lastError = "删除失败：\(error.localizedDescription)"
        }
    }

    // MARK: 磁盘满预检（#1 预检式替换流）

    /// 普通确认框点「移入回收站」后的预检：充足走原流，不足返回 (needed, free) 供升级 Sheet 展示。
    /// 探测失败（nil）不拦人——真失败由 D14 回滚 + 失败回执兜底（设计 §1#1 判定口径）。
    func requestDelete(_ item: InventoryItem) -> (needed: Int64, free: Int64)? {
        let free = diskSpaceProbe.freeBytes(volumePath: item.sourcePath)
        // #15（D36）：体积预检并入同一份全量落点（TrashSpaceEstimator 对 symlink 算 0 字节，
        // 并入口径一致——回执/manifest/预检三处说同一件事）。
        // Set 去重（评审轮 1 点修）：spots 恒含 sourcePath 与 duplicates，不去重会把
        // 跨卷实体落点的体积计 2 倍，needed 虚高可能把本可正常删除的人推向不可逆路径
        let needed = TrashSpaceEstimator.neededBytes(
            entityPaths: Array(Set([item.sourcePath] + item.duplicates + index.mountStat(of: item.id).spots.map(\.path))),
            trashVolume: trashVolumePath, volumeOf: volumeOf)
        if DiskSpaceDecision.decide(free: free, needed: needed) == .proceed {
            deleteItem(item)
            return nil
        }
        return (needed, free ?? 0)
    }

    /// 回收站所在卷（预检比对基准；解析失败退回 home 卷）
    private var trashVolumePath: String {
        let url = paths.trashDir.standardizedFileURL
        if let v = try? url.resourceValues(forKeys: [.volumeURLKey]), let vol = v.volume {
            return vol.path
        }
        return FileManager.default.homeDirectoryForCurrentUser.path
    }

    /// 路径 → 卷（needed 计算的注入参数；解析失败按同卷处理——宁可少算不拦人）
    private func volumeOf(_ path: String) -> String? {
        let url = URL(fileURLWithPath: path).standardizedFileURL
        if let v = try? url.resourceValues(forKeys: [.volumeURLKey]), let vol = v.volume {
            return vol.path
        }
        return nil
    }

    /// 磁盘满时的直接删除（#1）：逐落点移除（symlink unlink / 实体递归删），不写 manifest、不进回收站；
    /// 操作日志尽力落（reversible:false），写失败如实记进回执。盘满时写越少越好（设计关键决策 3）。
    func deleteItemIrreversibly(_ item: InventoryItem) {
        let fm = FileManager.default
        var removed = 0
        var failures: [String] = []
        // #15（D36）：不可逆删除用同一份全量集合——否则磁盘满直删同样留下悬空 symlink，
        // 与回收站路径（deleteItem）各说各话
        for path in [item.sourcePath] + item.duplicates + index.mountStat(of: item.id).spots.map(\.path)
        where !path.contains("#") {
            // lstat 语义：实体、有效链接、悬空链接都尝试处理；已消失的落点不算失败
            guard Self.pathOccupied(path) else { continue }
            do {
                try writeLock.withLock { try fm.removeItem(atPath: path) }
                removed += 1
            } catch {
                failures.append("\(path)（\(error.localizedDescription)）")
            }
        }
        // 日志尽力落；写失败不假装落了（用例 E2），如实进回执
        var logFailed = false
        do {
            try opLog.append(LogRecord(actor: "智昊", actorKind: .human, action: .delete,
                                       detail: "磁盘满直接删除 \(item.name)（\(removed) 个落点；未入回收站，不可恢复）",
                                       target: item.id, reversible: false))
        } catch {
            logFailed = true
        }
        if failures.isEmpty {
            lastError = nil
            lastIrreversibleDeleteReceipt = IrreversibleDeleteReceipt(name: item.name, locations: removed,
                                                                      logFailed: logFailed)
            index.removeItem(id: item.id)
            objectWillChange.send()
            refreshRollback()
            rescan()
        } else {
            // 有落点没删成：如实报部分失败，行不摘（盘上还有它的落点，摘行等于撒谎）
            lastIrreversibleDeleteReceipt = nil
            lastError = "删除未完成：\(removed) 个落点已删除，\(failures.count) 个未能删除（\(failures.joined(separator: "、"))）"
        }
    }

    private static func pathOccupied(_ path: String) -> Bool {
        var st = stat()
        return lstat(path, &st) == 0
    }

    @Published var lastError: String?

    func restoreEntry(_ manifest: TrashManifest) {
        do {
            let outcome = try trash.restore(manifest)
            lastError = nil
            lastDeleteReceipt = nil          // 恢复是删除的后续，回执换成恢复结果
            lastRestoreOutcome = outcome      // G4：部分恢复由 UI 如实拆开展示
            refreshRollback()
            rescan()
        } catch {
            lastRestoreOutcome = nil
            lastError = "恢复失败：\(error.localizedDescription)"
        }
    }

    /// 有没有该上屏的写操作结果。RootView 的显示门只看这一个值——
    /// 再加一类回执时不必去改界面，免得又出现"状态有了、容器没出现"（D32=B 踩过）。
    var hasWriteOutcome: Bool {
        lastError != nil || lastRestoreOutcome != nil || lastReapplyOutcome != nil
            || lastDeleteReceipt != nil || lastIrreversibleDeleteReceipt != nil
    }

    /// 关掉写结果回执（Banner 唯一出口，不自动消失——数字要留给人看完）
    func dismissWriteOutcome() {
        lastError = nil
        lastRestoreOutcome = nil
        lastReapplyOutcome = nil
        lastDeleteReceipt = nil
        lastIrreversibleDeleteReceipt = nil
    }

    func refreshRollback() {
        logEntries = opLog.entries()
        trashEntries = trash.listEntries()
        refreshAssemblyEvents()
        loadItemChanges()
    }

    // MARK: - 装配事件 / 验收面

    func refreshAssemblyEvents() {
        assemblyEvents = assembly.eventStore.all().sorted { $0.event.date > $1.event.date }
    }

    /// 未验收事件（Banner 未验收态数据源）
    var pendingAssemblies: [StoredAssemblyEvent] {
        assemblyEvents.filter { !$0.accepted && !$0.restored }
    }

    func openDiff(_ id: String) {
        diffEventId = id
        diffStale = false
        diffSurfaceGone = false
        diffRebased = false
        refreshDiffStaleness()
    }

    var diffEvent: StoredAssemblyEvent? {
        diffEventId.flatMap { id in assemblyEvents.first { $0.event.id == id } }
    }

    /// G3：这次装配的结果在验收前又被改了 → 重载前禁用「关闭并验收」。
    ///
    /// 口径（2026-09-22 改，D15）：只比对**这次装配影响面内**的清单版本。
    /// 旧实现拿整盘条目 id 的哈希，于是别家 Agent 装了个东西、某个临时目录多出一列，
    /// 都会把这次验收锁住——真机上「清单已更新」几乎必然出现，人根本点不下去验收。
    /// 旧事件（revisionScope == nil）持的是全盘口径，与新口径不可比，
    /// 因此不再拿它锁人（宁可放行，也不要用一把永远解不开的锁）。
    ///
    /// `rebasing: true` 是"用户已经按了重新加载、看过当前清单"这一刻：
    /// 把基线刷成现在的版本，验收才有终点。不这么做的话，那句
    /// 「重新加载后再验收」就是张空头支票——影响面只要真的又变过一次（Agent 还在干活，
    /// 这是常态），历史快照永远比不过，按钮永久灰着。2026-09-23 真机撞上。
    ///
    /// 9①（2026-09-26）：`currentRevision(within:)` 要重建全清单索引（真机实测 2-5s），
    /// 挪进 `Task.detached(.userInitiated)`，主线程只留 stat 级的 `scopeStillPresent`。
    /// 生命周期：进入本函数先 `diffCheckGeneration += 1` 并置 `diffRevisionPending = true`，
    /// 后台结果回来先验代际，过期即弃；一轮检查只在开始/结束各发布一次（D16 口径，
    /// 不新增发布通道）。
    func refreshDiffStaleness(rebasing: Bool = false) {
        guard let e = diffEvent else { diffStale = false; diffSurfaceGone = false; diffRebased = false; diffRevisionPending = false; return }
        // D31（2026-09-23 ③a 首跑抓到）：已结案的事件没有"待验收"这回事，不该再被 G3 锁。
        // 恢复动作本身就会改变影响面（少一个落点），所以拿当前快照比历史快照永远对不上——
        // 于是「回看」一条已验收+已恢复的记录时，表头写着「清单已更新。重新加载后再验收」、
        // 按钮灰着，而这里根本没有需要验收的东西。更糟的是此时点「重新加载」会走 rebase，
        // 把一条已结案事件的 revision 改掉——rebase 的语义只属于"人看过现状后放行验收"那一步。
        if e.accepted || e.restored {
            diffStale = false; diffSurfaceGone = false; diffRebased = false; diffRevisionPending = false
            return
        }
        guard let scope = e.revisionScope, !scope.isEmpty else {
            diffStale = false; diffSurfaceGone = false; diffRebased = false; diffRevisionPending = false; return
        }
        // 先问"影响面还在不在"：整个项目被移走时，范围内的条目集合恒为空，
        // 拿它跟当年的快照比永远对不上——那不是"清单变了"，是"没有可比的对象了"。
        // （stat 级检查，留主线程。）
        guard AssemblyService.scopeStillPresent(scope) else {
            diffSurfaceGone = true
            diffRebased = false
            diffStale = false
            diffRevisionPending = false
            return
        }
        diffSurfaceGone = false
        diffRebased = false
        // 重活后台跑：建索引 + 算哈希。代际 +1，旧的后台结果一律作废。
        diffCheckGeneration += 1
        let myGen = diffCheckGeneration
        diffRevisionPending = true
        let scopeDirs = scope
        let wantRebase = rebasing
        let baseline = e.revision
        Task { @MainActor [weak self] in
            guard let service = self?.assembly else { return }
            let computed = await Task.detached(priority: .userInitiated) {
                service.currentRevision(within: scopeDirs)
            }.value
            guard let self, myGen == self.diffCheckGeneration else { return }   // 过期结果：直接丢弃
            self.diffRevisionPending = false
            if wantRebase, computed != baseline {
                try? self.assembly.eventStore.rebaseRevision(eventId: e.event.id, to: computed)
                self.refreshAssemblyEvents()          // 让 diffEvent 读到刷过的基线
                self.diffRebased = true
                self.diffStale = false
                return
            }
            self.diffStale = computed != baseline
        }
    }

    /// diff Sheet「重新加载」：先按已知位置重扫，扫完再比对快照。
    /// 旧写法是 rescan() 之后立刻 refreshDiffStaleness()——重扫是异步的，比对永远发生在
    /// 索引还没落定的一瞬间，于是「清单已更新」这条锁谁也解不开，人既不能验收也不能明确退出。
    func reloadDiff() {
        guard diffEventId != nil, !reloadingDiff else { return }
        reloadingDiff = true
        requestRescan(reason: .userAction)
        if !rescanning && scanPhase == .idle {
            // 扫描压根没起跑（未授权等）→ 当场比对，不让人干等一个不会来的回调
            finishDiffReload()
        }
    }

    /// 重扫落定后补一次快照比对（轻量重扫与三段式扫描共用）
    private func finishDiffReload() {
        guard reloadingDiff else { return }
        reloadingDiff = false
        refreshDiffStaleness(rebasing: true)
    }

    /// 关闭并验收（裁定①：关闭=默认接受）。
    /// #4：去掉 `try?` 吞错——失败时 Sheet 不关（可重试），错误走 lastError
    /// （全局 Banner 在 Sheet 底下看不见，diff Sheet footer 另有内联绑定）。
    func acceptDiff(_ id: String) {
        do {
            try assembly.eventStore.markReviewed(eventId: id)
            refreshAssemblyEvents()
            diffEventId = nil
        } catch {
            lastError = "验收失败：\(error.localizedDescription)——清单未记录这次验收，可重试"
        }
    }

    /// 全部恢复原状（显式动作）
    func restoreAssembly(_ event: AssemblyEvent) {
        do {
            let outcome = try assembly.restoreAssembly(event: event)
            lastError = nil
            lastRestoreOutcome = outcome      // 部分回挂失败同样要如实报
            refreshRollback()
            rescan()
        } catch {
            lastRestoreOutcome = nil
            lastError = "恢复失败：\(error.localizedDescription)"
        }
    }

    /// 撤销「全部恢复原状」＝按恢复时记下的目标重新挂回（D32=B）。
    /// 与恢复一样：先落盘、再落日志、界面如实拆部分态；不自动消失回执。
    func reapplyAssembly(eventId: String) {
        do {
            let outcome = try assembly.reapplyRestoredAssembly(eventId: eventId)
            lastError = nil
            lastRestoreOutcome = nil
            lastReapplyOutcome = outcome
            refreshAssemblyEvents()
            refreshRollback()
            rescan()
        } catch {
            lastReapplyOutcome = nil
            lastError = "重新挂回失败：\(error.localizedDescription)"
        }
    }

    /// 冲突行单条重试：对该项目重新 pull 该条目名（不红；仍失败则留痕）
    @discardableResult
    func retryConflict(landingPath: String, projectId: String, agent: String) -> Bool {
        guard let project = index.projects.first(where: { $0.id == projectId }) else { return false }
        let name = (landingPath as NSString).lastPathComponent
        if let r = try? assembly.pull(name: name, target: project.path, agent: agent),
           r.outcomes.contains(where: { if case .created = $0.status { return true }; return false }) {
            refreshAssemblyEvents()
            rescan()
            return true
        }
        refreshRollback()
        return false
    }

    // MARK: - 清单排序

    /// 点表头：同列翻转升降；换列时数量列默认降序（先看挂得最多的），名称列默认升序
    func toggleSort(_ key: InventorySortKey) {
        if sortKey == key {
            sortAscending.toggle()
        } else {
            sortKey = key
            sortAscending = key == .name
        }
    }

    // MARK: - 派生

    var selectedItem: InventoryItem? {
        selectedItemId.flatMap { index.item(id: $0) }
    }

    var showSkeleton: Bool {
        gatePhase == .scanning && scanClock == .early && index.items.isEmpty
    }

    var showIncrementalHint: Bool {
        index.isUpdating && scanClock == .hint
    }

    /// 设置页进度行（中性描述，不承诺剩余时间——全盘遍历耗时随磁盘内容变化）
    var scanPhaseText: String {
        if scanPhase == .idle && rescanning { return "正在按已知位置重扫…" }
        switch scanPhase {
        case .idle: return "扫描已完成"
        case .preparing: return "正在准备扫描…"
        case .quick: return "正在读取 home 内的 Agent 配置目录…"
        case .backfill: return "正在补齐项目级与其他位置…"
        case .discovering: return "正在全盘发现新的 skills 位置…"
        }
    }

    /// 任何扫描在跑（三段式或轻量重扫）——所有写入口与「重新扫描全盘」共用的忙碌判据
    var isScanning: Bool { scanPhase != .idle || rescanning }
}

extension Array {
    func chunked(into size: Int) -> [[Element]] {
        stride(from: 0, to: count, by: size).map { Array(self[$0..<Swift.min($0 + size, count)]) }
    }
}
