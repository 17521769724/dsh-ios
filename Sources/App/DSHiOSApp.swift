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