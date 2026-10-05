import SwiftUI

/// SSH 云服务器：配置登录信息 + 连接测试 + 命令控制台。
/// 密码保存在本机钥匙串，不会上传到任何服务。
struct SSHSettingsView: View {
    @EnvironmentObject private var sshStore: SSHStore
    @EnvironmentObject private var settingsStore: SettingsStore

    @State private var testing = false
    @State private var testResult: String?
    @State private var testSucceeded = false
    @State private var command = ""
    @State private var output = ""
    @State private var running = false

    var body: some View {
        List {
            agentSection
            serverSection
            testSection
            consoleSection
        }
        .listStyle(.insetGrouped)
        .navigationTitle("SSH 云服务器")
        .navigationBarTitleDisplayMode(.inline)
        .tint(DSHTheme.brand)
    }

    // MARK: - 智能体开关

    private var agentSection: some View {
        Section {
            Toggle(isOn: $settingsStore.settings.features.agentTools) {
                SettingsRowLabel(symbol: "wand.and.stars", color: .indigo, title: "让智能体调用工具")
            }
            .accessibilityIdentifier("ssh.agentTools")
        } header: {
            Text("智能体")
        } footer: {
            Text("开启后，对话中模型可自主执行 SSH 命令、打开或读取网页；SSH 未配置时只提供浏览器工具。每次执行都会在对话里留下记录。")
        }
    }

    // MARK: - 服务器

    private var serverSection: some View {
        Section {
            LabeledContent("主机") {
                TextField("例如 1.2.3.4 或 server.example.com", text: $sshStore.configuration.host)
                    .multilineTextAlignment(.trailing)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                    .accessibilityIdentifier("ssh.host")
            }
            LabeledContent("端口") {
                TextField("22", value: $sshStore.configuration.port, format: .number)
                    .multilineTextAlignment(.trailing)
                    .keyboardType(.numberPad)
                    .accessibilityIdentifier("ssh.port")
            }
            LabeledContent("用户名") {
                TextField("root", text: $sshStore.configuration.username)
                    .multilineTextAlignment(.trailing)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .accessibilityIdentifier("ssh.username")
            }
            LabeledContent("密码") {
                SecureField("登录密码", text: $sshStore.password)
                    .multilineTextAlignment(.trailing)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .accessibilityIdentifier("ssh.password")
            }
        } header: {
            Text("服务器")
        } footer: {
            Text("密码保存在本机钥匙串。当前版本支持密码登录；使用密钥登录的服务器请先在服务器上开启密码认证。")
        }
    }

    // MARK: - 连接测试

    private var testSection: some View {
        Section {
            Button {
                runTest()
            } label: {
                HStack {
                    Label("测试连接", systemImage: "bolt.horizontal.circle.fill")
                    Spacer()
                    if testing {
                        ProgressView().controlSize(.small)
                    } else if let testResult {
                        Text(testResult)
                            .font(.system(size: 13))
                            .foregroundStyle(testSucceeded ? DSHTheme.success : DSHTheme.danger)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(testing || !sshStore.isConfigured)
            .accessibilityIdentifier("ssh.test")
        } footer: {
            Text(sshStore.isConfigured ? "将执行 uname -a 验证登录是否正常。" : "请先填写主机、用户名与密码。")
        }
    }

    // MARK: - 控制台

    private var consoleSection: some View {
        Section {
            HStack(spacing: DSHTheme.Spacing.small) {
                TextField("输入命令，例如 docker ps", text: $command)
                    .font(.system(size: 14, design: .monospaced))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.go)
                    .onSubmit { if canRun { runCommand() } }
                    .accessibilityIdentifier("ssh.command")

                Button {
                    runCommand()
                } label: {
                    if running {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "play.circle.fill")
                            .font(.system(size: 20))
                            .foregroundStyle(canRun ? DSHTheme.brand : Color.secondary)
                    }
                }
                .buttonStyle(.plain)
                .disabled(!canRun)
                .accessibilityIdentifier("ssh.run")
            }

            if !output.isEmpty {
                ScrollView {
                    Text(output)
                        .font(.system(size: 12, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 220)
            }
        } header: {
            Text("命令控制台")
        } footer: {
            Text("在这里手动执行命令，用于验证配置；输出与智能体执行时看到的完全一致。")
        }
    }

    private var canRun: Bool {
        !running && sshStore.isConfigured && !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // MARK: - 行为

    private func runTest() {
        testing = true
        testResult = nil
        let configuration = sshStore.configuration
        let password = sshStore.password
        Task { @MainActor in
            defer { testing = false }
            do {
                let result = try await SSHService.execute(
                    command: "uname -a && whoami",
                    configuration: configuration,
                    password: password
                )
                testSucceeded = true
                testResult = firstLine(result)
            } catch {
                testSucceeded = false
                testResult = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }
    }

    private func runCommand() {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        running = true
        output = "执行中：\(trimmed)"
        let configuration = sshStore.configuration
        let password = sshStore.password
        Task { @MainActor in
            defer { running = false }
            do {
                let result = try await SSHService.execute(
                    command: trimmed,
                    configuration: configuration,
                    password: password
                )
                output = result
            } catch {
                output = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }
    }

    private func firstLine(_ text: String) -> String {
        let line = text.split(separator: "\n").first.map(String.init) ?? text
        return line.count > 34 ? String(line.prefix(34)) + "…" : line
    }
}