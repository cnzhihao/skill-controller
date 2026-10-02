// GateSheet.swift — 授权门（flow1 Screen1 + edge DiskAccessGate must 态）
// 文案照抄设计稿（硬规则 §3.3）。
// 裁决陈述（2026-09-25，智昊拍 B）：非沙箱 App 读点目录无 TCC 门槛（Phase 0 spike 实证），
// 本工具亦不读 Agent 会话日志，error-permission 态不存在任何触发路径，已裁决删除；
// 将来进入沙箱或新增受系统权限保护的读取面时恢复该态，并按 edge 原规格实现
//（中性说明行 + 深链按钮 + 返回自动重试）。授权门现在只有「授权并扫描 / 这次先不」两出口。

import SwiftUI
import SkillControllerCore

struct GateSheet: View {
    @ObservedObject var app: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Image(systemName: "checkmark.shield")
                .font(.system(size: 20))
                .foregroundStyle(Color.scMutedForeground)

            Text("让控制器看见全盘 Skill")
                .font(.system(size: 16, weight: .semibold))

            VStack(alignment: .leading, spacing: 12) {
                Text("本工具需要读取磁盘来构建清单（一次授权，全程本地，无任何网络请求）：")
                    .font(.system(size: 14))
                VStack(alignment: .leading, spacing: 4) {
                    Text("全盘发现名为 skills 的目录与 MCP 配置文件")
                    Text("跳过 node_modules、缓存与回收站副本，其余一律收录")
                }
                .font(.system(size: 12))
                .foregroundStyle(Color.scMutedForeground)

                Text("扫描结果只存在本机。你随时可以在「设置」里查看范围并忽略某个位置。")
                    .font(.system(size: 14))
                    .foregroundStyle(Color.scMutedForeground)
            }

            HStack {
                Spacer()
                // STATE: loading-submit —— 按下后 disabled+spinner，防重复触发
                Button("这次先不") {
                    app.deny()
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.scMutedForeground)
                .disabled(app.gatePhase == .scanning)
                .opacity(app.gatePhase == .scanning ? 0.5 : 1)

                Button {
                    app.grant()
                } label: {
                    HStack(spacing: 6) {
                        if app.gatePhase == .scanning {
                            ProgressView().controlSize(.small)
                            Text("正在建立索引…")
                        } else {
                            Image(systemName: "checkmark")
                            Text("授权并扫描")
                        }
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(app.gatePhase == .scanning)
                .opacity(app.gatePhase == .scanning ? 0.7 : 1)
            }
        }
        .padding(24)
        .frame(width: 480)
        .background(Color.scCard)
        .scContainerRadius()
        .overlay(RoundedRectangle(cornerRadius: LayoutMetrics.Radius.lg).stroke(Color.scBorder))
    }
}
