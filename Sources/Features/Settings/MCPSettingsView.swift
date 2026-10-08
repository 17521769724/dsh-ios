import SwiftUI

/// MCP 服务器管理：支持 MCP 2025-03-26 规范的 Streamable HTTP 远程服务器。
/// 连接成功后，它的工具会下发给智能体（工具名前缀 `mcp_<服务器别名>_`）。
struct MCPSettingsView: View {
    @EnvironmentObject private var mcpStore: MCPStore

    @State private var refreshingAll = false

    var body: some View {
        List {
            Section {
                if mcpStore.servers.isEmpty {
                    Text("还没有 MCP 服务器，点右上角「+」添加")
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("mcp.empty")
                } else {
                    ForEach(mcpStore.servers) { server in
                        NavigationLink {
                            MCPServerDetailView(serverID: server.id)
                        } label: {
                            row(server)
                        }
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

    @State private var showDeleteConfirm = false
    @State private var loadingPrompt: String?

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
                Task { await mcpStore.refresh(id: serverID) }
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
            if let error = server.lastError {
                Text(error).foregroundStyle(DSHTheme.danger)
            } else if let connectedAt = server.lastConnectedAt {
                Text("最近连接：\(Self.formatter.string(from: connectedAt))\(server.serverName.map { " · \($0)" } ?? "")\(server.protocolVersion.map { " · MCP \($0)" } ?? "")")
            } else {
                Text("修改后点「连接并刷新」生效。")
            }
        }
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
                Label("删除服务器", systemImage: "trash")
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