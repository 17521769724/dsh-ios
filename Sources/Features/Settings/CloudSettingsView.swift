import SwiftUI
import UniformTypeIdentifiers

/// 云端推理：把 Agent 部署到用户自己的 SSH 服务器上，会话交由服务器推理。
/// 本页包含：总开关（顶部）、一键部署与连接检测、沙盒管理（创建/暂停/恢复/销毁）。
struct CloudSettingsView: View {
    @EnvironmentObject private var settingsStore: SettingsStore
    @EnvironmentObject private var sshStore: SSHStore
    @EnvironmentObject private var cloudStore: CloudStore

    @State private var sandboxes: [CloudSandbox] = []
    @State private var loading = false
    @State private var newSandboxName = ""
    @State private var message: String?
    @State private var errorText: String?
    /// 部署日志弹窗
    @State private var loadingLog = false
    @State private var showLog = false
    @State private var logText = ""

    var body: some View {
        List {
            enableSection
            deploySection
            deployActionSection
            sandboxSection
        }
        .listStyle(.insetGrouped)
        .navigationTitle("云端推理")
        .navigationBarTitleDisplayMode(.inline)
        .tint(DSHTheme.brand)
        .task { await refreshSandboxes() }
        .refreshable { await refreshSandboxes() }
        .alert("提示", isPresented: messagePresented) {
            Button("好的", role: .cancel) { message = nil }
        } message: {
            Text(message ?? "")
        }
        .alert("出错了", isPresented: errorPresented) {
            Button("好的", role: .cancel) { errorText = nil }
        } message: {
            Text(errorText ?? "")
        }
        // 部署日志：可滚动的弹窗，排查部署失败用
        .sheet(isPresented: $showLog) {
            NavigationStack {
                ScrollView {
                    Text(logText)
                        .font(.system(size: 12, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                }
                .background(Color(uiColor: .systemGroupedBackground))
                .navigationTitle("部署日志")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button("完成") { showLog = false }
                    }
                }
            }
        }
    }

    private var messagePresented: Binding<Bool> {
        Binding(get: { message != nil }, set: { if !$0 { message = nil } })
    }

    private var errorPresented: Binding<Bool> {
        Binding(get: { errorText != nil }, set: { if !$0 { errorText = nil } })
    }

    private var client: CloudAgentClient? {
        guard let baseURL = cloudStore.baseURL(for: cloudStore.selectedServer(in: sshStore.servers)) else { return nil }
        return CloudAgentClient(baseURL: baseURL, token: cloudStore.token)
    }

    /// 当前选中的服务器（未选或已删除时回退第一台）
    private var selectedServer: SSHServer? {
        cloudStore.selectedServer(in: sshStore.servers)
    }

    // MARK: - 总开关

    private var enableSection: some View {
        Section {
            Toggle(isOn: $settingsStore.settings.features.cloudInference) {
                SettingsRowLabel(symbol: "cloud.fill", color: .blue, title: "使用云端推理")
            }
            .accessibilityIdentifier("cloud.enabled")
        } header: {
            Text("推理方式")
        } footer: {
            Text("开启后，新消息交由云服务器上的 Agent 推理并流式返回本机；App 退到后台推理不会中断，回到前台自动补全内容。关闭则保持本机直连模型。云端模式暂不支持图片与智能体工具（工具仍可在本机模式使用）。")
        }
    }

    // MARK: - 部署与检测

    private var deploySection: some View {
        Section {
            if sshStore.servers.isEmpty {
                LabeledContent("SSH 服务器") {
                    Text("未配置（先去「SSH 云服务器」添加）")
                        .foregroundStyle(Color.red)
                }
            } else {
                // 多台服务器时在这里指定云端推理与部署使用哪一台：
                // 只显示服务器名称（过长省略），保证这一行不换行
                HStack(spacing: DSHTheme.Spacing.small) {
                    Text("SSH 服务器")
                    Spacer(minLength: DSHTheme.Spacing.small)
                    Menu {
                        ForEach(sshStore.servers) { server in
                            Button {
                                cloudStore.configuration.sshServerID = server.id
                            } label: {
                                if server.id == selectedServer?.id {
                                    Label(server.displayName, systemImage: "checkmark")
                                } else {
                                    Text(server.displayName)
                                }
                            }
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Text(selectedServer?.displayName ?? "未选择")
                                .lineLimit(1)
                                .truncationMode(.tail)
                            Image(systemName: "chevron.up.chevron.down")
                                .font(.system(size: 10, weight: .semibold))
                        }
                        .foregroundStyle(DSHTheme.secondaryText)
                    }
                    .accessibilityIdentifier("cloud.serverPicker")
                }
            }
            LabeledContent("服务端口") {
                // grouping(.never)：避免显示成 8,931 这种带千位分隔符的写法
                TextField("8931", value: $cloudStore.configuration.port, format: .number.grouping(.never))
                    .multilineTextAlignment(.trailing)
                    .keyboardType(.numberPad)
                    .accessibilityIdentifier("cloud.port")
            }
            LabeledContent("访问令牌") {
                Text(cloudStore.token.prefix(8) + "…")
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("服务器 Agent")
        } footer: {
            Text("云端推理与部署都用这里选择的服务器；密码保存在本机钥匙串，不会上传。")
        }
    }

    /// 操作卡片（一键创建 / 检测连接 / 查看部署日志）：单独一张卡片，间距与其它操作行一致
    private var deployActionSection: some View {
        Section {
            Button {
                Task { await deploy() }
            } label: {
                HStack(spacing: DSHTheme.Spacing.small) {
                    if cloudStore.deploying {
                        ProgressView().controlSize(.small)
                    }
                    Text(cloudStore.deploying ? "正在创建云端环境…" : "一键创建云端 Agent 工作环境")
                }
            }
            .disabled(cloudStore.deploying)
            .accessibilityIdentifier("cloud.deploy")

            Button("检测连接") {
                Task { await check() }
            }
            .disabled(cloudStore.deploying)
            .accessibilityIdentifier("cloud.check")

            // 部署失败时用它排查：把服务器上的 Agent 日志取回来弹窗展示
            Button {
                Task { await loadLog() }
            } label: {
                HStack(spacing: DSHTheme.Spacing.small) {
                    Label("查看部署日志", systemImage: "doc.text.magnifyingglass")
                    Spacer(minLength: 0)
                    if loadingLog {
                        ProgressView().controlSize(.small)
                    }
                }
                .contentShape(Rectangle())
            }
            .disabled(loadingLog || cloudStore.deploying || selectedServer == nil)
            .accessibilityIdentifier("cloud.log")

            if let health = cloudStore.healthText {
                LabeledContent("连接状态") {
                    Text(health).foregroundStyle(.green)
                }
            }
        } header: {
            Text("操作")
        } footer: {
            Text("部署通过 SSH 把 Agent 装到上面所选服务器上并后台启动（仅你本机的令牌可访问），结果以弹窗提示。缺少 python3 时会尝试自动安装。若「检测连接」失败，请确认服务在运行，并在云服务器安全组放行该端口。模型 Key 不会保存到服务器，每次请求随会话下发。")
        }
    }

    // MARK: - 沙盒

    private var sandboxSection: some View {
        Section {
            if loading && sandboxes.isEmpty {
                HStack { ProgressView().controlSize(.small); Text("正在读取沙盒…").foregroundStyle(.secondary) }
            } else if sandboxes.isEmpty {
                Text("还没有沙盒。发送第一条云端消息时会自动创建，也可以手动新建。")
                    .foregroundStyle(.secondary)
            }
            ForEach(sandboxes) { sandbox in
                NavigationLink {
                    CloudSandboxDetailView(sandbox: sandbox) {
                        Task { await refreshSandboxes() }
                    }
                } label: {
                    HStack(spacing: DSHTheme.Spacing.medium) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(sandbox.id)
                            Text("\(sandbox.stateText) · \(sandbox.files ?? 0) 个文件")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if sandbox.isPaused {
                            Text("已暂停")
                                .font(.caption2)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(DSHTheme.chipFill)
                                .clipShape(Capsule())
                        }
                    }
                    .contentShape(Rectangle())
                }
                .accessibilityIdentifier("cloud.sandbox.\(sandbox.id)")
            }

            HStack(spacing: DSHTheme.Spacing.small) {
                TextField("新沙盒名称（如 work）", text: $newSandboxName)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .accessibilityIdentifier("cloud.newSandbox")
                Button("创建") {
                    Task { await createSandbox() }
                }
                .disabled(newSandboxName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        } header: {
            Text("沙盒（工作目录）")
        } footer: {
            Text("沙盒用来存放云端任务的文件，可暂停（停止其中任务并拒绝新请求）、恢复、销毁。默认沙盒「\(cloudStore.configuration.sandboxID)」在首次发送消息时自动创建。")
        }
    }

    // MARK: - 操作

    private func refreshSandboxes() async {
        guard let client else { return }
        loading = true
        defer { loading = false }
        do {
            sandboxes = try await client.listSandboxes()
        } catch {
            // 列表拉取失败不算错误：未部署时静默，由「检测连接」给出提示
            cloudStore.healthText = nil
        }
    }

    private func deploy() async {
        guard let server = selectedServer, server.isFilled else {
            errorText = "请先在「设置 → SSH 云服务器」里添加服务器（主机、用户名必填）。"
            return
        }
        guard !sshStore.password(for: server.id).isEmpty else {
            errorText = "「\(server.displayName)」还没有填写登录密码：请到「SSH 云服务器」里补上。"
            return
        }
        guard let source = CloudDeploy.agentSource() else {
            errorText = "App 内置的 Agent 脚本缺失，请更新应用后重试。"
            return
        }
        cloudStore.deploying = true
        defer { cloudStore.deploying = false }
        do {
            let script = CloudDeploy.script(
                source: source,
                port: cloudStore.configuration.port,
                token: cloudStore.token
            )
            let output = try await SSHService.execute(
                command: script,
                server: server,
                password: sshStore.password(for: server.id),
                timeout: 240
            )
            if CloudDeploy.missingPython(output) {
                errorText = "服务器上没有 python3，且自动安装失败。请在服务器上手动安装（apt install python3 / yum install python3）后重试。"
                return
            }
            if !CloudDeploy.succeeded(output) {
                errorText = "部署脚本已执行，但服务没有通过自检。可点下方「查看部署日志」排查。"
                return
            }
            await check(afterDeploy: true)
        } catch {
            errorText = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    /// 把服务器上的 Agent 日志取回来，以弹窗展示（部署失败时排查用）
    private func loadLog() async {
        guard let server = selectedServer, server.isFilled else {
            errorText = "请先在「设置 → SSH 云服务器」里添加服务器。"
            return
        }
        loadingLog = true
        defer { loadingLog = false }
        do {
            // 日志文件在部署脚本写死的目录下；没有文件时给一句人话提示
            let output = try await SSHService.execute(
                command: "tail -n 120 \(CloudDeploy.remoteDirectory)/agent.log 2>/dev/null || echo \"（服务器上还没有日志：可能尚未部署）\"",
                server: server,
                password: sshStore.password(for: server.id)
            )
            logText = "$ tail -n 120 ~/.dsh/agent.log · \(server.displayTarget)\n\n\(output)"
            showLog = true
        } catch {
            errorText = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    /// 检测连接：成功与否都以弹窗提示（部署完成后自动调用一次）
    private func check(afterDeploy: Bool = false) async {
        guard let server = selectedServer, server.isFilled else {
            errorText = "请先在「设置 → SSH 云服务器」里添加服务器。"
            return
        }
        guard let client else {
            errorText = CloudError.badURL.localizedDescription
            return
        }
        do {
            let version = try await client.health()
            cloudStore.healthText = "已连接（Agent \(version)）"
            message = afterDeploy
                ? "已在「\(server.displayName)」部署并连接正常（版本 \(version)）。\n\n打开顶部「使用云端推理」开关即可开始使用。"
                : "「\(server.displayName)」连接正常（Agent \(version)）。"
            await refreshSandboxes()
        } catch {
            cloudStore.healthText = nil
            errorText = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    private func createSandbox() async {
        guard let client else {
            errorText = CloudError.badURL.localizedDescription
            return
        }
        let name = newSandboxName.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            let sandbox = try await client.ensureSandbox(name)
            newSandboxName = ""
            message = "沙盒「\(sandbox.id)」已就绪"
            await refreshSandboxes()
        } catch {
            errorText = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }
}

// MARK: - 沙盒详情（暂停 / 恢复 / 销毁 + 文件管理）

struct CloudSandboxDetailView: View {
    @EnvironmentObject private var sshStore: SSHStore
    @EnvironmentObject private var cloudStore: CloudStore

    let sandbox: CloudSandbox
    /// 沙盒状态被改动后通知列表刷新
    var onChanged: () -> Void

    @State private var files: [CloudFileItem] = []
    @State private var busy = false
    @State private var message: String?
    @State private var errorText: String?
    @State private var shareItem: ShareItem?
    @State private var showImporter = false
    @State private var current: CloudSandbox

    init(sandbox: CloudSandbox, onChanged: @escaping () -> Void) {
        self.sandbox = sandbox
        self.onChanged = onChanged
        _current = State(initialValue: sandbox)
    }

    private struct ShareItem: Identifiable {
        let id = UUID()
        let url: URL
    }

    private var client: CloudAgentClient? {
        guard let baseURL = cloudStore.baseURL(for: cloudStore.selectedServer(in: sshStore.servers)) else { return nil }
        return CloudAgentClient(baseURL: baseURL, token: cloudStore.token)
    }

    var body: some View {
        List {
            Section {
                LabeledContent("状态", value: current.stateText)
                Button(current.isPaused ? "恢复沙盒" : "暂停沙盒") {
                    Task { await togglePause() }
                }
                .disabled(busy)
                .accessibilityIdentifier("cloud.sandbox.toggle")
                Button("销毁沙盒（删除全部文件）", role: .destructive) {
                    Task { await destroy() }
                }
                .disabled(busy)
                .accessibilityIdentifier("cloud.sandbox.destroy")
            } header: {
                Text("沙盒")
            } footer: {
                Text("暂停会停止其中正在执行的任务并拒绝新请求；恢复后可继续使用；销毁会删除整个目录且不可恢复。")
            }

            Section {
                if files.isEmpty {
                    Text("沙盒里还没有文件。上传后云端的任务就可以读写它们。")
                        .foregroundStyle(.secondary)
                }
                ForEach(files) { file in
                    HStack(spacing: DSHTheme.Spacing.medium) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(file.name).font(.system(size: 15))
                            Text(file.sizeText).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "square.and.arrow.down")
                            .font(.system(size: 13))
                            .foregroundStyle(DSHTheme.tertiaryText)
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { Task { await download(file) } }
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) {
                            Task { await delete(file) }
                        } label: {
                            Label("删除", systemImage: "trash")
                        }
                    }
                }
                Button {
                    showImporter = true
                } label: {
                    Label("上传文件", systemImage: "square.and.arrow.up")
                }
                .disabled(busy)
                .accessibilityIdentifier("cloud.file.upload")
            } header: {
                Text("文件")
            } footer: {
                Text("点文件即可下载（下载后可保存到「文件」App 或分享）；左滑删除。")
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(current.id)
        .navigationBarTitleDisplayMode(.inline)
        .tint(DSHTheme.brand)
        .task { await loadFiles() }
        .refreshable { await loadFiles() }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.item], allowsMultipleSelection: false) { result in
            Task { await handleImport(result) }
        }
        .sheet(item: $shareItem) { item in
            ActivityView(items: [item.url])
        }
        .alert("提示", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
            Button("好的", role: .cancel) { message = nil }
        } message: {
            Text(message ?? "")
        }
        .alert("出错了", isPresented: Binding(get: { errorText != nil }, set: { if !$0 { errorText = nil } })) {
            Button("好的", role: .cancel) { errorText = nil }
        } message: {
            Text(errorText ?? "")
        }
    }

    // MARK: 操作

    private func loadFiles() async {
        guard let client else { return }
        do {
            files = try await client.listFiles(sandbox: current.id)
        } catch {
            // 沙盒可能刚被销毁：保持空列表并提示
            errorText = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    private func togglePause() async {
        guard let client else { return }
        busy = true
        defer { busy = false }
        do {
            if current.isPaused {
                try await client.resumeSandbox(current.id)
                message = "沙盒已恢复，可以继续发送云端会话了"
            } else {
                try await client.pauseSandbox(current.id)
                message = "沙盒已暂停；其中的任务已停止，新请求会被拒绝"
            }
            current = try await client.ensureSandbox(current.id)
            onChanged()
        } catch {
            errorText = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    private func destroy() async {
        guard let client else { return }
        busy = true
        defer { busy = false }
        do {
            try await client.destroySandbox(current.id)
            message = "沙盒已销毁"
            onChanged()
        } catch {
            errorText = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    private func download(_ file: CloudFileItem) async {
        guard let client else { return }
        busy = true
        defer { busy = false }
        do {
            let data = try await client.downloadFile(sandbox: current.id, name: file.name)
            let baseName = (file.name as NSString).lastPathComponent
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("dsh-cloud-\(UUID().uuidString.prefix(6))-\(baseName)")
            try data.write(to: url)
            shareItem = ShareItem(url: url)
        } catch {
            errorText = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    private func delete(_ file: CloudFileItem) async {
        guard let client else { return }
        do {
            try await client.deleteFile(sandbox: current.id, name: file.name)
            await loadFiles()
        } catch {
            errorText = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    private func handleImport(_ result: Result<[URL], Error>) async {
        guard let client else { return }
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            let accessing = url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }
            do {
                let data = try Data(contentsOf: url)
                busy = true
                defer { busy = false }
                try await client.uploadFile(sandbox: current.id, name: url.lastPathComponent, data: data)
                message = "已上传 \(url.lastPathComponent)"
                await loadFiles()
            } catch {
                errorText = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        case .failure(let error):
            errorText = error.localizedDescription
        }
    }
}