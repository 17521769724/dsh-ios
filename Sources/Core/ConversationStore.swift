import Foundation

/// 会话与用量存储，落盘到 Documents/state.json。
final class ConversationStore: ObservableObject {
    @Published private(set) var conversations: [Conversation] = []
    @Published private(set) var usage: UsageStat = UsageStat()

    private struct PersistedState: Codable {
        var conversations: [Conversation]
        var usage: UsageStat
    }

    private let fileURL: URL
    private var saveTask: Task<Void, Never>?

    init(fileName: String = "state.json") {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        self.fileURL = dir.appendingPathComponent(fileName)
        load()
    }

    // MARK: - 查询

    var sortedConversations: [Conversation] {
        conversations.sorted { lhs, rhs in
            if lhs.isPinned != rhs.isPinned { return lhs.isPinned }
            return lhs.updatedAt > rhs.updatedAt
        }
    }

    func conversation(id: UUID) -> Conversation? {
        conversations.first(where: { $0.id == id })
    }

    // MARK: - 写入

    @discardableResult
    func createConversation(model: String) -> Conversation {
        let conversation = Conversation(model: model)
        conversations.append(conversation)
        scheduleSave()
        return conversation
    }

    func upsert(_ conversation: Conversation) {
        if let index = conversations.firstIndex(where: { $0.id == conversation.id }) {
            conversations[index] = conversation
        } else {
            conversations.append(conversation)
        }
        scheduleSave()
    }

    func delete(id: UUID) {
        conversations.removeAll { $0.id == id }
        scheduleSave()
    }

    func deleteAll() {
        conversations.removeAll()
        scheduleSave()
    }

    func togglePin(id: UUID) {
        guard let index = conversations.firstIndex(where: { $0.id == id }) else { return }
        conversations[index].isPinned.toggle()
        scheduleSave()
    }

    func recordUsage(prompt: Int, completion: Int) {
        usage.totalPromptTokens += prompt
        usage.totalCompletionTokens += completion
        usage.totalRequests += 1
        scheduleSave()
    }

    func resetUsage() {
        usage = UsageStat()
        scheduleSave()
    }

    /// 仅用于 UI 测试与演示：写入一条包含 Markdown、代码块与思考过程的会话，
    /// 以便在无法真实调用模型的情况下验证聊天界面的渲染。
    @discardableResult
    func seedDemoConversation(model: String) -> Conversation {
        var conversation = Conversation(model: model)
        conversation.messages = [
            ChatMessage(
                role: .user,
                content: "用 Swift 写一个防抖函数，并解释它的用途。"
            ),
            ChatMessage(
                role: .assistant,
                content: """
                下面是一个通用的防抖实现：

                ```swift
                final class Debouncer {
                    private var workItem: DispatchWorkItem?

                    func schedule(delay: TimeInterval, action: @escaping () -> Void) {
                        workItem?.cancel()
                        let item = DispatchWorkItem(block: action)
                        workItem = item
                        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
                    }
                }
                ```

                **用途**：把短时间内连续触发的事件合并为一次执行，常见于搜索输入、按钮连点与滚动回调。

                - 减少无效请求与重复计算
                - 保证只在用户停下来之后处理
                - 与节流（`throttle`）的区别是：防抖只触发最后一次
                """,
                reasoning: "用户要的是防抖函数，需要给出可运行实现并说明使用场景。先确认防抖与节流的区别，再组织代码与要点。",
                isStreaming: false,
                model: model,
                promptTokens: 86,
                completionTokens: 214,
                rating: 1
            )
        ]
        conversation.refreshTitleFromFirstUserMessage()
        upsert(conversation)
        return conversation
    }

    /// 导出全部会话为 Markdown 文本
    func exportMarkdown() -> String {
        var output = "# DSH iOS 会话导出\n\n"
        for conversation in sortedConversations {
            output += "## \(conversation.title)\n\n"
            output += "- 模型：`\(conversation.model)`\n"
            output += "- 创建时间：\(Self.formatter.string(from: conversation.createdAt))\n\n"
            for message in conversation.messages where message.role != .system {
                output += "**\(message.role.displayName)**：\n\n\(message.content)\n\n"
            }
            output += "---\n\n"
        }
        return output
    }

    // MARK: - 持久化

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        if let state = try? JSONDecoder().decode(PersistedState.self, from: data) {
            conversations = state.conversations
            usage = state.usage
        }
    }

    private func scheduleSave() {
        saveTask?.cancel()
        let snapshot = PersistedState(conversations: conversations, usage: usage)
        let url = fileURL
        saveTask = Task {
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled else { return }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted]
            guard let data = try? encoder.encode(snapshot) else { return }
            try? data.write(to: url, options: .atomic)
        }
    }

    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter
    }()
}
