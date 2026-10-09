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

    // Gitee 一键登录（授权码模式）
    @State private var pendingGiteeState: String?
    @State private var awaitingGiteeCallback = false
    @State private var giteeMessage: String?
    @State private var giteeSucceeded = false

    // 内置浏览器（打开授权页 / 创建令牌页）
    @State private var browserRequest: BrowserRequest?

    // 仓库列表
    @State private var repositories: [GitService.RepositorySummary] = []
    @State private var loadingRepositories = false
    @State private var repositoryError: String?

    private var settings: AppSettings { settingsStore.settings }
    private var isConnected: Bool { gitStore.isConnected(provider) }
    /// GitHub 走设备码流程
    private var supportsDeviceFlow: Bool { provider == .github }
    /// Gitee 走授权码流程（需要应用凭据）
    private var supportsGiteeOneClick: Bool { provider == .gitee && GiteeAuthService.isConfigured }

    var body: some View {
        List {
            // 开关放在配置页顶部：设置首页那一行只留进入配置的箭头
            agentSection
            accountSection
            if isConnected {
                repositorySection
            }
            capabilitiesSection
        }
        .listStyle(.insetGrouped)
        // 登录状态切换会整段替换登录/账号区块，SwiftUI 增量更新时有概率漏画分隔线（退出登录上方那条）。
        // 用 id 让列表在状态变化时整体重建，分隔线一定重新绘制。
        .id(isConnected)
        .navigationTitle(provider.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .tint(DSHTheme.brand)
        .onAppear { loadRepositories() }
        .onDisappear { deviceTask?.cancel() }
        // 用内置浏览器打开网站，用户不必离开 App；Gitee 授权回调在这里被拦下
        .sheet(item: $browserRequest) { request in
            BrowserView(initialURL: request.url, onRedirect: handleRedirect)
                .environmentObject(settingsStore)
                .dshAppearance(settings.appTheme)
        }
        .onChange(of: browserRequest) { request in
            // 用户手动关掉内置浏览器：结束等待授权状态
            guard request == nil, awaitingGiteeCallback else { return }
            pendingGiteeState = nil
            awaitingGiteeCallback = false
            giteeSucceeded = false
            giteeMessage = "已取消登录"
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

    private var toolBinding: Binding<Bool> {
        switch provider {
        case .github: return $settingsStore.settings.features.githubTool
        case .gitee: return $settingsStore.settings.features.giteeTool
        }
    }

    // MARK: - 账号 / 登录

    @ViewBuilder
    private var accountSection: some View {
        if isConnected {
            connectedSection
        } else {
            // GitHub 走设备码；Gitee 走授权码；两者都保留 Token 登录
            if supportsDeviceFlow {
                deviceLoginSection
            }
            if supportsGiteeOneClick {
                giteeOneClickSection
            }
            manualTokenSection
        }
    }

    private var connectedSection: some View {
        Section {
            LabeledContent("账号", value: gitStore.account(for: provider) ?? "已登录")
                .listRowSeparator(.visible)
            LabeledContent("Token", value: "已保存在本机钥匙串")
                .listRowSeparator(.visible)
            Button(role: .destructive) {
                showSignOutConfirm = true
            } label: {
                // power 是各版本 iOS 都有的退出符号，避免较新的矩形箭头符号在某些机型上渲染异常
                Label("退出登录", systemImage: "power")
            }
            .listRowSeparator(.visible)
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
            Text("一键登录")
        } footer: {
            Text("点击后会打开 GitHub 授权页（设备码自动复制），确认后 App 会自己完成登录，无需手动创建 Token。若网络连不上 GitHub，可用下方「Token 登录」。")
        }
    }

    /// Gitee：一键登录（授权码模式，需要已配置应用凭据）
    private var giteeOneClickSection: some View {
        Section {
            if awaitingGiteeCallback {
                VStack(alignment: .leading, spacing: 12) {
                    Text("已打开 Gitee 授权页，点「同意授权」后会自动完成登录。")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)

                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("等待你在网页完成授权…")
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                    }

                    Button("取消登录", role: .destructive) { cancelGiteeLogin() }
                        .accessibilityIdentifier("git.giteeCancel")
                }
                .padding(.vertical, 4)
            } else {
                Button {
                    startGiteeLogin()
                } label: {
                    HStack {
                        Label("一键登录 Gitee", systemImage: "person.badge.key.fill")
                        Spacer()
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("git.giteeLogin")
            }

            if let giteeMessage {
                statusView(giteeMessage, ok: giteeSucceeded, identifier: "git.gitee.result")
            }
        } header: {
            Text("一键登录")
        } footer: {
            Text("点击后会打开 Gitee 授权页，点「同意授权」后 App 会自己用授权码换取 Token，无需手动创建 Token。")
        }
    }

    /// Token 直接登录：手动粘贴 Token，网络不通或一键登录不可用时的兜底
    private var manualTokenSection: some View {
        Section {
            LabeledContent("Token") {
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

                    Button {
                        revealed.toggle()
                    } label: {
                        Image(systemName: revealed ? "eye.slash" : "eye")
                            .foregroundStyle(.secondary)
                            .frame(width: 22, height: 22)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(revealed ? "隐藏 Token" : "显示 Token")
                }
                .accessibilityIdentifier("git.token")
            }

            Button {
                browserRequest = BrowserRequest(url: provider.tokenPageURL)
            } label: {
                Label("打开 \(provider.displayName) 令牌页", systemImage: "safari")
            }
            .accessibilityIdentifier("git.openTokenPage")

            Button {
                connect()
            } label: {
                HStack {
                    Label("登录", systemImage: "person.crop.circle.badge.checkmark")
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
            // GitHub 与 Gitee 都提供 Token 直接登录，Gitee 只有这一种方式
            Text("Token 登录")
        } footer: {
            Text("\(provider.scopeHint)登录时会用 Token 拉取一次账号信息做校验，失败会说明具体原因；Token 只保存在本机钥匙串。")
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

    private var trimmedToken: String {
        tokenInput.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - 行为：Gitee 一键登录（授权码）

    private func startGiteeLogin() {
        let state = GiteeAuthService.makeState()
        guard let url = GiteeAuthService.authorizeURL(state: state) else {
            giteeSucceeded = false
            giteeMessage = "尚未配置 Gitee 应用凭据。"
            return
        }
        pendingGiteeState = state
        awaitingGiteeCallback = true
        giteeSucceeded = false
        giteeMessage = nil
        browserRequest = BrowserRequest(url: url)
    }

    private func cancelGiteeLogin() {
        pendingGiteeState = nil
        awaitingGiteeCallback = false
        browserRequest = nil
        giteeSucceeded = false
        giteeMessage = "已取消登录"
    }

    /// 内置浏览器的跳转拦截：命中 Gitee 回调就接管并换取 Token
    private func handleRedirect(_ url: URL) -> Bool {
        guard provider == .gitee, awaitingGiteeCallback, GiteeAuthService.isCallback(url) else {
            return false
        }
        finishGiteeLogin(with: url)
        return true
    }

    private func finishGiteeLogin(with callback: URL) {
        let expectedState = pendingGiteeState ?? ""
        // 先结束等待状态，再关闭浏览器，避免 onChange 把它当成「用户取消」
        pendingGiteeState = nil
        awaitingGiteeCallback = false

        let code: String
        do {
            code = try GiteeAuthService.authorizationCode(from: callback, expectedState: expectedState)
        } catch {
            browserRequest = nil
            giteeSucceeded = false
            giteeMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            return
        }

        browserRequest = nil
        giteeMessage = "正在完成登录…"
        Task { @MainActor in
            do {
                let token = try await GiteeAuthService.exchangeToken(code: code)
                let name = try await gitStore.connect(.gitee, token: token)
                giteeSucceeded = true
                giteeMessage = "已登录 \(name)"
                loadRepositories()
            } catch {
                giteeSucceeded = false
                giteeMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }
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
        giteeMessage = nil
        awaitingGiteeCallback = false
        pendingGiteeState = nil
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