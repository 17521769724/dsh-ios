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

        // UI 测试用：-uitest-reset 启动参数清空历史，保证用例从干净状态开始
        if ProcessInfo.processInfo.arguments.contains("-uitest-reset") {
            conversations.deleteAll()
        }
        // UI 测试用：-uitest-seed 注入演示会话，用于验证聊天界面渲染
        if ProcessInfo.processInfo.arguments.contains("-uitest-seed") {
            conversations.seedDemoConversation(model: settings.settings.defaultModel)
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
                .preferredColorScheme(preferredScheme)
                .tint(DSHTheme.brand)
        }
    }

    private var preferredScheme: ColorScheme? {
        switch settingsStore.settings.appTheme {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}