// ScanPublishPolicy.swift — 一轮扫描里"什么时候允许把结果写进界面"（D16）
//
// 真机现象：后台重扫期间页头从 1,973 跌到 1,398 再一路涨回来；跌下去的那一瞬间
// 详情栏里选中的条目"不存在"了，正开着的「移入回收站」确认框被系统直接作废
// （智昊连点两次都撞上元素失效）。根因不是数字算错，是**发布时机**：
// 每扫完一批位置就往界面写一版全量索引，等于把清单先拆掉再拼回去。
//
// 口径：
// - 冷启动（上一版什么都没有）→ 逐批发布。首屏必须边扫边出（edge loading-initial 的 >3s 增量态），
//   且累积器只增不减，所以这条路里的数字单调上涨、不会回头。
// - 手上已有一版全量（⌘R 轻量重扫 / 回到前台 / FSEvents / ⌘⇧R 全盘重扫）→ 一轮 pass 只在收尾发布一次。
//   期间展示层停在上一版全量数字上，配「索引持续更新中」标注（由 isUpdating + >3s 驱动）；
//   收尾那一次发布才可能让数字下降，而那时的下降是磁盘事实（比如刚删掉的条目），不是抖动。

import Foundation

public struct ScanPublishPolicy: Sendable, Equatable {
    /// 本轮开始时界面上已有的条目数——0 表示冷启动，没有"上一版"可保留
    public let previousItemCount: Int

    public init(previousItemCount: Int) {
        self.previousItemCount = previousItemCount
    }

    /// 扫完一批位置后是否立刻发布
    public var publishesEachBatch: Bool { previousItemCount == 0 }

    /// 一轮 pass 收尾必须发布，否则界面永远停在旧数据（被别轮接管由调用方的代际号挡掉）
    public var publishesAtEnd: Bool { true }
}
