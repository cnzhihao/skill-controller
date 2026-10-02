# 审计批复盘设计（2026-09-26 批 · 台账 #12-#16）

> 作者：eng-designer · 2026-09-26 · 内部批次记录（智昊 20:12 拍「批，选 A」）。
> 本批五条 = 台账 #12-#16（D36/D37/D39/D40/D41，即 D36-D41 除 D38；S8/S10/S11/S12/S13 证据）。编号口径（2026-09-26 fix 轮统一，以台账为准）：内部走查登记表为 D36-D40，其表内 D40=回收站归档缺失（=台账 D41），台账 D40=清单滞后（S11）。核心主题：**失败态/缺失态/滞后态没有如实呈现**（G7「按钮不撒谎」家族），外加一条扫描取消出口缺失（PRD §6.8 强制标准，spark-output/prd/skill-controller.md:222）。
> 持久化并发语义唯一权威在 docs/design/concurrency-model.md（本批动锁路径均按其章节执行）；前批设计结构与既有机制（IrreversibleDeleteSheet / hasWriteOutcome / ScanPublishPolicy / removeItem 模式）见 docs/design/audit-remediation-design.md。
> 文中代码锚点为 2026-09-26 现状（本轮逐处实读核对，非沿用批记录转述）。事件 schema 只增不改不删；旧事件文件必须可解码（D15 先例）。

## 1 · 方案与理由（逐条）

### #12（D37）CLI 写失败被 App 呈成 0/0/0 no-op

**缺陷现场**：`finishAssembly`（AssemblyService.swift:589-622）把 outcomes 分成三组——`ok`（仅 `.created`）、`addedPaths`/`removedPaths`、`conflicts`（仅 `.skippedConflict`）。`.failed` outcome 被整体丢弃：只读目录下 `skillctl pull` 全失败时，事件 added/removed/conflicts 全空，落盘的 StoredAssemblyEvent 没有任何失败痕迹。App 端 AssemblyReview.swift:170（Banner `.empty` 判定）与 :356（diff 空态判定）只看三组 → 渲染成「检查过了，没带来新东西」（:180、:357）——把「两次写入都失败」说成「检查过了，没带来新东西」，G7 级撒谎。CLI 侧 reportJSON 完整含 outcomes（main.swift:203-229，`failed` label 已有），坏的是事件文件与 App 呈现。

**改法**：

1. **事件 schema 加可选失败数组，落在 `StoredAssemblyEvent`**（定义在 AssemblyService.swift:114-149，与 revisionScope/restoredLinks/restoredCopies 同层）：

   ```swift
   /// 写失败的落点（路径 + 原因）。可选：旧事件没这个字段，缺省/nil = 旧事件（D15 同款兼容）。
   /// 不放 AssemblyEvent：那是 types.ts 1:1 模型（字段不许增删改）；
   /// App 侧持久化扩展字段的既有位置就是 Stored 层（D15 revisionScope / D32 restoredLinks 先例）。
   public var failed: [AssemblyConflict]?
   ```

   init 补 `failed: [AssemblyConflict]? = nil` 尾参，存量调用零改动。`AssemblyEvent`（Models.swift:133-154）一个字段不动。

2. **finishAssembly 归组**（AssemblyService.swift:590-596 一带）：在 conflicts 之后加：

   ```swift
   let failed = outcomes.compactMap { o -> AssemblyConflict? in
       guard case .failed(let why) = o.status else { return nil }
       return AssemblyConflict(itemId: o.path, reason: why)
   }
   ```

   注意：`.failed` 的原因在枚举关联值里，`o.reason` 对 failed 恒为 nil（AssemblyService.swift:525 现状）——从关联值取，不取 `o.reason`。事件构造点（:617-619）把 `failed: failed.isEmpty ? nil : failed` 传入（空数组也存 nil，省得旧事件与新事件形状无谓分叉）。

3. **操作日志与 itemIds 如实**（:611-614）：detail 尾注 `"（挂上 N · 卸下 N · 跳过 N）"` 在 failed 非空时追加 `" · 失败 F"`；`itemIds` 追加 failed 路径——回退页/详情栏「挂载变动」按落点路径命中日志（D3 口径），失败条目的变动史必须查得到。

4. **App 呈现**（AssemblyReview.swift）：
   - Banner 状态判定（:170）：`.empty` 条件改为三组全空 **且** `(stored.failed ?? []).isEmpty`。pending 文案（:181-184）：在既有「跳过 C 项冲突」段之外，failed 非空时拼「失败 F 项」——两者都有则「（跳过 C 项冲突 · 失败 F 项）」。全失败事件呈 pending 态（它确实需要人看，不是 no-op）。
   - diff Sheet：content（:352-358）在 conflictsGroup 之后加 `failedGroup`——`Label("失败 F 项（未写入盘）", systemImage: "xmark")`，`foregroundStyle(Color.scMutedForeground)`（中性 muted，不红——硬规则「destructive 红全应用唯一豁免=磁盘满」，失败态属 muted 中性系）；每行 = 落点名 + reason（12/14 号 token，与 conflictsGroup 卡片同形）。**不挂「重试这一项」**：conflicts 的重试语义是「占位移开后重挂」（:409-415 走 retryConflict mount 路径），失败的成因（权限/IO）与动作（可能该 unmount）都不同，摆一个照抄的重试按钮是又一个撒谎按钮。空态判定（:356）同步加 failed 空判据。
   - 待验收清单行（:217）：「挂上 N · 卸下 N · 跳过 N」后按非空拼「 · 失败 F」。
5. **CLI reportJSON 不动**（outcomes 本来就全）；`skillctl events`（main.swift:168 起）读 all() 对新字段自动透传。
6. **版本纪律（D34）**：finishAssembly 是 CLI 进程内行为 → Models.swift:26 `0.2.6` → `0.2.7`，Models.swift 头部补一行变更注（模式照 :24），同一提交 bump + 按 README 重装。前向兼容：旧 App 读新事件 = synthesized Codable 忽略未知键，解码不炸。

### #13（D40）CLI 卸下后清单滞后到重启

**缺陷现场**：FSEvents 到达 → `requestRescan(.fileEvent)`（AppState.swift:512），但三段式在跑时 :533-535 把它**排队**（`rescanQueued = true; return`）——排队等到的是整轮全盘扫描收尾（本机 40s+），S11 走查因此看到「扫描期间 UI 仍显示旧 2 处」。轻量重扫本身是秒级，堵点全在忙时段。

**改法（定向行更新，扩展 removeItem 既有模式；信任锚 = 自家 CLI 写的事件文件）**：

- skillctl 每次装配（含 unmount）都落 assembly-events.jsonl，且本工具数据目录在 FSEvents 监听根里（FSEventWatcher.swift:88 `add(supportDir)`）。事件的 added/removed 是**我们自己工具写下的落点路径事实**——与 `InventoryIndex.removeItem`「只用于我们自己刚做完写操作」（InventoryIndex.swift:219 注释）同一信任级别，不是拿猜测改索引。
- **FSEventWatcher 一行不改**：回调今天丢弃变更路径，不必为此加路径捕获新机制——触发器用「事件文件有了新行」即可，事实内容从事件文件拿。
- AppState：
  - 新增 `private var appliedLandingEventId: String?`（已反映进索引的最新事件 id）。初始化时置为当前最新事件 id（存量历史早已反映在盘上，不回放）。
  - `requestRescan`（:528）在忙碌判定**之前**调 `applyLandingFacts()`：读事件存储（AppState 既有 AssemblyEventStore，#6 注入链），取 marker 之后的新事件，聚合 added/removed 路径，调 `index.applyLandingFacts(added:removed:home:)`（新 Core 方法，见接口契约），然后无论成败把 marker 推进到最新事件 id（定向更新是加速器，权威兜底永远是后面的重扫）。任何原因的 requestRescan 都先跑这一步：幂等、毫秒级（事件文件十几行）。
- Core（InventoryIndex.swift）：新增 `applyLandingFacts(added:[String], removed:[String], home: URL) -> Bool`：
  - 只对**文件系统落点**动手：含 `#` 的 MCP 路径跳过（MCP 呈现由扫描管线管）。
  - removed：找到 sourcePath/duplicates 含该路径的条目 → 从 duplicates 摘除（unmount 只摘链接——removeLandings 对实体一律 refused，AssemblyService.swift:528-531，所以 removed 恒为 symlink 落点）→ 单条目重derive MountStat。
  - added：条目已在索引（pull 的源必来自全集）→ 路径不在 duplicates 则加入 → 单条目重derive。条目找不到 = 盘面已被别的操作改变 → 跳过该路径（重扫兜底）。
  - **单条目重derive 必须放 Core、与 rebuild 的 `spots(for:)`（InventoryIndex.swift:189-210）同文件同源**：kind 判定（link→symlink / 源→entitySource / 其余→entityCopy）+ agentId/level/projectId 走 LocationClassifier 同一张读侧表；不许在 App 层抄第二份口径（两份表不一致就是 D19 的成因）。整体规则偏离时，下一轮全量重扫是权威校正。
  - 返回是否有变化；App 侧有变化才 `objectWillChange.send()`（与 removeItem 同款，AppState.swift:653）。
- **与 D16 的相容性（专门说明）**：ScanPublishPolicy 管的是**一轮 pass 的结果发布时机**（收尾一次发布）；本条是 removeItem 家族的**写后即时行更新**——App 自己的删除/恢复早就这么干（AppState.swift:652、:728），从不在 pass 管线里走。且 CLI unmount 摘不掉实体源（refused），条目**整行**不会消失、只有行内计数变——D16 那个「详情栏条目消失→确认框被系统作废」的形状在本路径上不可达。不新增发布通道、不碰 `publish(generation:)`。

**已知边界（2026-09-26 fix 轮 2 登记：advisor 实施评审轮 1 🟡#2，实施者判为设计层口径缺口上抛；实现语义不动，处置待智昊裁）**
- **触发形状**：`added` 落点位于 pull 现场新建的 skills 目录（如新项目 `<project>/.agents/skills/`）。该目录经 D35 已被 CLI 写进发现缓存，但不在 App 内存的位置清单 `lastDiscovered`（AppState.swift:167）里——发现缓存只在冷启动 startScan 装载（AppState.swift:243-246），轻量重扫的位置清单取自内存 `lastDiscovered`（:580）。
- **缺陷表现**：applyLandingFacts 先行把 added 落点就地并进条目（本身正确、毫秒级）；随后任何一次按旧位置清单的 rebuild + 发布（轻量重扫收尾，或在跑全盘 pass 的收尾发布——累积器同源于 `lastDiscovered`/缓存）都会把不在清单里的新目录漏扫，刚并进的落点从索引回滚掉。
- **影响面**：仅 added 侧的新目录场景；存量项目（目录已在 `lastDiscovered`）与 S11 主场景（removed 侧）不受影响。有界过期：下次全盘扫描自愈——段 3 全盘发现把新目录并进位置清单（AppState.swift:287-288），冷启动也会装载已含该目录的 D35 缓存。
- **处置选项**：a) applyLandingFacts 命中索引外新增落点时，把落点所属 skills 目录同步 merge 进 `lastDiscovered`（App 层一处；D35「CLI 与 App 同一份真相」原则的 App 侧补全）；b) 接受有界过期、靠全盘扫描自愈（现状）；c) requestRescan 改读发现缓存而非内存清单（动重扫范围语义，改动大）。
- **工程判断**：a 是正确修法——与 D35 同构（CLI 侧已把新目录写进缓存，App 内存清单补同一格即可），一处改动、不碰扫描管线与发布时机；落地前 b 可接受（有界、自愈，页头与重扫口径一致，无撒谎数字）。按本批禁止范围**不实现**，作下批候补登记（§10⑦）。

### #14（D41）回收站归档缺失时恢复按钮仍可用

**缺陷现场**：`isRestorable`（TrashManager.swift:213-220）对实体落点只 `fileExists(storedRelativePath 壳)`——归档**内容**被移走、空壳还在时照样返回 true；S12 真机：移走归档内容后「恢复」仍可点、无「目标已不在回收站」提示（SidePages.swift:599-608 的禁用分支没进）。symlink 落点只查 manifest.json 存在——这是**对的**（链接重建只凭 manifest 里记的 linkTarget，不依赖归档内容），保持不动。

**改法**：

1. `isRestorable` 实体落点降层检查：壳存在之外，用 `FileManager.enumerator(atPath:)` 验 `entryDir/storedRelativePath` 下**非空内容**（第一个对象存在即可，短路枚举，不做全量遍历）；空壳 → false。symlink 落点维持 manifest 检查不变。
2. `restore()` 同口径守卫（TrashManager.swift:235-245 一带）：实体落点的 stored 目录为空壳时，该落点记 failed「归档内容缺失」进 RestoreOutcome（G4 部分失败如实报）——否则按钮禁用了、API 层还是会把空壳「恢复成功」搬回原位，isRestorable 在 API 层撒谎。
3. **快照重判时机评估（结论：够，补一处 onAppear）**：
   - isRestorable 是**渲染时逐行现算**（SidePages.swift:591），不是快照缓存——真正缺的是重渲染触发器。
   - 回收站在 supportDir 内（监听根，FSEventWatcher.swift:88）→ 外部清空回收站会触发 fileEvent → 轻量重扫收尾 `refreshRollback()`（AppState.swift:561）重读 trashEntries → 重渲染时新判据生效。三条链路（FSEvents、写操作后 refreshRollback、每个 pass 收尾）都已存在。
   - 补：RollbackView 加 `.onAppear { app.refreshRollback() }`——页面冷进入时（监听尚未起、或事件竞态窗口内）也强制重读一次，把「进页面看到的是上次快照」的窗口关死。
   - 判定与点击之间的竞态（看完按钮再被外部清空）：由 restore 的空壳 failed + 既有 targetVanished（TrashManager.swift:228-229）兜底，不为它加锁。

### #15（D36）整体删除不卸全部 Agent symlink 落点——**方案已落定：选 A（2026-09-26 20:12，批记录 §4③）**

**缺陷现场**：`trash()` 的 `allPaths = [sourcePath] + duplicates`（TrashManager.swift:90），而「挂载」的真相是 MountStat.spots——symlink 落点不在 duplicates 里（duplicates 只收物理副本），于是确认框承诺「各 Agent 的挂载将同时卸下」（DetailPanel.swift:189）只对索引内物理落点兑现，symlink 全部留下悬空（S13/S12 证据：manifest 只含实体源 1 项）。不可逆删除路径同病：`deleteItemIrreversibly` 也遍历 `[sourcePath] + duplicates`（AppState.swift:705），磁盘满直删同样留下悬空 symlink。

**改法（选 A：重算全量落点并入删除清单）**：

1. TrashManager.trash 加参：`trash(item:actor:additionalPaths: [String] = [])`——allPaths = `[sourcePath] + duplicates + additionalPaths` 去重；既有 `contains("#")` 过滤、逐路径 symlink/实体分流（:156-180）、D14 全有或全无回滚（:121-152）、并发模型 §6 存档保留——全部原样复用，symlink 落点进 `links/` 记 linkTarget，恢复时重建（restore 的 isSymlink 分支现成）。
2. App 侧两处调用点传入同一份全量落点：`app.index.mountStat(of: item.id).spots.map(\.path)`（索引早就知道这些 symlink——详情栏「挂载 N 次」就是它算的，数据现成，零新扫描）。落点：`deleteItem`（AppState.swift:645）与 `requestDelete` 的体积预检（:671-673，TrashSpaceEstimator 对 symlink 算 0 字节，并入无害且口径一致）与 `deleteItemIrreversibly`（:705 改用同一集合）。
3. 确认框文案**一字不动**（DetailPanel.swift:189）——选 A 的前提就是兑现承诺而非改口。删除回执的落点数自动变真（DeleteReceipt.locations = manifest.locations.count）。
4. 恢复分母随之变全（S13 的「1/1 只证明实体源」翻转）：恢复后两处项目 symlink 复原、磁盘 diff 为空。

**登记的实现细节（2026-09-26 fix 轮 2 回填：实施期发现并已修复的必现缺陷，eng-coder 上抛、本设计师登记）**：perform 循环的落点存在性检查必须用 **lstat 语义**（TrashManager.swift:111-115 `occupied`、:157-163），不能用跟随链接的 `fileExists`——additionalPaths 并入后，指向实体源的 symlink 落点排在实体源之后，实体先搬走、链接随即悬空，`fileExists` 对悬空链接返回 false → 链接被**静默跳过**、manifest 漏记，「各 Agent 的挂载将同时卸下」就只兑现一半（新增测试 additionalPathsLandInManifest 在修复前首跑即红，测试实证必要）。lstat 语义的确切含义：悬空链接也算存在（盘面事实：挂过就是挂过，C3「悬空 symlink 破例保留」同口径），照卸并记 linkTarget；lstat 都不存在的路径才跳过——已消失的落点不算失败。本条不改选 A 的行为语义，是「删得全」的正确实现。

### #16（D39）全盘重扫无用户取消出口

**缺陷现场**：设置页忙态按钮 `disabled(app.isScanning)`（SidePages.swift:32），重复点击与 ⌘⇧R 均不能停；`beginPass` 的 shouldStop/detached 取消通道（9③，AppState.swift:307-315）只有「新一轮 pass 接管」这一个触发者，用户没有触发点。PRD :222「长任务可取消」为强制标准。

**改法（协作取消：Task.isCancelled 检查点 + 尾部清理不发布）**：

1. AppState 新增 `cancelScan()`：`scanTask?.cancel(); rescanTask?.cancel(); discoveryTask?.cancel()`（discoveryTask 是 detached 句柄，父任务 cancel 传不进去，必须显式——9③ 已存句柄）。**不 bump scanGeneration**（代际号语义是「新 pass 接管」，见关键决策 6）。
2. 轻量重扫 Task 落句柄：requestRescan 的匿名 `Task { }`（:542-546）存进 `private var rescanTask: Task<Void, Never>?`。
3. 两条尾部的取消归位（这是本条的成败处——取消后忙碌态必须干净退出）：
   - `finishRescan`（:549-572）：publish 之前加 `if Task.isCancelled { stopTicker 已在函数头；index.setUpdating(false); refreshRollback(); finishDiffReload(); return }`——**不发布半截累积器**（累积器是暂存，展示索引从未被拆，D16 的保障原样成立）。非取消路径一字不动。
   - `startScan` 尾段（:289-300）：`guard myGen == self.scanGeneration else { return }` 之后、publish 之前加同款 `if Task.isCancelled` 分支：stopTicker、`scanPhase = .idle`、`gatePhase = .idle`、`index.setUpdating(false)`、startWatching()、finishDiffReload()、rescanQueued 照旧结转，**不 publish**。
     清单保持上一版全量：冷启动被取消时停在点停前已发布的最后一批、不再增长；首批发布前点停 = 留空——两种都是用户显式选择的结果，「重新扫描全盘」立即可用。
   - diff 等待链不受害：取消时索引仍持上一版全量，`finishDiffReload()` 照常交代「重新加载」的等待（G3 不会锁死）。
4. **取消感知点清单（2026-09-26 实读 AppState.swift 定位：管线中途轮询点全部现成、复用零新增；本条唯一新增代码 = 第 3 条的两条尾部归位分支）**：
   - 段边界：startScan Task 内 AppState.swift:234（发现来源落定后）、:247（段 2 入口）、:253（段 3 入口）三处既有 `!Task.isCancelled` / 代际 guard——cancelScan 后后续段立即短路；
   - 位置循环 tick：AppState.swift:419 scan() chunk 循环顶 `if Task.isCancelled || generation != scanGeneration { return }`——每 120 处位置（D16 批大小）轮询一次，是取消的真正停机点；点击时在飞的一个 detached chunk（:421-423）自然跑完，循环顶随即退出。
     冷启动逐批路径下这一批照既有 :435 增量发布一次（单调增长、不回缩），已有一版全量时零中途发布——两种都停在点停那一刻的进度，不继续推进；
   - 全盘发现段：AppState.swift:261 `shouldStop: { Task.isCancelled }`（审计批 #9③ 既有通道）——discoveryTask 被 cancelScan 显式 cancel 后逐批停；
   - 轻量重扫：requestRescan 的 Task（:542-546）单段直达 scan()，取消感知同落在 :419 + finishRescan 尾部。
   - AC① 的 5s 判据由此按构造达成：点击后最迟一个在飞 chunk（~120 处位置，秒级）+ 尾部归位，不存在「扫到收尾才感知取消」的形状。
5. UI（SidePages.swift:21-36）：忙态时同一按钮变 **「停止扫描」**——enabled、`.buttonStyle(.bordered)` 原样式、无 opacity 禁用标识（它必须可点）；action 分流 `app.isScanning ? app.cancelScan() : app.rescanFullDiskFromScratch()`。⌘⇧R 快捷键随按钮走：忙时 ⌘⇧R = 取消（按钮即语义，不另设键）。**Esc/⌘. 不引入**（任务指定遵循既有交互惯例，批记录 §1 已定）。
   取消回执 = 转圈消失、按钮复原、数字停在上一版（无「索引持续更新中」残留——`index.setUpdating(false)` 已归位）；不加「已停止」新文案（上一版全量 + 无更新标注 = 事实，不拿文案复述）。
6. **与 D16 的相容性（专门说明）**：取消路径**零发布**——ScanPublishPolicy 的「收尾一次发布」语义未动（那条规则的成立前提是 pass 自己走完，收尾发布的是磁盘事实；被取消的 pass 没有收尾事实可发布，发布半截累积器反而正是 D16 要防的「拆了再拼回去」）。代际号未动、发布函数未动、policy 文件未动；ScanPublishPolicyTests 零改动。

## 2 · #15 方案选择专节（已落定：选 A —— 2026-09-26 20:12 批记录 §4③，主代理代行确认依据=批记录 §4 授权口径②）

**选择：A——重算全量落点并入删除清单**（B = 改文案认领边界，否决）。

理由：

1. **承诺即合同**：确认框「各 Agent 的挂载将同时卸下」是 PRD/flow 面写定的产品行为（story-4 GWT 家族），不是本批可以顺手改口的文案。改 B 要动合同面（6.4 删除语义 + copy_hint），比改代码重，且方向是「把承诺做小」。
2. **数据现成**：索引的 MountStat.spots 本来就含全部 symlink 落点（详情栏「挂载 N 次」「项目 N 个」就是它算的）——兑现承诺不需要新扫描、新发现逻辑，只是把已经算出来的事实交给 trash()。
3. **G4/G7 全链受益**：删除回执、manifest、恢复分母（S13 抱怨的「1/1 只证明实体源」）、不可逆删除路径（:705）四处一次对齐到同一份事实；B 方案下这四处继续各自说各自的话。
4. 风险可控：新增落点全部走既有 symlink 分流（只删链接不碰源，C3 红线不破）、D14 回滚与并发模型 §6 存档保留原样覆盖；恢复用 manifest 里的 linkTarget 重建（既有能力，D32=B 验证过）。

**决策记录（2026-09-26 20:12 落定，批记录 §4③）**：选 A 生效，删除的副作用从「索引内物理落点进回收站」扩为「全部已知挂载落点一并卸下（链接只删链接本体、源不动，实体与副本进回收站）」——行为变真、文案不变。B 退路（决策语境保留）：若智昊事后改判 B（缩承诺），代码改动退为 DetailPanel.swift:189 一句改写 + 文案过目，其余四条不受影响。

## 3 · 接口契约

- `StoredAssemblyEvent.failed: [AssemblyConflict]?`（默认 nil；nil/缺省 = 旧事件；空失败组也存 nil）。
- `TrashManager.trash(item:actor:additionalPaths: [String] = []) throws -> TrashManifest`（尾参默认值，存量调用零改动）。
- `InventoryIndex.applyLandingFacts(added: [String], removed: [String], home: URL) -> Bool`（返回有无变化；`#` 路径跳过；未知条目跳过）。
- `home` 参数释义 = 当前用户主目录。取值来源：调用侧 `FileManager.default.homeDirectoryForCurrentUser`，与扫描管线 AppState.swift:444/:539 同源。
  用途：单条目重derive 时 LocationClassifier.classify / relativeComponents(of:to:)（ScopeDiscovery.swift:435-469、:513）判定层级与归属的锚点（home 内相对段判用户级、.git 祖先判项目级）——必须与扫描期同一取值，否则重derive 出的 level/agentId 与 rebuild 的 spots(for:) 口径分叉（两份口径 = D19 的成因）。
- `InventoryIndex` 内部：单条目 MountStat 重derive（与 `spots(for:)` 同文件同源，私有）。
- `AppState.cancelScan()`；`AppState.rescanTask: Task<Void, Never>?`（私有存储）；`AppState.appliedLandingEventId: String?`（私有）。
- `RollbackView.onAppear → app.refreshRollback()`。
- 版本：`SkillControllerVersion.string = "0.2.7"`（Models.swift，同一提交 bump + 按 README 重装）。

## 4 · 受影响文件清单（现行数 → 预期增量）

| 文件 | 现行数 | 增量 | 涉及 |
| --- | --- | --- | --- |
| App/SkillController/AppState.swift | 1001 | +~55 | #13 applyLandingFacts 接线 / #16 cancelScan + rescanTask 句柄 + 两处尾部取消分支 |
| App/SkillController/AssemblyReview.swift | 532 | +~35 | #12 Banner 判定与文案 / failedGroup / 清单行 / 空态判定 |
| App/SkillController/SidePages.swift | 652 | +~20 | #14 onAppear / #16 停止扫描按钮分流 |
| App/SkillController/DetailPanel.swift | 431 | 0 | #15 确认框文案一字不动（选 A 的验收点之一） |
| Sources/SkillControllerCore/AssemblyService.swift | 869 | +~12 | #12 StoredAssemblyEvent.failed 字段 + finishAssembly 归组 + 日志 detail/itemIds |
| Sources/SkillControllerCore/InventoryIndex.swift | 408 | +~50 | #13 applyLandingFacts + 单条目重derive |
| Sources/SkillControllerCore/TrashManager.swift | 306 | +~30 | #14 isRestorable 降检 + restore 空壳守卫 / #15 additionalPaths |
| Sources/SkillControllerCore/Models.swift | 183 | +2 | #12 版本 0.2.7 + 头部变更注 |
| Sources/skillctl/main.swift | 239 | 0 | #12 reportJSON 已含 outcomes（不改） |
| Sources/SkillControllerCore/FSEventWatcher.swift | 92 | 0 | #13 明确不改（触发器用既有 supportDir 监听） |
| Tests/SkillControllerTests/AssemblyEventFailedGroupTests.swift | 新 | +~80 | #12（含旧事件解码兼容，D15 同款） |
| Tests/SkillControllerTests/LandingFactsTests.swift | 新 | +~70 | #13 |
| Tests/SkillControllerTests/TrashRollbackTests.swift | 现有 | +~70 | #14 #15 |
| docs/design/audit-retro-design.md · 批记录 §2 | — | — | 本档 |

AppState.swift（1001）、AssemblyService.swift（869）、InventoryView（732）、SidePages（652）均已越 500 行上限：本批改动内聚不拆（与前批同一裁决），拆分观察项已在内部待办挂账（写回执独立 ObservableObject / 事件存储与装配服务职责切分），本批增量继续记入该观察项；建议排近期拆分窗口（三个文件每批增量都在涨）。

## 5 · 关键决策记录（含否决项）

1. **#12 failed 数组放 StoredAssemblyEvent，不放 AssemblyEvent**——types.ts 1:1 数据模型是合同（字段不许增删改）；App 侧持久化扩展字段的既有位置就是 Stored 层（D15 revisionScope / D32 restoredLinks 两个先例）。否决「复用 conflicts 数组加前缀区分」——冲突（占位跳过，可重试）与失败（写入未发生）语义不同，混装让「跳过 N」这个数字撒谎。
2. **#12 失败组不给重试按钮**——conflicts 的重试语义（占位移开后重挂）对失败不成立；照抄一个必然语义错位的按钮 = 又一个撒谎按钮（G7）。
3. **#12 只收 `.failed`，`.refused` 不并入**（任务书指定形状）——refused-only unmount 仍会呈 0/0/0 no-op，属同族缺陷，本批不顺手扩容语义，上抛智昊裁（见上抛项 ③）。
4. **#13 信任锚 = 自家事件文件，否决「FSEventWatcher 捕获变更路径做单目录重扫」**——watcher 回调今天丢弃路径，加捕获是新机制；单目录重扫仍要过 scanner 管线、忙时照样被 :533 排队，堵不住 S11 的实际症状。事件文件已在监听根内，零新机制、毫秒级、幂等。
5. **#13 定向更新不整行摘除**——unmount 摘不掉实体源（refused），条目恒在、只变行内计数，D16「详情栏条目消失→模态作废」形状在本路径不可达（见 §1 #13 相容性说明）。
6. **#16 协作取消，否决「bump scanGeneration」**——代际号 = 「新 pass 接管」，bump 会让在跑 pass 在 :289/:554 的代际守卫处跳过尾部归位，scanPhase/gatePhase 卡忙碌永久死（这正是 D20 修「裸 return 丢事件」时守住的同一条尾巴）。也否决「只换按钮 label 不接取消」——那就是又一个撒谎按钮。
7. **#16 取消零发布**——被取消的 pass 没有「磁盘事实」可发布，发半截累积器 = D16 的病根本尊。清单停在上一版全量。
8. **#15 选 A**（理由与确认点见 §2 专节）。
9. **#14 深检只对实体落点**——symlink 落点的恢复凭据是 manifest 里的 linkTarget，不依赖归档内容；给它加内容检查反而会把「本来能恢复」判成不能（另一种撒谎）。
10. **版本 0.2.7**——finishAssembly 是 CLI 进程内行为（D34 纪律：改 CLI 行为必须同一次提交 bump + 重装）。

## 6 · 验收判据（机器可查，逐条对台账）

| 台账 | 判据（命令 / 断言 / 可点击路径） |
| --- | --- |
| #12 | ① `swift test` 含 AssemblyEventFailedGroupTests：无 `failed` 键的旧事件 JSON 行解码成功且 `failed == nil`（D15 同款）；含 failed 行 encode→decode roundtrip 相等；finishAssembly(全 `.failed` outcomes) → stored.failed 计数正确、added/removed 空、日志 detail 含「失败 N」且 itemIds 含失败路径 ② node 行扫 AssemblyReview.swift：「检查过了，没带来新东西」的可达条件含 failed 空判据（代码走查点：:170 与 :356 两处判定）③ 真机：只读目标目录 `skillctl pull`（S10 同形状）→ Banner 显「失败 N 项」且不出现 no-op 文案；diff 出现失败组逐行原因 ④ Models.swift 版本字面量 `0.2.7`（node 扫描）+ 同一提交 bump ⑤ 存量测试零回归 |
| #13 | ① `swift test` 含 LandingFactsTests：removed symlink 落点 → duplicates 减一、mountedBy/totals 重算、幂等重放零变化、`#` 路径与未知条目 no-op；added 对称 ② 真机：⌘⇧R 全盘重扫进行中 `skillctl unmount --on <agent> <name>` → 约 2s 内行内「挂载 N 次/项目 N 个」回落，不等扫描收尾、不重启（S11 翻转）③ 同场页头数字全程无缩水（D16 回归点）④ ScanPublishPolicyTests 及存量测试零回归 |
| #14 | ① `swift test`（TrashRollbackTests 扩展）：实体归档内容清空 → isRestorable false；内容在 → true；纯 symlink + manifest 在 → true；manifest.json 缺 → false；空壳 restore → 该落点 failed「归档内容缺失」且 outcome 如实 ② 真机：回退页在场时外部移走归档内容 → FSEvents 落定后按钮禁用 + 「目标已不在回收站，无法恢复」（S12 翻转）；回退页冷进入（onAppear）同样判准 |
| #15 | ① `swift test`（TrashRollbackTests 扩展）：实体源 + 物理副本 + symlink 落点（additionalPaths 传入）→ manifest.locations == 3；restore 后磁盘 diff 为空、symlink 按 linkTarget 重建；D14 回滚覆盖新增落点 ② 真机双落点夹具（S13 原夹具）：删除回执落点数 = 全量、manifest 含两处项目 symlink、恢复后链接复原且源未伤 ③ node 行扫 DetailPanel.swift:189：确认框原句「各 Agent 的挂载将同时卸下」仍逐字在案（该行命中即过） ④ `deleteItemIrreversibly` 用同一全量集合（代码走查点：AppState.swift:705 一带不再只遍历 duplicates） |
| #16 | ① 真机：⌘⇧R 全盘重扫进行至 ~5s 点「停止扫描」→ 点击后 2s 内转圈消失（构造上限 = 一个在飞 120 处 chunk + 尾部归位，见 §1 #16 第 4 条）、按钮复原为「重新扫描全盘」、页头数字全程无缩水、无「索引持续更新中」残留；随后 ⌘R 轻量重扫与 FSEvents 均正常（机器不中毒）；轻量重扫进行中取消同理。
     冷启动取消同判（用例 B2：gate 回 idle、清单停在点停前已发布部分不再增长（先于首批发布取消 = 留空）、按钮立即可用、无残留忙态） ② node 行扫 SidePages.swift 忙态分支：停止按钮无 `.disabled` ③ 代码走查：两条尾部的 publish 调用点被 `Task.isCancelled` 守卫包住；cancelScan 显式 cancel discoveryTask；rescanTask 句柄已存 ④ ScanPublishPolicyTests 零改动零回归 |

全局：`swift test` 全绿（当期存量 + 本批新增约 8-10 例）；`xcodebuild -scheme SkillController build` 绿；#12 重装后 CLI 冒烟（search + 一次只读 pull 失败路径看 reportJSON）正常。

## 7 · 用例表（normal / boundary / error）

| 用例 | 输入 | 期望 |
| --- | --- | --- |
| N1 部分失败装配 | 2 落点 1 成 1 败的 pull | 事件 added=1、failed=1；Banner「装配了 1 项（失败 1 项）」；diff 两组都渲染 |
| N2 正常卸下 | 空闲时 CLI unmount | 行为同今（秒级轻量重扫兜底），定向更新先行不冲突 |
| N3 删除三落点条目 | 实体源 + 副本 + symlink | 回执 3 落点；manifest 3 项；恢复后磁盘 diff 空 |
| B1 旧事件文件 | 既有 assembly-events.jsonl 原样 | 全部解码成功、failed==nil、Banner/diff 呈现与今一致 |
| B2 冷启动取消 | 首屏扫描中点停止 | gate 回 idle、清单停在点停前最后一批已发布结果（先于首批发布取消 = 留空）、重扫按钮立即可用、无残留忙态 |
| B3 回收站竞态 | 判定后、点击前外部清空 | restore 报 failed「归档内容缺失」/ targetVanished，不假装成功 |
| E1 全失败装配 | 只读目录 pull（S10 形状） | 事件 failed 全量；Banner/diff 如实；日志 detail「失败 N」；CLI 退出码 69 不变 |
| E2 忙时卸下 | 全盘重扫中 CLI unmount | ~2s 行内计数回落；页头不缩水；扫描照常收尾 |
| E3 扫描中取消 | 全盘重扫 5s 时点停止 | 见 #16 AC ①；diff 若在等待重新加载则照常交代（G3 不锁死） |
| E4 事件条目已被删 | removed 路径无属主条目 | 定向更新跳过该路径，marker 照常推进，重扫兜底 |

## 8 · 边界（本批不做）

- 不碰 D38（主代理复测定性，批记录 §1 已载）；不动 PRD/AGENTS/edge 合同原文。
- 事件 schema 只增不改不删：不加 `refused` 组、不改既有字段语义（refused-only 形状上抛，见关键决策 3）。
- 不引入新发布通道；ScanPublishPolicy 口径与其测试不动。
- FSEventWatcher 不改（不加路径捕获）；不新增键盘取消（Esc/⌘. 不引入）。
- 不做 backlog 项与 500 行文件拆分（观察项已在内部待办）。
- 零网络、零遥测、零观点；不引入新色值/新 token（失败组用既有 muted 系）。

## 9 · UI/交互决策落定（无 open 项）

#12 Banner pending 文案拼接规则 + diff 失败组（muted、无重试按钮、与 conflicts 卡片同形）；#13 无新 UI（既有行内计数即时回落）；#14 复用既有禁用文案「目标已不在回收站，无法恢复」（SidePages.swift:600 原句，copy_hint 已存在）；#15 确认框文案不变；#16 设置页按钮忙态变「停止扫描」（可点、原样式、⌘⇧R 随按钮）。**新拟文案两处**（无 copy_hint 可依 → 上抛过目）：① Banner/清单行的「失败 N 项」段；② diff 失败组标题「失败 F 项（未写入盘）」。失败原因行照抄 CLI outcome reason（既有 CLI 文案，非新拟）。

## 10 · 上抛项（本批不做/需人裁，逐条承接落点）

| # | 内容 | 承接落点 |
| --- | --- | --- |
| ① | **#15 方案 A 已落定**（2026-09-26 20:12 批记录 §4③，主代理代行确认依据=§4 授权口径②；§2 专节：行为变真、文案不变，B 退路留作决策语境） | 批记录 §4③（已确认在案，无待办） |
| ② | 新拟文案两处过目（「失败 N 项」段 / 「失败 F 项（未写入盘）」标题） | 批记录 §4，先行落地事后过目（前批同一模式） |
| ③ | refused-only unmount 的 0/0/0 no-op 形状（D19 拒绝语义 + D37 呈现缺口的交点）：是否给 refused 开组/文案，智昊裁 | 内部待办审计批复盘节，本批不动 |
| ④ | 版本 0.2.7 bump + 按 README 重装（纪律动作，随 #12 实施） | 批记录 §5 实施记录 |
| ⑤ | 文档面收口：内部走查发现表状态行、test-report.md S8/S10/S11/S12/S13 复测行回填 | 主代理，批记录 §6 |
| ⑥ | AppState 再 +~55 行，500 行拆分观察项继续挂账 | 内部待办既有观察项行 |
| ⑦ | #13 已知边界（§1 #13）的下批候补：选项 a——applyLandingFacts 命中索引外新增落点时，把所属 skills 目录同步 merge 进 `lastDiscovered`（工程判断=正确修法，与 D35 同构）；落地前维持 b（现状自愈） | 智昊裁决 → 下一批设计/实施；本批零代码改动 |

---

**Changelog**
- 2026-09-26 初稿：台账 #12-#16 五条设计落盘；#15 选 A（重算全量落点）专节交智昊确认；#12 failed 数组落 StoredAssemblyEvent（1:1 模型不动，D15 同款兼容）；#13 事件文件驱动定向行更新（D16 相容性说明在案）；#16 协作取消零发布。锚点为 2026-09-26 现状。
- 2026-09-26 fix 轮（评审轮 1 pass · 7 条 advisory 全部点修）：
  ① #15 裁决状态对齐（§1 #15 标题/§2 专节标题/§10① 改记「已落定 2026-09-26 20:12 批记录 §4③」，B 退路留作决策语境）② §3 补 applyLandingFacts 的 home 释义（取值来源 + 用途，实读 ScopeDiscovery/InventoryIndex 定位）。
  ③ #16 写明取消感知点清单（实读 AppState.swift：段边界 :234/:247/:253、chunk tick :419、发现段 shouldStop :261 全部现成复用、零新增插入）并校准 AC①/用例 B2/冷启动留空表述与机制自洽。
  ④ 删「Esc/⌘. 不引入」重复句（括注合并）⑤ D 编号统一（header/§10⑤ 对齐台账，#14=D41；内部表内 D40=台账 D41 的差拍已注明）。
  ⑥ AC 补全（#16 ①含 B2 断言、#15 ③改「各 Agent 的挂载将同时卸下」逐字行扫判据）⑦ §4 挂账句补「建议排近期拆分窗口」。
  五条机制本体与验收判据实质语义未动。
- 2026-09-26 fix 轮 2（实施完成后的文档面收尾，承接批记录 §5 轮次 2 上抛①③）：§1 #15 补「登记的实现细节」——perform 循环 lstat 判存语义与理由（悬空 symlink 必须可处理=盘面事实；锚点 TrashManager.swift:111-115/:157-163），该句既有锚点 :151-170/:137-146 对齐实施后现状（:156-180/:121-152）；§1 #13 补「已知边界」小节（新目录 added 落点被 rebuild 回滚：触发形状/影响面/自愈路径/三处置选项+工程判断）+ §10⑦ 下批候补登记。五条机制描述实质未动、零代码改动；批记录 §5 上抛汇总①③ 各补已回填/已登记结论。
