// swift-tools-version:6.0
// Skill Controller — Phase 0 骨架
// skillctl（executable）+ SkillControllerCore（共享模型/常量）+ 单元测试
// 注意：SwiftUI App target 需要 Xcode（本机暂缺），App 源码在 App/ 下，见 docs/phase-0-notes.md D2
import PackageDescription

let package = Package(
    name: "SkillController",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "SkillControllerCore", targets: ["SkillControllerCore"]),
        .executable(name: "skillctl", targets: ["skillctl"]),
    ],
    targets: [
        .target(
            name: "SkillControllerCore",
            path: "Sources/SkillControllerCore"
        ),
        .executableTarget(
            name: "skillctl",
            dependencies: ["SkillControllerCore"],
            path: "Sources/skillctl"
        ),
        .testTarget(
            name: "SkillControllerTests",
            dependencies: ["SkillControllerCore"],
            path: "Tests/SkillControllerTests"
        ),
    ]
)
