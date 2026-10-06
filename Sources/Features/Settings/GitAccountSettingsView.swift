import SwiftUI

/// GitHub / Gitee 账号：Token 保存在本机钥匙串，校验通过后智能体即可调用对应工具操作仓库。
struct GitAccountSettingsView: View {
    let provider: GitProvider

    @EnvironmentObject private var gitStore: GitAccountStore
    @EnvironmentObject private var settingsStore: SettingsStore

    @State private var tokenInput = ""
    @State private var revealed = false
    @State private var connecting = false
    @State private var message: String?
    @State private var succeeded = false
    @State private var showSignOutConfirm = false

    private var isConnected: Bool { gitStore.isConnected(provider) }

    /// 两个平台的开关各自独立
    private var toolBinding: Binding<Bool> {
        switch provider {
        case .github: return $settingsStore.settings.features.githubTool
        case .gitee: return $settingsStore.settings.features.giteeTool
        }
    }

    var body: some View {
        List {
            agentSection
            accountSection
            helpSection
        }
        .listStyle(.insetGrouped)
        .navigationTitle(provider.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .tint(DSHTheme.brand)
        .confirmationDialog(
            "退出 \(provider.displayName) 账号？",
            isPresented: $showSignOutConfirm,
            titleVisibility: .visible
        ) {
            Button("退出登录", role: .destructive) { signOut() }
            Button("取消", role: .cancel) {}
        }
    }

    // MARK: - 智能体开关

    private var agentSection: some View {
        Section {
            Toggle(isOn: toolBinding) {
                SettingsRowLabel(symbol: "wand.and.stars", color: .purple, title: "让智能体操作仓库")
            }
            .accessibilityIdentifier("git.agentTools")
        } header: {
            Text("智能体")
        } footer: {
            Text("开启后模型可调用 \(provider.displayName) 工具查看仓库、读写文件与创建 Issue；需要先登录账号，否则工具不会下发给模型。")
        }
    }

    // MARK: - 账号

    @ViewBuilder
    private var accountSection: some View {
        if isConnected {
            connectedSection
        } else {
            loginSection
        }
    }

    private var connectedSection: some View {
        Section {
            LabeledContent("账号", value: gitStore.account(for: provider) ?? "已登录")
            LabeledContent("Token", value: "已保存在本机钥匙串")
            Button(role: .destructive) {
                showSignOutConfirm = true
            } label: {
                Label("退出登录", systemImage: "rectangle.portrait.and.arrow.right")
            }
            .accessibilityIdentifier("git.signOut")
        } header: {
            Text("账号")
        } footer: {
            Text("退出后 Token 会从本机删除，智能体将无法再调用 \(provider.displayName) 工具。")
        }
    }

    private var loginSection: some View {
        Section {
            HStack(spacing: DSHTheme.Spacing.small) {
                Group {
                    if revealed {
                        TextField("粘贴 Token", text: $tokenInput)
                    } else {
                        SecureField("粘贴 Token", text: $tokenInput)
                    }
                }
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .font(.system(size: 14, design: .monospaced))
                .frame(maxWidth: .infinity, alignment: .leading)

                Button {
                    revealed.toggle()
                } label: {
                    Image(systemName: revealed ? "eye.slash" : "eye")
                        .foregroundStyle(.secondary)
                        .frame(width: 26, height: 26)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(revealed ? "隐藏 Token" : "显示 Token")
            }
            .accessibilityIdentifier("git.token")

            Button {
                connect()
            } label: {
                HStack {
                    Label("登录", systemImage: "person.badge.key.fill")
                    Spacer()
                    if connecting {
                        ProgressView().controlSize(.small)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(connecting || trimmedToken.isEmpty)
            .accessibilityIdentifier("git.login")

            if let message {
                Text(message)
                    .font(.system(size: 13))
                    .foregroundStyle(succeeded ? DSHTheme.success : DSHTheme.danger)
                    .accessibilityIdentifier("git.login.result")
            }
        } header: {
            Text("登录")
        } footer: {
            Text("登录时会用 Token 请求一次账号信息，确认 Token 有效且具备仓库权限；Token 只保存在本机钥匙串。")
        }
    }

    // MARK: - 帮助

    private var helpSection: some View {
        Section {
            Link(destination: provider.tokenPageURL) {
                Label("前往 \(provider.displayName) 创建 Token", systemImage: "safari")
            }
        } header: {
            Text("获取 Token")
        } footer: {
            Text(provider.scopeHint)
        }
    }

    // MARK: - 行为

    private var trimmedToken: String {
        tokenInput.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func connect() {
        let token = trimmedToken
        guard !token.isEmpty else { return }
        connecting = true
        message = nil
        Task { @MainActor in
            defer { connecting = false }
            do {
                let name = try await gitStore.connect(provider, token: token)
                succeeded = true
                message = "已登录 \(name)"
                tokenInput = ""
            } catch {
                succeeded = false
                message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }
    }

    private func signOut() {
        gitStore.signOut(provider)
        tokenInput = ""
        message = nil
    }
}