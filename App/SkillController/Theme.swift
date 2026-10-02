// Theme.swift — 视觉 token 映射（App 侧）
// 硬规则 §3.4：只从 Asset Catalog（31 色，由 extract tokens 生成）取色；
// destructive 唯一红 = Color.destructiveOnly 单点约定（design-language §18）。
// 全局等宽 + 数字 monospacedDigit 由 SkillControllerApp 根视图施加。

import SwiftUI
import SkillControllerCore

/// 语义色命名空间——颜色名与 Asset Catalog colorset 一一对应，禁止自创色值
extension Color {
    static let scBackground = Color("background")
    static let scForeground = Color("foreground")
    static let scCard = Color("card")
    static let scMuted = Color("muted")
    static let scMutedForeground = Color("mutedForeground")
    static let scSecondary = Color("secondary")
    static let scBorder = Color("border")
    static let scInput = Color("input")
    static let scRing = Color("ring")

    /// 全应用唯一 destructive 红的使用入口。
    /// 宪法豁免清单（唯一）：磁盘满不可逆删除确认（edge G5 / error-disk-full）。
    static let destructiveOnly = Color("destructive")
}

extension ShapeStyle where Self == Color {
    static var scMuted: Color { .scMuted }
    static var scMutedForeground: Color { .scMutedForeground }
}

/// 设计语言：等宽全局、数字 .monospacedDigit()（硬规则 §3.4）
extension View {
    func scGlobalTypography() -> some View {
        fontDesign(.monospaced)
    }
}

/// 圆角：容器 lg / 控件 md（LayoutMetrics.Radius 是唯一数值源）
extension View {
    func scContainerRadius() -> some View {
        cornerRadius(LayoutMetrics.Radius.lg)
    }

    func scControlRadius() -> some View {
        cornerRadius(LayoutMetrics.Radius.md)
    }
}
