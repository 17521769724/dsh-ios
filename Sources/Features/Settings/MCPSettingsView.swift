import SwiftUI

/// MCP 服务器管理：支持 MCP 2025-03-26 规范的 Streamable HTTP 远程服务器。
/// 连接成功后，它的工具会下发给智能体（工具名前缀 `mcp_<服务器别名>_`）。
struct MCPSettingsView: View {
    @EnvironmentObject private var mcpStore: MCPStore
    @EnvironmentObject private var gitStore: GitAccountStore
    @EnvironmentObject private var engine: ChatEngine
    @EnvironmentObject private var settingsStore: SettingsStore

    @State private var refreshingAll = false
    /// 点开的服务器（用于推入详情页）
    @State private var detailServer: MCPServerConfig?
    /// 添加失败 / 未登录时的提示
    @State private var alertMessage: String?

    private var detailPresented: Binding<Bool> {
        Binding(
            get: { detailServer != nil },
            set: { if !$0 { detailServer = nil } }
        )
    }

    private var alertPresented: Binding<Bool> {
        Binding(
            get: { alertMessage != nil },
            set: { if !$0 { alertMessage = nil } }
        )
    }

    var body: some View {
        List {
            // 总开关在配置页顶部：设置首页那一行只有箭头
            Section {
                Toggle(isOn: $settingsStore.settings.features.mcpTool) {
                    SettingsRowLabel(symbol: "puzzlepiece.extension", color: .green, title: "MCP 工具")
                }
                .accessibilityIdentifier("feature.mcpTool")
            } header: {
                Text("智能体")
            } footer: {
                Text("开启后已连接服务器的工具会随请求下发给模型；关闭只影响下发，不影响这里的服务器配置。")
            }

            Section {
                ForEach(Self.presets) { preset in
                    Button {
                        add(preset)
                    } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 6) {
                                Text(preset.name)
                                    .font(.system(size: 15))
                                    .foregroundStyle(DSHTheme.assistantText)
                                if preset.needsToken, !hasGitHubToken {
                                    Text("需先登录 GitHub")
                                        .font(.system(size: 10, weight: .semibold))
                                        .foregroundStyle(DSHTheme.tertiaryText)
                                        .padding(.horizontal, 5)
                                        .padding(.vertical, 1)
                                        .background(DSHTheme.chipFill)
                                        .clipShape(Capsule())
                                }
                            }
                            Text(preset.detail)
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("mcp.preset")
                }
            } header: {
                Text("推荐服务器（点一下即添加）")
            } footer: {
                Text("都是官方提供的远程 MCP 服务器，无需本地安装：GitHub 官方 MCP 会用你在「代码托管」里登录的 Token 自动鉴权；DeepWiki 与 Context7 免鉴权，可直接用。")
            }

            Section {
                if mcpStore.servers.isEmpty {
                    Text("还没有 MCP 服务器，点右上角「+」添加")
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("mcp.empty")
                } else {
                    ForEach(mcpStore.servers) { server in
                        // 与技能库同一套左滑删除：删除区与卡片同高同圆角、固定红色实底
                        SwipeToDeleteRow(
                            onDelete: { mcpStore.delete(id: server.id) },
                            onTap: { detailServer = server },
                            tapTitle: "查看详情",
                            deleteTitle: "删除服务器"
                        ) {
                            HStack(spacing: DSHTheme.Spacing.small) {
                                row(server)
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(DSHTheme.tertiaryText)
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 12)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(DSHTheme.page)
                            .contentShape(Rectangle())
                        }
                        // 与其它分组统一内边距、去掉行间分割线：卡片宽度一致，列表中间不再出现杂线
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                        .accessibilityIdentifier("mcp.row")
                    }
                }
            } header: {
                Text("服务器（共 \(mcpStore.availableToolCount) 个工具）")
            } footer: {
                Text("支持按 MCP 2025-03-26 规范提供 Streamable HTTP 的远程服务器：添加后在详情页点「连接并刷新」，它的工具就会出现在对话里；需要鉴权的服务器在「请求头」里填 Authorization。stdio 类本地服务器 iOS 无法运行，旧版 HTTP+SSE 传输暂不支持。")
            }

            Section {
                Button {
                    Task {
                        refreshingAll = true
                        await mcpStore.refreshAll()
                        refreshingAll = false
                    }
                } label: {
                    HStack {
                        Label("全部刷新", systemImage: "arrow.triangle.2.circlepath")
                        Spacer()
                        if refreshingAll { ProgressView().controlSize(.small) }
                    }
                    .contentShape(Rectangle())
                }
                .disabled(refreshingAll || mcpStore.enabledServers.isEmpty)
                .accessibilityIdentifier("mcp.refreshAll")
            } footer: {
                Text("刷新会依次连接每台已启用的服务器，重新拉取工具与提示模板。")
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("MCP 服务器")
        .navigationBarTitleDisplayMode(.inline)
        .tint(DSHTheme.brand)
        // 服务器详情：卡片不是 NavigationLink（会与左滑抢手势），改为点按后按需推入
        .navigationDestination(isPresented: detailPresented) {
            if let server = detailServer {
                MCPServerDetailView(serverID: server.id)
            }
        }
        .alert("无法添加服务器", isPresented: alertPresented) {
            Button("知道了", role: .cancel) {}
        } message: {
            Text(alertMessage ?? "")
        }
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                NavigationLink {
                    MCPAddServerView()
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityIdentifier("mcp.add")
                .accessibilityLabel("添加服务器")
            }
        }
    }

    private func row(_ server: MCPServerConfig) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(server.name)
                    .font(.system(size: 16))
                if !server.isEnabled {
                    Text("已关闭")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(DSHTheme.chipFill)
                        .clipShape(Capsule())
                }
            }
            Text(statusText(server))
                .font(.system(size: 12))
                .foregroundStyle(server.lastError == nil ? Color.secondary : DSHTheme.danger)
                .lineLimit(2)
        }
        .padding(.vertical, 2)
    }

    private func statusText(_ server: MCPServerConfig) -> String {
        if let error = server.lastError { return error }
        guard !server.tools.isEmpty else { return "\(server.displayHost) · 未连接" }
        var text = "\(server.displayHost) · \(server.tools.count) 个工具"
        if let version = server.protocolVersion { text += " · MCP \(version)" }
        return text
    }

    // MARK: - 推荐服务器

    /// 预设的远程 MCP 服务器（官方托管，无需本地安装）
    private struct Preset: Identifiable {
        let name: String
        let urlString: String
        let detail: String
        /// 是否需要用 GitHub Token 鉴权
        let needsToken: Bool

        var id: String { name }
    }

    private static let presets: [Preset] = [
        Preset(
            name: "GitHub 官方 MCP",
            urlString: "https://api.githubcopilot.com/mcp/",
            detail: "仓库、Issue、PR、Actions 等操作；用「代码托管」里登录的 GitHub Token 自动鉴权",
            needsToken: true
        ),
        Preset(
            name: "DeepWiki",
            urlString: "https://mcp.deepwiki.com/mcp",
            detail: "查询任意 GitHub 仓库的文档结构与代码问答，免鉴权",
            needsToken: false
        ),
        Preset(
            name: "Context7",
            urlString: "https://mcp.context7.com/mcp",
            detail: "按库名取回最新版本文档与示例，写代码时避免用过时 API，免鉴权",
            needsToken: false
        )
    ]

    private var hasGitHubToken: Bool { gitStore.isConnected(.github) }

    /// 添加预设：重复地址会跳过；需要鉴权的服务器先确认账号已登录
    private func add(_ preset: Preset) {
        guard !mcpStore.servers.contains(where: { $0.urlString == preset.urlString }) else {
            engine.showToast("这台服务器已经添加过了")
            return
        }
        // GitHub 官方 MCP 必须带 Token：未登录时只提示去登录，不写入一份连不上的配置
        guard !preset.needsToken || hasGitHubToken else {
            alertMessage = "GitHub 账号未登录，请登录后再添加（设置 → 代码托管 → GitHub 账号）。"
            return
        }
        let token = gitStore.token(for: .github)
        let headers = preset.needsToken ? "Authorization: Bearer \(token)" : ""
        guard let server = mcpStore.add(name: preset.name, urlString: preset.urlString, headerLines: headers) else {
            alertMessage = "添加失败：服务器地址不合法。"
            return
        }
        engine.showToast("已添加，正在连接…")
        Task { await mcpStore.refresh(id: server.id) }
    }
}

// MARK: - 添加服务器

struct MCPAddServerView: View {
    @EnvironmentObject private var mcpStore: MCPStore
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var urlString = ""
    @State private var headerLines = ""
    @State private var invalidMessage: String?
    @State private var saving = false

    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !urlString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !saving
    }

    var body: some View {
        Form {
            Section("名称") {
                TextField("例如：DeepWiki", text: $name)
                    .accessibilityIdentifier("mcp.editor.name")
            }

            Section {
                TextField("https://example.com/mcp", text: $urlString)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(.system(size: 14, design: .monospaced))
                    .accessibilityIdentifier("mcp.editor.url")
            } header: {
                Text("服务器地址")
            } footer: {
                Text("填 MCP 服务器的端点地址（Streamable HTTP），例如 https://mcp.example.com/mcp。")
            }

            Section {
                TextField("Authorization: Bearer xxx", text: $headerLines, axis: .vertical)
                    .lineLimit(2...4)
                    .font(.system(size: 13, design: .monospaced))
                    .accessibilityIdentifier("mcp.editor.headers")
            } header: {
                Text("请求头（可选）")
            } footer: {
                Text("每行一条「Key: Value」，用于需要鉴权的服务器。")
            }

            if let invalidMessage {
                Section {
                    Text(invalidMessage)
                        .font(.system(size: 13))
                        .foregroundStyle(DSHTheme.danger)
                }
            }
        }
        .navigationTitle("添加 MCP 服务器")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button("保存") { save() }
                    .disabled(!canSave)
                    .accessibilityIdentifier("mcp.editor.save")
            }
        }
    }

    private func save() {
        guard let config = mcpStore.add(name: name, urlString: urlString, headerLines: headerLines) else {
            invalidMessage = "请填写名称与合法的 http(s) 地址"
            return
        }
        // 保存后立即连接一次，直接拿到工具清单
        saving = true
        Task {
            await mcpStore.refresh(id: config.id)
            saving = false
            dismiss()
        }
    }
}

// MARK: - 服务器详情

struct MCPServerDetailView: View {
    let serverID: UUID

    @EnvironmentObject private var mcpStore: MCPStore
    @EnvironmentObject private var engine: ChatEngine
    @Environment(\.dismiss) private var dismiss

    @State private var showDeleteConfirm = false
    @State private var loadingPrompt: String?
    /// 连接并刷新的结果弹窗（成功给工具数量，失败给原因）
    @State private var showConnectionAlert = false
    @State private var connectionSucceeded = false
    @State private var connectionResult: String?

    private var server: MCPServerConfig? { mcpStore.server(id: serverID) }

    var body: some View {
        List {
            if let server {
                serverSection(server)
                toolsSection(server)
                promptsSection(server)
                dangerSection(server)
            } else {
                Text("服务器已被删除")
                    .foregroundStyle(.secondary)
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(server?.name ?? "MCP 服务器")
        .navigationBarTitleDisplayMode(.inline)
        .tint(DSHTheme.brand)
        .confirmationDialog("确定删除这台服务器？", isPresented: $showDeleteConfirm, titleVisibility: .visible) {
            Button("删除", role: .destructive) {
                mcpStore.delete(id: serverID)
                dismiss()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("删除后它的工具不会再出现在对话里。")
        }
        // 连接并刷新的结果：弹窗提示成功还是失败
        .alert(connectionSucceeded ? "连接成功" : "连接失败", isPresented: $showConnectionAlert) {
            Button("好的", role: .cancel) {}
        } message: {
            Text(connectionResult ?? "")
        }
    }

    // MARK: 基本信息

    private func serverSection(_ server: MCPServerConfig) -> some View {
        Section {
            TextField("名称", text: nameBinding)
                .accessibilityIdentifier("mcp.detail.name")

            TextField("https://example.com/mcp", text: urlBinding)
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .font(.system(size: 14, design: .monospaced))
                .accessibilityIdentifier("mcp.detail.url")

            TextField("Authorization: Bearer xxx", text: headersBinding, axis: .vertical)
                .lineLimit(1...3)
                .font(.system(size: 13, design: .monospaced))
                .accessibilityIdentifier("mcp.detail.headers")

            Toggle(isOn: enabledBinding) {
                Text("启用（工具下发给模型）")
            }
            .accessibilityIdentifier("mcp.detail.enabled")

            Button {
                Task { await refreshAndReport() }
            } label: {
                HStack {
                    Label("连接并刷新", systemImage: "arrow.triangle.2.circlepath")
                    Spacer()
                    if mcpStore.refreshing.contains(serverID) {
                        ProgressView().controlSize(.small)
                    }
                }
                .contentShape(Rectangle())
            }
            .disabled(mcpStore.refreshing.contains(serverID))
            .accessibilityIdentifier("mcp.detail.refresh")
        } header: {
            Text("连接设置")
        } footer: {
            // 卡片下方只显示最近连接时间；连接成功/失败改为弹窗提示
            if let connectedAt = server.lastConnectedAt {
                Text("最近连接：\(Self.formatter.string(from: connectedAt))")
            } else {
                Text("尚未连接过，点「连接并刷新」试试，结果会以弹窗提示。")
            }
        }
    }

    /// 连接并刷新：结果以弹窗提示（成功给工具数量，失败给原因）
    private func refreshAndReport() async {
        await mcpStore.refresh(id: serverID)
        guard let server = mcpStore.server(id: serverID) else { return }
        if let error = server.lastError {
            connectionSucceeded = false
            connectionResult = "连接失败：\(error)"
        } else {
            connectionSucceeded = true
            var text = "连接成功：已获取 \(server.tools.count) 个工具"
            if let name = server.serverName, !name.isEmpty {
                text += "（\(name)）"
            }
            if let version = server.protocolVersion {
                text += "\n协议版本：MCP \(version)"
            }
            if !server.prompts.isEmpty {
                text += "\n提示模板：\(server.prompts.count) 个"
            }
            connectionResult = text
        }
        showConnectionAlert = true
    }

    // MARK: 工具

    private func toolsSection(_ server: MCPServerConfig) -> some View {
        Section {
            if server.tools.isEmpty {
                Text("还没有工具：点「连接并刷新」从服务端拉取")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("mcp.tools.empty")
            } else {
                ForEach(server.tools) { tool in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(tool.name)
                            .font(.system(size: 15, design: .monospaced))
                        if !tool.description.isEmpty {
                            Text(tool.description)
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                                .lineLimit(3)
                        }
                        Text(MCPStore.modelToolName(alias: server.alias.isEmpty ? "server" : server.alias, tool: tool.name))
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(DSHTheme.tertiaryText)
                    }
                    .padding(.vertical, 2)
                }
            }
        } header: {
            Text("工具（\(server.tools.count)）")
        } footer: {
            Text("这些工具会随请求下发给模型，模型按需调用并由本机代发到 MCP 服务器。")
        }
    }

    // MARK: 提示模板

    @ViewBuilder
    private func promptsSection(_ server: MCPServerConfig) -> some View {
        if !server.prompts.isEmpty {
            Section {
                ForEach(server.prompts) { prompt in
                    Button {
                        fill(prompt)
                    } label: {
                        HStack(spacing: DSHTheme.Spacing.small) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(prompt.name)
                                    .font(.system(size: 15))
                                    .foregroundStyle(DSHTheme.assistantText)
                                if !prompt.description.isEmpty {
                                    Text(prompt.description)
                                        .font(.system(size: 12))
                                        .foregroundStyle(.secondary)
                                        .lineLimit(2)
                                }
                            }
                            Spacer(minLength: DSHTheme.Spacing.small)
                            if loadingPrompt == prompt.name {
                                ProgressView().controlSize(.small)
                            } else if prompt.needsArguments {
                                Text("需要参数")
                                    .font(.system(size: 11))
                                    .foregroundStyle(DSHTheme.tertiaryText)
                            } else {
                                Image(systemName: "arrow.down.to.line")
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(DSHTheme.brand)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(prompt.needsArguments || loadingPrompt != nil)
                }
            } header: {
                Text("提示模板（\(server.prompts.count)）")
            } footer: {
                Text("点一条即可把模板内容填入对话输入框；带参数的模板请到对应工具里手动使用。")
            }
        }
    }

    // MARK: 删除

    private func dangerSection(_ server: MCPServerConfig) -> some View {
        Section {
            Button(role: .destructive) {
                showDeleteConfirm = true
            } label: {
                // 图标与文字都用同一个红色，避免出现「蓝图标 + 红文字」的不一致观感
                HStack(spacing: DSHTheme.Spacing.small) {
                    Image(systemName: "trash")
                    Text("删除服务器")
                    Spacer(minLength: 0)
                }
                .foregroundStyle(DSHTheme.danger)
                .contentShape(Rectangle())
            }
            .accessibilityIdentifier("mcp.detail.delete")
        }
    }

    // MARK: 绑定

    private var nameBinding: Binding<String> {
        Binding(
            get: { mcpStore.server(id: serverID)?.name ?? "" },
            set: { value in mcpStore.update(id: serverID) { $0.name = value } }
        )
    }

    private var urlBinding: Binding<String> {
        Binding(
            get: { mcpStore.server(id: serverID)?.urlString ?? "" },
            set: { value in mcpStore.update(id: serverID) { $0.urlString = value } }
        )
    }

    private var headersBinding: Binding<String> {
        Binding(
            get: { mcpStore.server(id: serverID)?.headerLines ?? "" },
            set: { value in mcpStore.update(id: serverID) { $0.headerLines = value } }
        )
    }

    private var enabledBinding: Binding<Bool> {
        Binding(
            get: { mcpStore.server(id: serverID)?.isEnabled ?? true },
            set: { value in mcpStore.setEnabled(value, id: serverID) }
        )
    }

    private func fill(_ prompt: MCPPromptInfo) {
        guard loadingPrompt == nil else { return }
        loadingPrompt = prompt.name
        Task {
            let text = await mcpStore.loadPrompt(serverID: serverID, name: prompt.name)
            loadingPrompt = nil
            guard let text, !text.isEmpty else {
                engine.showToast("提示模板读取失败")
                return
            }
            engine.draft = text
            engine.showToast("已填入输入框，关闭设置后即可发送")
        }
    }

    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MM-dd HH:mm"
        return formatter
    }()
}