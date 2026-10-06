import SwiftUI

@main
struct DSHiOSApp: App {

    @StateObject private var settingsStore: SettingsStore
    @StateObject private var conversationStore: ConversationStore
    @StateObject private var pluginManager: PluginManager
    @StateObject private var sshStore: SSHStore
    @StateObject private var gitStore: GitAccountStore
    @StateObject private var engine: ChatEngine

    init() {
        let settings = SettingsStore()
        let conversations = ConversationStore()
        let pluginManager = PluginManager()
        let sshStore = SSHStore()
        let gitStore = GitAccountStore()
        let arguments = ProcessInfo.processInfo.arguments

        // UI 测试用：-uitest-reset 清空历史，-uitest-seed 注入演示会话，
        // -uitest-apikey 预置 Key 以便跳过引导页
        if arguments.contains("-uitest-reset") {
            conversations.deleteAll()
            // Keychain 在模拟器上不会随 App 卸载而清空，需显式清掉 Key，
            // 否则引导页门禁测试会因残留 Key 直接进入主页。
            settings.apiKey = ""
        }
        if arguments.contains("-uitest-seed") {
            conversations.seedDemoConversation(model: settings.settings.defaultModel)
        }
        if arguments.contains("-uitest-apikey") {
            settings.apiKey = "sk-uitest-placeholder"
        }

        let engine = ChatEngine(
            settingsStore: settings,
            conversationStore: conversations,
            pluginManager: pluginManager,
            sshStore: sshStore,
            gitStore: gitStore
        )
        // 让插件（如「回答风格约束」）能读到设置里编辑的内容
        pluginManager.configure(settingsStore: settings)
        // -uitest-server-models 模拟「已从服务端拉取模型列表」，用于验证列表刷新链路
        if arguments.contains("-uitest-server-models") {
            engine.availableModels = DSHModel.list(from: [
                "deepseek-flash",
                "deepseek-v4-pro",
                "deepseek-vl-experimental"
            ])
        }

        _settingsStore = StateObject(wrappedValue: settings)
        _conversationStore = StateObject(wrappedValue: conversations)
        _pluginManager = StateObject(wrappedValue: pluginManager)
        _sshStore = StateObject(wrappedValue: sshStore)
        _gitStore = StateObject(wrappedValue: gitStore)
        _engine = StateObject(wrappedValue: engine)
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(engine)
                .environmentObject(settingsStore)
                .environmentObject(conversationStore)
                .environmentObject(pluginManager)
                .environmentObject(sshStore)
                .environmentObject(gitStore)
                .tint(DSHTheme.brand)
        }
    }
}