import SwiftUI

/// SSH 云服务器：支持添加多台；每台一张卡片，点进去配置、测试连接与命令控制台。
/// 密码保存在本机钥匙串（按服务器区分），不会上传到任何服务。
struct SSHSettingsView: View {
    @EnvironmentObject private var sshStore: SSHStore
    @EnvironmentObject private var settingsStore: SettingsStore

    @State private var detailServer: SSHServer?

    private var detailPresented: Binding<Bool> {
        Binding(
            get: { detailServer != nil },
            set: { if !$0 { detailServer = nil } }
        )
    }

    var body: some View {
        List {
            // 开关放在配置页顶部：设置首页那一行只留进入配置的箭头
            agentSection

            Section {
                if sshStore.servers.isEmpty {
                    Text("还没有云服务器，点右上角「+」添加")
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("ssh.empty")
                } else {
                    ForEach(sshStore.servers) { server in
                        // 与技能库同一套左滑删除：删除区与卡片同高同圆角、固定红色实底
                        SwipeToDeleteRow(
                            onDelete: { sshStore.delete(id: server.id) },
                            onTap: { detailServer = server },
                            tapTitle: "编辑服务器",
                            deleteTitle: "删除服务器"
                        ) {
                            // 只显示服务器名称与右侧箭头（名称过长省略，卡片保持单行）
                            HStack(spacing: DSHTheme.Spacing.small) {
                                Text(server.displayName)
                                    .font(.system(size: 16))
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                                Spacer(minLength: DSHTheme.Spacing.small)
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
                        // 用系统标准行外观（白底、与同页其它分组同宽）；去掉行间分割线，避免列表中间出现杂线
                        .listRowSeparator(.hidden)
                        .accessibilityIdentifier("ssh.row")
                    }
                }
            } header: {
                Text("服务器（\(sshStore.servers.count) 台）")
            } footer: {
                Text("可以添加多台云服务器：智能体执行命令时可指定用哪一台，云端推理也能选用其中一台。密码保存在本机钥匙串。当前版本支持密码登录；使用密钥登录的服务器请先在服务器上开启密码认证。")
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("SSH 云服务器")
        .navigationBarTitleDisplayMode(.inline)
        .tint(DSHTheme.brand)
        // 卡片不是 NavigationLink（会与左滑抢手势），点按后按需推入详情页
        .navigationDestination(isPresented: detailPresented) {
            if let server = detailServer {
                SSHServerDetailView(serverID: server.id)
            }
        }
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                NavigationLink {
                    SSHServerEditorView()
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityIdentifier("ssh.addServer")
                .accessibilityLabel("添加服务器")
            }
        }
    }

    // MARK: - 智能体开关

    private var agentSection: some View {
        Section {
            Toggle(isOn: $settingsStore.settings.features.sshTool) {
                SettingsRowLabel(symbol: "terminal.fill", color: .black, title: "让智能体执行 SSH 命令")
            }
            .accessibilityIdentifier("ssh.agentTools")
        } header: {
            Text("智能体")
        } footer: {
            Text("开启后模型可自主在这些服务器上执行命令，可用 server 参数指定用哪一台（不填用第一台）；每次执行都会在对话里留下记录。")
        }
    }
}

// MARK: - 添加服务器

struct SSHServerEditorView: View {
    @EnvironmentObject private var sshStore: SSHStore
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var host = ""
    @State private var port = 22
    @State private var username = "root"
    @State private var password = ""

    private var canSave: Bool {
        !host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && port > 0 && port <= 65_535
    }

    var body: some View {
        Form {
            Section {
                TextField("例如：东京节点（可省略）", text: $name)
                    .accessibilityIdentifier("ssh.name")
            } header: {
                Text("名称")
            } footer: {
                Text("给服务器起个好记的名字，智能体指定服务器时可用它；省略则显示主机地址。")
            }

            Section {
                LabeledContent("主机") {
                    TextField("例如 1.2.3.4 或 server.example.com", text: $host)
                        .multilineTextAlignment(.trailing)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                        .accessibilityIdentifier("ssh.host")
                }
                LabeledContent("端口") {
                    TextField("22", value: $port, format: .number.grouping(.never))
                        .multilineTextAlignment(.trailing)
                        .keyboardType(.numberPad)
                        .accessibilityIdentifier("ssh.port")
                }
                LabeledContent("用户名") {
                    TextField("root", text: $username)
                        .multilineTextAlignment(.trailing)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .accessibilityIdentifier("ssh.username")
                }
                LabeledContent("密码") {
                    SecureField("登录密码", text: $password)
                        .multilineTextAlignment(.trailing)
                        .accessibilityIdentifier("ssh.password")
                }
            } header: {
                Text("连接信息")
            }
        }
        .navigationTitle("添加服务器")
        .navigationBarTitleDisplayMode(.inline)
        .tint(DSHTheme.brand)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button("保存") { save() }
                    .disabled(!canSave)
                    .accessibilityIdentifier("ssh.save")
            }
        }
    }

    private func save() {
        let server = sshStore.add(SSHServer(
            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            host: host.trimmingCharacters(in: .whitespacesAndNewlines),
            port: port,
            username: username.trimmingCharacters(in: .whitespacesAndNewlines)
        ))
        sshStore.setPassword(password, for: server.id)
        dismiss()
    }
}

// MARK: - 服务器详情（配置 + 测试连接 + 命令控制台）

struct SSHServerDetailView: View {
    let serverID: UUID

    @EnvironmentObject private var sshStore: SSHStore
    @Environment(\.dismiss) private var dismiss

    @State private var testing = false
    /// 测试连接的弹窗
    @State private var testMessage: String?
    @State private var testSucceeded = false
    @State private var showTestAlert = false
    /// 命令控制台：输入与结果弹窗
    @State private var command = ""
    @State private var running = false
    @State private var consoleTitle = ""
    @State private var consoleOutput: String?
    @State private var showConsole = false
    @State private var showDeleteConfirm = false

    private var server: SSHServer? { sshStore.server(id: serverID) }

    var body: some View {
        List {
            if let server {
                configSection(server)
                testSection(server)
                consoleSection(server)
                dangerSection
            } else {
                Text("服务器已被删除")
                    .foregroundStyle(.secondary)
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(server?.displayName ?? "服务器")
        .navigationBarTitleDisplayMode(.inline)
        .tint(DSHTheme.brand)
        .confirmationDialog("确定删除这台服务器？", isPresented: $showDeleteConfirm, titleVisibility: .visible) {
            Button("删除", role: .destructive) {
                sshStore.delete(id: serverID)
                dismiss()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("删除后它的连接信息与密码会一起从本机移除。")
        }
        // 测试连接结果：弹窗提示
        .alert(testSucceeded ? "连接正常" : "连接失败", isPresented: $showTestAlert) {
            Button("好的", role: .cancel) {}
        } message: {
            Text(testMessage ?? "")
        }
        // 命令执行结果：弹窗展示（长输出可滚动）
        .sheet(isPresented: $showConsole) {
            NavigationStack {
                ScrollView {
                    Text(consoleOutput ?? "")
                        .font(.system(size: 12, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                }
                .background(Color(uiColor: .systemGroupedBackground))
                .navigationTitle(consoleTitle)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button("完成") { showConsole = false }
                    }
                }
            }
        }
    }

    // MARK: 连接信息

    private func configSection(_ server: SSHServer) -> some View {
        Section {
            TextField("名称（可省略）", text: nameBinding)
                .accessibilityIdentifier("ssh.detail.name")
            LabeledContent("主机") {
                TextField("例如 1.2.3.4", text: hostBinding)
                    .multilineTextAlignment(.trailing)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                    .accessibilityIdentifier("ssh.detail.host")
            }
            LabeledContent("端口") {
                TextField("22", value: portBinding, format: .number.grouping(.never))
                    .multilineTextAlignment(.trailing)
                    .keyboardType(.numberPad)
                    .accessibilityIdentifier("ssh.detail.port")
            }
            LabeledContent("用户名") {
                TextField("root", text: usernameBinding)
                    .multilineTextAlignment(.trailing)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .accessibilityIdentifier("ssh.detail.username")
            }
            LabeledContent("密码") {
                SecureField("登录密码", text: passwordBinding)
                    .multilineTextAlignment(.trailing)
                    .accessibilityIdentifier("ssh.detail.password")
            }
        } header: {
            Text("连接信息")
        } footer: {
            Text("修改即时保存；密码写入本机钥匙串。")
        }
    }

    // MARK: 测试连接

    private func testSection(_ server: SSHServer) -> some View {
        Section {
            Button {
                runTest(server)
            } label: {
                HStack {
                    Label("测试连接", systemImage: "bolt.horizontal.circle.fill")
                    Spacer()
                    if testing {
                        ProgressView().controlSize(.small)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(testing || !canUse(server))
            .accessibilityIdentifier("ssh.test")
        } footer: {
            Text(canUse(server) ? "将执行 uname -a 验证登录是否正常，结果以弹窗提示。" : "请先填写主机、用户名与密码。")
        }
    }

    // MARK: 命令控制台

    private func consoleSection(_ server: SSHServer) -> some View {
        Section {
            HStack(spacing: DSHTheme.Spacing.small) {
                TextField("输入命令，例如 docker ps", text: $command)
                    .font(.system(size: 14, design: .monospaced))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.go)
                    .onSubmit { if canRun(server) { runCommand(server) } }
                    .accessibilityIdentifier("ssh.command")

                Button {
                    runCommand(server)
                } label: {
                    if running {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "play.circle.fill")
                            .font(.system(size: 20))
                            .foregroundStyle(canRun(server) ? DSHTheme.brand : Color.secondary)
                    }
                }
                .buttonStyle(.plain)
                .disabled(!canRun(server))
                .accessibilityIdentifier("ssh.run")
            }
        } header: {
            Text("命令控制台")
        } footer: {
            Text("在这里手动执行命令（用这台服务器），执行结果以弹窗展示；输出与智能体执行时看到的完全一致。")
        }
    }

    // MARK: 删除

    private var dangerSection: some View {
        Section {
            Button(role: .destructive) {
                showDeleteConfirm = true
            } label: {
                HStack(spacing: DSHTheme.Spacing.small) {
                    Image(systemName: "trash")
                    Text("删除服务器")
                    Spacer(minLength: 0)
                }
                .foregroundStyle(DSHTheme.danger)
                .contentShape(Rectangle())
            }
            .accessibilityIdentifier("ssh.detail.delete")
        }
    }

    // MARK: 行为

    private func canUse(_ server: SSHServer) -> Bool {
        server.isFilled && !sshStore.password(for: server.id).isEmpty
    }

    private func canRun(_ server: SSHServer) -> Bool {
        !running && canUse(server) && !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func runTest(_ server: SSHServer) {
        testing = true
        let password = sshStore.password(for: server.id)
        Task { @MainActor in
            defer { testing = false }
            do {
                let result = try await SSHService.execute(
                    command: "uname -a && whoami",
                    server: server,
                    password: password
                )
                testSucceeded = true
                testMessage = "已成功登录 \(server.displayTarget)\n\n\(firstLines(result))"
            } catch {
                testSucceeded = false
                testMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
            showTestAlert = true
        }
    }

    private func runCommand(_ server: SSHServer) {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        running = true
        consoleTitle = "执行中：\(trimmed)"
        consoleOutput = "执行中…"
        showConsole = true
        let password = sshStore.password(for: server.id)
        Task { @MainActor in
            defer { running = false }
            do {
                let result = try await SSHService.execute(
                    command: trimmed,
                    server: server,
                    password: password
                )
                consoleTitle = "命令结果"
                consoleOutput = "$ \(trimmed)\n\n\(result)"
            } catch {
                consoleTitle = "执行失败"
                consoleOutput = "$ \(trimmed)\n\n" + ((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
            }
        }
    }

    /// 只保留前几行，避免弹窗太长
    private func firstLines(_ text: String) -> String {
        let lines = text.split(separator: "\n").prefix(6).joined(separator: "\n")
        return lines.isEmpty ? "(没有输出)" : lines
    }

    // MARK: 绑定

    private var nameBinding: Binding<String> {
        Binding(
            get: { sshStore.server(id: serverID)?.name ?? "" },
            set: { value in sshStore.update(id: serverID) { $0.name = value } }
        )
    }

    private var hostBinding: Binding<String> {
        Binding(
            get: { sshStore.server(id: serverID)?.host ?? "" },
            set: { value in sshStore.update(id: serverID) { $0.host = value } }
        )
    }

    private var portBinding: Binding<Int> {
        Binding(
            get: { sshStore.server(id: serverID)?.port ?? 22 },
            set: { value in sshStore.update(id: serverID) { $0.port = value } }
        )
    }

    private var usernameBinding: Binding<String> {
        Binding(
            get: { sshStore.server(id: serverID)?.username ?? "" },
            set: { value in sshStore.update(id: serverID) { $0.username = value } }
        )
    }

    private var passwordBinding: Binding<String> {
        Binding(
            get: { sshStore.password(for: serverID) },
            set: { value in sshStore.setPassword(value, for: serverID) }
        )
    }
}