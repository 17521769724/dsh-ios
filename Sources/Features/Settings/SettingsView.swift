import SwiftUI
import UIKit

/// 设置主页：与 iPhone 系统「设置」一致的 inset grouped 列表 + 彩色图标 + 二级页面。
struct SettingsView: View {
    @EnvironmentObject private var engine: ChatEngine
    @EnvironmentObject private var settingsStore: SettingsStore
    @EnvironmentObject private var plugins: PluginManager
    @Environment(\.dismiss) private var dismiss

    private var settings: AppSettings { settingsStore.settings }

    var body: some View {
        NavigationStack {
            List {
                serviceSection
                conversationSection
                appearanceSection
                homeFeaturesSection
                pluginsSection
                dataSection
                aboutSection
            }
            .listStyle(.insetGrouped)
            .navigationTitle("设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
            // 在设置内切换深浅色时立即生效
            .dshAppearance(settings.appTheme)
            .tint(DSHTheme.brand)
        }
    }

    // MARK: - 模型服务

    private var serviceSection: some View {
        Section {
            NavigationLink {
                APIKeySettingsView()
            } label: {
                SettingsValueRow(
                    symbol: "key.fill",
                    color: .blue,
                    title: "API Key",
                    value: settingsStore.isConfigured ? "已配置" : "未配置"
                )
            }

            NavigationLink {
                ServiceAddressSettingsView()
            } label: {
                SettingsValueRow(
                    symbol: "network",
                    color: .teal,
                    title: "API 地址",
                    value: URL(string: settings.baseURL)?.host ?? settings.baseURL
                )
            }

            NavigationLink {
                ModelSettingsView()
            } label: {
                SettingsValueRow(
                    symbol: "cpu",
                    color: .indigo,
                    title: "模型",
                    value: DSHModel.describe(id: settings.defaultModel).name
                )
            }
            .accessibilityIdentifier("settings.model")

            NavigationLink {
                ConnectionTestView()
            } label: {
                SettingsRowLabel(symbol: "bolt.horizontal.circle.fill", color: .green, title: "连接测试")
            }
        } header: {
            Text("模型服务")
        } footer: {
            Text("API Key 保存在本机钥匙串。API 地址兼容任意 OpenAI 格式接口。")
        }
    }

    // MARK: - 对话

    private var conversationSection: some View {
        Section("对话") {
            Toggle(isOn: $settingsStore.settings.streamEnabled) {
                SettingsRowLabel(symbol: "waveform", color: .purple, title: "流式输出")
            }

            Toggle(isOn: $settingsStore.settings.thinkingEnabled) {
                SettingsRowLabel(symbol: "brain.fill", color: .pink, title: "深度思考")
            }

            NavigationLink {
                ThinkingEffortSettingsView()
            } label: {
                SettingsValueRow(
                    symbol: "dial.high.fill",
                    color: .orange,
                    title: "思考强度",
                    value: settings.reasoningEffort.displayName
                )
            }

            NavigationLink {
                TemperatureSettingsView()
            } label: {
                SettingsValueRow(
                    symbol: "thermometer.medium",
                    color: .red,
                    title: "温度",
                    value: String(format: "%.2f", settings.temperature)
                )
            }

            NavigationLink {
                SystemPromptSettingsView()
            } label: {
                SettingsValueRow(
                    symbol: "text.quote",
                    color: .brown,
                    title: "系统提示词",
                    value: settings.systemPrompt.isEmpty ? "未设置" : "已设置"
                )
            }
        }
    }

    // MARK: - 外观

    private var appearanceSection: some View {
        Section("外观与体验") {
            NavigationLink {
                ThemeSettingsView()
            } label: {
                SettingsValueRow(
                    symbol: "circle.lefthalf.filled",
                    color: .gray,
                    title: "外观",
                    value: settings.appTheme.displayName
                )
            }
            .accessibilityIdentifier("settings.theme")

            Toggle(isOn: $settingsStore.settings.hapticsEnabled) {
                SettingsRowLabel(symbol: "hand.tap.fill", color: .cyan, title: "触感反馈")
            }
        }
    }

    // MARK: - 主页功能开关

    private var homeFeaturesSection: some View {
        Section {
            Toggle(isOn: $settingsStore.settings.features.deepThinkingToggle) {
                SettingsRowLabel(symbol: "brain", color: .pink, title: "主页显示深度思考开关")
            }
            .accessibilityIdentifier("feature.deepThinkingToggle")
            Toggle(isOn: $settingsStore.settings.features.examplePrompts) {
                SettingsRowLabel(symbol: "text.bubble", color: .mint, title: "主页显示示例问题")
            }
            .accessibilityIdentifier("feature.examplePrompts")
            Toggle(isOn: $settingsStore.settings.features.modelPicker) {
                SettingsRowLabel(symbol: "chevron.up.chevron.down", color: .indigo, title: "输入框显示模型选择")
            }
            .accessibilityIdentifier("feature.modelPicker")
            Toggle(isOn: $settingsStore.settings.features.usageMetrics) {
                SettingsRowLabel(symbol: "chart.bar.fill", color: .orange, title: "显示运行指标")
            }
            .accessibilityIdentifier("feature.usageMetrics")
            Toggle(isOn: $settingsStore.settings.features.trajectoryTab) {
                SettingsRowLabel(symbol: "point.topleft.down.curvedto.point.bottomright.up", color: .teal, title: "对话 / 轨迹 切换")
            }
            .accessibilityIdentifier("feature.trajectoryTab")
            Toggle(isOn: $settingsStore.settings.features.sessionLog) {
                SettingsRowLabel(symbol: "list.bullet.rectangle", color: .blue, title: "会话日志入口")
            }
            .accessibilityIdentifier("feature.sessionLog")
            Toggle(isOn: $settingsStore.settings.features.pluginCommands) {
                SettingsRowLabel(symbol: "command", color: .purple, title: "插件命令与入口")
            }
            .accessibilityIdentifier("feature.pluginCommands")
        } header: {
            Text("主页功能")
        } footer: {
            Text("默认保持主页简洁，需要的功能在这里开启；关闭只影响入口，不影响已有数据。")
        }
    }

    // MARK: - 插件

    private var pluginsSection: some View {
        Section("插件") {
            NavigationLink {
                PluginsView()
                    .environmentObject(engine)
                    .environmentObject(plugins)
            } label: {
                SettingsValueRow(
                    symbol: "puzzlepiece.extension.fill",
                    color: .purple,
                    title: "插件中心",
                    value: "\(plugins.manifests.filter { $0.isEnabled }.count) 个已启用"
                )
            }
        }
    }

    // MARK: - 数据

    private var dataSection: some View {
        Section("数据") {
            NavigationLink {
                DataSettingsView()
            } label: {
                SettingsValueRow(
                    symbol: "internaldrive.fill",
                    color: .gray,
                    title: "对话与用量",
                    value: "\(engine.conversationStore.conversations.count) 个会话"
                )
            }
        }
    }

    // MARK: - 关于

    private var aboutSection: some View {
        Section("关于") {
            NavigationLink {
                AboutSettingsView()
            } label: {
                SettingsRowLabel(symbol: "info.circle.fill", color: .blue, title: "关于 DeepSeek")
            }
        }
    }
}

// MARK: - API Key

struct APIKeySettingsView: View {
    @EnvironmentObject private var settingsStore: SettingsStore
    @EnvironmentObject private var engine: ChatEngine
    @State private var revealed = false

    var body: some View {
        List {
            Section {
                HStack {
                    Group {
                        if revealed {
                            TextField("sk-…", text: $settingsStore.apiKey)
                        } else {
                            SecureField("sk-…", text: $settingsStore.apiKey)
                        }
                    }
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(.system(size: 15, design: .monospaced))

                    Button {
                        revealed.toggle()
                    } label: {
                        Image(systemName: revealed ? "eye.slash" : "eye")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            } header: {
                Text("API Key")
            } footer: {
                Text("保存在本机钥匙串。清空后将退回首次配置页面。")
            }

            Section {
                Link(destination: URL(string: "https://platform.deepseek.com/api_keys")!) {
                    Text("前往开放平台获取 Key")
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("API Key")
        .navigationBarTitleDisplayMode(.inline)
        .tint(DSHTheme.brand)
    }
}

// MARK: - API 地址

struct ServiceAddressSettingsView: View {
    @EnvironmentObject private var settingsStore: SettingsStore

    var body: some View {
        List {
            Section {
                TextField("https://api.deepseek.com", text: $settingsStore.settings.baseURL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                    .font(.system(size: 14, design: .monospaced))
            } header: {
                Text("API 地址")
            } footer: {
                Text("默认 https://api.deepseek.com，可替换为兼容 OpenAI 格式的自建或中转地址。")
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("API 地址")
        .navigationBarTitleDisplayMode(.inline)
        .tint(DSHTheme.brand)
    }
}

// MARK: - 模型

struct ModelSettingsView: View {
    @EnvironmentObject private var engine: ChatEngine
    @EnvironmentObject private var settingsStore: SettingsStore

    var body: some View {
        List {
            Section {
                ForEach(engine.availableModels) { model in
                    Button {
                        engine.selectModel(model.id)
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(model.name)
                                    .foregroundStyle(.primary)
                                Text(model.id)
                                    .font(.system(size: 12, design: .monospaced))
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            if engine.activeModelID == model.id {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(DSHTheme.brand)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                }
            } header: {
                Text("模型")
            } footer: {
                if let error = engine.modelsError {
                    Text(error).foregroundStyle(DSHTheme.danger)
                } else {
                    Text("模型名以官方 API 为准：deepseek-flash 对应 DeepSeek-V4.1-Flash，deepseek-v4-pro 对应 DeepSeek-V4-Pro。")
                }
            }

            Section {
                Button {
                    engine.refreshModels()
                } label: {
                    HStack {
                        Text("从服务端获取模型列表")
                        Spacer()
                        if engine.isRefreshingModels {
                            ProgressView().controlSize(.small)
                        }
                    }
                }
                .disabled(engine.isRefreshingModels)
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("模型")
        .navigationBarTitleDisplayMode(.inline)
        .tint(DSHTheme.brand)
    }
}

// MARK: - 连接测试

struct ConnectionTestView: View {
    @EnvironmentObject private var settingsStore: SettingsStore

    @State private var testing = false
    @State private var result: String?
    @State private var succeeded = false

    var body: some View {
        List {
            Section {
                Button {
                    run()
                } label: {
                    HStack {
                        Text("开始测试")
                        Spacer()
                        if testing { ProgressView().controlSize(.small) }
                    }
                }
                .disabled(testing || !settingsStore.isConfigured)
            } footer: {
                if let result {
                    Text(result).foregroundStyle(succeeded ? DSHTheme.success : DSHTheme.danger)
                } else {
                    Text("向服务端请求模型列表，用于验证 Key 与地址是否可用。")
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("连接测试")
        .navigationBarTitleDisplayMode(.inline)
        .tint(DSHTheme.brand)
    }

    private func run() {
        testing = true
        result = nil
        let client = DeepSeekClient(timeout: 20)
        let settings = settingsStore.settings
        let key = settingsStore.apiKey
        Task { @MainActor in
            do {
                let ids = try await client.fetchModelIDs(settings: settings, apiKey: key)
                succeeded = true
                result = "连接成功，共 \(ids.count) 个模型"
            } catch {
                succeeded = false
                result = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
            testing = false
        }
    }
}

// MARK: - 思考强度

struct ThinkingEffortSettingsView: View {
    @EnvironmentObject private var settingsStore: SettingsStore

    var body: some View {
        List {
            Section {
                ForEach(ReasoningEffort.allCases) { effort in
                    Button {
                        settingsStore.settings.reasoningEffort = effort
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(effort.displayName)
                                    .foregroundStyle(.primary)
                                Text(effort.detail)
                                    .font(.system(size: 12))
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            if settingsStore.settings.reasoningEffort == effort {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(DSHTheme.brand)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                }
            } header: {
                Text("思考强度")
            } footer: {
                Text("对应官方 API 的 reasoning_effort 参数：low / high / max。")
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("思考强度")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - 温度

struct TemperatureSettingsView: View {
    @EnvironmentObject private var settingsStore: SettingsStore

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: DSHTheme.Spacing.small) {
                    HStack {
                        Text("当前值")
                        Spacer()
                        Text(String(format: "%.2f", settingsStore.settings.temperature))
                            .foregroundStyle(.secondary)
                            .font(.system(size: 14, design: .monospaced))
                    }
                    Slider(value: $settingsStore.settings.temperature, in: 0...2, step: 0.05)
                        .tint(DSHTheme.brand)
                }
            } footer: {
                Text("值越低回答越稳定，越高越有创造性。日常建议 0.6 ~ 1.0。")
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("温度")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - 系统提示词

struct SystemPromptSettingsView: View {
    @EnvironmentObject private var settingsStore: SettingsStore

    var body: some View {
        List {
            Section {
                TextEditor(text: $settingsStore.settings.systemPrompt)
                    .font(.system(size: 15))
                    .frame(minHeight: 160)
            } header: {
                Text("系统提示词")
            } footer: {
                Text("每次请求都会作为 system 消息发送，用于设定角色与约束。留空则不发送。")
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("系统提示词")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - 外观

struct ThemeSettingsView: View {
    @EnvironmentObject private var settingsStore: SettingsStore

    var body: some View {
        List {
            Section {
                ForEach(AppThemePreference.allCases) { theme in
                    Button {
                        withAnimation(DSHAnim.standard) {
                            settingsStore.settings.appTheme = theme
                        }
                    } label: {
                        HStack {
                            Text(theme.displayName)
                                .foregroundStyle(.primary)
                            Spacer()
                            if settingsStore.settings.appTheme == theme {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(DSHTheme.brand)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("theme.\(theme.rawValue)")
                }
            } footer: {
                Text("切换后立即生效。")
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("外观")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - 数据

struct DataSettingsView: View {
    @EnvironmentObject private var engine: ChatEngine
    @State private var showClearConfirm = false
    @State private var showResetUsageConfirm = false

    var body: some View {
        List {
            Section("用量") {
                LabeledContent("请求次数", value: "\(engine.usage.totalRequests) 次")
                LabeledContent("累计 tokens", value: "\(engine.usage.totalTokens)")
                LabeledContent("输入 tokens", value: "\(engine.usage.totalPromptTokens)")
                LabeledContent("输出 tokens", value: "\(engine.usage.totalCompletionTokens)")
            }

            Section {
                ShareLink(item: engine.conversationStore.exportMarkdown()) {
                    Text("导出全部会话为 Markdown")
                }
                Button("重置用量统计") { showResetUsageConfirm = true }
            }

            Section {
                Button("清空全部会话", role: .destructive) { showClearConfirm = true }
                    .disabled(engine.conversationStore.conversations.isEmpty)
            } footer: {
                Text("会话与设置仅保存在本机。")
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("对话与用量")
        .navigationBarTitleDisplayMode(.inline)
        .tint(DSHTheme.brand)
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

// MARK: - 关于

struct AboutSettingsView: View {
    @EnvironmentObject private var plugins: PluginManager

    var body: some View {
        List {
            Section {
                LabeledContent("版本", value: appVersion)
                LabeledContent("支持系统", value: "iOS 16.2 及以上")
                LabeledContent("插件运行时", value: "JavaScriptCore")
            }
            Section {
                NavigationLink {
                    PluginDirectoryInfoView()
                        .environmentObject(plugins)
                } label: {
                    Text("插件目录说明")
                }
                Link(destination: URL(string: "https://api-docs.deepseek.com")!) {
                    Text("DeepSeek API 文档")
                }
                Link(destination: URL(string: "https://github.com/deepseek-ai/deepseek-harness")!) {
                    Text("DeepSeek Harness 上游")
                }
            } footer: {
                Text("本应用为社区实现，与 DeepSeek 官方无隶属关系。")
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("关于")
        .navigationBarTitleDisplayMode(.inline)
        .tint(DSHTheme.brand)
    }

    private var appVersion: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1.0"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "\(version) (\(build))"
    }
}

/// 插件目录说明与「文件」App 指引
struct PluginDirectoryInfoView: View {
    @EnvironmentObject private var plugins: PluginManager

    var body: some View {
        List {
            Section("安装步骤") {
                Text("1. 用「文件」App 打开「我的 iPhone → DSH → Plugins」。")
                Text("2. 把以 .js 结尾的插件脚本放入该目录。")
                Text("3. 回到「插件中心」点击刷新即可识别并启用。")
            }
            Section("脚本元数据") {
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
        .listStyle(.insetGrouped)
        .navigationTitle("插件目录")
        .navigationBarTitleDisplayMode(.inline)
    }
}