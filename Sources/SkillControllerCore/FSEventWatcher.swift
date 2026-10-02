// FSEventWatcher.swift — FSEvents 增量监听（spike 已验证：点目录可监听、事件正常送达）
// 变更 → 防抖 0.5s → 触发重扫回调。App 与 CLI 均可复用。

import Foundation
import CoreServices

public final class FSEventWatcher: @unchecked Sendable {
    private let queue = DispatchQueue(label: "skillcontroller.fsevents")
    private var stream: FSEventStreamRef?
    private var paths: [String] = []
    private let debounceInterval: TimeInterval
    private var debounceItem: DispatchWorkItem?
    private let onChange: @Sendable () -> Void

    public init(paths: [URL], debounce: TimeInterval = 0.5, onChange: @escaping @Sendable () -> Void) {
        self.paths = paths.map(\.path)
        self.debounceInterval = debounce
        self.onChange = onChange
    }

    deinit { stop() }

    public func start() {
        guard stream == nil, !paths.isEmpty else { return }
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil, release: nil, copyDescription: nil,
        )
        let pathsCF = paths as CFArray
        // spike 教训：回调第 4 位才是 eventPaths，第 5/6 位是 flags/ids 数组；路径经 context info 传回 self
        let cb: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            let watcher = Unmanaged<FSEventWatcher>.fromOpaque(info).takeUnretainedValue()
            watcher.scheduleRescan()
        }
        guard let s = FSEventStreamCreate(
            kCFAllocatorDefault, cb, &context, pathsCF,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.2,
            UInt32(kFSEventStreamCreateFlagNoDefer),
        ) else { return }
        FSEventStreamSetDispatchQueue(s, queue)
        guard FSEventStreamStart(s) else {
            FSEventStreamRelease(s)
            return
        }
        stream = s
    }

    public func stop() {
        guard let s = stream else { return }
        FSEventStreamStop(s)
        FSEventStreamInvalidate(s)
        FSEventStreamRelease(s)
        stream = nil
        debounceItem?.cancel()
    }

    /// 防抖：FSEvents 一轮变动会连发多次事件，合并为一次重扫
    fileprivate func scheduleRescan() {
        debounceItem?.cancel()
        let item = DispatchWorkItem { [onChange] in onChange() }
        debounceItem = item
        queue.asyncAfter(deadline: .now() + debounceInterval, execute: item)
    }
}

extension FSEventWatcher {
    /// 监听根清单（App 启动增量监听时唯一的数据来源；做成纯函数是为了能单测口径）
    ///
    /// 收录：
    /// - Skills 目录本身（Agent 挂/卸、CLI pull 都发生在这里，是必须实时的动作）
    /// - 本工具自己的数据目录（skillctl 写的 assembly-events.jsonl / operation-log.jsonl /
    ///   trash —— 不监听它，Agent 装配后 Banner 就只能等下一次别的事件）
    ///
    /// **故意不收录 MCP 配置文件的父目录**：FSEvents 的监听是递归的，
    /// `~/.codex` 这类目录一旦进监听根，它底下的会话日志（每秒在写）就会把回调变成风暴，
    /// 而一次重扫是秒级全量——等于用「实时 MCP」换来整屏抖动。
    /// MCP 的新鲜度改由「回到前台 + 清单页显式刷新」保证（AppState），不假装实时。
    public static func watchRoots(for locations: [ScanLocation], supportDir: URL) -> [URL] {
        var roots: [URL] = []
        var seen = Set<String>()
        func add(_ url: URL) {
            guard seen.insert(url.standardizedFileURL.path).inserted else { return }
            roots.append(url)
        }
        for loc in locations where loc.kind == .skillDirectory { add(loc.url) }
        add(supportDir)
        return roots
    }
}
