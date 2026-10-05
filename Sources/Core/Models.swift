import Foundation

// MARK: - 角色

enum MessageRole: String, Codable, Hashable {
    case system
    case user
    case assistant
    case tool

    var displayName: String {
        switch self {
        case .system: return "系统"
        case .user: return "我"
        case .assistant: return "DSH"
        case .tool: return "工具"
        }
    }
}

// MARK: - 消息

struct ChatMessage: Identifiable, Codable, Hashable {
    var id: UUID
    var role: MessageRole
    var content: String
    var reasoning: String?
    var createdAt: Date
    var isStreaming: Bool
    var errorText: String?
    var model: String?
    var promptTokens: Int?
    var completionTokens: Int?
    /// 用户对回复的反馈：1 赞，-1 踩，nil 未评价
    var rating: Int?

    init(
        id: UUID = UUID(),
        role: MessageRole,
        content: String,
        reasoning: String? = nil,
        createdAt: Date = Date(),
        isStreaming: Bool = false,
        errorText: String? = nil,
        model: String? = nil,
        promptTokens: Int? = nil,
        completionTokens: Int? = nil,
        rating: Int? = nil
    ) {
        self.id = id
        self.role = role
        self.content = content
        self.reasoning = reasoning
        self.createdAt = createdAt
        self.isStreaming = isStreaming
        self.errorText = errorText
        self.model = model
        self.promptTokens = promptTokens
        self.completionTokens = completionTokens
        self.rating = rating
    }
}

// MARK: - 会话

struct Conversation: Identifiable, Codable, Hashable {
    var id: UUID
    var title: String
    var messages: [ChatMessage]
    var model: String
    var createdAt: Date
    var updatedAt: Date
    var isPinned: Bool

    init(
        id: UUID = UUID(),
        title: String = "新会话",
        messages: [ChatMessage] = [],
        model: String,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        isPinned: Bool = false
    ) {
        self.id = id
        self.title = title
        self.messages = messages
        self.model = model
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.isPinned = isPinned
    }

    /// 根据首条用户消息推导标题
    mutating func refreshTitleFromFirstUserMessage() {
        guard let first = messages.first(where: { $0.role == .user }) else { return }
        let trimmed = first.content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let line = trimmed.split(separator: "\n").first.map(String.init) ?? trimmed
        title = line.count > 24 ? String(line.prefix(24)) + "…" : line
    }
}

// MARK: - 模型能力

struct DSHModel: Identifiable, Codable, Hashable {
    var id: String
    var name: String
    var supportsReasoning: Bool
    var contextWindow: Int

    static let catalog: [DSHModel] = [
        DSHModel(id: "deepseek-chat", name: "DeepSeek Chat", supportsReasoning: false, contextWindow: 64_000),
        DSHModel(id: "deepseek-reasoner", name: "DeepSeek Reasoner", supportsReasoning: true, contextWindow: 64_000)
    ]

    static func model(for id: String) -> DSHModel {
        catalog.first(where: { $0.id == id }) ?? catalog[0]
    }
}

// MARK: - 应用设置

struct AppSettings: Codable, Equatable {
    var baseURL: String
    var defaultModel: String
    var temperature: Double
    var systemPrompt: String
    var streamEnabled: Bool
    var requestTimeout: Double
    var hapticsEnabled: Bool
    var appTheme: AppThemePreference

    static let `default` = AppSettings(
        baseURL: "https://api.deepseek.com",
        defaultModel: "deepseek-chat",
        temperature: 0.7,
        systemPrompt: "",
        streamEnabled: true,
        requestTimeout: 120,
        hapticsEnabled: true,
        appTheme: .system
    )
}

enum AppThemePreference: String, Codable, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .system: return "跟随系统"
        case .light: return "浅色"
        case .dark: return "深色"
        }
    }
}

// MARK: - 用量统计

struct UsageStat: Codable, Equatable {
    var totalPromptTokens: Int = 0
    var totalCompletionTokens: Int = 0
    var totalRequests: Int = 0

    var totalTokens: Int { totalPromptTokens + totalCompletionTokens }
}
