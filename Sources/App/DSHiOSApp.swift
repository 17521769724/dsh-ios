import SwiftUI

@main
struct DSHiOSApp: App {

    @StateObject private var settingsStore: SettingsStore
    @StateObject private var conversationStore: ConversationStore
    @StateObject private var pluginManager: PluginManager
    @StateObject private var engine: ChatEngine

    init() {
        let settings = SettingsStore()
        let conversations = ConversationStore()
        let pluginManager = PluginManager()
        let arguments = ProcessInfo.processInfo.arguments

        // UI 测试用：-uitest-reset 清空历史，-uitest-seed 注入演示会话，
        // -uitest-apikey 预置 Key 以便跳过引导页
        if arguments.contains("-uitest-reset") {
            conversations.deleteAll()
        }
        if arguments.contains("-uitest-seed") {
            conversations.seedDemoConversation(model: settings.settings.defaultModel)
        }
        if arguments.contains("-uitest-apikey") {
            settings.apiKey = "sk-uitest-placeholder"
        }

        _settingsStore = StateObject(wrappedValue: settings)
        _conversationStore = StateObject(wrappedValue: conversations)
        _pluginManager = StateObject(wrappedValue: pluginManager)
        _engine = StateObject(wrappedValue: ChatEngine(
            settingsStore: settings,
            conversationStore: conversations,
            pluginManager: pluginManager
        ))
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(engine)
                .environmentObject(settingsStore)
                .environmentObject(conversationStore)
                .environmentObject(pluginManager)
                .tint(DSHTheme.brand)
        }
    }
}