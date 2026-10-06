import Foundation
import Combine
import SwiftUI
import UIKit

/// 应用总控：串联设置、会话、插件与网络层。
final class ChatEngine: ObservableObject {

    // MARK: - 依赖

    let settingsStore: SettingsStore
    let conversationStore: ConversationStore
    let pluginManager: PluginManager
    let sshStore: SSHStore
    let gitStore: GitAccountStore

    // MARK: - 界面状态

    @Published var currentConversation: Conversation?
    @Published var isStreaming: Bool = false
    @Published var streamingReasoning: String = ""
    @Published var toast: String?
    @Published var lastError: String?
    @Published var draft: String = ""
    @Published var commandPaletteVisible: Bool = false
    /// 流式内容每次变化自增，用于驱动视图滚动
    @Published var streamingTick: Int = 0
    /// 可用模型列表（可来自服务端 /models，失败时回退内置列表）
    @Published var availableModels: [DSHModel] = DSHModel.catalog
    @Published var isRefreshingModels: Bool = false
    @Published var modelsError: String?
    /// 请求弹出内置浏览器（由 RootView 消费）
    @Published var browserRequest: BrowserRequest?

    private var streamTask: Task<Void, Never>?
    private var client: DeepSeekClient
    private var cancellables: Set<AnyCancellable> = []

    init(
        settingsStore: SettingsStore,
        conversationStore: ConversationStore,
        pluginManager: PluginManager,
        sshStore: SSHStore,
        gitStore: GitAccountStore
    ) {
        self.settingsStore = settingsStore
        self.conversationStore = conversationStore
        self.pluginManager = pluginManager
        self.sshStore = sshStore
        self.gitStore = gitStore
        self.client = DeepSeekClient(timeout: settingsStore.settings.requestTimeout)

        if let latest = conversationStore.sortedConversations.first {
            self.currentConversation = latest
        }

        // ConversationStore 是嵌套的 ObservableObject：把它的变更桥接到 engine，
        // 否则「侧边栏长按删除会话」这类只改 store、不改 engine 状态的操作，
        // 正在显示的列表不会立即刷新（需要重开抽屉才看到结果）。
        conversationStore.objectWillChange
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
            .store(in: &cancellables)
    }

    // MARK: - 模型

    /// 当前会话使用的模型 ID
    var activeModelID: String {
        currentConversation?.model ?? settingsStore.settings.defaultModel
    }

    var activeModelName: String {
        DSHModel.describe(id: activeModelID).name
    }

    /// 从服务端拉取真实模型列表，避免内置名称与实际不符
    func refreshModels() {
        guard !isRefreshingModels else { return }
        guard settingsStore.isConfigured else {
            modelsError = DSHError.missingAPIKey.localizedDescription
            return
        }
        isRefreshingModels = true
        modelsError = nil
        let settings = settingsStore.settings
        let key = settingsStore.apiKey

        Task { @MainActor in
            defer { isRefreshingModels = false }
            do {
                let ids = try await client.fetchModelIDs(settings: settings, apiKey: key)
                guard !ids.isEmpty else {
                    modelsError = "服务端未返回任何模型"
                    return
                }
                // 拉取成功后，设置页与输入框上方的模型列表会立即刷新为服务端结果
                availableModels = DSHModel.list(from: ids)
                if !availableModels.contains(where: { $0.id == settingsStore.settings.defaultModel }) {
                    settingsStore.settings.defaultModel = availableModels[0].id
                }
                showToast("已获取 \(availableModels.count) 个模型")
            } catch {
                modelsError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }
    }

    func selectModel(_ id: String) {
        settingsStore.settings.defaultModel = id
        if var conversation = currentConversation {
            conversation.model = id
            currentConversation = conversation
            conversationStore.upsert(conversation)
        }
    }

    /// 主页「深度思考」开关
    func toggleDeepThinking() {
        settingsStore.settings.thinkingEnabled.toggle()
        haptic(.light)
    }

    // MARK: - 会话操作

    func newConversation() {
        stopStreaming()
        let conversation = Conversation(model: settingsStore.settings.defaultModel)
        conversationStore.upsert(conversation)
        currentConversation = conversation
        haptic(.light)
    }

    func select(_ conversation: Conversation) {
        guard conversation.id != currentConversation?.id else { return }
        stopStreaming()
        currentConversation = conversation
    }

    func delete(_ conversation: Conversation) {
        if currentConversation?.id == conversation.id {
            stopStreaming()
            currentConversation = nil
        }
        conversationStore.delete(id: conversation.id)
        haptic(.light)
    }

    func deleteAllConversations() {
        stopStreaming()
        currentConversation = nil
        conversationStore.deleteAll()
    }

    func togglePin(_ conversation: Conversation) {
        conversationStore.togglePin(id: conversation.id)
        if currentConversation?.id == conversation.id, let updated = conversationStore.conversation(id: conversation.id) {
            currentConversation = updated
        }
    }

    /// 侧栏长按菜单：重命名会话
    func rename(_ conversation: Conversation, to title: String) {
        conversationStore.rename(id: conversation.id, title: title)
        if currentConversation?.id == conversation.id, let updated = conversationStore.conversation(id: conversation.id) {
            currentConversation = updated
        }
        haptic(.light)
    }

    // MARK: - 发送

    func send(_ rawText: String? = nil) {
        let text = (rawText ?? draft).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isStreaming else { return }

        guard settingsStore.isConfigured else {
            presentError(DSHError.missingAPIKey.localizedDescription)
            return
        }

        if currentConversation == nil {
            currentConversation = conversationStore.createConversation(model: settingsStore.settings.defaultModel)
        }
        guard var conversation = currentConversation else { return }

        draft = ""
        let outgoing = pluginManager.transformOutgoing(text, role: "user")

        var userMessage = ChatMessage(role: .user, content: text)
        userMessage.model = conversation.model
        conversation.messages.append(userMessage)

        var assistantMessage = ChatMessage(role: .assistant, content: "", isStreaming: true)
        assistantMessage.model = conversation.model
        conversation.messages.append(assistantMessage)

        conversation.refreshTitleFromFirstUserMessage()
        conversation.updatedAt = Date()
        currentConversation = conversation
        conversationStore.upsert(conversation)

        streamingReasoning = ""
        haptic(.medium)
        startStreaming(conversationID: conversation.id, assistantID: assistantMessage.id, outgoing: outgoing)
    }

    func stopStreaming() {
        streamTask?.cancel()
        streamTask = nil
        if isStreaming {
            isStreaming = false
            finalizeStreamingMessage()
        }
    }

    /// 重新生成最后一条助手回复
    func regenerateLast() {
        guard !isStreaming, var conversation = currentConversation else { return }
        guard let lastAssistantIndex = conversation.messages.lastIndex(where: { $0.role == .assistant }) else { return }

        conversation.messages.removeSubrange(lastAssistantIndex...)
        var assistantMessage = ChatMessage(role: .assistant, content: "", isStreaming: true)
        assistantMessage.model = conversation.model
        conversation.messages.append(assistantMessage)
        conversation.updatedAt = Date()
        currentConversation = conversation
        conversationStore.upsert(conversation)

        let outgoing = lastUserText(in: conversation) ?? ""
        streamingReasoning = ""
        haptic(.medium)
        startStreaming(conversationID: conversation.id, assistantID: assistantMessage.id, outgoing: outgoing)
    }

    func deleteMessage(_ message: ChatMessage) {
        guard var conversation = currentConversation, !isStreaming else { return }
        conversation.messages.removeAll { $0.id == message.id }
        conversation.updatedAt = Date()
        currentConversation = conversation
        conversationStore.upsert(conversation)
    }

    /// 打开内置浏览器（手动入口）
    func openBrowser(_ url: URL) {
        browserRequest = BrowserRequest(url: url)
    }

    /// 点赞 / 点踩
    func rate(_ message: ChatMessage, value: Int) {
        mutateMessage(id: message.id) { target in
            target.rating = (target.rating == value) ? nil : value
        }
        if let conversation = currentConversation {
            conversationStore.upsert(conversation)
        }
        haptic(.light)
    }

    /// 把某条用户消息重新填入输入框（并截断其后的对话）
    func editAndResend(_ message: ChatMessage) {
        guard var conversation = currentConversation, !isStreaming else { return }
        guard let index = conversation.messages.firstIndex(where: { $0.id == message.id }) else { return }
        draft = message.content
        conversation.messages.removeSubrange(index...)
        conversation.updatedAt = Date()
        currentConversation = conversation
        conversationStore.upsert(conversation)
        haptic(.light)
    }

    // MARK: - 流式实现

    private func startStreaming(conversationID: UUID, assistantID: UUID, outgoing: String) {
        let model = activeModelID
        let settings = settingsStore.settings
        let apiKey = settingsStore.apiKey
        // 工具调用（Agent）：开启后模型可自主执行 SSH / 浏览器工具，最多连续 6 轮
        let tools = activeTools()
        let maxRounds = tools.isEmpty ? 1 : 6

        client = DeepSeekClient(timeout: settings.requestTimeout)
        isStreaming = true

        streamTask = Task { @MainActor [weak self] in
            guard let self else { return }
            var currentAssistantID = assistantID
            var usage: TokenUsage?
            do {
                for _ in 0..<maxRounds {
                    if Task.isCancelled { break }
                    let messages = self.buildAPIMessages(conversationID: conversationID, latestUserText: outgoing)
                    var pendingToolCalls: [ToolCall] = []

                    if settings.streamEnabled || !tools.isEmpty {
                        let stream = self.client.streamChat(
                            messages: messages,
                            model: model,
                            tools: tools,
                            settings: settings,
                            apiKey: apiKey
                        )
                        for try await event in stream {
                            if Task.isCancelled { break }
                            switch event {
                            case .content(let delta):
                                self.appendContent(delta, assistantID: currentAssistantID)
                            case .reasoning(let delta):
                                self.appendReasoning(delta, assistantID: currentAssistantID)
                            case .toolCalls(let calls):
                                pendingToolCalls = calls
                            case .finished(let tokenUsage):
                                if let tokenUsage { usage = tokenUsage }
                            }
                        }
                    } else {
                        let result = try await self.client.complete(
                            messages: messages,
                            model: model,
                            settings: settings,
                            apiKey: apiKey
                        )
                        self.appendContent(result.text, assistantID: currentAssistantID)
                        if let reasoning = result.reasoning, !reasoning.isEmpty {
                            self.appendReasoning(reasoning, assistantID: currentAssistantID)
                        }
                        if let tokenUsage = result.usage { usage = tokenUsage }
                    }

                    if Task.isCancelled { break }
                    guard !pendingToolCalls.isEmpty else { break }

                    // 记录本轮工具调用，并逐个在本地执行后写回结果
                    self.attachToolCalls(pendingToolCalls, assistantID: currentAssistantID)
                    for call in pendingToolCalls {
                        if Task.isCancelled { break }
                        self.ensureToolMessagePlaceholder(call: call, model: model)
                        let output = await self.run(toolCall: call)
                        self.completeToolMessage(output, call: call)
                    }

                    if Task.isCancelled { break }
                    // 下一轮：新建助手占位消息，带上工具结果继续请求
                    currentAssistantID = self.beginAssistantMessage(model: model)
                }

                self.finish(assistantID: currentAssistantID, conversationID: conversationID, usage: usage)
            } catch {
                if Task.isCancelled {
                    self.finish(assistantID: currentAssistantID, conversationID: conversationID, usage: nil)
                } else {
                    self.fail(assistantID: currentAssistantID, conversationID: conversationID, error: error)
                }
            }
        }
    }

    // MARK: - 工具调用（Agent）

    /// 当前开启的工具集合：SSH / 浏览器 / GitHub / Gitee 各自独立开关，
    /// 未配置（SSH 未填服务器、Git 未登录）的工具不下发，避免模型调用必然失败的工具。
    private func activeTools() -> [APITool] {
        let features = settingsStore.settings.features
        let browser = settingsStore.settings.browser
        return AgentToolCatalog.tools(
            sshEnabled: features.sshTool && sshStore.isConfigured,
            browserEnabled: features.browserTool,
            browserReadEnabled: features.browserTool && browser.allowAgentRead,
            githubEnabled: features.githubTool && gitStore.isConnected(.github),
            giteeEnabled: features.giteeTool && gitStore.isConnected(.gitee)
        )
    }

    private func attachToolCalls(_ calls: [ToolCall], assistantID: UUID) {
        mutateMessage(id: assistantID) { message in
            message.toolCalls = calls
            message.isStreaming = false
        }
        if let conversation = currentConversation {
            conversationStore.upsert(conversation)
        }
    }

    /// 先插入一条「执行中」的工具结果消息，便于界面上即时反馈
    private func ensureToolMessagePlaceholder(call: ToolCall, model: String) {
        guard var conversation = currentConversation else { return }
        guard !conversation.messages.contains(where: { $0.toolCallID == call.id }) else { return }
        var message = ChatMessage(role: .tool, content: "", isStreaming: true)
        message.toolCallID = call.id
        message.toolName = call.name
        message.model = model
        conversation.messages.append(message)
        conversation.updatedAt = Date()
        currentConversation = conversation
    }

    private func completeToolMessage(_ output: String, call: ToolCall) {
        guard var conversation = currentConversation else { return }
        guard let index = conversation.messages.lastIndex(where: { $0.toolCallID == call.id }) else { return }
        conversation.messages[index].content = output
        conversation.messages[index].isStreaming = false
        conversation.updatedAt = Date()
        currentConversation = conversation
        conversationStore.upsert(conversation)
    }

    /// 新增助手占位消息（工具结果之后继续对话）
    @discardableResult
    private func beginAssistantMessage(model: String) -> UUID {
        var message = ChatMessage(role: .assistant, content: "", isStreaming: true)
        message.model = model
        if var conversation = currentConversation {
            conversation.messages.append(message)
            conversation.updatedAt = Date()
            currentConversation = conversation
            conversationStore.upsert(conversation)
        }
        return message.id
    }

    /// 本地执行一次工具调用，返回给模型的文本结果
    @MainActor
    private func run(toolCall call: ToolCall) async -> String {
        switch call.name {
        case AgentToolCatalog.sshExecName:
            guard let command = ToolArguments.string("command", in: call.arguments) else {
                return "工具参数错误：缺少 command"
            }
            do {
                return try await SSHService.execute(
                    command: command,
                    configuration: sshStore.configuration,
                    password: sshStore.password
                )
            } catch {
                return (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }

        case AgentToolCatalog.browserOpenName:
            guard let raw = ToolArguments.string("url", in: call.arguments),
                  let url = WebAddress.normalize(raw) else {
                return "工具参数错误：缺少合法的 url"
            }
            browserRequest = BrowserRequest(url: url)
            return "已在内置浏览器中打开：\(url.absoluteString)"

        case AgentToolCatalog.browserReadName:
            guard let raw = ToolArguments.string("url", in: call.arguments),
                  let url = WebAddress.normalize(raw) else {
                return "工具参数错误：缺少合法的 url"
            }
            do {
                return try await WebPageReader.shared.read(url: url)
            } catch {
                return (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }

        case AgentToolCatalog.githubName, AgentToolCatalog.giteeName:
            let provider: GitProvider = call.name == AgentToolCatalog.githubName ? .github : .gitee
            let token = gitStore.token(for: provider)
            guard !token.isEmpty else {
                return "尚未在设置中登录 \(provider.displayName) 账号。"
            }
            do {
                return try await GitService.perform(
                    provider: provider,
                    arguments: call.arguments,
                    token: token
                )
            } catch {
                return (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }

        default:
            return "未知工具：\(call.name)"
        }
    }

    private func buildAPIMessages(conversationID: UUID, latestUserText: String) -> [APIMessage] {
        guard let conversation = currentConversation else { return [] }
        var result: [APIMessage] = []

        if !settingsStore.settings.systemPrompt.isEmpty {
            result.append(APIMessage(role: "system", content: settingsStore.settings.systemPrompt))
        }

        for message in conversation.messages where message.id != lastStreamingAssistantID(in: conversation) {
            switch message.role {
            case .user, .assistant:
                let toolCalls = message.toolCalls ?? []
                guard !message.content.isEmpty || !toolCalls.isEmpty else { continue }
                result.append(APIMessage(
                    role: message.role.rawValue,
                    content: message.content,
                    toolCalls: toolCalls.isEmpty ? nil : toolCalls,
                    toolCallID: nil
                ))
            case .tool:
                guard !message.content.isEmpty else { continue }
                result.append(APIMessage(
                    role: "tool",
                    content: message.content,
                    toolCalls: nil,
                    toolCallID: message.toolCallID
                ))
            case .system:
                continue
            }
        }

        // 确保最新的用户输入（可能被插件改写）出现在最后
        if let last = result.last, last.role == "user" {
            result[result.count - 1] = APIMessage(role: "user", content: latestUserText)
        }
        return result
    }

    private func lastStreamingAssistantID(in conversation: Conversation) -> UUID? {
        conversation.messages.last(where: { $0.role == .assistant && $0.isStreaming })?.id
    }

    private func lastUserText(in conversation: Conversation) -> String? {
        conversation.messages.last(where: { $0.role == .user })?.content
    }

    private func appendContent(_ delta: String, assistantID: UUID) {
        mutateMessage(id: assistantID) { message in
            message.content += delta
        }
        streamingTick &+= 1
    }

    private func appendReasoning(_ delta: String, assistantID: UUID) {
        streamingReasoning += delta
        mutateMessage(id: assistantID) { message in
            message.reasoning = (message.reasoning ?? "") + delta
        }
    }

    private func finish(assistantID: UUID, conversationID: UUID, usage: TokenUsage?) {
        mutateMessage(id: assistantID) { message in
            message.isStreaming = false
            _ = conversationID
        }
        if let usage {
            conversationStore.recordUsage(prompt: usage.promptTokens, completion: usage.completionTokens)
            mutateMessage(id: assistantID) { message in
                message.promptTokens = usage.promptTokens
                message.completionTokens = usage.completionTokens
            }
        }
        if let conversation = currentConversation {
            conversationStore.upsert(conversation)
        }
        isStreaming = false
        streamTask = nil
        haptic(.light)
    }

    private func fail(assistantID: UUID, conversationID: UUID, error: Error) {
        let text = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        mutateMessage(id: assistantID) { message in
            message.isStreaming = false
            message.errorText = text
        }
        _ = conversationID
        lastError = text
        if let conversation = currentConversation {
            conversationStore.upsert(conversation)
        }
        isStreaming = false
        streamTask = nil
    }

    private func finalizeStreamingMessage() {
        guard var conversation = currentConversation else { return }
        for index in conversation.messages.indices where conversation.messages[index].isStreaming {
            conversation.messages[index].isStreaming = false
        }
        currentConversation = conversation
        conversationStore.upsert(conversation)
    }

    // MARK: - 消息变更

    private func mutateMessage(id: UUID, _ transform: (inout ChatMessage) -> Void) {
        guard var conversation = currentConversation else { return }
        guard let index = conversation.messages.firstIndex(where: { $0.id == id }) else { return }
        transform(&conversation.messages[index])
        conversation.updatedAt = Date()
        currentConversation = conversation
    }

    // MARK: - 反馈

    private func haptic(_ style: UIImpactFeedbackGenerator.FeedbackStyle) {
        guard settingsStore.settings.hapticsEnabled else { return }
        let generator = UIImpactFeedbackGenerator(style: style)
        generator.impactOccurred()
    }

    private func presentError(_ message: String) {
        lastError = message
        // 与触感反馈开关保持一致：关闭后不产生任何振动
        guard settingsStore.settings.hapticsEnabled else { return }
        UINotificationFeedbackGenerator().notificationOccurred(.error)
    }

    func showToast(_ message: String) {
        withAnimation(DSHAnim.standard) { toast = message }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_800_000_000)
            withAnimation(DSHAnim.standard) { self.toast = nil }
        }
    }

    // MARK: - 统计

    var usage: UsageStat { conversationStore.usage }

    var estimatedContextTokens: Int {
        guard let conversation = currentConversation else { return 0 }
        let characters = conversation.messages.reduce(0) { $0 + $1.content.count }
        // 中文约 1.5 字符/token，英文约 4 字符/token，此处取折中估计
        return max(0, Int(Double(characters) / 2.2))
    }
}