import Testing
import Foundation
@testable import SkillControllerCore

/// D17：扫描范围设置必须是「默认 ⊕ 逐项覆盖」，不能是一份绝对列表。
/// 旧格式的致命问题在真机实测过：`prunedCategories` 写死了 8 个类别，
/// 后来新增的 `.temp` 不在里面 → 分不清"关掉了"还是"当时还不存在" →
/// 老用户永远吃不到新剪枝类别，`.tmp` 里 628 个假条目照旧进清单。
struct SettingsOverridesTests {
    private func sandbox() throws -> (dir: URL, paths: SkillControllerPaths) {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("sc-set-\(UUID().uuidString)")
        return (d, SkillControllerPaths(supportDir: d))
    }

    /// ① 旧绝对列表里没有的类别，必须跟随今天的默认（这条就是 D17 的回归）
    @Test func legacyListWithoutNewCategoryStillGetsItsDefault() {
        let legacy = AppSettings(prunedCategories: PruneCategory.allCases
            .filter { $0 != .temp && $0.defaultPruned }
            .map(\.rawValue))                       // 老用户：碰过开关，但当时还没有 .temp
        #expect(legacy.discoveryRules.isCategoryPruned(.temp) == true)
        #expect(legacy.discoveryRules.isCategoryPruned(.personalFolders) == false)
    }

    /// ② 迁移规则的取向：**旧列表里多出来的项 = 用户主张（保留）；缺项 = 无主张（跟随默认）**。
    /// 旧格式分不清"关掉了"与"当时还不存在"，两者在文件里长得一模一样，只能选一边：
    /// 选"缺项跟随默认"，代价是本次迁移之前主动放开过的类别会被恢复成剪枝
    /// （设置页每一类都带实测数字、一次点击就能改回）；
    /// 反过来选"缺项算关掉"，则以后每加一个剪枝类别都会对所有老用户静默失效——
    /// 那正是 D13 让我们花一整轮去定位的坑。
    @Test func legacyExtraCategoryIsTreatedAsUserClaim() {
        // 用户当年把「桌面与下载」（默认不剪）勾成了剪枝 → 必须保留
        let withExtra = AppSettings(prunedCategories: PruneCategory.allCases
            .filter { $0.defaultPruned || $0 == .personalFolders }
            .map(\.rawValue))
        #expect(withExtra.discoveryRules.isCategoryPruned(.personalFolders))
        #expect(withExtra.discoveryRules.isCategoryPruned(.temp))   // 缺项 → 跟随默认
        // 用户当年放开了「缓存」→ 迁移后恢复为剪枝（已知代价，见上）
        let dropped = AppSettings(prunedCategories: PruneCategory.allCases
            .filter { $0.defaultPruned && $0 != .cache }.map(\.rawValue))
        #expect(dropped.discoveryRules.isCategoryPruned(.cache))
    }

    /// ③ 落盘只写覆盖项：与默认一致的类别不落盘，读回来有效集不变
    @Test func saveWritesOnlyDivergentOverrides() throws {
        let (dir, paths) = try sandbox()
        defer { try? FileManager.default.removeItem(at: dir) }
        var s = AppSettings()
        // 用户只把「缓存」放开，其余保持默认
        var pruned = Set(PruneCategory.allCases.filter(\.defaultPruned))
        pruned.remove(.cache)
        s.setPrunedCategories(pruned)
        #expect(s.prunedOverrides == ["cache": false])
        #expect(s.prunedCategories == nil)           // 旧字段迁移后不再写
        try s.save(paths: paths)

        let back = AppSettings.load(paths: paths)
        #expect(!back.discoveryRules.isCategoryPruned(.cache))
        #expect(back.discoveryRules.isCategoryPruned(.temp))
        // 此后产品再加一个新剪枝类别：这位用户也自动吃到默认（覆盖表里没有它）
        #expect(back.effectiveOverrides[.personalFolders] == nil)
    }

    /// ④ 全新安装 = 纯默认集，且默认集与 DiscoveryRules.standard 一致
    @Test func freshInstallEqualsStandard() {
        let s = AppSettings()
        #expect(s.discoveryRules == .standard)
        #expect(s.discoveryRules.isCategoryPruned(.temp))
    }
}
