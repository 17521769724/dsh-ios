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
    /// 用户自定义技能库：技能规定做法（与执行操作的工具互补）
    let skillStore: SkillStore
    /// 工作区文件：内置文件管理器与 IDE 和智能体工具共用同一批文件
    let workspaceStore: WorkspaceStore
    /// MCP 服务器：把远程服务器的工具下发给模型
    let mcpStore: MCPStore
    /// 系统提醒事项与日历（本机 EventKit）
    private let reminders = RemindersService()

    // MARK: - 界面状态

    @Published var currentConversation: Conversation?
    @Published var isStreaming: Bool = false
    @Published var toast: String?
    @Published var lastError: String?
    @Published var draft: String = ""
    /// 输入框里待发送的图片（发送后清空）
    @Published var draftImages: [ChatAttachment] = []
    @Published var commandPaletteVisible: Bool = false
    /// 正在生成的增量缓冲：只有订阅它的那一条消息视图会随生成刷新，
    /// 其余界面（会话列表、输入区、侧栏抽屉、导航栏）在生成期间完全不动，滑动才跟手
    @Published private(set) var streaming: StreamingText?
    /// 正在压缩上下文：此时不接受新的发送，界面显示「正在压缩上下文…」
    @Published private(set) var compacting = false
    /// 可用模型列表（可来自服务端 /models，失败时回退内置列表）
    @Published var availableModels: [DSHModel] = DSHModel.catalog
    @Published var isRefreshingModels: Bool = false
    @Published var modelsError: String?
    /// 请求弹出内置浏览器（由 RootView 消费）
    @Published var browserRequest: BrowserRequest?

    private var streamTask: Task<Void, Never>?
    private var client: DeepSeekClient
    private var cancellables: Set<AnyCancellable> = []

    /// 流式增量缓冲区：模型每秒可能推送几十个增量，逐条刷新会让消息列表、
    /// Markdown 解析与滚动反复重排导致明显卡顿，这里先攒起来再按固定节奏写入。
    private var pendingStreamDeltas: (assistantID: UUID, content: String, reasoning: String)?
    private var streamFlushTask: Task<Void, Never>?
    /// 后台执行申请：进入后台时若仍在生成，用它把请求续跑一段时间
    private var backgroundTaskID: UIBackgroundTaskIdentifier = .invalid

    init(
        settingsStore: SettingsStore,
        conversationStore: ConversationStore,
        pluginManager: PluginManager,
        sshStore: SSHStore,
        gitStore: GitAccountStore,
        skillStore: SkillStore,
        workspaceStore: WorkspaceStore = WorkspaceStore(),
        mcpStore: MCPStore = MCPStore()
    ) {
        self.settingsStore = settingsStore
        self.conversationStore = conversationStore
        self.pluginManager = pluginManager
        self.sshStore = sshStore
        self.gitStore = gitStore
        self.skillStore = skillStore
        self.workspaceStore = workspaceStore
        self.mcpStore = mcpStore
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

        // 后台继续生成：App 退到后台时若仍在流式请求，申请一段后台执行时间，
        // 否则进程被挂起、网络回调停止，模型回复会「暂停」到回到前台才继续。
        NotificationCenter.default.publisher(for: UIApplication.didEnterBackgroundNotification)
            .sink { [weak self] _ in self?.beginBackgroundAssertionIfNeeded() }
            .store(in: &cancellables)
        NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)
            .sink { [weak self] _ in self?.flushPendingStream() }
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
        // 只有从输入框直接发送时才带上待发图片（插件改写、编辑重发等走 rawText 的路径不带）
        let attachments = rawText == nil ? draftImages : []
        guard !text.isEmpty || !attachments.isEmpty, !isStreaming, !compacting else { return }

        guard settingsStore.isConfigured else {
            presentError(DSHError.missingAPIKey.localizedDescription)
            return
        }

        if currentConversation == nil {
            currentConversation = conversationStore.createConversation(model: settingsStore.settings.defaultModel)
        }
        guard var conversation = currentConversation else { return }

        draft = ""
        draftImages = []
        let outgoing = pluginManager.transformOutgoing(text, role: "user")

        var userMessage = ChatMessage(role: .user, content: text)
        userMessage.model = conversation.model
        if !attachments.isEmpty {
            userMessage.attachments = attachments
        }
        conversation.messages.append(userMessage)

        var assistantMessage = ChatMessage(role: .assistant, content: "", isStreaming: true)
        assistantMessage.model = conversation.model
        conversation.messages.append(assistantMessage)

        conversation.refreshTitleFromFirstUserMessage()
        conversation.updatedAt = Date()
        currentConversation = conversation
        conversationStore.upsert(conversation)

        haptic(.medium)
        // 上下文接近当前模型的窗口上限时，先把较早的历史压成摘要再生成
        if settingsStore.settings.features.autoCompact, needsContextCompaction(conversation) {
            compacting = true
            Task { @MainActor [weak self] in
                guard let self else { return }
                await self.performCompaction(conversationID: conversation.id, automatic: true)
                self.compacting = false
                guard self.currentConversation?.id == conversation.id, !self.isStreaming else { return }
                self.startStreaming(conversationID: conversation.id, assistantID: assistantMessage.id, outgoing: outgoing)
            }
            return
        }
        startStreaming(conversationID: conversation.id, assistantID: assistantMessage.id, outgoing: outgoing)
    }

    // MARK: - 上下文压缩

    /// 估算的上下文占用与模型窗口（界面展示「上下文 xx%」）
    var contextUsage: (used: Int, limit: Int) {
        let model = DSHModel.describe(id: activeModelID)
        let used = currentConversation.map { ContextCompactor.estimatedTokens(for: $0.messages) } ?? 0
        return (used, model.contextWindow)
    }

    /// 当前对话是否需要压缩上下文
    func needsContextCompaction(_ conversation: Conversation) -> Bool {
        ContextCompactor.needsCompaction(
            conversation.messages.filter { $0.id != lastStreamingAssistantID(in: conversation) },
            model: DSHModel.describe(id: activeModelID)
        )
    }

    /// 手动压缩上下文（顶栏菜单入口）
    func compactContext(automatic: Bool = false) async {
        guard !compacting, !isStreaming else { return }
        guard settingsStore.isConfigured else {
            presentError(DSHError.missingAPIKey.localizedDescription)
            return
        }
        guard let conversation = currentConversation else {
            showToast("当前没有可压缩的对话")
            return
        }
        guard needsContextCompaction(conversation) else {
            showToast("当前上下文还很空，不需要压缩")
            return
        }
        compacting = true
        await performCompaction(conversationID: conversation.id, automatic: automatic)
        compacting = false
    }

    /// 真正执行一次压缩：较早的历史 → 模型摘要 → 替换成一条摘要消息
    private func performCompaction(conversationID: UUID, automatic: Bool) async {
        guard let conversation = conversationStore.conversation(id: conversationID) else { return }
        let model = DSHModel.describe(id: activeModelID)
        let visible = conversation.messages.filter { $0.id != lastStreamingAssistantID(in: conversation) }
        guard let plan = ContextCompactor.plan(
            for: visible,
            keepBudget: Int(Double(model.contextWindow) * ContextCompactor.keepRatio)
        ) else {
            if !automatic { showToast("当前上下文还很空，不需要压缩") }
            return
        }

        let client = DeepSeekClient(timeout: settingsStore.settings.requestTimeout)
        do {
            let result = try await client.complete(
                messages: ContextCompactor.summaryMessages(for: plan.summarized),
                model: activeModelID,
                settings: settingsStore.settings,
                apiKey: settingsStore.apiKey
            )
            let summary = ContextCompactor.summaryContent(from: result.text)
            guard !summary.isEmpty else {
                if !automatic { showToast("压缩失败：模型没有返回摘要内容") }
                return
            }
            apply(plan: plan, summary: summary, conversationID: conversationID)
            showToast("已\(automatic ? "自动" : "")压缩上下文：\(plan.summarized.count) 条历史 → 摘要")
        } catch {
            // 自动压缩失败不打断本次发送，交由后续请求按原上下文继续
            if !automatic {
                presentError("压缩上下文失败：\((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)")
            }
        }
    }

    /// 用摘要替换被压缩的历史消息
    private func apply(plan: CompactionPlan, summary: String, conversationID: UUID) {
        guard var conversation = conversationStore.conversation(id: conversationID) else { return }
        let summarizedIDs = Set(plan.summarized.map(\.id))
        var messages = conversation.messages.filter { !summarizedIDs.contains($0.id) }

        var summaryMessage = ChatMessage(role: .assistant, content: summary)
        summaryMessage.model = conversation.model
        summaryMessage.isContextSummary = true
        // 时间沿用被压缩的第一条，列表里的顺序与「历史发生时间」一致
        summaryMessage.createdAt = plan.summarized.first?.createdAt ?? Date()
        messages.insert(summaryMessage, at: 0)

        conversation.messages = messages
        conversation.updatedAt = Date()
        conversationStore.upsert(conversation)
        if currentConversation?.id == conversationID {
            currentConversation = conversation
        }
        // 被压缩掉的图片文件一并删除，避免长期占磁盘
        ChatAttachment.delete(plan.summarized.flatMap { $0.attachments ?? [] })
    }

    func stopStreaming() {
        streamTask?.cancel()
        streamTask = nil
        endBackgroundAssertion()
        if isStreaming {
            // 先把缓冲里的文字落进消息，停止时不会丢内容
            if let buffer = streaming { commitStreamingBuffer(to: buffer.messageID) }
            isStreaming = false
            streaming = nil
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
        haptic(.medium)
        startStreaming(conversationID: conversation.id, assistantID: assistantMessage.id, outgoing: outgoing)
    }

    func deleteMessage(_ message: ChatMessage) {
        guard var conversation = currentConversation, !isStreaming else { return }
        guard conversation.messages.contains(where: { $0.id == message.id }) else { return }

        let removingIDs = Self.deletionIDs(for: message, in: conversation.messages)
        let removed = conversation.messages.filter { removingIDs.contains($0.id) }
        conversation.messages.removeAll { removingIDs.contains($0.id) }
        conversation.updatedAt = Date()
        currentConversation = conversation
        conversationStore.upsert(conversation)
        // 消息没了，附带的图片文件也一起删掉，否则会长期留在磁盘上
        ChatAttachment.delete(removed.flatMap { $0.attachments ?? [] })
    }

    /// 删除某条消息时需要连带删除的消息 id（纯函数，便于单测）：
    /// - 删除用户消息：连同它的回复一起删（直到下一条用户消息之前）。
    ///   只删提问却留下回答，会让对话上下文前后错位。
    /// - 删除助手回复：连同它调用工具产生的工具结果一起删，
    ///   否则会留下没有对应 tool_calls 的孤立 tool 消息，后续请求会被服务端拒绝。
    static func deletionIDs(for message: ChatMessage, in messages: [ChatMessage]) -> Set<UUID> {
        var removingIDs: Set<UUID> = [message.id]
        guard let index = messages.firstIndex(where: { $0.id == message.id }) else { return removingIDs }

        if message.role == .user {
            for next in messages[(index + 1)...] {
                if next.role == .user { break }
                removingIDs.insert(next.id)
            }
        } else if message.role == .assistant {
            let callIDs = Set((message.toolCalls ?? []).map(\.id))
            if !callIDs.isEmpty {
                for other in messages where other.role == .tool {
                    if let callID = other.toolCallID, callIDs.contains(callID) {
                        removingIDs.insert(other.id)
                    }
                }
            }
        }
        return removingIDs
    }

    /// 移除一张待发送图片（连同磁盘文件）
    func removeDraftImage(_ attachment: ChatAttachment) {
        draftImages.removeAll { $0.id == attachment.id }
        ChatAttachment.delete([attachment])
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
        // 图片一并回到输入框，否则重发时附件会被静默丢掉
        draftImages = message.attachments ?? []
        // 被截断的消息里，除回到输入框的图片外，其余图片文件一并删除
        let reusedIDs = Set(draftImages.map(\.id))
        let dropped = conversation.messages[index...]
            .flatMap { $0.attachments ?? [] }
            .filter { !reusedIDs.contains($0.id) }
        conversation.messages.removeSubrange(index...)
        conversation.updatedAt = Date()
        currentConversation = conversation
        conversationStore.upsert(conversation)
        ChatAttachment.delete(dropped)
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
        streaming = StreamingText(messageID: assistantID)

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
            giteeEnabled: features.giteeTool && gitStore.isConnected(.gitee),
            visionEnabled: features.visionTool,
            fileEnabled: features.fileTool,
            clipboardEnabled: features.clipboardTool,
            reminderEnabled: features.reminderTool,
            mcpTools: features.mcpTool ? mcpStore.availableTools() : [],
            skillNames: activeSkillNames
        )
    }

    /// 下发给模型的技能名：开关关闭或没有启用技能时为空（此时不下发 skill 工具）
    private var activeSkills: [Skill] {
        settingsStore.settings.features.skillTool ? skillStore.enabledSkills : []
    }

    private var activeSkillNames: [String] {
        activeSkills.map(\.name)
    }

    private func attachToolCalls(_ calls: [ToolCall], assistantID: UUID) {
        // 先把这一段正文落进消息再标记「生成结束」，
        // 否则该消息在界面上会变成空白（内容还留在缓冲里没落库）
        commitStreamingBuffer(to: assistantID)
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
        // 新一轮重新开始累积：缓冲切换到新消息
        streaming?.restart(for: message.id)
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

        case AgentToolCatalog.skillName:
            guard let name = ToolArguments.string("name", in: call.arguments) else {
                return "工具参数错误：缺少 name"
            }
            guard let skill = skillStore.skill(named: name) else {
                let available = activeSkillNames
                return "没有找到技能「\(name)」。当前可用技能：\(available.isEmpty ? "无" : available.joined(separator: "、"))"
            }
            return "技能「\(skill.name)」的完整说明如下，请严格按它的步骤与要求完成用户的请求：\n\n\(skill.content)"

        case AgentToolCatalog.screenshotName:
            let raw = ToolArguments.string("target", in: call.arguments) ?? ScreenVision.Target.screen.rawValue
            let target = ScreenVision.Target(rawValue: raw.lowercased()) ?? .screen
            return await captureScreen(target: target, call: call)

        case AgentToolCatalog.workspaceName:
            let action = ToolArguments.string("action", in: call.arguments) ?? ""
            let path = ToolArguments.string("path", in: call.arguments) ?? ""
            // 文件内容原样写入：代码里的缩进与换行不能被裁掉
            let content = ToolArguments.rawString("content", in: call.arguments) ?? ""
            return workspaceStore.perform(action: action, path: path, content: content)

        case AgentToolCatalog.clipboardName:
            return clipboard(action: ToolArguments.string("action", in: call.arguments) ?? "read", call: call)

        case AgentToolCatalog.reminderName:
            let action = ToolArguments.string("action", in: call.arguments) ?? ""
            return await reminders.perform(action: action, arguments: ToolArguments.dictionary(call.arguments))

        default:
            // MCP 服务器提供的工具：转发给对应服务器执行
            if AgentToolCatalog.isMCPTool(call.name) {
                return await mcpStore.callTool(modelToolName: call.name, argumentsJSON: call.arguments)
            }
            return "未知工具：\(call.name)"
        }
    }

    // MARK: - 剪贴板

    /// 读写系统剪贴板：读取时系统会弹「允许粘贴」确认（iOS 的行为）
    private func clipboard(action: String, call: ToolCall) -> String {
        switch action.lowercased() {
        case "read":
            guard let text = UIPasteboard.general.string, !text.isEmpty else {
                return "剪贴板里现在没有文本内容。"
            }
            let limited = text.count > 4_000 ? String(text.prefix(4_000)) + "\n…（内容过长，已截断）" : text
            return "剪贴板内容如下：\n\n\(limited)"
        case "write":
            guard let text = ToolArguments.rawString("text", in: call.arguments), !text.isEmpty else {
                return "请通过 text 参数给出要复制到剪贴板的文本。"
            }
            UIPasteboard.general.string = text
            return "已复制到剪贴板（\(text.count) 字符），用户现在可以在任意 App 里粘贴。"
        default:
            return "不支持的动作：\(action)（可用：read / write）"
        }
    }

    // MARK: - 查看画面（截图 + 本地 OCR）

    /// 截取界面并识别文字：截图挂到工具消息上（「过程」弹窗里能看到），
    /// 随后的请求会把它作为图片发给模型——视觉模型直接看画面，纯文本模型读 OCR 文本。
    @MainActor
    private func captureScreen(target: ScreenVision.Target, call: ToolCall) async -> String {
        var image: UIImage?
        var sourceName = "App 当前界面"
        if target == .browser {
            if let snapshot = await ScreenVision.captureBrowser() {
                image = snapshot.image
                sourceName = snapshot.url.map { "内置浏览器页面（\($0.absoluteString)）" } ?? "内置浏览器页面"
            }
        } else {
            image = ScreenVision.captureAppScreen()
        }
        guard let image else {
            return target == .browser
                ? "内置浏览器没有打开或页面还没就绪，无法截图。可以先用 browser_open 打开目标网址，再调用 screenshot。"
                : "截图失败，请稍后重试。"
        }

        // 识别与压缩都放到后台，避免阻塞主线程（截图本身必须在主线程）
        let recognized = await ScreenVision.recognizeText(in: image)
        let jpeg = image.jpegData(compressionQuality: 0.82)
        let attachment = await Task.detached(priority: .userInitiated) {
            jpeg.flatMap { ChatAttachment.save($0) }
        }.value
        if let attachment {
            attach(attachment, toToolCall: call.id)
        }

        var lines = ["已截取\(sourceName)，截图作为图片附在本次工具结果之后。"]
        if recognized.isEmpty {
            lines.append("本地 OCR 没有识别到文字，请直接看图片内容。")
        } else {
            lines.append("本地 OCR 识别到的文字：\n\(ScreenVision.truncated(recognized))")
        }
        return lines.joined(separator: "\n\n")
    }

    /// 把截图挂到对应的工具结果消息上
    @MainActor
    private func attach(_ attachment: ChatAttachment, toToolCall callID: String) {
        guard var conversation = currentConversation else { return }
        guard let index = conversation.messages.lastIndex(where: { $0.toolCallID == callID }) else { return }
        var attachments = conversation.messages[index].attachments ?? []
        attachments.append(attachment)
        conversation.messages[index].attachments = attachments
        conversation.updatedAt = Date()
        currentConversation = conversation
    }

    /// 把「可用技能」清单并入系统提示：技能规定做法，工具负责执行，两者互补。
    /// 清单只给名字与摘要，全文由模型调用 skill 工具按需取回，避免每条请求都塞满上下文。
    static func systemPrompt(base: String, skills: [Skill]) -> String {
        guard !skills.isEmpty else { return base }
        let list = skills
            .map { "- \($0.name)：\($0.summary.isEmpty ? "（未写摘要）" : $0.summary)" }
            .joined(separator: "\n")
        let block = """
        可用技能（用户自己写的做事方法与规范）：
        \(list)
        技能与工具的分工：工具用来执行操作（执行命令、打开网页、读写仓库），技能用来说明「该怎么做」。\
        当前请求与某个技能相关时，先用 skill 工具取回该技能的完整说明，再按它的步骤与要求完成。
        """
        return base.isEmpty ? block : base + "\n\n" + block
    }

    private func buildAPIMessages(conversationID: UUID, latestUserText: String) -> [APIMessage] {
        guard let conversation = currentConversation else { return [] }
        var result: [APIMessage] = []
        /// 工具产生的截图（如「查看画面」）：等这一批工具结果都发完之后再作为一条用户消息附上，
        /// 避免打断「assistant(tool_calls) → tool(tool_call_id)…」的配对顺序
        var pendingToolImages: [ChatAttachment] = []

        func flushToolImages() {
            guard !pendingToolImages.isEmpty else { return }
            result.append(APIMessage(role: "user", content: Self.toolImagePlaceholder, images: pendingToolImages))
            pendingToolImages = []
        }

        let systemPrompt = Self.systemPrompt(base: settingsStore.settings.systemPrompt, skills: activeSkills)
        if !systemPrompt.isEmpty {
            result.append(APIMessage(role: "system", content: systemPrompt))
        }

        for message in conversation.messages where message.id != lastStreamingAssistantID(in: conversation) {
            // 遇到非工具消息说明这一批工具结果已经发完，先把截图补上
            if message.role != .tool { flushToolImages() }
            // 压缩摘要：按系统提示注入，让模型知道这是此前的对话
            if message.isContextSummary == true {
                guard !message.content.isEmpty else { continue }
                result.append(APIMessage(role: "system", content: ContextCompactor.injectedContent(message.content)))
                continue
            }
            switch message.role {
            case .user, .assistant:
                let toolCalls = message.toolCalls ?? []
                let images = message.role == .user ? message.attachments : nil
                guard !message.content.isEmpty || !toolCalls.isEmpty || !(images ?? []).isEmpty else { continue }
                result.append(APIMessage(
                    role: message.role.rawValue,
                    content: message.content,
                    toolCalls: toolCalls.isEmpty ? nil : toolCalls,
                    toolCallID: nil,
                    images: images
                ))
            case .tool:
                guard !message.content.isEmpty else { continue }
                result.append(APIMessage(
                    role: "tool",
                    content: message.content,
                    toolCalls: nil,
                    toolCallID: message.toolCallID
                ))
                pendingToolImages.append(contentsOf: message.attachments ?? [])
            case .system:
                continue
            }
        }
        flushToolImages()

        // 确保最新的用户输入（可能被插件改写）出现在最后；图片要一并保留。
        // 末尾若是刚补上的截图消息，则不动它（否则截图会关联到错误的文字）。
        if let last = result.last, last.role == "user", last.content != Self.toolImagePlaceholder {
            result[result.count - 1] = APIMessage(
                role: "user",
                content: latestUserText,
                images: last.images
            )
        }
        return result
    }

    /// 工具截图补给模型时用的占位文案（末尾替换逻辑据此跳过）
    private static let toolImagePlaceholder = "（这是工具刚截取的画面）"

    private func lastStreamingAssistantID(in conversation: Conversation) -> UUID? {
        conversation.messages.last(where: { $0.role == .assistant && $0.isStreaming })?.id
    }

    private func lastUserText(in conversation: Conversation) -> String? {
        conversation.messages.last(where: { $0.role == .user })?.content
    }

    private func appendContent(_ delta: String, assistantID: UUID) {
        coalesceStreamDelta(assistantID: assistantID, content: delta, reasoning: "")
    }

    private func appendReasoning(_ delta: String, assistantID: UUID) {
        coalesceStreamDelta(assistantID: assistantID, content: "", reasoning: delta)
    }

    /// 把增量攒进缓冲区，并按固定节奏写入界面缓冲（约 14 次/秒）。
    /// 逐条写入时每个 token 都会触发一次界面刷新，攒起来再写可以显著减少刷新次数。
    private func coalesceStreamDelta(assistantID: UUID, content: String, reasoning: String) {
        if var pending = pendingStreamDeltas, pending.assistantID == assistantID {
            pending.content += content
            pending.reasoning += reasoning
            pendingStreamDeltas = pending
        } else {
            // 换了消息（例如工具调用后的新一轮），先把上一条攒下的内容落地
            flushPendingStream()
            pendingStreamDeltas = (assistantID, content, reasoning)
        }
        scheduleStreamFlush()
    }

    private func scheduleStreamFlush() {
        guard streamFlushTask == nil, pendingStreamDeltas != nil else { return }
        streamFlushTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 70_000_000)
            guard let self else { return }
            self.streamFlushTask = nil
            self.flushPendingStream()
        }
    }

    /// 把缓冲区内容写入「流式缓冲对象」。
    /// 注意这里不动 `currentConversation`：生成期间只有订阅缓冲的那一条消息视图会刷新，
    /// 其余界面（列表、输入区、侧栏）完全不参与，这是滑动/开抽屉不卡的关键。
    private func flushPendingStream() {
        streamFlushTask?.cancel()
        streamFlushTask = nil
        guard let pending = pendingStreamDeltas else { return }
        pendingStreamDeltas = nil
        guard !pending.content.isEmpty || !pending.reasoning.isEmpty else { return }
        guard let buffer = streaming, buffer.messageID == pending.assistantID else { return }
        buffer.appendReasoning(pending.reasoning)
        buffer.appendContent(pending.content)
    }

    /// 生成结束 / 停止 / 切换新一轮时：把缓冲里的完整内容落进消息
    private func commitStreamingBuffer(to assistantID: UUID) {
        flushPendingStream()
        guard let buffer = streaming, buffer.messageID == assistantID else { return }
        guard !buffer.content.isEmpty || !buffer.reasoning.isEmpty else { return }
        let content = buffer.content
        let reasoning = buffer.reasoning
        mutateMessage(id: assistantID) { message in
            message.content = content
            message.reasoning = reasoning.isEmpty ? nil : reasoning
        }
    }

    // MARK: - 后台续跑

    private func beginBackgroundAssertionIfNeeded() {
        guard isStreaming, backgroundTaskID == .invalid else { return }
        backgroundTaskID = UIApplication.shared.beginBackgroundTask(withName: "dsh.stream") { [weak self] in
            // 系统即将收回后台时间：主动结束申请，让 App 正常进入挂起
            self?.endBackgroundAssertion()
        }
    }

    private func endBackgroundAssertion() {
        guard backgroundTaskID != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTaskID)
        backgroundTaskID = .invalid
    }

    private func finish(assistantID: UUID, conversationID: UUID, usage: TokenUsage?) {
        // 收尾前先把缓冲里的完整内容落进消息，否则最后几十毫秒的内容会丢
        commitStreamingBuffer(to: assistantID)
        streaming = nil
        endBackgroundAssertion()

        var finalUsage = usage
        var estimated = false
        if finalUsage == nil {
            // 服务端未在流式结束时返回 usage（少数中转服务会这样）时的兜底：
            // 按文本长度估算，保证「用量」始终可用（界面以 ≈ 标注为估算值）
            let completion = (message(id: assistantID)?.content ?? "")
                + (message(id: assistantID)?.reasoning ?? "")
            if !completion.isEmpty {
                finalUsage = TokenUsage.estimate(
                    prompt: Self.estimatedPromptText(conversation: currentConversation, excluding: assistantID),
                    completion: completion
                )
                estimated = true
            }
        }

        mutateMessage(id: assistantID) { message in
            message.isStreaming = false
            _ = conversationID
        }
        if let finalUsage {
            conversationStore.recordUsage(prompt: finalUsage.promptTokens, completion: finalUsage.completionTokens)
            mutateMessage(id: assistantID) { message in
                message.promptTokens = finalUsage.promptTokens
                message.completionTokens = finalUsage.completionTokens
                message.tokensEstimated = estimated
            }
        }
        if let conversation = currentConversation {
            conversationStore.upsert(conversation)
        }
        isStreaming = false
        streamTask = nil
        haptic(.light)
    }

    private func message(id: UUID) -> ChatMessage? {
        currentConversation?.messages.first(where: { $0.id == id })
    }

    /// 估算用上下文：除本次要写 token 的助手消息外，其余消息的正文
    private static func estimatedPromptText(conversation: Conversation?, excluding id: UUID) -> String {
        (conversation?.messages ?? [])
            .filter { $0.id != id }
            .map(\.content)
            .joined(separator: "\n")
    }

    private func fail(assistantID: UUID, conversationID: UUID, error: Error) {
        commitStreamingBuffer(to: assistantID)
        streaming = nil
        endBackgroundAssertion()
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