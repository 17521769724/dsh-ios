import SwiftUI
import UIKit

/// GitHub / Gitee 账号：登录后 Token 保存在本机钥匙串，
/// 页面内可直接看到仓库列表与智能体可执行的仓库操作。
struct GitAccountSettingsView: View {
    let provider: GitProvider

    @EnvironmentObject private var gitStore: GitAccountStore
    @EnvironmentObject private var settingsStore: SettingsStore

    // 手动 Token 登录
    @State private var tokenInput = ""
    @State private var revealed = false
    @State private var connecting = false
    @State private var message: String?
    @State private var succeeded = false
    @State private var showSignOutConfirm = false

    // GitHub 设备码登录
    @State private var deviceCode: GitHubAuthService.DeviceCode?
    @State private var deviceMessage: String?
    @State private var deviceSucceeded = false
    @State private var copiedCode = false
    @State private var deviceTask: Task<Void, Never>?

    // 内置浏览器（打开授权页 / 创建令牌页）
    @State private var browserRequest: BrowserRequest?

    // 仓库列表
    @State private var repositories: [GitService.RepositorySummary] = []
    @State private var loadingRepositories = false
    @State private var repositoryError: String?

    private var settings: AppSettings { settingsStore.settings }
    private var isConnected: Bool { gitStore.isConnected(provider) }
    /// Gitee 官方未提供设备码登录，只有 GitHub 支持一键登录
    private var supportsDeviceFlow: Bool { provider == .github }

    var body: some View {
        List {
            agentSection
            accountSection
            if isConnected {
                repositorySection
            }
            capabilitiesSection
        }
        .listStyle(.insetGrouped)
        .navigationTitle(provider.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .tint(DSHTheme.brand)
        .onAppear { loadRepositories() }
        .onDisappear { deviceTask?.cancel() }
        // 用内置浏览器打开网站，用户不必离开 App
        .sheet(item: $browserRequest) { request in
            BrowserView(initialURL: request.url)
                .environmentObject(settingsStore)
                .dshAppearance(settings.appTheme)
        }
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

    // MARK: - 账号 / 登录

    @ViewBuilder
    private var accountSection: some View {
        if isConnected {
            connectedSection
        } else if supportsDeviceFlow {
            deviceLoginSection
        } else {
            manualTokenSection
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

    /// GitHub：一键登录（设备码模式）
    private var deviceLoginSection: some View {
        Section {
            if let device = deviceCode {
                VStack(alignment: .leading, spacing: 12) {
                    Text("在打开的 GitHub 网页里输入下面的设备码并确认：")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)

                    HStack {
                        Text(device.userCode)
                            .font(.system(size: 26, weight: .semibold, design: .monospaced))
                            .textSelection(.enabled)
                        Spacer(minLength: DSHTheme.Spacing.small)
                        Button {
                            UIPasteboard.general.string = device.userCode
                            copiedCode = true
                        } label: {
                            Label(copiedCode ? "已复制" : "复制", systemImage: copiedCode ? "checkmark" : "doc.on.doc")
                                .font(.system(size: 13))
                        }
                        .buttonStyle(.borderless)
                        .accessibilityIdentifier("git.copyCode")
                    }

                    Button {
                        browserRequest = BrowserRequest(url: device.verificationURL)
                    } label: {
                        Label("打开 GitHub 授权页", systemImage: "safari")
                    }
                    .accessibilityIdentifier("git.openAuthorize")

                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("等待你在网页完成授权…")
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                    }

                    Button("取消登录", role: .destructive) { cancelDeviceLogin() }
                        .accessibilityIdentifier("git.cancelLogin")
                }
                .padding(.vertical, 4)
            } else {
                Button {
                    startDeviceLogin()
                } label: {
                    HStack {
                        Label("一键登录 GitHub", systemImage: "person.badge.key.fill")
                        Spacer()
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("git.deviceLogin")
            }

            if let deviceMessage {
                statusView(deviceMessage, ok: deviceSucceeded, identifier: "git.device.result")
            }
        } header: {
            Text("登录")
        } footer: {
            Text("点击后会打开 GitHub 授权页（设备码自动复制），确认后 App 会自己完成登录，无需手动创建 Token。")
        }
    }

    /// Gitee / 备用方案：手动填写 Token
    private var manualTokenSection: some View {
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
                browserRequest = BrowserRequest(url: provider.tokenPageURL)
            } label: {
                Label("打开 \(provider.displayName) 创建 Token 页面", systemImage: "safari")
            }
            .accessibilityIdentifier("git.openTokenPage")

            Button {
                connect()
            } label: {
                HStack {
                    Label("登录", systemImage: "key.fill")
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
                statusView(message, ok: succeeded, identifier: "git.login.result")
            }
        } header: {
            Text("登录")
        } footer: {
            Text("\(provider.scopeHint) 登录时会请求一次账号信息校验 Token；Token 只保存在本机钥匙串。")
        }
    }

    // MARK: - 仓库列表

    private var repositorySection: some View {
        Section {
            if loadingRepositories && repositories.isEmpty {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("正在获取仓库…")
                        .foregroundStyle(.secondary)
                }
            } else if let repositoryError {
                VStack(alignment: .leading, spacing: 6) {
                    Text(repositoryError)
                        .font(.system(size: 13))
                        .foregroundStyle(DSHTheme.danger)
                    Button("重新获取") { loadRepositories() }
                        .font(.system(size: 13))
                }
            } else if repositories.isEmpty {
                Text("账号下暂无可访问的仓库")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(repositories) { repo in
                    repositoryRow(repo)
                }
            }

            Button {
                loadRepositories()
            } label: {
                HStack {
                    Label("刷新仓库列表", systemImage: "arrow.clockwise")
                    Spacer()
                    if loadingRepositories {
                        ProgressView().controlSize(.small)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(loadingRepositories)
            .accessibilityIdentifier("git.refreshRepos")
        } header: {
            Text("仓库（最近更新 \(repositories.count) 个）")
        } footer: {
            Text("列表来自 \(provider.displayName) 的 /user/repos；点仓库名可在内置浏览器打开。")
        }
    }

    private func repositoryRow(_ repo: GitService.RepositorySummary) -> some View {
        Button {
            if let url = repo.webURL {
                browserRequest = BrowserRequest(url: url)
            }
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(repo.fullName)
                        .font(.system(size: 15))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text(repo.visibilityText)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(repo.isPrivate ? DSHTheme.warning : DSHTheme.success)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(DSHTheme.chipFill)
                        .clipShape(Capsule())
                }
                if !repo.summary.isEmpty {
                    Text(repo.summary)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Text("默认分支 \(repo.defaultBranch)")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(repo.webURL == nil)
    }

    // MARK: - 智能体可执行的操作

    private var capabilitiesSection: some View {
        Section {
            capabilityRow(symbol: "list.bullet", title: "list_repos", detail: "列出账号下的仓库")
            capabilityRow(symbol: "doc.text.magnifyingglass", title: "read_file", detail: "读取仓库里的文件内容")
            capabilityRow(symbol: "square.and.pencil", title: "write_file", detail: "新建或更新仓库文件（自动提交）")
            capabilityRow(symbol: "exclamationmark.bubble", title: "create_issue", detail: "在仓库里创建 Issue")
        } header: {
            Text("智能体可执行的操作")
        } footer: {
            Text("在对话里直接说明需求即可，例如「把 README 里的部署说明改成分步的」；模型会自动调用上面的工具并在对话里留下记录。")
        }
    }

    private func capabilityRow(symbol: String, title: String, detail: String) -> some View {
        HStack(spacing: DSHTheme.Spacing.medium) {
            Image(systemName: symbol)
                .font(.system(size: 14))
                .foregroundStyle(DSHTheme.brand)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 14, weight: .semibold, design: .monospaced))
                Text(detail)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - 子视图

    private func statusView(_ text: String, ok: Bool, identifier: String) -> some View {
        Text(text)
            .font(.system(size: 13))
            .foregroundStyle(ok ? DSHTheme.success : DSHTheme.danger)
            .accessibilityIdentifier(identifier)
    }

    private var toolBinding: Binding<Bool> {
        switch provider {
        case .github: return $settingsStore.settings.features.githubTool
        case .gitee: return $settingsStore.settings.features.giteeTool
        }
    }

    private var trimmedToken: String {
        tokenInput.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - 行为：设备码登录

    private func startDeviceLogin() {
        deviceMessage = nil
        copiedCode = false
        deviceTask?.cancel()
        deviceTask = Task { @MainActor in
            do {
                let device = try await GitHubAuthService.requestDeviceCode()
                deviceCode = device
                // 设备码直接放进剪贴板，网页里粘贴即可
                UIPasteboard.general.string = device.userCode
                copiedCode = true
                browserRequest = BrowserRequest(url: device.verificationURL)

                let token = try await GitHubAuthService.waitForToken(for: device)
                let name = try await gitStore.connectGitHub(accessToken: token)
                deviceCode = nil
                deviceSucceeded = true
                deviceMessage = "已登录 \(name)"
                loadRepositories()
            } catch is CancellationError {
                deviceCode = nil
            } catch {
                deviceCode = nil
                deviceSucceeded = false
                deviceMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }
    }

    private func cancelDeviceLogin() {
        deviceTask?.cancel()
        deviceTask = nil
        deviceCode = nil
        copiedCode = false
        deviceSucceeded = false
        deviceMessage = "已取消登录"
    }

    // MARK: - 行为：Token 登录

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
                loadRepositories()
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
        deviceMessage = nil
        repositories = []
        repositoryError = nil
    }

    // MARK: - 行为：仓库列表

    private func loadRepositories() {
        guard isConnected else {
            repositories = []
            return
        }
        guard !loadingRepositories else { return }
        loadingRepositories = true
        repositoryError = nil
        let token = gitStore.token(for: provider)

        Task { @MainActor in
            defer { loadingRepositories = false }
            do {
                repositories = try await GitService.listRepositories(provider: provider, token: token)
            } catch {
                repositories = []
                repositoryError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }
    }
}