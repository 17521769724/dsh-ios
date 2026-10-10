import SwiftUI

@main
struct DSHiOSApp: App {

    @StateObject private var settingsStore: SettingsStore
    @StateObject private var conversationStore: ConversationStore
    @StateObject private var pluginManager: PluginManager
    @StateObject private var skillStore: SkillStore
    @StateObject private var sshStore: SSHStore
    @StateObject private var gitStore: GitAccountStore
    @StateObject private var workspaceStore: WorkspaceStore
    @StateObject private var mcpStore: MCPStore
    @StateObject private var engine: ChatEngine

    init() {
        let settings = SettingsStore()
        let conversations = ConversationStore()
        let pluginManager = PluginManager()
        let skillStore = SkillStore()
        let sshStore = SSHStore()
        let gitStore = GitAccountStore()
        let arguments = ProcessInfo.processInfo.arguments

        // UI 测试用：-uitest-reset 清空历史，-uitest-seed 注入演示会话，
        // -uitest-apikey 预置 Key 以便跳过引导页
        if arguments.contains("-uitest-reset") {
            conversations.deleteAll()
            skillStore.deleteAll()
            // 工作区（文件 / IDE 的文件夹）也一并清空，保证文件相关用例从空目录开始
            try? FileManager.default.removeItem(at: WorkspaceStore.defaultRoot)
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
        // 首次启动权限引导：UI 测试默认跳过（否则会挡住所有用例），
        // 需要单独验证时用 -uitest-permissions-primer 强制弹出
        if arguments.contains("-uitest-reset") {
            UserDefaults.standard.set(true, forKey: PermissionKeys.primerShown)
        }
        if arguments.contains("-uitest-permissions-primer") {
            UserDefaults.standard.set(false, forKey: PermissionKeys.primerShown)
        }

        // 上面可能删除了工作区目录，这里再建实例，保证根目录存在
        let workspaceStore = WorkspaceStore()
        let mcpStore = MCPStore()
        let cloudStore = CloudStore()

        let engine = ChatEngine(
            settingsStore: settings,
            conversationStore: conversations,
            pluginManager: pluginManager,
            sshStore: sshStore,
            gitStore: gitStore,
            skillStore: skillStore,
            workspaceStore: workspaceStore,
            mcpStore: mcpStore,
            cloudStore: cloudStore
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
        // 新功能弹窗：UI 测试默认跳过（否则会挡住用例）；
        // 需要单独验证时用 -uitest-release-notes 强制弹出
        if arguments.contains("-uitest-reset") {
            UserDefaults.standard.set(ReleaseNotes.currentVersion, forKey: ReleaseNotes.seenKey)
        }
        if arguments.contains("-uitest-release-notes") {
            UserDefaults.standard.set("", forKey: ReleaseNotes.seenKey)
        }

        _settingsStore = StateObject(wrappedValue: settings)
        _conversationStore = StateObject(wrappedValue: conversations)
        _pluginManager = StateObject(wrappedValue: pluginManager)
        _skillStore = StateObject(wrappedValue: skillStore)
        _sshStore = StateObject(wrappedValue: sshStore)
        _gitStore = StateObject(wrappedValue: gitStore)
        _workspaceStore = StateObject(wrappedValue: workspaceStore)
        _mcpStore = StateObject(wrappedValue: mcpStore)
        _engine = StateObject(wrappedValue: engine)
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(engine)
                .environmentObject(settingsStore)
                .environmentObject(conversationStore)
                .environmentObject(pluginManager)
                .environmentObject(skillStore)
                .environmentObject(sshStore)
                .environmentObject(gitStore)
                .environmentObject(workspaceStore)
                .environmentObject(mcpStore)
                .environmentObject(engine.cloudStore)
                .tint(DSHTheme.brand)
        }
    }
}