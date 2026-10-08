import SwiftUI
import UIKit

/// 设置主页：与 iPhone 系统「设置」一致的 inset grouped 列表 + 彩色图标 + 二级页面。
struct SettingsView: View {
    @EnvironmentObject private var engine: ChatEngine
    @EnvironmentObject private var settingsStore: SettingsStore
    @EnvironmentObject private var plugins: PluginManager
    @EnvironmentObject private var sshStore: SSHStore
    @EnvironmentObject private var gitStore: GitAccountStore
    @EnvironmentObject private var skillStore: SkillStore
    @Environment(\.dismiss) private var dismiss

    private var settings: AppSettings { settingsStore.settings }

    var body: some View {
        NavigationStack {
            List {
                serviceSection
                conversationSection
                appearanceSection
                homeFeaturesSection
                toolsSection
                gitSection
                pluginsSection
                skillsSection
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
            .accessibilityIdentifier("settings.apikey")

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

            ConnectionTestRow()
        } header: {
            Text("模型服务")
        } footer: {
            Text("API Key 保存在本机钥匙串。API 地址兼容任意 OpenAI 格式接口。")
        }
    }

    // MARK: - 工具（智能体）

    private var toolsSection: some View {
        Section {
            // SSH 与内置浏览器各自独立控制，互不影响
            Toggle(isOn: $settingsStore.settings.features.sshTool) {
                SettingsRowLabel(symbol: "terminal.fill", color: .black, title: "SSH 云服务器工具")
            }
            .accessibilityIdentifier("feature.sshTool")

            NavigationLink {
                SSHSettingsView()
            } label: {
                SettingsValueRow(
                    symbol: "server.rack",
                    color: .gray,
                    title: "SSH 服务器配置",
                    // 已配置时不暴露主机与用户名等信息
                    value: sshStore.isConfigured ? "已配置" : "未配置"
                )
            }
            .accessibilityIdentifier("settings.ssh")

            Toggle(isOn: $settingsStore.settings.features.browserTool) {
                SettingsRowLabel(symbol: "safari.fill", color: .blue, title: "内置浏览器工具")
            }
            .accessibilityIdentifier("feature.browserTool")

            NavigationLink {
                BrowserSettingsView()
            } label: {
                SettingsValueRow(
                    symbol: "globe",
                    color: .teal,
                    title: "浏览器设置",
                    value: settings.browser.desktopSite ? "桌面版网站" : "移动版网站"
                )
            }
            .accessibilityIdentifier("settings.browser")
        } header: {
            Text("智能体工具")
        } footer: {
            Text("两个开关彼此独立：SSH 控制智能体能否在服务器上执行命令（需先配置服务器），浏览器控制智能体能否打开或读取网页；关闭后模型不会再调用对应工具。")
        }
    }

    // MARK: - 代码托管（GitHub / Gitee）

    private var gitSection: some View {
        Section {
            Toggle(isOn: $settingsStore.settings.features.githubTool) {
                SettingsRowLabel(symbol: "arrow.triangle.branch", color: .black, title: "GitHub 工具")
            }
            .accessibilityIdentifier("feature.githubTool")

            NavigationLink {
                GitAccountSettingsView(provider: .github)
            } label: {
                SettingsValueRow(
                    symbol: "person.crop.circle.fill",
                    color: .gray,
                    title: "GitHub 账号",
                    value: gitStore.statusText(for: .github)
                )
            }
            .accessibilityIdentifier("settings.githubAccount")

            Toggle(isOn: $settingsStore.settings.features.giteeTool) {
                SettingsRowLabel(symbol: "arrow.triangle.branch", color: .red, title: "Gitee 工具")
            }
            .accessibilityIdentifier("feature.giteeTool")

            NavigationLink {
                GitAccountSettingsView(provider: .gitee)
            } label: {
                SettingsValueRow(
                    symbol: "person.crop.circle.fill",
                    color: .gray,
                    title: "Gitee 账号",
                    value: gitStore.statusText(for: .gitee)
                )
            }
            .accessibilityIdentifier("settings.giteeAccount")
        } header: {
            Text("代码托管")
        } footer: {
            Text("登录后 Token 只保存在本机钥匙串；开启开关后模型可查看仓库、读写仓库文件与创建 Issue，未登录时对应工具不会下发给模型。")
        }
    }

    // MARK: - 对话

    private var conversationSection: some View {
        Section("对话") {
            Toggle(isOn: $settingsStore.settings.streamEnabled) {
                SettingsRowLabel(symbol: "waveform", color: .purple, title: "流式输出")
            }

            Toggle(isOn: $settingsStore.settings.thinkingEnabled) {
                SettingsRowLabel(symbol: "brain.head.profile", color: .pink, title: "深度思考")
            }

            NavigationLink {
                ThinkingEffortSettingsView()
            } label: {
                SettingsValueRow(
                    symbol: "speedometer",
                    color: .orange,
                    title: "思考强度",
                    value: settings.reasoningEffort.displayName
                )
            }

            NavigationLink {
                TemperatureSettingsView()
            } label: {
                SettingsValueRow(
                    symbol: "thermometer",
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
                SettingsRowLabel(symbol: "brain.head.profile", color: .pink, title: "主页显示深度思考开关")
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
        Section {
            NavigationLink {
                PluginsView()
                    .environmentObject(engine)
                    .environmentObject(plugins)
            } label: {
                SettingsValueRow(
                    symbol: "puzzlepiece.extension.fill",
                    color: .purple,
                    title: "插件中心",
                    // 与插件中心列表一致：不含由本页单独管理的「回答风格约束」
                    value: "\(plugins.manifests.filter { $0.isEnabled && !PluginManager.settingsManagedPluginIDs.contains($0.id) }.count) 个已启用"
                )
            }

            NavigationLink {
                StyleSuffixSettingsView()
            } label: {
                SettingsValueRow(
                    symbol: "text.bubble.fill",
                    color: .indigo,
                    title: "回答风格约束",
                    value: settings.styleSuffix.isEmpty ? "未设置" : "已设置"
                )
            }
            .accessibilityIdentifier("settings.styleSuffix")
        } header: {
            Text("插件")
        } footer: {
            Text("「回答风格约束」插件需在插件中心开启；开启后这里编辑的强调指令会追加在每条消息末尾发送给模型。")
        }
    }

    // MARK: - 技能

    private var skillsSection: some View {
        Section {
            Toggle(isOn: $settingsStore.settings.features.skillTool) {
                SettingsRowLabel(symbol: "sparkles", color: .orange, title: "技能（智能体可调用）")
            }
            .accessibilityIdentifier("feature.skillTool")

            NavigationLink {
                SkillsView()
                    .environmentObject(skillStore)
                    .environmentObject(settingsStore)
            } label: {
                SettingsValueRow(
                    symbol: "text.book.closed.fill",
                    color: .brown,
                    title: "技能库",
                    value: skillStore.skills.isEmpty
                        ? "未添加"
                        : "\(skillStore.enabledSkills.count)/\(skillStore.skills.count) 个已启用"
                )
            }
            .accessibilityIdentifier("settings.skills")
        } header: {
            Text("技能")
        } footer: {
            Text("技能与工具不重合：工具负责执行操作（执行命令、打开网页、读写仓库），技能负责规定做法（步骤、规范、检查清单）。启用后模型会在需要时调用 skill 工具读取技能全文并照着完成。")
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

            NavigationLink {
                CacheCleanupSettingsView()
            } label: {
                CacheCleanupRow()
            }
            .accessibilityIdentifier("settings.cache")
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
    @State private var showClearConfirm = false

    var body: some View {
        List {
            Section {
                HStack(spacing: DSHTheme.Spacing.small) {
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
                    // 与引导页保持一致：明文/密文切换时输入框宽度不变
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
                    .frame(width: 26, height: 26)
                    .accessibilityLabel(revealed ? "隐藏 Key" : "显示 Key")
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

            Section {
                Button(role: .destructive) {
                    showClearConfirm = true
                } label: {
                    Label("清除 API Key", systemImage: "trash")
                }
                .disabled(!settingsStore.isConfigured)
                .accessibilityIdentifier("settings.apikey.clear")
            } footer: {
                Text("清除后会自动退回首次配置页面，重新填写 Key 才能进入主页。在输入框里直接删除字符只会删除 Key，不会跳转页面。")
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("API Key")
        .navigationBarTitleDisplayMode(.inline)
        .tint(DSHTheme.brand)
        .confirmationDialog("确定清除 API Key？", isPresented: $showClearConfirm, titleVisibility: .visible) {
            Button("清除", role: .destructive) {
                settingsStore.apiKey = ""
                // 由 RootView 关闭设置浮层并回到引导页
                settingsStore.onboardingRequested = true
            }
            Button("取消", role: .cancel) {}
        }
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
                        .contentShape(Rectangle())
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
                        Label("从服务端获取模型列表", systemImage: "arrow.triangle.2.circlepath")
                        Spacer()
                        if engine.isRefreshingModels {
                            ProgressView().controlSize(.small)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .disabled(engine.isRefreshingModels)
                .accessibilityIdentifier("settings.models.refresh")
            } footer: {
                Text("拉取成功后，上方列表与输入框的模型选择会立即更新为服务端返回的模型。")
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("模型")
        .navigationBarTitleDisplayMode(.inline)
        .tint(DSHTheme.brand)
    }
}

// MARK: - 连接测试（行内直接测试，不进入二级页面）

struct ConnectionTestRow: View {
    @EnvironmentObject private var settingsStore: SettingsStore

    @State private var testing = false
    @State private var result: String?
    @State private var succeeded = false

    var body: some View {
        Button {
            run()
        } label: {
            HStack(spacing: DSHTheme.Spacing.medium) {
                SettingsIcon(symbol: "bolt.horizontal.circle.fill", color: .green)
                Text("连接测试")
                Spacer(minLength: DSHTheme.Spacing.small)
                trailing
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(testing || !settingsStore.isConfigured)
        .accessibilityIdentifier("settings.connection")
    }

    @ViewBuilder
    private var trailing: some View {
        if testing {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("测试中")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
        } else if let result {
            Text(result)
                .font(.system(size: 13))
                .foregroundStyle(succeeded ? DSHTheme.success : DSHTheme.danger)
                .lineLimit(1)
                .truncationMode(.tail)
                .accessibilityIdentifier("settings.connection.result")
        } else {
            Text(settingsStore.isConfigured ? "点击测试" : "未配置 Key")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
        }
    }

    private func run() {
        testing = true
        result = nil
        let client = DeepSeekClient(timeout: 20)
        let settings = settingsStore.settings
        let key = settingsStore.apiKey
        Task { @MainActor in
            defer { testing = false }
            do {
                let ids = try await client.fetchModelIDs(settings: settings, apiKey: key)
                succeeded = true
                result = "连接正常 · \(ids.count) 个模型"
            } catch {
                succeeded = false
                // 行内只显示简短结果，完整信息在无障碍标签中
                let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                result = Self.short(message)
            }
        }
    }

    /// 缩短错误文案，例如「API Key 无效或已失效（401）」→「Key 无效 · 401」
    private static func short(_ message: String) -> String {
        if let range = message.range(of: "（") {
            let head = String(message[..<range.lowerBound])
            let tail = message[range.upperBound...].replacingOccurrences(of: "）", with: "")
            return "\(head) · \(tail)"
        }
        return message.count > 12 ? String(message.prefix(12)) + "…" : message
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
                        .contentShape(Rectangle())
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
                Text("值越低回答越稳定，越高越有创造性。日常建议 0.6 ~ 1.0。\n与「深度思考」不冲突：两者是不同参数，但官方 API 在深度思考开启时会忽略 temperature，此时该值不生效。")
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

// MARK: - 回答风格约束（插件）

/// 「回答风格约束」：编辑追加在每条消息末尾的强调指令，并可直接开关该插件。
struct StyleSuffixSettingsView: View {
    @EnvironmentObject private var settingsStore: SettingsStore
    @EnvironmentObject private var plugins: PluginManager

    /// 内置插件「回答风格约束」的固定 id（来自脚本文件名 prompt-suffix.js）
    private var suffixPlugin: PluginManifest? {
        plugins.manifests.first { $0.id == "builtin.prompt-suffix" }
    }

    var body: some View {
        List {
            pluginSection
            editorSection
            defaultSection
        }
        .listStyle(.insetGrouped)
        .navigationTitle("回答风格约束")
        .navigationBarTitleDisplayMode(.inline)
        .tint(DSHTheme.brand)
    }

    private var pluginSection: some View {
        Section {
            if let suffixPlugin {
                Toggle(isOn: Binding(
                    get: { suffixPlugin.isEnabled },
                    set: { plugins.setEnabled($0, for: suffixPlugin.id) }
                )) {
                    SettingsRowLabel(symbol: "text.bubble.fill", color: .indigo, title: "启用回答风格约束")
                }
                .accessibilityIdentifier("styleSuffix.enabled")
            } else {
                Text("未找到内置插件，可在插件中心刷新后重试。")
                    .foregroundStyle(.secondary)
            }
        } footer: {
            Text("关闭时不会追加任何内容；修改下方指令后立即生效，无需重启。")
        }
    }

    private var editorSection: some View {
        Section {
            TextEditor(text: $settingsStore.settings.styleSuffix)
                .font(.system(size: 15))
                .frame(minHeight: 140)
                .accessibilityIdentifier("styleSuffix.editor")
        } header: {
            Text("强调指令")
        } footer: {
            Text("这段内容会追加在每条用户消息末尾发送给模型，例如：「请用中文分点回答，不要客套话」。留空则使用默认约束。")
        }
    }

    private var defaultSection: some View {
        Section {
            Button {
                settingsStore.settings.styleSuffix = AppSettings.defaultStyleSuffix
            } label: {
                Label("恢复默认指令", systemImage: "arrow.counterclockwise")
            }
            .disabled(settingsStore.settings.styleSuffix == AppSettings.defaultStyleSuffix)
            .accessibilityIdentifier("styleSuffix.reset")
        } footer: {
            Text("默认指令：\(AppSettings.defaultStyleSuffix)")
        }
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
                        // 窗口级交叉淡入淡出，避免深浅色切换整屏生硬跳变
                        dshApplyAppearanceChange(to: theme) {
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
                        // plain 按钮默认只有文字本身可点，这里让整行都可点
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("theme.\(theme.rawValue)")
                }
            } footer: {
                Text("切换后立即生效。")
            }
        }
        .listStyle(.insetGrouped)
        .animation(DSHAnim.standard, value: settingsStore.settings.appTheme)
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

    var body: some View {
        List {
            Section {
                LabeledContent("版本", value: appVersion)
                LabeledContent("支持系统", value: "iOS 16.2 及以上")
                LabeledContent("插件运行时", value: "JavaScriptCore")
            }
            Section {
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
                Text("dsh.log(msg)\ndsh.registerCommand(name, summary, fn)\ndsh.onMessage(fn)\ndsh.setStorage(key, value)\ndsh.getStorage(key)\ndsh.getSetting(key)  // 读取宿主设置，如 styleSuffix")
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