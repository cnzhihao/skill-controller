import Testing
@testable import SkillControllerCore

/// Phase 0 骨架自检：视觉常量与 extract tokens 一致（值漂移即红）
struct LayoutMetricsTests {
    @Test func layoutConstants() {
        #expect(LayoutMetrics.detailPanelWidth == 360)
        #expect(LayoutMetrics.diffSheetWidth == 520)
        #expect(LayoutMetrics.minWindowWidth == 960)
        #expect(LayoutMetrics.zDetailOverlay == 70)
    }

    @Test func radiusScale() {
        #expect(LayoutMetrics.Radius.sm == 6)
        #expect(LayoutMetrics.Radius.md == 8)
        #expect(LayoutMetrics.Radius.lg == 10)
        #expect(LayoutMetrics.Radius.xl == 14)
    }

    @Test func motionAndBoundary() {
        #expect(LayoutMetrics.stateTransition == 0.15)
        #expect(LayoutMetrics.maxNameLength == 40)
    }
}
