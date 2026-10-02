// LayoutMetrics.swift — 视觉常量唯一收敛点
// 来源：spark-output/extract/skill-controller-proto-design-tokens.json（layout/radius/motion）
// 硬规则 §3.4：UI 代码宽度/圆角/层级一律从这里取，不得自创数值。

import CoreGraphics

public enum LayoutMetrics {
    /// 详情栏宽度（阅读型容器限宽）
    public static let detailPanelWidth: CGFloat = 360
    /// 装配 diff Sheet 宽度
    public static let diffSheetWidth: CGFloat = 520
    /// CLI 引导 Sheet 宽度——取 Sheet 档位 520，与 diffSheetWidth 同值不同义：
    /// 一个是装配 diff 容器、一个是 CLI 引导容器，各自独立取档位，将来可各自调整，不得互相借用。
    public static let guideSheetWidth: CGFloat = 520
    /// 最小窗口宽度（Sheet 520 + 详情 360 并存不重叠）
    public static let minWindowWidth: CGFloat = 960

    /// 详情浮层 Z 层级（z.detail-overlay = 70）
    public static let zDetailOverlay: CGFloat = 70

    /// 圆角：容器 lg / 控件 md / 徽章 full
    public enum Radius {
        public static let sm: CGFloat = 6
        public static let md: CGFloat = 8
        public static let lg: CGFloat = 10
        public static let xl: CGFloat = 14
    }

    /// 状态过渡 150ms（Badge 更新等；装饰性动效被宪法禁止）
    public static let stateTransition: Double = 0.15

    /// 名称 >40 字 truncate（edge boundary-long-text）
    public static let maxNameLength: Int = 40
}
