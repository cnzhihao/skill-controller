// IrreversibleDeleteSheet.swift — 磁盘满不可逆删除升级确认（edge G5 / error-disk-full must 态）
// 全应用唯一 destructive 红（Color.destructiveOnly）的产品面第一处使用：
// 普通确认框点「移入回收站」→ 预检可用空间不足 → 关普通框、开本 Sheet（替换流，两框永不同屏）。
// 标题与正文保持中性（只报总量不报风险）；标题句 = edge copy_hint 原文。

import SwiftUI
import SkillControllerCore

struct IrreversibleDeleteSheet: View {
    @ObservedObject var app: AppState
    let item: InventoryItem
    /// 预检算出的需要字节数（TrashSpaceEstimator.neededBytes 的人读值）
    let neededBytes: Int64
    /// 预检探测到的可用字节数
    let freeBytes: Int64
    var onCancel: () -> Void

    @State private var input = ""

    private var nameMatches: Bool { input == item.name }   // 精确比对，不 trim——文件名可以含空格

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // 标题（16 semibold，中性色，不红）：edge error-disk-full copy_hint 原文
            Text("磁盘空间不足，该条目将无法恢复。确认仍要删除？")
                .font(.system(size: 16, weight: .semibold))

            // 事实行（12 muted，数字 monospacedDigit）
            Text("无法移入回收站，此删除不可恢复。需要约 \(ByteCount.string(neededBytes)) · 当前可用 \(ByteCount.string(freeBytes))")
                .font(.system(size: 12))
                .foregroundStyle(Color.scMutedForeground)
                .monospacedDigit()
                .textSelection(.enabled)

            // 键入行：输入条目名以确认
            VStack(alignment: .leading, spacing: 6) {
                Text("输入条目名「\(item.name)」以确认")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.scMutedForeground)
                TextField("", text: $input)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 14))
            }

            HStack {
                Spacer()
                Button("取消") { onCancel() }
                    .keyboardShortcut(.cancelAction)
                    .buttonStyle(.bordered)
                Button("仍然删除") {
                    app.deleteItemIrreversibly(item)
                    onCancel()
                }
                .buttonStyle(.bordered)
                .foregroundStyle(Color.destructiveOnly)   // 全应用唯一红的产品面第一处使用
                .disabled(!nameMatches)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: LayoutMetrics.diffSheetWidth)
        .background(Color.scCard)
        .scContainerRadius()
        .overlay(RoundedRectangle(cornerRadius: LayoutMetrics.Radius.lg).stroke(Color.scBorder))
    }
}

/// 人读字节格式：预检事实行与回执共用一个口径，不各写一套
enum ByteCount {
    static func string(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
