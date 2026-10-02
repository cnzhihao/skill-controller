# 设计走查报告 — 本地 Skill 管理工具（Skill 控制器）

- 生成时间：2026-09-19T07:15:04Z
- 模式：Mode C 定向验证 + 10 类补充
- 裁决：内容区不限宽 → 放行（数据面桌面语义，阅读容器已限宽）
- 总览：Blocker 0 / Major 2 / Minor 7 / Pass 类：components、brief-consistency


## 🟠 Major

1. **[accessibility]** 清单行与装配列表行仅 onClick，键盘不可聚焦不可触发
   - 位置：skill-controller-proto/src/flows/flow-1/flow1-cold-start.tsx (Screen2 TableRow) / flow-2 (Screen1 列表行)
   - 建议：行加 tabIndex+role=button+onKeyDown(Enter/Space)，或行尾显式详情按钮

2. **[edge-states]** 扫描缺部分降级态：单目录无权限/JSON 解析失败未表达，只有全授权/全拒绝两态
   - 位置：flow1-cold-start.tsx Screen2_Inventory
   - 建议：清单顶部加中性降级横幅；完整异常矩阵交 /edge


## 🟡 Minor

1. **[feedback]** 卸下/恢复挂载按钮仅 toast 不更新徽章与时间线（原型保真度）
   - 位置：flow1 Screen3 动作区
   - 建议：本地状态更新或标注只读演示

2. **[copy]** 装配/挂上/卸下/卸载 动词漂移，banner、diff、详情三处不一致
   - 位置：flow1+flow2 全部文案
   - 建议：两级词汇：装配（Agent 行为）/挂上·卸下（条目状态）

3. **[visual-hierarchy]** 详情区 h1→h3 跳级
   - 位置：flow1 Screen3_ItemDetail
   - 建议：改 h2 或补中间标题层

4. **[responsive]** Sheet520px+详情360px 在 <900px 窗口重叠
   - 位置：flow2 容器
   - 建议：声明最小窗口宽度 960px（原型与 SwiftUI 同）

5. **[ia]** 侧栏『装配验收·演示』为 sitemap 外第 5 项
   - 位置：skill-controller-app.tsx nav
   - 建议：原型豁免；不得带入原生实现

6. **[flow-continuity]** gate 状态机存在死值 'none'，无入口无出口
   - 位置：flow1 Flow1_ColdStart
   - 建议：删除，或接『已有授权记录』直入分支

7. **[edge-states]** 清单行 description 无 truncate，超长文案撑高行
   - 位置：flow1 Screen2 名称列
   - 建议：加 truncate（diff 行已做，对齐）


## Mode C 核对表要点

- 策略维度：IA ✅ / 交互 ✅ / 数据可视化 🟡（挂载账页为计划内占位）
- story-1 四条 AC 全过；story-2 CLI 侧 N/A 交 PRD；story-3 🟡 见 Minor#1(feedback)
- out_of_scope 零违反：全原型无任何推荐/评分/警告色判断

## 修复记录（2026-09-19）

- Major#1 ✅ 行键盘可达（tabIndex+role+Enter/Space+focus ring+aria-label）
- Major#2 ✅ 部分降级横幅（中性色如实报数 + 跳设置）
- Minor truncate ✅ / h2 ✅ / 死状态 ✅ / 动词统一（挂上·卸下 / 装配两级词汇）✅
- 仍开放：Minor#3 卸下不更新状态（建议随 Edge 一并处理）、#6 最小窗口宽度（SwiftUI 侧声明）、#7 演示入口（原型豁免）
