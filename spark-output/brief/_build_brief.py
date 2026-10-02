#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Clone prototype/brief.html + merge brief-themes.css, then replace fields only."""
import pathlib, sys

SKILL_DIR = pathlib.Path("<home>/.qwenworkcn/plugins/product-design/skills/brief/prototype")
OUT = pathlib.Path("<home>/MacOS-App/Skill-controller/spark-output/brief/skill-controller.html")

html = (SKILL_DIR / "brief.html").read_text(encoding="utf-8")
css = (SKILL_DIR / "brief-themes.css").read_text(encoding="utf-8")

# Step 2: merge structure + styles (self-contained)
assert '<link rel="stylesheet" href="brief-themes.css">' in html
html = html.replace('<link rel="stylesheet" href="brief-themes.css">\n', '')
assert '<style></style>' in html
html = html.replace('<style></style>', '<style>\n' + css + '\n  </style>')

def rep(old, new):
    global html
    n = html.count(old)
    if n != 1:
        print(f"FATAL: pattern count={n}: {old[:60]!r}"); sys.exit(1)
    html = html.replace(old, new)

# ---- Step 3: field replacements ----
rep('<title>Design Brief — 购物车流程改版</title>',
    '<title>Design Brief — 本地 Skill 管理工具（Skill 控制器）</title>')
rep('<p class="topbar-title" spellcheck="false">购物车流程改版</p>',
    '<p class="topbar-title" spellcheck="false">本地 Skill 管理工具（Skill 控制器）</p>')
rep('<p class="topbar-meta" spellcheck="false">产品迭代 · 2026-04-29</p>',
    '<p class="topbar-meta" spellcheck="false">全新产品 · 2026-09-19</p>')
rep('<body data-theme="chalk" data-ratio="16-9" data-scale="md">',
    '<body data-theme="script" data-ratio="16-9" data-scale="md">')

# 业务背景
rep('<p>平台处于<strong>成熟期</strong>，GMV 增速趋缓，战略重心转向存量用户的转化效率提升。近三季度监控数据显示，购物车放弃率持续高于行业均值 <span class="num">12</span> 个百分点，结算环节为最主要流失节点。本次设计由 Q2 增长专项驱动，聚焦购物车至支付完成的核心转化路径。</p>',
    '<p>本机散落近 <span class="num">1000</span> 个 Skill，被多个 Agent 无差别全量加载，上下文稀释让 Agent 肉眼可见地变笨；新项目只能全量重装。现有管理工具全是"人当操作员 + 打开是空的"，无一可用。</p>')

# 业务目标
rep('''      <ul class="list">
        <li>购物车转化率 <span class="num">45%</span> → <strong class="num">58%</strong></li>
        <li>结算页跳出率下降 <strong class="num">20%</strong></li>
        <li>支付成功率提升 <strong class="num">8%</strong></li>
        <li>流程类客诉占比下降 <strong class="num">30%</strong></li>
      </ul>''',
'''      <ul class="list">
        <li>每 Agent 挂载降至最小高信号集 <strong class="num">&lt;50</strong></li>
        <li>新项目装配从半天变一条命令</li>
        <li>用户级 Skill <span class="num">30</span> 天瘦身过半，账本背书</li>
        <li>Agent 变笨可归因、可一键回滚</li>
      </ul>''')

# 用户
rep('''      <ul class="list">
        <li><span class="num">25–40</span> 岁城市女性</li>
        <li>移动端为主，碎片时间下单</li>
        <li>月均购物 <span class="num">3</span> 次以上</li>
        <li>对繁琐流程容忍度低</li>
      </ul>''',
'''      <ul class="list">
        <li>设计师本人，重度多 Agent 用户</li>
        <li>本机近千 Skill 跨层级散落</li>
        <li>只看不管，智能外包给 Agent</li>
        <li>对重型面板与空启动零容忍</li>
      </ul>''')

# 设计策略
rep('''      <div class="s-grid">
        <div class="s-item">
          <b>信息架构 IA</b>
          <p class="thesis">核心操作提至首屏，减少结算路径层级。</p>
          <ul class="tactics">
            <li>结算入口上移到首屏</li>
            <li>精简冗余跳转层级</li>
            <li>分类重组贴近心智</li>
          </ul>
          <p class="rationale">对应 B2 跳出率↓20%；用户低容忍繁琐</p>
        </div>
        <div class="s-item">
          <b>交互设计</b>
          <p class="thesis">结算压缩到 <span class="num">3</span> 步，错误校验前置。</p>
          <ul class="tactics">
            <li>地址 / 支付合并一屏</li>
            <li>字段实时校验提示</li>
            <li>进度条常驻顶部</li>
          </ul>
          <p class="rationale">对应 B1 转化 45%→58%</p>
        </div>
        <div class="s-item">
          <b>情感化设计</b>
          <p class="thesis">支付完成正向动效，加购即时反馈。</p>
          <ul class="tactics">
            <li>支付成功动效 + 音效</li>
            <li>加购浮层确认态</li>
            <li>异常态温和提示</li>
          </ul>
          <p class="rationale">对应 B4 客诉↓30%</p>
        </div>
      </div>''',
'''      <div class="s-grid">
        <div class="s-item">
          <b>信息架构 IA</b>
          <p class="thesis">清单即产品：两类对象 × 归属三维，不按路径罗列。</p>
          <ul class="tactics">
            <li>Skill（目录）+ MCP（JSON）并列</li>
            <li>Agent × 层级 × 项目聚合</li>
            <li>同名去重合并，零配置即开即满</li>
          </ul>
          <p class="rationale">对应机会 #2；竞品败在"打开是空的"</p>
        </div>
        <div class="s-item">
          <b>交互设计</b>
          <p class="thesis">人只看、只撤销；管理动作全部外包 CLI。</p>
          <ul class="tactics">
            <li>GUI 只读 + 删/恢两个动作封顶</li>
            <li>查/拉/挂/卸 × 两类对象</li>
            <li>操作日志 + 回收站，一步回滚</li>
          </ul>
          <p class="rationale">对应"我不要管 Skill"；回滚是底线</p>
        </div>
        <div class="s-item">
          <b>数据可视化</b>
          <p class="thesis">账本只展示不判断：谁在用什么、用了多少。</p>
          <ul class="tactics">
            <li>按 Agent / 项目聚合频次</li>
            <li>触发词重叠对并列标注</li>
            <li>零评分、零建议、零警告色</li>
          </ul>
          <p class="rationale">对应机会 #3；数据由 CLI 装配白捡</p>
        </div>
      </div>''')

# 设计标准
rep('''      <ul class="list">
        <li><span class="tag" data-kind="quant">定量</span><span class="text">结算步骤 ≤ <span class="num">3</span> 步</span></li>
        <li><span class="tag" data-kind="quant">定量</span><span class="text">任务完成率 &gt; <span class="num">88%</span></span></li>
        <li><span class="tag" data-kind="qual">定性</span><span class="text">流程感知清晰</span></li>
        <li><span class="tag" data-kind="qual">定性</span><span class="text">无明显操作卡点</span></li>
      </ul>''',
'''      <ul class="list">
        <li><span class="tag" data-kind="quant">定量</span><span class="text">冷启动 ≤ <span class="num">5s</span>，清单即开即满</span></li>
        <li><span class="tag" data-kind="quant">定量</span><span class="text">一次装配 ≤ <span class="num">1</span> 条 CLI 命令</span></li>
        <li><span class="tag" data-kind="qual">定性</span><span class="text"><span class="num">30</span> 秒答出"归谁、在哪、谁挂着"</span></li>
        <li><span class="tag" data-kind="qual">定性</span><span class="text">任何写删一步撤销，日志可查</span></li>
      </ul>''')

# 边界约束
rep('''      <ul class="list">
        <li><span class="num">8</span> 周内上线，不可延期</li>
        <li>支付模块不可改动（第三方接入）</li>
        <li>须遵守现有 Design System v2.3</li>
        <li>设计资源：<span class="num">2</span> 名设计师</li>
      </ul>''',
'''      <ul class="list">
        <li>纯本地零云端，无网络请求</li>
        <li>单用户无账号，只为自己设计</li>
        <li>回滚底线：日志 + 回收站，JSON 保格式</li>
        <li>零观点：自装配假设未验证，不做智能承诺</li>
        <li>Swift / SwiftUI 原生 macOS App</li>
      </ul>''')

# 不做什么
rep('''      <ul class="list">
        <li>商品详情页不纳入本次改版</li>
        <li>会员积分体系不重设计</li>
        <li>PC 端不覆盖，移动端优先</li>
        <li>推荐算法逻辑不调整</li>
      </ul>''',
'''      <ul class="list">
        <li>不做推荐 / 评分 / "该删了"判断</li>
        <li>不做 hooks / 规则 / memory 管理</li>
        <li>不做云同步与团队共享</li>
        <li>不做 Windows / Linux 端</li>
        <li>不做引导流程（onboarding 即设计失败）</li>
      </ul>''')

OUT.parent.mkdir(parents=True, exist_ok=True)
OUT.write_text(html, encoding="utf-8")
lines = html.count("\n") + 1
print(f"OK wrote {OUT} ({lines} lines)")
