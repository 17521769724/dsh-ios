import SwiftUI

/// 权限状态：集中查看本 App 需要的系统权限，并可直接申请或跳转系统设置。
/// 首次启动时以引导形式（`isPrimer = true`）自动走一遍申请流程。
struct PermissionsView: View {
    /// 首次启动引导模式：自动发起申请，并显示「完成」按钮
    var isPrimer: Bool = false

    @StateObject private var permissions = PermissionCenter()
    @Environment(\.dismiss) private var dismiss

    /// 申请结果提示
    @State private var banner: String?
    @State private var requesting = false

    var body: some View {
        List {
            if isPrimer {
                Section {
                    VStack(alignment: .leading, spacing: DSHTheme.Spacing.small) {
                        Text("为了让智能体能替你办事，需要几分钟把下面这些权限确认一下。")
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(DSHTheme.assistantText)
                        Text("提醒事项与日历用于读写待办日程；剪贴板用于复制内容；网络与文件不需要授权。确认完点右上角「完成」，之后可在 设置 → 关于 → 权限状态 里再改。")
                            .font(.system(size: 13))
                            .foregroundStyle(DSHTheme.secondaryText)
                    }
                    .padding(.vertical, 4)
                }
            }

            Section {
                ForEach(permissions.items) { item in
                    row(item)
                }
            } header: {
                Text("权限状态（\(permissions.items.count - permissions.pendingCount)/\(permissions.items.count) 已就绪）")
            } footer: {
                Text("提醒事项与日历由智能体按需读写；剪贴板与本地网络会在使用时由系统询问；网络访问、照片与文件不需要单独授权。被拒绝的权限可以到系统设置里开启。")
            }

            if let banner {
                Section {
                    Text(banner)
                        .font(.system(size: 13))
                        .foregroundStyle(DSHTheme.secondaryText)
                        .accessibilityIdentifier("permissions.banner")
                }
            }

            Section {
                Button {
                    Task {
                        requesting = true
                        banner = await permissions.requestAll()
                        requesting = false
                    }
                } label: {
                    HStack {
                        Label("一键申请（提醒事项 / 日历 / 剪贴板）", systemImage: "checkmark.shield")
                        Spacer()
                        if requesting { ProgressView().controlSize(.small) }
                    }
                    .contentShape(Rectangle())
                }
                .disabled(requesting)
                .accessibilityIdentifier("permissions.requestAll")

                Button {
                    permissions.openSystemSettings()
                } label: {
                    Label("打开系统设置", systemImage: "gearshape")
                }
                .accessibilityIdentifier("permissions.systemSettings")
            } footer: {
                Text("iOS 的「允许粘贴」每次读取都会再问一次，属于系统行为；在系统设置里能改的是提醒事项与日历。")
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(isPrimer ? "权限申请" : "权限状态")
        .navigationBarTitleDisplayMode(.inline)
        .tint(DSHTheme.brand)
        .toolbar {
            // 「完成」固定在导航栏：清单较长时底部按钮需要滚动才能看到
            if isPrimer {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("完成") {
                        permissions.hasPrimed = true
                        dismiss()
                    }
                    .font(.system(size: 16, weight: .semibold))
                    .accessibilityIdentifier("permissions.done")
                }
            }
        }
        .task {
            // 引导模式：进来就把能申请的走一遍，用户只需在系统弹窗上点允许
            guard isPrimer, PermissionCenter.shouldAutoRequest, !permissions.hasPrimed, banner == nil else { return }
            requesting = true
            banner = await permissions.requestAll()
            requesting = false
        }
    }

    // MARK: - 单行

    private func row(_ item: PermissionCenter.Item) -> some View {
        HStack(spacing: DSHTheme.Spacing.medium) {
            SettingsRowLabel(symbol: item.symbol, color: color(for: item), title: item.title)

            Spacer(minLength: 8)

            VStack(alignment: .trailing, spacing: 3) {
                Text(item.status.title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(item.status.isSatisfied ? DSHTheme.success : DSHTheme.warning)
                if item.canRequest, !item.status.isSatisfied {
                    Button("申请") {
                        Task {
                            requesting = true
                            banner = await item.request?()
                            requesting = false
                        }
                    }
                    .font(.system(size: 12))
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
                }
            }
        }
        .padding(.vertical, 2)
        .accessibilityIdentifier("permissions.row.\(item.id)")
    }

    private func color(for item: PermissionCenter.Item) -> Color {
        switch item.status {
        case .granted: return .green
        case .denied: return .red
        case .notDetermined: return .orange
        case .systemPrompt: return .blue
        case .notRequired: return .gray
        }
    }
}