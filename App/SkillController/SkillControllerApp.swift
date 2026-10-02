// SkillControllerApp.swift — App 入口
// 全局等宽（design-language §18）+ 数字 monospacedDigit 在根视图施加。
// 零网络、零遥测；无 onboarding（授权门 Sheet 属 flow1 设计稿，非引导流程）。

import SwiftUI
import SkillControllerCore

@main
struct SkillControllerApp: App {
    @StateObject private var app = AppState()

    var body: some Scene {
        WindowGroup {
            RootView(app: app, cliGuide: app.cliGuide)
                .scGlobalTypography()
                .tint(Color.scForeground)
        }
        .windowResizability(.contentMinSize)
    }
}
