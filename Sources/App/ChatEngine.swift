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

    private var streamTask: Task<Void, Never>?
    private var client: DeepSeekClient
    private var cancellables: Set<AnyCancellable> = []

    init(
        settingsStore: SettingsStore,
        conversationStore: ConversationStore,
        pluginManager: PluginManager
    ) {
        self.settingsStore = settingsStore
        self.conversationStore = conversationStore
        self.pluginManager = pluginManager
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
        let apiMessages = buildAPIMessages(conversationID: conversationID, latestUserText: outgoing)
        let model = activeModelID
        let settings = settingsStore.settings
        let apiKey = settingsStore.apiKey

        client = DeepSeekClient(timeout: settings.requestTimeout)
        isStreaming = true

        streamTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                if settings.streamEnabled {
                    let stream = self.client.streamChat(
                        messages: apiMessages,
                        model: model,
                        settings: settings,
                        apiKey: apiKey
                    )
                    var usage: TokenUsage?
                    for try await event in stream {
                        if Task.isCancelled { break }
                        switch event {
                        case .content(let delta):
                            self.appendContent(delta, assistantID: assistantID)
                        case .reasoning(let delta):
                            self.appendReasoning(delta, assistantID: assistantID)
                        case .finished(let tokenUsage):
                            if let tokenUsage { usage = tokenUsage }
                        }
                    }
                    self.finish(assistantID: assistantID, conversationID: conversationID, usage: usage)
                } else {
                    let result = try await self.client.complete(
                        messages: apiMessages,
                        model: model,
                        settings: settings,
                        apiKey: apiKey
                    )
                    self.appendContent(result.text, assistantID: assistantID)
                    if let reasoning = result.reasoning, !reasoning.isEmpty {
                        self.appendReasoning(reasoning, assistantID: assistantID)
                    }
                    self.finish(assistantID: assistantID, conversationID: conversationID, usage: result.usage)
                }
            } catch {
                if Task.isCancelled {
                    self.finish(assistantID: assistantID, conversationID: conversationID, usage: nil)
                } else {
                    self.fail(assistantID: assistantID, conversationID: conversationID, error: error)
                }
            }
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
                guard !message.content.isEmpty else { continue }
                result.append(APIMessage(role: message.role.rawValue, content: message.content))
            case .system, .tool:
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