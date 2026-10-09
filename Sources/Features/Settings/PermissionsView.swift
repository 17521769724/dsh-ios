import SwiftUI

/// 权限状态：集中查看本 App 需要的系统权限，并可直接申请或跳转系统设置。
/// 首次启动时以引导形式（`isPrimer = true`）自动走一遍申请流程。
struct PermissionsView: View {
    /// 首次启动引导模式：自动发起申请，并显示「完成」按钮
    var isPrimer: Bool = false

    @StateObject private var permissions = PermissionCenter()
    @Environment(\.dismiss) private var dismiss

    /// 申请结果用弹窗提示（用户反馈：只在页面里显示一行卡片太容易错过）
    @State private var alertTitle = "权限申请"
    @State private var alertMessage: String?
    @State private var requesting = false

    private var alertPresented: Binding<Bool> {
        Binding(
            get: { alertMessage != nil },
            set: { if !$0 { alertMessage = nil } }
        )
    }

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

            Section {
                Button {
                    Task { await requestAllPermissions() }
                } label: {
                    HStack {
                        Label("一键申请权限", systemImage: "checkmark.shield")
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
            // （结果不弹窗，避免叠在系统授权框上；页面里的状态会直接更新）
            guard isPrimer, PermissionCenter.shouldAutoRequest, !permissions.hasPrimed, alertMessage == nil else { return }
            requesting = true
            _ = await permissions.requestAll()
            requesting = false
        }
        .alert(alertTitle, isPresented: alertPresented) {
            Button("知道了", role: .cancel) {}
        } message: {
            Text(alertMessage ?? "")
        }
    }

    // MARK: - 申请

    /// 一键申请：已经没有待申请项时用弹窗说明，而不是只在页面里加一行字
    private func requestAllPermissions() async {
        let pending = permissions.items.filter { $0.canRequest && !$0.status.isSatisfied }
        guard !pending.isEmpty else {
            alertTitle = "无需申请"
            alertMessage = "提醒事项、日历、剪贴板都已经处理过，不需要再申请。之前拒绝过的权限，请到系统设置里手动开启。"
            return
        }
        requesting = true
        alertTitle = "权限申请结果"
        alertMessage = await permissions.requestAll()
        requesting = false
    }

    /// 单项申请：同样用弹窗反馈结果
    private func requestSingle(_ item: PermissionCenter.Item) async {
        requesting = true
        alertTitle = "权限申请结果"
        alertMessage = await item.request?()
        requesting = false
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
                        Task { await requestSingle(item) }
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