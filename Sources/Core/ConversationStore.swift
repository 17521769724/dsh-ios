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
