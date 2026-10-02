# 审计整改设计（2026-09-25 批 · 台账 #1-#9）

> 作者：eng-designer · 2026-09-25 · 内部批次记录（智昊五问裁决全落档）。
> 本批九条红牌 + 两份合同件的设计。全部裁决已拍，本文不复开裁决项。
> 持久化并发语义的唯一权威在 `docs/design/concurrency-model.md`（本文 #6 只写改法与该文档的章节对应）。文中代码锚点为 2026-09-25 现状（按仓库实际状态核对漂移）。

## 1 · 方案与理由（逐条）

### #1 磁盘满不可逆删除确认（edge G5 must，全应用唯一 destructive 豁免）

**决策**：预检式（替换流），不做「先写失败再升级」。智昊拍 A=按 PRD §6.4 原文做全量：预检可用空间 → 不足时升级确认（键入条目名）→ destructive 红第一次启用。预检式比「写入失败后补救」好：彻底避免半态——D14 已经证明三步齐不是原子的，能不进 `trash()` 就不进。

**交互规格（完整）**

- **预检时机**：详情栏现有删除确认框（DetailPanel.swift:167-179）里点「移入回收站」之后、任何磁盘写之前，同步执行（读卷可用空间，毫秒级）。
- **层级关系：替换，不是叠加**。预检充足 → 原流照旧（`deleteItem`）；预检不足 → 关闭普通确认框，呈现升级确认 Sheet。两框永不同屏（macOS 上 confirmationDialog 叠 sheet 不可靠）。普通确认框的文案一个字不动。
- **升级确认 Sheet**（新文件 `App/SkillController/IrreversibleDeleteSheet.swift`，锚定在 DetailPanel）：
  - 标题（16 semibold，中性色，**不红**）：`磁盘空间不足，该条目将无法恢复。确认仍要删除？`（edge error-disk-full copy_hint 原文）。
  - 事实行（12 muted，数字 `monospacedDigit()`）：`无法移入回收站，此删除不可恢复。需要约 <X> · 当前可用 <Y>`（X=预检算出的需要字节，Y=探测到的可用字节，人读格式）。
  - 键入行 label（12 muted）：`输入条目名「<name>」以确认`；TextField 精确比对 `input == item.name`（不 trim——文件名可以含空格）。
  - 按钮：`仍然删除`（`.foregroundStyle(Color.destructiveOnly)`，input 不等时 disabled）＋`取消`（`.keyboardShortcut(.cancelAction)`，Esc=取消整次删除，回到详情栏原状，不清 selectedItemId）。
- **destructive token 用法**：全应用唯一红 = `Color.destructiveOnly`（Theme.swift:21-23 单点约定）。本 Sheet 的「仍然删除」是它在产品面的**第一处使用**；标题与正文保持中性（只报总量不报风险——标题句如实陈述事实，无惊叹号）。不引入任何新颜色/新 token。

**预检判定口径**（新 Core 文件 `Sources/SkillControllerCore/DiskSpace.swift`）

- `needed = Σ(与回收站不同卷的实体落点字节数) + 1 MiB 元数据余量`。同卷实体是 move 不占新增空间；symlink 落点算 0；MCP 落点（`#`）不参与（见 #3，MCP 已无删除入口）。
- 判定 `DiskSpaceDecision.decide(free:needed:)`：`free < needed → .requireIrreversible`；`free ≥ needed → .proceed`；**探测失败（nil）→ .proceed**——探测不到不拦人，真失败由 D14 回滚 + 失败回执兜底。
- 卷可用空间用 `URLResourceKey.volumeAvailableCapacityForImportantUsageKey`。
- 落点体积遍历只发生在「跨卷实体」上（极少），同卷不遍历，避免大目录卡预检。

**写侧**：`AppState.deleteItemIrreversibly(item)`——逐落点移除（symlink unlink；实体 `removeItem` 递归），不写 manifest、不进回收站；操作日志落一条 `action=.delete`、`reversible:false`、detail 写明「磁盘满直接删除…（未入回收站，不可恢复）」，日志写失败则**如实**记进回执（不假装落了日志）。回执新字段 `lastIrreversibleDeleteReceipt`（name+locations），Banner 文案：`已直接删除 <N> 个落点（磁盘满，未入回收站）· 此操作不可恢复`。`hasWriteOutcome`（AppState.swift:652-654）与 `dismissWriteOutcome` 同步收编新字段——D32=B 的教训：加回执必须改显示门，一处计算属性收口。

**真机不可复现磁盘满的测试策略**

- Core 面（swift test）：`DiskSpaceDecision` 是纯函数，表驱动断言（见 §5 验收）。`needed` 计算把「路径→卷」的映射作为注入参数，测试用假映射造跨卷/同卷形状。
- App 面（真机验收）：`DiskSpaceProbe` 以注入点接入 AppState（默认 `.system` 实现）；**仅 `#if DEBUG`** 编译进 Debug build 的环境变量 `SKILLCTL_FAKE_FREE_BYTES=<n>` 替换探测值 → 真机走完整升级链路。Release 不含此分支。

### #2 permissionDenied 死分支：删除 + edge 改判（智昊拍 B）

- **代码**：删 `AppState.GatePhase.permissionDenied`（AppState.swift:22）；删 GateSheet.swift:35-52 整个 `if app.gatePhase == .permissionDenied` 块；GateSheet.swift:1-3 文件头注释重写为裁决陈述：非沙箱 App 读点目录无 TCC 门槛（Phase 0 spike 实证），该态无触发路径，已于 2026-09-25 裁决删除（**无效表达删除不留尸**，不写「原来如何」）。
- **edge 改判措辞**（`spark-output/edge/skill-controller.md:27`，整行替换为）：

  `| error-permission | 条件态（2026-09-25 裁决，智昊拍 B） | 触发条件当前不存在：非沙箱 App 读点目录无 TCC 门槛（Phase 0 spike 实证，docs/agent-recon.md），工具亦不读会话日志；将来进入沙箱或新增受系统权限保护的读取面时恢复 must，并按原规格实现（中性说明行 + 深链按钮 + 返回自动重试；文案「系统还没放行 · 在系统设置中允许后会自动重试」） | 不可达，无出口 | — |`

- **计数同步改（D3）**：edge.md:4 `状态：25（must 15 / should 7 / nice 3）` → `状态：25（must 14 / 条件态 1 / should 7 / nice 3；条件态=error-permission，2026-09-25 裁决改判）`。总 25 不变（态不删、降级为条件态）。
- **镜像**：`spark-output/context/edge.json:31-40` 同一 entry 加 `"required": false`、`"severity"` 保持字段但语义以 md 行为准，另加 `"adjudication": "2026-09-25 裁决：非沙箱无 TCC 门槛（docs/agent-recon.md spike），该态不可达；触发条件回归时恢复 must"`。
- PRD §6.1「系统层拒绝」GWT 与「must 15 态」原文不动（合同面，上抛见 §7「上抛项」①；26 vs 28 计数差异的承接见同处 ③）。

### #3 MCP 删除入口（智昊拍 A 堵入口）

- DetailPanel.swift:153-159：`item.type == .mcp` 时不渲染「删除」Button，只渲染 muted 提示行。
- actionHint（:329-332）MCP 分支现有文案**是一句假话**（「这里只能整体删除（走回收站）」——TrashManager.swift:91-93 剥掉 `#` 落点后必抛 nothingToDelete），整句替换为：

  `MCP 条目的删除属 story-6 写侧，尚未实现：配置项由各 Agent 按自己的格式写回，删除入口会随该能力一起提供。`

- Core 不动（trash 的 `#` 过滤是正确的 story-6 边界守卫）。新文案无 copy_hint 可依 → 上抛智昊过目（§7「上抛项」②）。

### #4 acceptDiff 吞错 + 无条件关 Sheet

- AppState.swift:762-766 重写：`do { try markReviewed; refreshAssemblyEvents(); diffEventId = nil } catch { lastError = "验收失败：<原因>——清单未记录这次验收，可重试"; /* diffEventId 不动 */ }`。
- **Sheet 不关**：失败时 diff Sheet 保持打开、可重试。因为全局 Banner 在 Sheet 底下看不见，AssemblyReview.swift footer（:410 起）加一行内联错误（绑 `app.lastError`，muted 中性，不红），Sheet 关闭后全局 Banner 仍按既有通道显示。不新增发布通道（D32=B 同一判据：`hasWriteOutcome` 已含 lastError，显示门不用改）。

### #5 mount 类型守卫 + 版本纪律

- AssemblyService.swift:393 守卫对齐 pull（:378）：`$0.name == name` → `$0.name == name && $0.type == .skill`。
- **诚实报错**：只加守卫会把「存在但不是 Skill」报成 notFound（另一种假话）。`AssemblyError`（:781-785）加 `case notASkill(name: String)`，mount 查到同名 `.mcp` 条目时抛它；main.swift 的 `describe(e)` 补人话：`「<name>」是 MCP 配置项，不是 Skill，mount 只支持 Skill`。
- **版本纪律（D34）**：CLI 进程内行为变了 → `Models.swift:25` `0.2.5` → `0.2.6`，Models.swift 头部补一行变更注（模式照 :22-23），**同一提交** bump + 按 README 重装 `skillctl`。
- 回归测试见 §5。

### #6 事件存储并发三修（前置：docs/design/concurrency-model.md 已落盘）

三处与该文档章节的对应（改法细节以文档为准绳）：

| 缺陷 | 锚点 | 改法 | concurrency-model.md 章节 |
| --- | --- | --- | --- |
| 6a update 读在锁外+整体重写丢并发追加 | AssemblyService.swift:204-214 | 读—改—写全程持锁；`.atomic` 写；损坏行原样保留并计数 | §2 全程持锁 · §3 atomic 写 · §4 损坏行口径 |
| 6b undoAll 无条件销毁存档 | TrashManager.swift:134-141 | `removeItem(entryDir)` 只在 `leftovers.isEmpty` 时执行；部分失败保留整个 entryDir（后续 `trash.restore` 可再试，occupied 守卫防重复放回） | §6 回滚存档保留 |
| 6c 缓存合并 `try?` 吞锁超时 | AssemblyService.swift:318-328 | `mergeLocationsIntoCache` 返回 warning String?；超时/失败不再静默，警告进 `AssemblyReport.warning`（新可选字段，默认 nil）；CLI reportJSON 输出 `"warning"`；App 侧 retryConflict 将 warning 落 `lastError`（Banner 如实上屏） | §5 锁超时如实上抛 |

6a 实现要点（给 coder 的坑位提示）：损坏行存在时 events 下标 ≠ 输出行下标，需维护 `events→out` 的下标映射；`update` 返回 `RewriteStats{linesRead, eventsRewritten, corruptPreserved}`（`@discardableResult`），存量调用方零改动，测试断言计数。锁超时测试用第二把 WriteLock 实例（同进程多 fd = 互斥，正是当年死锁的形状）+ `timeout: 0.1` 注入。

### #7 卫生件

- `.gitignore` 恢复为七类（git show 0041b4f:.gitignore）＋保留现存两条（`.build/`、`spark-output/collections/*.tsv`）：SwiftPM `.build/`、spike 二进制（docs/spike/tcc-spike、*.o）、`.DS_Store`、Xcode（xcuserdata/、DerivedData/）、本地构建产物（build/、`__pycache__/`、*.pyc）、出表趟 tsv。
- **护栏**：恢复后跑 `git status --short`——若发现 `build/` 下有**已被 track** 的文件，停下上报主代理（删除 tracked 文件需确认），本设计只授权「让忽略规则生效」。
- README.md:13 `33 单测` → 本次绿测实数（以批记录 §6 收口时的 `swift test` 通过数为准，预期 105+本批新增）。

### #8 两份合同件

**docs/test-report.md（表结构）**——列：`# | Story | GWT 要点 | 验证面 | 证据`。验证面取值：`swift test <文件>:<用例名>` ／ `真机验收 <日期>` ／ `CLI 实测 <命令+退出码>`。**无自动化测试的 GWT 逐条标「真机验收」**；未映射 = 未测（测试纪律原文）。

行清单（按 PRD §6.1-6.6 逐条清点，**共 28 条**——§1 写 26，按 D3 以本清单为准，差异上抛 §7「上抛项」③，承接=批记录 §1 追记已裁决 28 为准）：

- 6.1（6 条）：≤5s 可交互 ／ 副本×3 合并 ／ 系统层拒绝不白屏 ／ 降级横幅+忽略出口 ／ >3s 增量+40 字 truncate ／ 全盘 0 条目空态
- 6.2（6 条）：search→pull 落位落日志 ／ App 未开 Banner ／ 冲突行留痕+重试 ／ 快照过期禁验收 ／ 关闭=验收+显式恢复 ／ 0 增 0 删事实态
- 6.3（5 条）：unmount 生效集合减一 ／ 跨 Agent 授权拒绝 ／ 面板消失态 ／ 写回失败行内原因 ／ 状态原地更新
- 6.4（5 条）：删除→回收站→一步恢复 ／ Finder 清空灰态 ／ **磁盘满升级确认（→本批 #1）** ／ 部分恢复如实报 ／ 无变动空态
- 6.5（3 条）：账本起点说明 ／ 触发词重叠并列 ／ 全页零观点检查
- 6.6（3 条）：MCP 写回保格式+备份 ／ 同 server 两处并列 ／ JSON 非法中性态

映射策略：Core/CLI 面（合并模型、三维归属、回收站往返、并发双写、卸下口径、装配事件、基线）→ 对应 Tests/SkillControllerTests/ 现有用例名，实施时逐一 grep 核对；App 视图面（三栏清单、Banner 三态、diff Sheet、授权门、消失态、磁盘满对话框、挂载账、回退页动线）→「真机验收」+日期，其中 #1 行的证据 = DiskSpaceDecisionTests + DEBUG 注入真机链路两栏都填。`swift test` 不覆盖 App 侧是已知事实，如实标注不硬凑。

**docs/phase-3-notes.md（结构骨架）**：① 交付了什么（采集表 5 行 ／ README「Dogfooding 周计划」含 skillctl 元 Skill 安装）② 卡在哪里（无阻断；Phase 3 之后按合同停）③ 需要人裁决的事（story-3 全量、story-5 视图①③、story-6 写侧等 R1 回填后由人决定；D21/D23/P2.5 挂内部待办）④ 测试与验证快照（当期测试数、基准数字）⑤ 未做与诚实边界。内容只用既有进度事实，不新写历史。

### #9 性能三件（线程/生命周期设计；结果发布走既有 ScanPublishPolicy 代际口径，不新增发布通道）

- **9① diff revision 后台化**（AssemblyService.swift:599-601 + AppState.swift:706-759）：`scopeStillPresent`（stat 级）留主线程；`currentRevision(within:)` 挪进 `Task.detached(.userInitiated)`。生命周期：`diffCheckGeneration += 1` 于 openDiff / reloadDiff / 每次 refreshDiffStaleness 进入时，detached 结果回来先验代际，过期即弃（复用扫描代际守卫的同一形状）；新增 `@Published private(set) var diffRevisionPending`，一轮检查只发布两次（开始/结束），UI 据此禁用「关闭并验收」+「重新加载」并显 12px muted「正在比对清单…」（D16 教训：不许每 200ms 抖 @Published）。
- **9② 挂载账聚合收敛**（SidePages.swift:434-443）：`zeroMountSection` 改为收参函数，body 里 `let zeroAll = app.index.zeroMountItems(type: type)` **每次渲染恰好一次**，total = zeroAll.count；删掉 zeroItems 计算属性里的第二次全量过滤。语义零变化（D21 恒空集口径不动）。
- **9③ 全盘发现真取消**（AppState.swift:240-245）：根因是 `Task.detached` 的 `Task.isCancelled` 看的是**detached 自己**，外层 scanTask.cancel() 传不进去——44s 全盘遍历只能等它跑完。改法：detached 句柄存 `private var discoveryTask: Task<...>?`；`beginPass()`（:288，startScan 与 requestRescan 的唯一汇合点）里 `discoveryTask?.cancel()`；`shouldStop: { Task.isCancelled }` 原样保留——现在它真的会停。结果侧既有代际守卫（:246）继续兜底丢弃过期结果。

### 字号归一（Q5-A，随批实施）

token 四档 12/14/16/20。偏离清点（grep 实测 19 处，§1 记「约 20」）：`11`×4（DetailPanel.swift:81,278,298；AssemblyReview.swift:357）→ **12**；`13`×14（AssemblyReview.swift:56,116,145,148,214,290,301,312,319,389,398；InventoryView.swift:186,225,273）→ **14**；`28`×1（GateSheet.swift:14 图标）→ **20**。weight 修饰原样保留；不引入新 token，不改 960/360/520。App 侧 → 真机验收（960 窄窗 + 360 详情栏下逐屏过目；GateSheet 图标缩到 20 的观感一并过目）。

## 2 · 接口契约

- `DiskSpaceDecision.decide(free: Int64?, needed: Int64) -> Decision`（`.proceed` / `.requireIrreversible`）——纯函数，Sendable。
- `DiskSpaceProbe`：`freeBytes(volumePath: String) -> Int64?`；`.system` 默认实现；AppState 注入点（默认 `.system`）。
- `TrashSpaceEstimator.neededBytes(entityPaths: [String], trashVolume: String, volumeOf: (String) -> String?) -> Int64`。
- `AssemblyEventStore.update(eventId:_:) throws -> RewriteStats`（新返回值，`@discardableResult`，存量调用零改动）。
- `AssemblyReport.warning: String?`（默认 nil）；CLI reportJSON 非 nil 时输出 `"warning"`。
- `AssemblyError.notASkill(name: String)`；`describe` 人话见 #5。
- AppState 新增：`requestDelete(_:)`、`deleteItemIrreversibly(_:)`、`lastIrreversibleDeleteReceipt`、`diffRevisionPending`；`GatePhase` 减少 `permissionDenied`。

## 3 · 受影响文件清单（现行数 → 预期增量）

| 文件 | 现行数 | 增量 | 涉及 |
| --- | --- | --- | --- |
| App/SkillController/AppState.swift | 860 | +~90 / −1 | #1 #2 #4 #9① #9③ |
| App/SkillController/DetailPanel.swift | 405 | +~15 | #1 接线 #3 字号 |
| App/SkillController/IrreversibleDeleteSheet.swift | 新 | +~90 | #1 |
| App/SkillController/GateSheet.swift | 89 | −~20 | #2 |
| App/SkillController/AssemblyReview.swift | 499 | +~8 | #4 字号 |
| App/SkillController/InventoryView.swift | 732 | 0 | 字号 |
| App/SkillController/SidePages.swift | 653 | ±6 | #9② |
| Sources/SkillControllerCore/AssemblyService.swift | 786 | +~45 | #5 #6a #6c #9①字段无 |
| Sources/SkillControllerCore/TrashManager.swift | 300 | +~10 | #6b |
| Sources/SkillControllerCore/DiskSpace.swift | 新 | +~80 | #1 |
| Sources/SkillControllerCore/Models.swift | 181 | +2 | #5 版本 0.2.6 |
| Sources/skillctl/main.swift | 235 | +~5 | #5 describe #6c warning |
| Tests/SkillControllerTests/（现 18 文件 2446 行） | — | +4 新文件 ~230 / 改 2 文件 +~45 | #1 #5 #6 #9③ |
| docs/design/concurrency-model.md · test-report.md · phase-3-notes.md · 本设计档 | 新 | — | #6 #8 |
| spark-output/edge/skill-controller.md · context/edge.json | — | 2 行/1 entry | #2 |
| .gitignore（2→14 行）· README.md（1 行） | — | — | #7 |

AppState.swift 将近千行：本批不拆（改动内聚），拆分建议（写回执状态独立 ObservableObject）已落内部待办「审计批」节的观察项行，目标批次=下一同类批或独立小批（2026-09-26 裁决接受，防无限期挂起），不在本批。

## 4 · 关键决策记录（含否决项）

1. **#1 预检式（替换流）**，否决「trash 失败后再升级确认」——预检避免半态；探测失败不拦人，D14 回滚兜底。
2. **#1 升级确认与普通确认 = 替换关系**，否决双框叠加——macOS 呈现不可靠。
3. **#1 磁盘满直接删除**走「逐落点移除 + 尽力日志 + 如实回执」，否决「也写 manifest」——盘满时写越少越好。
4. **#2 删死分支 + edge 改判条件态**（智昊拍 B）；无效表达删除不留尸；计数 15→14+1 同步改。
5. **#3 堵入口不补删除闭环**（不越 story-6）；现有 actionHint 假话整句换掉。
6. **#5 加 `notASkill` 类型化报错**——只加守卫会把「存在但不是 Skill」谎报成 notFound；与 #5 缺陷同源（mount 撒谎），随批修。
7. **#6 先立 docs/design/concurrency-model.md 再动代码**（裁决前置）；损坏行**原样保留不静默清除**。
8. **#9① 后台化而非"算快一点"**——2-5s 的活不可能变快，只能离开主线程；代际守卫防过期结果回写。
9. **#9③ 取消传进 detached**（存句柄 + beginPass 单点取消），否决"改结构化并发"——三段式编排已定型，改动面最小且真解决。
10. 字号映射 11→12 / 13→14 / 28→20，weight 不动。

## 5 · 验收判据（机器可查，逐条对台账）

| 台账 | 判据（命令 / 断言 / 可点击路径） |
| --- | --- |
| #1 | ① `swift test` 含 DiskSpaceDecisionTests：free<needed→requireIrreversible、free≥needed→proceed、free=nil→proceed、跨卷实体计入 needed（DiskSpace 决策+估算两组用例；跨卷实体断言归 Estimator 组）② node 行扫 `App/**/*.swift`：`destructiveOnly` 仅出现于 Theme.swift 与 IrreversibleDeleteSheet.swift ③ 真机（DEBUG `SKILLCTL_FAKE_FREE_BYTES=0`）：删除→普通确认→升级 Sheet；键错名按钮禁用、键对名启用；确认后落点消失、回收站无新条目、回执上屏；Esc/取消路径磁盘零变化 ④ edge must 台账 error-disk-full 打勾 |
| #2 | ① node 行扫 App/ Sources/ Tests/：`permissionDenied` 0 命中 ② `swift build` 绿（枚举删成员的编译期保证）③ edge.md 行内容与 :4 计数行=node 扫描可验（「must 14 / 条件态 1」且 error-permission 行含「条件态（2026-09-25 裁决」）④ 真机：授权门只有「授权并扫描 / 这次先不」两出口 |
| #3 | ① 真机：选中任一 MCP 条目，动作区无「删除」按钮、提示行文案如上；选中 Skill 条目按钮仍在 ② node 行扫 DetailPanel.swift：删除按钮在 `item.type == .mcp` 分支不可达（代码走查点）③ 现有 105 测试零回归 |
| #4 | ① node 行扫 AppState.swift acceptDiff 函数体：无 `try?` ② 真机：正常验收 Sheet 关、Banner 转已验收（回归）；AssemblyReview footer 含 lastError 内联绑定（代码走查点）③ 失败路径无自动化（App 侧），test-report 如实标「代码断言+成功路径真机」 |
| #5 | ① AssemblyServiceTests 新增：mount MCP 名抛 `.notASkill`、mount Skill 名成功（2 断言）② Models.swift 版本字面量 `0.2.6`（node 扫描）③ 按 README 重装后 `skillctl mount <mcp名> --on codex` 退出码 69 且 error 字段含「MCP 配置项」④ bump 与守卫同一提交 |
| #6 | ① EventStoreConcurrencyTests：损坏行重写后逐字节保留、RewriteStats 计数正确、先 append 后 update 无丢失、第二把锁超时→warning 非空且缓存未动 ② TrashRollbackTests 新增：占位制造 restore 失败→rollbackFailed 且 entryDir 仍在（含失败落点文件）；成功路径 entryDir 已清 ③ docs/design/concurrency-model.md 存在且 §2/§3/§4/§5/§6 覆盖三修语义（本表三行引用的章节号与其标题一致）④ 真机：retryConflict 触发 warning 时 Banner 出现（可注入场景缺失则如实标代码断言） |
| #7 | ① `git check-ignore build .build DerivedData docs/spike/tcc-spike` 各返回路径 ② `git status --short` 无 build/ 条目（若出现 tracked → 停下上报，见 #7 护栏）③ node 扫 README 第 13 行数字 == 当次 `swift test` 通过数 ④ .gitignore 七类齐全（node 逐类扫描） |
| #8 | ① test-report.md 行数=28（node 扫描表行形态 `^\|\s*\d+ \| 6\.`，与 §8 表结构对齐）且逐行有验证面与证据列 ② 无自动化测试且**非条件态**的行含「真机验收」字样；条件态行（6.1「系统层拒绝不白屏」）证据列标「条件态·不可达（2026-09-25 裁决，见 edge error-permission 行）」，不作走查要求 ③ phase-3-notes.md 五节骨架齐全 ④ 两文件在 docs/ 目录（测试纪律合同路径） |
| #9 | ① 9②：node 行扫 SidePages.swift `zeroMountItems` 出现次数 ≤1 ② 9③：DiscoveryCancellationTests（确定性中途取消路径：每目录同步点注入或 shouldStop 恒 true；断言提前返回、dirsVisited<全量，不依赖真实 cancel 恰落遍历中途）③ 9①：真机验收——开 diff 后窗口可拖动/可滚动、无 beachball；diffRevisionPending 期间两按钮禁用 ④ ScanPublishPolicyTests 及全部 105 存量测试零回归 |
| 字号 | node 扫 `App/**/*.swift`：`.system(size: N)` 中 N ∉ {12,14,16,20} 命中 0 处；真机逐屏过目（960/360） |

全局：`swift test` 全绿（105 存量 + 新增约 10）；`xcodebuild -scheme SkillController build` 绿；#5 重装后 CLI 冒烟（search 一条）正常。

## 6 · 用例表（normal / boundary / error）

| 用例 | 输入 | 期望 |
| --- | --- | --- |
| N1 预检充足删除 | 磁盘余量大，删一个 Skill | 普通确认→入回收站→回执「已移入回收站」（现行为不变） |
| N2 预检不足→键入确认 | 注入 free=0，删一个 Skill | 升级 Sheet；键对名→直接删除；日志一条 reversible:false |
| B1 键入近似名 | 名称含空格/大小写不同 | 按钮保持禁用（精确比对） |
| B2 同卷大条目 | 实体与回收站同卷 | needed 只含 1MiB 余量，正常流 |
| E1 探测失败 | probe 返回 nil | 正常流放行；若 trash 真失败→D14 回滚+失败回执 |
| E2 满盘时日志也写不进 | 注入 free=0 且日志写入失败 | 回执如实含「操作日志未能记录」，不假装落了日志 |
| E3 验收时写锁超时 | acceptDiff 遇 timeout | Sheet 不关，footer 内联错误，重试可成 |
| E4 挂载账零挂载搜索 | 视图② 输入查询 | 单次聚合后本地过滤，行为同今 |
| E5 发现阶段取消 | 段 3 在跑时开新一轮扫描/重扫 | discoveryTask 被取消，旧结果被代际守卫丢弃，新轮照常 |

## 7 · 边界（本批不做）

- 不重开五问已裁决项；不做 backlog 附录 🔵 项与 #10 口径差异排查；🟡 loadItemChanges 默认不折叠。
- 不越 story-6：MCP 只堵入口，不做任何 MCP 写侧实现。
- 不引入新视觉 token、不改 960/360/520、不加后台常驻、零网络。
- PRD 合同原文不改（#2 的 edge 两文件属审计整改授权内）。

**上抛项（本批不做，逐条承接落点）**

| 上抛 | 内容 | 承接落点 |
| --- | --- | --- |
| ① | #2 合同面回填：PRD §6.1「系统层拒绝」GWT 行与「must 15 态」计数随 edge 改判加裁决回填注（口径：must 14 + 条件态 1） | 内部待办审计批节（主代理在 #2 落地后落笔，需求档写域） |
| ② | 新拟文案过目（无 copy_hint 可依）：#1 事实行/键入行/回执行、#3 MCP 提示行、#4 失败回执句（「验收失败：<原因>…可重试」）、#5 describe 人话句（「…是 MCP 配置项，不是 Skill，mount 只支持 Skill」）、#6c warning 文案（mergeLocationsIntoCache 锁超时警告）、9①「正在比对清单…」 | 批记录 §4 已裁决：先行落地，交付通知时逐条列出供智昊事后过目 |
| ③ | 26 vs 28 GWT 计数差异 | 批记录 §1 追记已裁决（2026-09-26 主 agent 清点 28 为准）；此处留档备查 |
| ④ | 超过 500 行硬上限文件的拆分观察项（AppState/AssemblyService/InventoryView/SidePages，目标批次=下一同类批或独立小批） | 内部待办审计批节观察项行（已落） |
- 不为 #4/#6c 的失败路径造生产注入开关（DEBUG 探针仅 #1 一处，且仅 Debug build）。

## 8 · UI/交互决策落定（无 open 项）

#1 全交互规格见 §1（预检时机/替换层级/键入交互/destructive 用法/回执文案）；#2 授权门两出口不变；#3 MCP 动作区 = 无按钮 + 一句中性提示；#4 footer 内联错误行（muted）；#9① diff 检查期间按钮禁用 + 12px muted「正在比对清单…」。新拟文案八处（无 copy_hint 可依）：#1 事实行/键入行/回执行、#3 MCP 提示行、#4 失败回执句、#5 describe 人话句、#6c warning 文案、9①「正在比对清单…」→ 全部列入 §7「上抛项」② 上抛智昊过目（#1 标题用 edge copy_hint 原文，无需过目）。

---

**Changelog**
- 2026-09-25 初稿：台账 #1-#9 + 字号归一设计落盘；并发语义权威收在 docs/design/concurrency-model.md；GWT 清点 28 条与批记录 §1 的 26 不一致，按清点为准并上抛。
- 2026-09-26 fix：设计评审 10 条 advisory 逐条点修——§7 增设「上抛项」承接表并补入四处新拟文案（#4 失败回执句/#5 describe 人话句/#6c warning 文案/9①「正在比对清单…」）、AC #8① 扫描模式改为表行形态正则、AC #8② 加「非条件态」限定并给条件态行显式处置、并发权威文档引用统一为 docs/design/concurrency-model.md、AC #9② 补确定性取消路径措辞、AC #6③ 自检清单补 §3、AC #1① 改为 DiskSpace 决策+估算两组用例、§3 观察项行落内部待办审计批节并给目标批次、头部补锚点新鲜度声明。
