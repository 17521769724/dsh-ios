import SwiftUI

/// 设置页：服务配置、对话偏好、数据管理。
struct SettingsView: View {
    @EnvironmentObject private var engine: ChatEngine
    @EnvironmentObject private var settingsStore: SettingsStore
    @EnvironmentObject private var plugins: PluginManager
    @Environment(\.dismiss) private var dismiss

    @State private var testing = false
    @State private var testResult: String?
    @State private var testSucceeded = false
    @State private var showClearConfirm = false
    @State private var showResetUsageConfirm = false
    @State private var revealKey = false

    var body: some View {
        NavigationStack {
            Form {
                serviceSection
                behaviorSection
                dataSection
                aboutSection
            }
            .navigationTitle("设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("完成") { dismiss() }
                        .fontWeight(.semibold)
                }
            }
            .confirmationDialog("确定清空全部会话？", isPresented: $showClearConfirm, titleVisibility: .visible) {
                Button("清空", role: .destructive) { engine.deleteAllConversations() }
                Button("取消", role: .cancel) {}
            }
            .confirmationDialog("确定重置用量统计？", isPresented: $showResetUsageConfirm, titleVisibility: .visible) {
                Button("重置", role: .destructive) { engine.conversationStore.resetUsage() }
                Button("取消", role: .cancel) {}
            }
        }
    }

    // MARK: - 服务

    private var serviceSection: some View {
        Section {
            HStack {
                Label("API Key", systemImage: "key.fill")
                Spacer()
                if revealKey {
                    TextField("sk-…", text: $settingsStore.apiKey)
                        .multilineTextAlignment(.trailing)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .font(.system(size: 14, design: .monospaced))
                } else {
                    SecureField("sk-…", text: $settingsStore.apiKey)
                        .multilineTextAlignment(.trailing)
                        .font(.system(size: 14, design: .monospaced))
                }
                Button {
                    revealKey.toggle()
                } label: {
                    Image(systemName: revealKey ? "eye.slash" : "eye")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }

            HStack {
                Label("Base URL", systemImage: "network")
                Spacer()
                TextField("https://api.deepseek.com", text: $settingsStore.settings.baseURL)
                    .multilineTextAlignment(.trailing)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .font(.system(size: 13, design: .monospaced))
                    .keyboardType(.URL)
            }

            Picker(selection: $settingsStore.settings.defaultModel) {
                ForEach(DSHModel.catalog) { model in
                    Text(model.name).tag(model.id)
                }
            } label: {
                Label("默认模型", systemImage: "cpu")
            }

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Label("温度", systemImage: "thermometer.medium")
                    Spacer()
                    Text(String(format: "%.2f", settingsStore.settings.temperature))
                        .font(.system(size: 13, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                Slider(value: $settingsStore.settings.temperature, in: 0...2, step: 0.05)
                    .tint(DSHTheme.brand)
            }

            VStack(alignment: .leading, spacing: 6) {
                Label("系统提示词", systemImage: "text.quote")
                    .font(.system(size: 15))
                ZStack(alignment: .topLeading) {
                    if settingsStore.settings.systemPrompt.isEmpty {
                        Text("可选。为每次对话设定角色与约束。")
                            .font(.system(size: 13))
                            .foregroundStyle(.tertiary)
                            .padding(.top, 8)
                            .padding(.leading, 4)
                    }
                    TextEditor(text: $settingsStore.settings.systemPrompt)
                        .font(.system(size: 14))
                        .frame(minHeight: 72)
                        .scrollContentBackground(.hidden)
                }
            }

            Button {
                testConnection()
            } label: {
                HStack {
                    Label("测试连接", systemImage: "bolt.horizontal.circle")
                    Spacer()
                    if testing {
                        ProgressView().controlSize(.small)
                    } else if let testResult {
                        Text(testResult)
                            .font(.system(size: 12))
                            .foregroundStyle(testSucceeded ? DSHTheme.success : DSHTheme.danger)
                            .lineLimit(1)
                    }
                }
            }
            .disabled(testing || !settingsStore.isConfigured)
        } header: {
            Text("模型服务")
        } footer: {
            Text("API Key 仅保存在本机 Keychain，不会上传到任何第三方服务器。Base URL 兼容任意 OpenAI 格式接口。")
        }
    }

    // MARK: - 偏好

    private var behaviorSection: some View {
        Section("对话偏好") {
            Toggle(isOn: $settingsStore.settings.streamEnabled) {
                Label("流式输出", systemImage: "waveform")
            }
            .tint(DSHTheme.brand)

            Toggle(isOn: $settingsStore.settings.hapticsEnabled) {
                Label("触感反馈", systemImage: "hand.tap")
            }
            .tint(DSHTheme.brand)

            Picker(selection: $settingsStore.settings.appTheme) {
                ForEach(AppThemePreference.allCases) { theme in
                    Text(theme.displayName).tag(theme)
                }
            } label: {
                Label("外观", systemImage: "circle.lefthalf.filled")
            }
        }
    }

    // MARK: - 数据

    private var dataSection: some View {
        Section("数据") {
            LabeledContent {
                Text("\(engine.usage.totalRequests) 次")
            } label: {
                Label("请求次数", systemImage: "arrow.up.arrow.down")
            }
            LabeledContent {
                Text(formatted(engine.usage.totalTokens))
            } label: {
                Label("累计 tokens", systemImage: "number")
            }

            ShareLink(item: engine.conversationStore.exportMarkdown()) {
                Label("导出会话为 Markdown", systemImage: "square.and.arrow.up")
            }

            Button {
                showResetUsageConfirm = true
            } label: {
                Label("重置用量统计", systemImage: "arrow.counterclockwise")
            }

            Button(role: .destructive) {
                showClearConfirm = true
            } label: {
                Label("清空全部会话", systemImage: "trash")
            }
        }
    }

    // MARK: - 关于

    private var aboutSection: some View {
        Section("关于") {
            LabeledContent {
                Text(appVersion)
            } label: {
                Label("版本", systemImage: "info.circle")
            }
            LabeledContent {
                Text("iOS 16.2+")
            } label: {
                Label("最低系统", systemImage: "iphone")
            }
            NavigationLink {
                PluginDirectoryInfoView()
                    .environmentObject(plugins)
            } label: {
                Label("插件目录", systemImage: "folder")
            }
            Link(destination: URL(string: "https://github.com/deepseek-ai/deepseek-harness")!) {
                Label("DeepSeek Harness 上游", systemImage: "link")
            }
        }
    }

    private var appVersion: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1.0"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "\(version) (\(build))"
    }

    private func formatted(_ value: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter.string(from: NSNumber(value: value)) ?? "\(value)"
    }

    private func testConnection() {
        testing = true
        testResult = nil
        let client = DeepSeekClient(timeout: 20)
        let settings = settingsStore.settings
        let key = settingsStore.apiKey
        Task { @MainActor in
            do {
                let ids = try await client.fetchModelIDs(settings: settings, apiKey: key)
                testSucceeded = true
                testResult = ids.isEmpty ? "连接成功" : "连接成功 · \(ids.count) 个模型"
            } catch {
                testSucceeded = false
                testResult = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
            testing = false
        }
    }
}

/// 插件目录说明与文件 App 指引
struct PluginDirectoryInfoView: View {
    @EnvironmentObject private var plugins: PluginManager

    var body: some View {
        List {
            Section("如何安装插件") {
                Text("1. 用「文件」App 打开「我的 iPhone → DSH → Plugins」文件夹。")
                Text("2. 把以 .js 结尾的插件脚本放入该目录。")
                Text("3. 回到「插件中心」点击右上角刷新，即可识别并启用。")
            }
            Section("脚本头部元数据") {
                Text("// @name 插件名称\n// @summary 一句话说明\n// @version 1.0.0\n// @author 作者\n// @enabled true")
                    .font(.system(size: 12, design: .monospaced))
                    .textSelection(.enabled)
            }
            Section("可用 API") {
                Text("dsh.log(msg)\ndsh.registerCommand(name, summary, fn)\ndsh.onMessage(fn)\ndsh.setStorage(key, value)\ndsh.getStorage(key)")
                    .font(.system(size: 12, design: .monospaced))
                    .textSelection(.enabled)
            }
            Section("当前目录") {
                Text(plugins.userPluginsDirectory.path)
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
            }
        }
        .navigationTitle("插件目录")
        .navigationBarTitleDisplayMode(.inline)
    }
}