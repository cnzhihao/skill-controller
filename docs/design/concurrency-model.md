# 并发模型说明（持久化层）

> 作者：eng-designer · 2026-09-25 · 内部批次记录（前置批次）。
> 范围：**本工具数据目录内的持久化文件**——operation-log.jsonl、assembly-events.jsonl、发现缓存 snapshot、回收站 manifest。范围外的盘面（用户项目目录、Agent 目录）由三步齐 + 回收站纪律管辖（AGENTS.md 硬规则 8），不在本文。
> 状态：语义已定稿（eng-coder 按此实施 #6 三修）；文中代码锚点为 2026-09-25 现状。

## 1 · 锁的形状：全进程一把，嵌套安全

- 唯一跨进程互斥原语 = `WriteLock`（Sources/SkillControllerCore/WriteLock.swift）：进程内 NSRecursiveLock + 同一 fd 上的 flock（:110，fd 只开一次），默认超时 10s（:124）。
- **App 全进程共用一把**（真机死锁教训：删除走 TrashManager 持锁 → 写日志换一把锁 → 同一文件两个 fd 互相等死；AssemblyService.swift:243-245 注释即此裁决）。CLI 每进程一把。
- 嵌套语义：`withLock` 内部再调任何走同一把锁的写操作都安全（递归锁）；**禁止**在持锁期间调用可能再次 flock 的**另一把**锁实例。
- 推论：`AssemblyEventStore` / `OperationLog` / `TrashManager` / `AssemblyService` 的全部落盘方法必须经构造时注入的那一把锁（AppState.swift:153-156 的注入链是唯一装配点）。

## 2 · 读—改—写全程持锁（台账 #6a 的判据）

- 凡「读出文件内容 → 内存改 → 整体写回」的方法（事件存储 `update`，AssemblyService.swift:204-214 为现存反例），**读必须在锁内**。锁外读 = 读到旧快照，锁内写回时把并发方刚追加的行整体抹掉。
- 判据：方法体（含首行读）整体位于 `lock.withLock { }` 之内；纯追加类（`append`）与纯读类（`all()`）不受此条约束，但纯读方必须容忍「读到半行」。
- 改写不得引入「读锁—写锁」两段式（等于没锁）；也不得用「先拷贝再比较」替代（TOCTOU 同源）。

## 3 · 覆盖写一律 atomic（台账 #6a 同源）

- 整体重写类写入（JSONL 重写、快照 snapshot、settings）必须 `Data.write(to:options:.atomic)`（或等价临时文件+rename）：进程被杀/磁盘满时旧文件完整保留，坏只坏在追加层面，可由 §4 的口径兜住。
- 追加类写入（日志/事件 append）保持 FileHandle 追加；单行 ≤ 数 KB 的追加在 APFS 上视为实际原子（本文口径：不为此加 fsync）。

## 4 · 损坏行计数口径（不静默清除）

- JSONL 逐行解码失败的行 = **损坏行**。处置：**原样保留、计数上抛、绝不静默丢弃**——它可能是并发方写了一半的行，删掉它等于替别人销毁数据；等下一次该行的写方自愈或人工裁决。
- 计数随方法返回值交出（`RewriteStats{linesRead, eventsRewritten, corruptPreserved}`），调用方决定上不上屏；Core 不打印、不弹窗。
- 追加路径遇到文件末尾无换行符：补一个 `\n` 再追加（自愈），不计数。

## 5 · 锁超时如实上抛（台账 #6c 的判据）

- `WriteLock.LockError.timeout`（WriteLock.swift:120,173-174，人话已配）**不允许 `try?` 吞掉**。吞掉的后果：调用方以为缓存合并成功，实际什么都没写——「一处真相」变成「零处真相」。
- 分层上抛规则：能抛到用户可见回执层的（App 侧走 `lastError` Banner；CLI 侧进 `AssemblyReport.warning` 并进 reportJSON 的 `warning` 字段）就地抛；确无用户面的内部补偿路径（当前无此形状），如实写进当次操作日志，不假装成功。
- 同进程双实例互斥（第二把锁 = 同文件两个 fd）是合法的测试注入形状：用 `timeout: 0.1` 造超时，断言失败可见、数据未动。

## 6 · 回滚存档保留（台账 #6b 的判据）

- 回收站删除回滚（TrashManager.swift:134-141 `undoAll`）：**放不回去的落点存在时，整个 entryDir 必须保留**——manifest + files/ 是后续重试恢复的唯一凭据；无条件 `removeItem` 等于在失败路径上再销毁一次存档。
- 全部放回成功（leftovers 为空）才清 entryDir。部分失败时：`rollbackFailed` 照抛（既有行为），错误信息列全放不回的路径（既有行为，TrashManager.swift:188-189），entryDir 留待下一次 `restore` 或人工处理。
- `restore` 的 occupied 守卫（TrashManager.swift:106-109，lstat 语义）保证对残留 entryDir 的重试不覆盖原位新文件——这是「保留」安全的前提，不得削弱。

---

**Changelog**
- 2026-09-25 初稿：六节语义定稿（锁形状/全程持锁/atomic/损坏行/锁超时/存档保留），作为 #6 三修的唯一语义权威；实施后的验收判据在设计档 §5 #6 行。
