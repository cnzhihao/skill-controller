# PRD — 本地 Skill 管理工具（Skill 控制器）

- **方向**：文件管理器 + Agent 接口（含 MCP 对象，挂载账做暗线）
- **生成时间**：2026-09-19
- **数据源**：frame / brief / stories / sitemap / flow-web / check / edge（7 个上游 Skill）
- **完整度**：strong
- **交付对象**：实现本 App 的工程师 / coding agent（SwiftUI 原生 macOS）

---

## 1. Summary（60 秒版）

「Skill 控制器」是一个 **SwiftUI 原生的 macOS 本地应用**：打开即呈现全盘 Skill 与 MCP 配置的完整清单（按 Agent × 用户级/项目级 × 具体项目三维归属），但**人只看不管**——一切挂载、卸除、装配、瘦身动作通过 `skillctl` CLI 外包给各 Agent 自己完成。它服务的唯一用户是智昊（设计师、重度多 Agent 用户，本机散落近千个 Skill），做的理由是他的 Agent 正在因为上下文里塞了几百个用不到的 Skill 而肉眼可见地变笨，而市面所有管理工具都把"人"当操作员、打开是空面板。成功的最硬指标：**90 天内每个 Agent 的实际挂载集降到 50 以下，新项目的技能装配从半天手工重装变成 Agent 一条命令**。全部数据留在本机，无云端、无网络请求、工具本体零观点。

---

## 2. Background & Problem

**问题（用户视角）**：智昊的电脑上，每个 Agent（Codex / Claude Code / QoderWork / Cursor…）启动时都会无差别加载用户级技能目录里的全部内容——近 1000 个 Skill。Agent 因此变笨（上下文稀释是主损失，他亲眼常见）、触发词互相打架导致错误命中、用户级 Skill 漏挂进项目造成层级错位。

**当前 workaround**：靠记忆翻文件夹、跑 `find` 定位某个 Skill 在哪；每开一个新项目就把用得到的 Skill 全量重装一遍；偶尔手动删但不敢多删——因为没有任何"谁用过什么"的记录。已有的管理工具（skills-manager、skill-cli、skillshare、HarnessKit 等）全部要求人当操作员、首次打开是空面板，被他明确否决（"一看就烦死了"）。

**为什么是现在**：Skill 生态在 2026 年爆发到个人机器千级规模，多 Agent 并存成为重度用户的常态，稀释从隐性成本变成每天可感知的生产力损失；同时所有现存工具押的都是"同步/分发/面板"，"按项目装配、挂载可观测、使用频次账本"三个空白无人认领。

**本 PRD 故意不解决的**：① Skill 的**调用级**追踪（文件层观测不到"装载后被调用"，已裁定工具拿不到的信息不做）；② hooks / MCP 之外的其他配置对象（rules、memory、AGENTS.md）管理——MCP 在本版作为第二类对象，其余仅预留清单文件类型；③ 团队协作 / 云同步 / 分发市场。

---

## 3. Personas & User Segments

**Primary persona（全链路唯一用户）**

```
姓名：智昊
身份：设计师，重度多 Agent 用户（Codex / Claude Code / QoderWork / Cursor 并行使用）
情境：多个 Agent 无差别全量加载用户级近千 Skill；新开项目需要重装一套技能
JTBD：当开新项目或日常使用各个 Agent 时，智昊想通过打开即满的全盘清单看清所有
      Skill、并让每个 Agent 经 CLI 按业务场景自动装配对的集合，从而 Agent 保持
      最小高信号技能集、自己从维护者降级为观察者。
当前 workaround：翻文件夹 / 跑 find / 新项目全量重装 / 不敢删
痛点：上下文稀释变笨（主）、触发词错命中、层级错位漏挂、重型面板与空启动
"完成"的定义：打开即见全盘清单；人只看不管；Agent 自装自管；一切文件级可回滚
```

**Secondary persona**：不适用（只给自己用，无买家/使用者分离）。

**这个产品不为谁做**：不做多 Agent 团队共享场景、不做 Windows/Linux、不做"想要推荐引擎帮我看什么该删"的用户——那类需求被"零观点"口径明确排除。

---

## 4. Goals & Success Metrics

**产品目标**（outcome-framed）：让每个 Agent 在任何时刻只加载对的 Skill 集合，且这件事不由人来管。

| 指标 | 度量什么用户行为 | 目标值 | 时间窗 |
| --- | --- | --- | --- |
| primary · 最小挂载 | 各 Agent 当前生效集合的条目数（清单直接可读） | 每 Agent < 50 | 90 天 |
| primary · 装配时间 | 新项目从空白到配齐技能，人的实际耗时 | 半天 → 0（一条 CLI 命令） | 上线即测 |
| secondary · 瘦身 | 用户级技能目录条目数 | 近千 → ≤一半 | 30 天 |
| health · 可回滚 | 误操作后经回收站/日志恢复的成功率 | 100%（失败必留日志可重试） | 持续 |
| health · 冷启动 | App 打开到首版清单可交互 | ≤ 5s | 每次启动 |

**Anti-metrics（明确反着优化）**：
- ❌ 不优化"用户在 App 内停留时长 / 打开频次"——这个工具的理想状态是**用户几乎不来**，只让 Agent 走 CLI；
- ❌ 不优化"清理条目数"这类代办式指标——工具零观点，不鼓励也不惩罚任何删除决策；
- ❌ 不做任何评分/推荐点击率——存在即误导。

**关键假设（⚠️ 全产品命门）**：**Agent 通过 `skillctl` CLI 自主装配/管理 Skill 集合是靠谱的**——目前为"合理推测、未真实验证"。若此假设不成立，产品退化为"一个只读清单"，装配仍需人管。**验证方式 = dogfooding 一周**：选真实项目（原型 mock 里的 proj-x 场景），让 Codex 全程只经 CLI 自管，观察装配质量、错命中率、回滚次数（详见 Section 8 第一里程碑）。

**埋点声明**：本产品纯本地、零云端——**不存在任何遥测/上报埋点**。上表指标全部由本机的挂载账与操作日志本地自读得出（智昊自己看，不回流任何服务）。

---

## 5. Value Proposition

**对智昊**：

> 智昊终于可以让每个 Agent 自己按业务场景装配技能、而自己完全不管这件事，而不必忍受"打开管理工具要先配置、管理动作要亲手做"的重型面板——因为控制器只做两件事：把全盘清单打开即满地摆出来，和把管理接口交给 Agent。

**竞争差异化**（对手押了什么 / 留下什么空白 / 我们填哪个）：
1. **打开即满 vs 空启动**：skills-manager / agent-skills 们都要人先添加导入；本工具首启全盘扫描即出清单。
2. **Agent 是操作员 vs 人是操作员**：最接近的 skill-cli 仍要求人写 `skill.config` 声明激活；本工具的 GUI 人类动作封顶为"删除/恢复"两个，装配全走 CLI 由 Agent 自主完成。
3. **零观点账本 vs 替你判断**：无人做挂载观测（现有工具不看"谁挂过什么"）；本工具只摆数、不评分、不推荐——"只报总量不报风险"是文案宪法，destructive 红色全应用仅磁盘满一处。
4. **文件管理器的本质**：不发明新存储层，Skill/MCP 都在文件里，控制器的每次写都可回滚、可被 Finder 视角审计。

---

## 6. Solution & Feature Scope

### 6.0 信息架构（继承 sitemap.json，不重开）

- **两类对象统一模型（v1 必须定死）**：`Skill`（文件夹）与 `MCP`（JSON 配置项条目）并列，同按 `Agent × 用户级/项目级 × 具体项目` 三维归属；同名多副本合并展示、落点并列。
- **导航**：侧栏 4 项——清单（默认）/ 挂载账 / 回退 / 设置；核心视图 = NavigationSplitView 三段式（侧栏 × 列表 × 详情栏）。
- **覆盖层**：首次授权 Sheet、装配 diff Sheet、写入失败痕迹卡（不占导航层级）。
- **窗口**：最小宽度 960px（Sheet 520 + 详情 360 并存不重叠；SwiftUI 原生窗口同样约束）。

### 6.1 Story 一：打开就满：一眼看清全盘 Skill 归属

**Persona**：智昊 ｜ **Job**：搞清楚这台电脑上有哪些 Skill、被谁挂着 ｜ **优先级**：P0

**功能描述**：App 启动即自动全盘扫描，按归属三维呈现清单，零配置问答。搜索、视角切换（按 Agent/按项目/按层级）、对象过滤（Skill/MCP）在清单顶部一行完成。

**In Scope**：全盘扫描建索引（增量并入）；三维归属徽章；同名副本合并；冷启动分层加载；授权半空引导态；搜索/过滤空态。
**Out of Scope**：扫描结果导出报表；跨机器同步。

**验收标准（G/W/T）**：
- Given 首次启动且用户授权，When 扫描完成，Then 清单在 ≤5s 内可交互，且每个条目显示：对象类型、用户级/项目级（含项目名）、当前被哪些 Agent 挂载、最近变动日期。
- Given 同一 Skill 存在 3 份副本，When 查看清单，Then 显示为 1 个条目 +"副本 ×3"，详情栏并列展示全部落点路径。
- Given 用户在 macOS 系统层拒绝文件访问，When 回到 App，Then 不白屏，显示解释卡 +「授权并扫描」重新入口。
- Given 某目录读取失败（权限/解析），When 清单渲染，Then 顶部出现中性降级横幅如实报数（"N 个位置未能读取 · 清单基于其余 M 个位置构建"），每行带「忽略此位置」出口，设置页可逆。
- 边缘情况：扫描 >3s 转增量出结果，页头计数标注"索引持续更新中"；名称 >40 字 truncate+tooltip。
- 空状态：全盘 0 条目时居中卡："这台机器还没有 Skill。装配是你未来 Agent 的事，也可以先检查扫描范围"。

> **2026-09-25 裁决回填注**：本 Story 第三条 GWT（系统层拒绝不白屏）所对应的 error-permission 态，经 Phase 0 spike 实证
> 非沙箱 App 读点目录无 TCC 门槛、无触发路径，2026-09-25 裁决（智昊拍 B）将 edge 矩阵中该态改判为条件态
> （must 15 → must 14 + 条件态 1，见 `spark-output/edge/skill-controller.md` error-permission 行）；
> 触发条件回归时（进入沙箱/新增受系统权限保护的读取面）恢复 must 并按原规格实现。本条 GWT 原文不改，以本注为准。

**设计触点**：屏 `overlay-disk-auth` / `page-inventory` / `page-item-detail`；组件 三级分组列表、Tabs 视角、Select 对象、搜索、Badge（全中性）。
**关联 Sitemap**：`page-inventory`(/inventory)、`page-item-detail`(/inventory/item/[id])、`overlay-disk-auth`。
**已生成设计资产**：
- `skill-controller-proto/src/flows/flow-1/flow1-cold-start.tsx`（3 屏完整交互稿，Web 规格，需映射 SwiftUI：NavigationSplitView / Table / .sheet / .confirmationDialog）
- `spark-output/brief/skill-controller.html`（Brief 一页纸，含设计标准与约束）

**待澄清**：各 Agent 的目录与 MCP 配置格式差异清单（见 R2 侦查任务）。

### 6.2 Story 二：新项目一条命令：Agent 自己来拉 Skill ⭐ 关键假设

**优先级**：P0 ｜ **关键假设标记**：⭐（本 Story 即 dogfooding 验证场景）

**功能描述**：任意 Agent 经 `skillctl` CLI 查询 Skill 全集、按业务场景自选并把选定项复制/链接到目标项目的技能目录；人不在场、不确认。控制器提供"装配 diff"验收面。

**In Scope**：CLI 子命令 `skillctl search / info / pull --target <project> [--agent <name>]`；装配事件写日志；清单项目视角呈现新条目；装配 diff Sheet（带来/卸下/跳过三组）；Banner 三态（未验收/已验收/已恢复）。
**Out of Scope**：调用层追踪（已裁定不做）；推荐"应该拉哪些"（零观点）；GUI 内手动装配（人动作封顶删/恢）。

**验收标准（G/W/T）**：
- Given 某 Agent 在项目目录内执行 `skillctl search <关键词>`，When 返回全集匹配项（含落点与描述），Then 该 Agent 可继续执行 `skillctl pull <name>` 完成复制/链接落位并落一条结构化日志。
- Given 一次 CLI 装配发生而 App 未开，When 下次打开 App，Then 项目视角顶部 Banner 显示"N 项装配 · 待验收"（**中性色**），可进 diff 查看每项来源。
- Given 装配中含触发词重叠冲突项，When diff 展示，Then 冲突行进内留痕 + 原因 + 「重试这一项」（不静默、不 toast 一闪而过、不红色）。
- Given diff 展示期间清单又被并发写变化，When 检测到快照过期，Then 顶部提示"清单已更新·重新加载"，**重载前禁用「关闭并验收」**（禁止对旧快照验收）。
- Given 用户关闭 diff，Then 视为验收通过（Banner 转已阅）；回退必须是显式「全部恢复原状」→ AlertDialog 确认。
- 空状态：CLI 运行但 0 增 0 删 → Banner "检查过了，没带来新东西"（事实态）。

**设计触点**：`overlay-assembly-diff`、Banner 组件、`toast:write-error`、CLI（无 GUI，文档先行）。
**关联 Sitemap**：`page-inventory#banner`、`overlay-assembly-diff`、`overlay-write-error`。
**已生成设计资产**：`skill-controller-proto/src/flows/flow-2/flow2-assembly-review.tsx`（4 屏）。
**待澄清**：CLI 命令命名最终定稿（skillctl?）；复制 vs 符号链接的逐 Agent 策略（见 R2）。

### 6.3 Story 三：Agent 自己挂、自己卸，保住最小集合 ⭐ 关键假设

**优先级**：P1 ｜ ⭐（专测"写回别的 Agent 目录"这一最危险侧面）

**功能描述**：Agent 经 CLI 对自己或（受授权约束）其他 Agent 的挂载集合做增删；卸载 ≠ 删除，条目永远留在全集可回挂。清单常驻显示"每个 Agent 当前生效集合"。

**In Scope**：`skillctl mount / unmount --on <agent> [--project <id>]`；卸下后条目状态转"未挂载"（全集仍在）；详情栏挂载时间线；面板开着时条目被并发移走 → 消失态面板。
**Out of Scope**：跨机器挂载同步；自动"闲置 N 天自动卸"（零观点：控制器不自发改变挂载状态，只执行 Agent 指令）。

**验收标准（G/W/T）**：
- Given Agent A 执行 unmount，When 写回成功，Then 该 Agent 生效集合减一、条目仍在全集、日志记录 actor/action/target。
- Given 目标目录属于 Agent B 而当前会话仅授权 Agent A，When 写回，Then 明确拒绝并提示授权约束（不做静默半成功）。
- Given 详情面板打开且条目被并发删除，When 文件监听发现目标消失，Then 面板转中性消失态："这条目刚刚被 {agent} 移出了清单（日志可查）"，唯一出口关闭。
- 边缘情况：写回失败（占用/权限）→ 按钮回原态 + 行内原因 + 日志留痕；提交期间按钮 loading 且禁双击。
- 状态即时更新：卸下成功后徽章与时间线**原地更新**（check Minor#3 的正式修复位）。

**设计触点**：`page-inventory` Agent 视角、详情栏动作区、CLI。
**已生成设计资产**：flow1 Screen3（详情栏）、edge G2/G8 规格。
**待澄清**：各 Agent 是否接受"符号链接"挂载形态（影响卸除语义）。

### 6.4 Story 四：看错了也能一步撤回：删除与操作日志

**优先级**：P1 ｜ **定位：MVP 底线件**（回滚是"把管理外包给 Agent"的信任前提，不属增强项）

**功能描述**：每一次读写进日志、每一次删除进回收站；GUI 人类动作封顶"删除、恢复"两个。

**In Scope**：操作日志流（按时间/按 Agent 过滤，按日分组折叠 + 虚拟列表）；回收站（保留窗 ≥30 天，配置可调大）；一步恢复；删除 AlertDialog 二次确认（含后果说明）。
**Out of Scope**：细粒度回滚到任意历史版本（只支持"撤销这一步"）；跨设备回收站同步。

**验收标准（G/W/T）**：
- Given 任意删除，When 确认 AlertDialog（"30 天内可在回退页一步恢复；各 Agent 挂载将同时卸下"），Then 文件入回收站、日志落条目、可一步恢复且磁盘状态与删除前一致。
- Given 回收站条目已被 Finder 手动清空，When 查看回退页，Then 恢复按钮置灰（opacity+cursor-not-allowed 双标识）+ 行内"目标已不存在"，日志保留仅作审计。
- Given 磁盘满导致回收站写入失败，When 删除，Then 弹出全应用唯一 destructive 升级确认："磁盘空间不足，该条目将无法恢复。确认仍要删除？"（需键入条目名）。
- Given 恢复过程部分条目失败（目录被占），When 完成，Then 如实报"3/5 项已恢复 · 2 项留日志可重试"，Banner 进"部分恢复"态。
- 空状态：无任何变动时 "近 30 天没有任何删除与挂载变动"（不是"暂无数据"）。

**关联 Sitemap**：`page-rollback-log`、`page-rollback-trash`。**设计资产**：edge 规范先行（回退页三态已定义）。

### 6.5 Story 五：挂载账：谁挂过什么、挂了多久

**优先级**：P1 ｜ **策略维度**：数据可视化（只摆数）

**功能描述**：纯文件系统观测的账本页：近 90 天挂载变动、被哪些 Agent/项目挂载、零挂载清单、基于 SKILL.md 文案的静态触发词重叠并列。**数据起点诚实展示**：账本从安装日起记录。

**In Scope**：三视图（变动时间线/清单频次/重叠对）；零挂载排序入口；重叠对静态文案比对并列卡。
**Out of Scope（硬约束落点）**：调用层/会话日志解析器/atime——**工具拿不到的信息不做**；任何"低频=建议删"的判断（红线：出现即违反 Brief）。

**验收标准（G/W/T）**：
- Given 打开挂载账，When 数据不足 90 天，Then 顶部一次性说明条"账本自 {安装日} 起记录，此前的挂载无从得知"，表头注明实际天数（如"仅 5 天数据"），无任何高/低暗示色。
- Given 静态比对发现 docx 与 document-writer 触发词重叠，When 查看详情栏，Then 两卡并列 + "谁留谁走，你或你的 Agent 决定"。
- 全页检查：无 destructive/警告色、无评分、无推荐按钮（Check 已验证当前实现通过）。

**关联 Sitemap**：`page-ledger`。**设计资产**：edge G6 规格 + 原型占位页。

### 6.6 Story 六：MCP 也是清单里的一等公民

**优先级**：P2 ｜ **前置**：统一对象模型已在 6.0 定死，本版仅实现读取与展示，写侧随 story-3 的 CLI 授权模型。

**功能描述**：各 Agent 的 MCP 配置（toml/json 中的 server 条目）作为第二类对象进清单，归属三维一致；增删改经工具/CLI，人不手编 JSON。

**验收标准（G/W/T）**：
- Given 某 Agent 的 MCP 配置文件被本工具修改，When 写回，Then 保持该 Agent 原生格式与字段顺序、写前自动备份、解析失败时拒绝写入并留痕。
- Given 同一 server 在两个 Agent 中配置，Then 并列展示两处落点，合并规则与 Skill 一致。
- 边缘：JSON 语法非法（用户手改坏）→ 该条目标"无法解析"中性态，提供备份恢复入口（如有）。

**关联 Sitemap**：`page-inventory`（对象过滤）、`overlay-write-error`。

### 6.7 未列入本版的 Stories / 能力

hooks / rules / memory 管理（清单仅预留文件类型）；团队共享与云同步；MenuBar 常驻形态；调用级账本（永久排除，见 6.5）；Windows/Linux。

### 6.8 异常态验收规格（继承 edge.json 全 25 态）

工程师实现每个屏时，**Section 6 各 Story 的 GWT 之外，还须逐条对照** `spark-output/edge/skill-controller.md` 的状态矩阵（25 态 = must 15 / should 7 / nice 3）。其中 8 个曾为关键缺失、现已给全设计描述（G1-G8）；加载态分层规则（<1.5s Skeleton / >3s 增量出结果 / 提交态按钮 loading 禁双击 / 长任务可取消）、"恢复按钮不撒谎"（禁用态用 opacity+cursor 双标识）为强制标准。must 级 15 态未实现不得进 Phase 2；nice 3 态可 v1.1。

---

## 7. Constraints & Risks

**技术约束**：
1. Swift / SwiftUI 原生 macOS；无 Electron/Tauri 壳。
2. 纯本地零云端：无网络请求（字体/依赖全部本地化，原型 HTML 中的 CDN 引用仅限原型）。
3. 单用户无账号体系；无遥测。
4. 一切写操作文件级可回滚（操作日志 + 回收站 + 写前备份），**MVP 底线件**，不是增强项。
5. MCP 改写保原生格式；各 Agent 目录结构不统一由"侦查表"收口（R2）。
6. 最小窗口宽 960px。

**设计约束（不可妥协）**：文案宪法="只报总量不报风险"；中性色默认，destructive 红全应用唯一豁免 = 磁盘满不可逆删除；零观点（无推荐/评分/自动清理）；人动作封顶删/恢；空态四型（首次/搜索/过滤/数据起点）不打包。

**数据 & 隐私**：扫描内容为 Skill 元数据与文件路径（本机个人数据不出机器）；明确不读取 Agent 会话日志（已裁定）；回收站文件保留 30 天属本地副本，无合规冲突。

**关键风险表**：

| 风险 | 可能性 | 影响 | 缓解措施 |
| --- | --- | --- | --- |
| R1 · Agent 自装配不靠谱（命门假设） | 未验证 | 高（错=产品形态推翻） | Phase 1 只含最小装配面；dogfooding 一周（见 8.1），失败则挂载决策退回"Agent 建议 + 人一步点头"的半自动态，架构不推翻 |
| R2 · 各 Agent 目录/授权模型不统一（Codex/Claude/QoderWork/Cursor） | 高 | 高 | **编码前先做侦查表**：4 个 Agent 的目录位置、配置格式、是否接受 symlink、TCC 授权路径，产出适配矩阵再定 `skillctl` 写回层 |
| R3 · CLI 并发写冲突（多 Agent 同时装配） | 中 | 中 | 写锁 + 快照版本 + 过期禁用验收（G3）；失败行内留痕不静默 |
| R4 · 磁盘满 → 回收站失效 → 删除不可逆 | 低 | 高 | G5 升级确认态；删除前预检可用空间 |
| R5 · "零观点"实现滑坡（顺手加推荐/警告色） | 中 | 中 | 6.5/文案宪法进代码评审清单；Check 的 pass 类结论作为基线 |
| R6 · 已识别未修复的设计问题（check 遗留） | — | 低 | Minor#3 转 G8 规格（本 PRD 已吸收，不再是缺口）；#6 窗口宽度、#7 演示入口（原型专属）已闭环 |

---

## 8. Release Approach

**8.1 第一里程碑 = 假设验证环（2 周，先于一切完整功能）**
先发 **story-1（清单地基）+ story-2（CLI 查询/拉取 + diff 验收面）+ story-4（回滚底线，最小实现：日志+回收站）**——三者是最小可 dogfooding 集。随后智昊把 proj-x 交给 Codex 全周自管（唯一管理通道 = skillctl），验收三条观察：装配质量（错命中次数）、diff 是否让他在 2 分钟内完成验收、是否需要动用回滚。**R1 未过关前，story-3/5/6 不开工**。

> **2026-09-23 裁决回填（D30）**：第三条观察"是否需要动用回滚"在采集表里曾被操作化成「回滚次数 ≤ 3 且每次一步恢复成功」，
> 实测有两个洞——① 它与第一条（装配质量）重复计数；② 一周内没人需要回滚时它既不能证真也不能证伪，
> 而我造的验收夹具还会把它刷成满分（详见 dogfooding 采集表三·补）。现拆成两格：
> **③a 底线件可用**＝gate，主动跑一次真实误装→一步恢复→磁盘 diff 为空 + 日志有条 + 回收站有件（动机人造、动作真实，只此一次不计入频度）；
> **③b 回滚需求频度**＝观察项，不设通过线，次数偏高时证据归第一条讨论。PRD 本节原文不改，以本注为准。

**8.2 阶梯**
- Phase 1（MVP）：story-1 + story-2 + story-4（底线件）→ dogfooding R1。
- Phase 2：story-3（跨 Agent 挂/卸 + 消失态）+ story-5（挂载账三视图，白捡数据）。
- Phase 3：story-6（MCP 写侧）+ hooks 等对象类型预留的实化评估。

**8.3 上线节奏**：无外部用户，soft-launch 即"自己天天用"；不设回退通道以外的发布流程。

**8.4 头两周监测（全部本地自读，无上报）**：① 每个 Agent 生效集合大小曲线（目标 <50 的轨迹）② 回滚使用次数与原因分布 ③ CLI 写失败率 ④ "关闭并验收"的平均停留时长（diff 面好不好用的代理指标）。

**8.5 完成定义（Definition of Done）**：6.1-6.4 全部 GWT 通过 + 6.8 的 15 个 must 态实现 + R2 侦查表完成 + dogfooding 周智昊本人没伸手手动装过一个 Skill。

---

> **附：全链路设计资产清单**
> - Brief 一页纸：`spark-output/brief/skill-controller.html`
> - Stories 全文：`spark-output/stories/file-manager-agent-cli.md`
> - Sitemap：`spark-output/sitemap/skill-controller.md`
> - 交互原型（可运行，shadcn 规格稿）：`skill-controller-proto/src/flows/`（flow-1 / flow-2 / shared / shell）
> - 走查报告：`spark-output/check/skill-controller-走查报告.md`
> - 异常态矩阵：`spark-output/edge/skill-controller.md`
> - 链路上下文 JSON：`spark-output/context/*.json`（frame/brief/stories/sitemap/flow-web/check/edge）
