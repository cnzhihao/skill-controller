// tcc-spike.swift — 可丢弃侦查探针（Phase 0-2）
// 问题 1：非 sandbox 进程能否稳定读取 ~/.codex / ~/.claude / ~/.qwenworkcn 等点目录？
// 问题 2：FSEvents 能否监听这些点目录的变更？
// 判定：exit 0 = 两问都通过；任何一步失败则打印 errno 与失败点并 exit 1。

import Foundation

setvbuf(stdout, nil, _IOLBF, 0) // 行缓冲：崩溃前也能看到进度

var failures: [String] = []

// ── Part 1: 点目录读取 ────────────────────────────────────────────
let home = FileManager.default.homeDirectoryForCurrentUser
let probes: [String] = [
    ".codex", ".codex/skills", ".codex/config.toml",
    ".claude", ".claude/skills", ".claude.json",
    ".qwenworkcn", ".qwenworkcn/skills",
    ".agents", ".agents/skills",
]

print("== Part 1: dot-directory read (non-sandboxed) ==")
var readableDirs: [URL] = []
for rel in probes {
    let url = home.appendingPathComponent(rel)
    var isDir: ObjCBool = false
    guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else {
        print("  MISS  \(rel) (不存在)")
        continue
    }
    if isDir.boolValue {
        do {
            let entries = try FileManager.default.contentsOfDirectory(atPath: url.path)
            print("  OK    \(rel)  (\(entries.count) entries)")
            readableDirs.append(url)
        } catch {
            print("  FAIL  \(rel)  errno-ish: \(error)")
            failures.append("read \(rel): \(error)")
        }
    } else {
        // 文件探针：读首字节验证可读
        if let handle = FileHandle(forReadingAtPath: url.path) {
            _ = try? handle.read(upToCount: 1)
            try? handle.close()
            print("  OK    \(rel)  (file readable)")
        } else {
            print("  FAIL  \(rel)  (file unreadable)")
            failures.append("read-file \(rel)")
        }
    }
}

// ── Part 2: FSEvents 监听点目录 ──────────────────────────────────
print("== Part 2: FSEvents on dot-directory ==")
// 不污染用户数据：在 ~/.codex/skills 内创建探针临时目录，监听它，自造事件后清理。
let watchBase = home.appendingPathComponent(".codex/skills")
let probeDir = watchBase.appendingPathComponent(".tcc-spike-probe-\(getpid())")
let semaphore = DispatchSemaphore(value: 0)
var gotEvent = false

do {
    try FileManager.default.createDirectory(at: probeDir, withIntermediateDirectories: true)
} catch {
    print("  FAIL  cannot create probe dir: \(error)")
    exit(1)
}

final class Box { var stream: FSEventStreamRef? }
let box = Box()
let boxPtr = Unmanaged.passRetained(box).toOpaque()

var context = FSEventStreamContext(version: 0, info: boxPtr,
                                   retain: nil, release: nil, copyDescription: nil)
let pathsToWatch = [probeDir.path] as CFArray

let callback: FSEventStreamCallback = { _, _, numEvents, _, _, _ in
    print("  EVENT batch (\(numEvents))")
    gotEvent = numEvents > 0
    semaphore.signal()
}

guard let stream = FSEventStreamCreate(kCFAllocatorDefault, callback, &context,
                                       pathsToWatch, FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
                                       0.1,
                                       UInt32(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer)) else {
    print("  FAIL  FSEventStreamCreate returned nil")
    try? FileManager.default.removeItem(at: probeDir)
    exit(1)
}
box.stream = stream
FSEventStreamSetDispatchQueue(stream, DispatchQueue(label: "spike.fsevents"))
guard FSEventStreamStart(stream) else {
    print("  FAIL  FSEventStreamStart")
    exit(1)
}
print("  STREAM started on \(probeDir.path)")

// 触发一次文件事件，等待回调（最长 5s）
let f = probeDir.appendingPathComponent("probe.txt")
try? "x".write(to: f, atomically: true, encoding: .utf8)
print("  TRIGGER wrote \(f.path)")
let waitResult = semaphore.wait(timeout: .now() + 5)

FSEventStreamStop(stream)
FSEventStreamInvalidate(stream)
FSEventStreamRelease(stream)
try? FileManager.default.removeItem(at: probeDir)

if gotEvent {
    print("  OK    FSEvents received change event in dot-directory")
} else {
    print("  FAIL  no FSEvents event within 5s")
    failures.append("fsevents no event")
}

// ── 裁决 ─────────────────────────────────────────────────────────
print("== Verdict ==")
if failures.isEmpty {
    print("PASS: non-sandboxed read + FSEvents both work")
    exit(0)
} else {
    print("FAIL: \(failures)")
    exit(1)
}
