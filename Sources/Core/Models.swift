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
        case .assistant: return "DeepSeek"
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
    /// 默认标题：仍等于该值时允许按首条消息自动生成标题
    static let defaultTitle = "新对话"

    var id: UUID
    var title: String
    var messages: [ChatMessage]
    var model: String
    var createdAt: Date
    var updatedAt: Date
    var isPinned: Bool

    init(
        id: UUID = UUID(),
        title: String = Conversation.defaultTitle,
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

    /// 根据首条用户消息推导标题；已被用户手动重命名的会话保持不变
    mutating func refreshTitleFromFirstUserMessage() {
        guard title == Self.defaultTitle else { return }
        guard let first = messages.first(where: { $0.role == .user }) else { return }
        let trimmed = first.content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let line = trimmed.split(separator: "\n").first.map(String.init) ?? trimmed
        title = line.count > 20 ? String(line.prefix(20)) + "…" : line
    }
}

// MARK: - 模型

/// 模型描述。名称与 ID 均以官方 API 文档为准（2026-09 更新）：
/// `deepseek-flash` = DeepSeek-V4.1-Flash，`deepseek-v4-pro` = DeepSeek-V4-Pro。
/// 历史模型（deepseek-chat / deepseek-reasoner）已下线，不再出现在可选列表中。
struct DSHModel: Identifiable, Codable, Hashable {
    var id: String
    var name: String
    var supportsThinking: Bool

    init(id: String, name: String, supportsThinking: Bool = true) {
        self.id = id
        self.name = name
        self.supportsThinking = supportsThinking
    }

    /// 内置兜底列表；实际使用时可用「获取模型列表」从服务端拉取真实 ID
    static let catalog: [DSHModel] = [
        DSHModel(id: "deepseek-flash", name: "DeepSeek-V4.1-Flash"),
        DSHModel(id: "deepseek-v4-pro", name: "DeepSeek-V4-Pro")
    ]

    static let defaultModelID = "deepseek-flash"

    /// 未知 ID 时保持原样展示，避免再次出现「名字对不上」的问题
    static func describe(id: String) -> DSHModel {
        catalog.first(where: { $0.id == id }) ?? DSHModel(id: id, name: id, supportsThinking: true)
    }

    /// 服务端返回的 ID 列表 → 去重排序后的模型列表（拉取后用于刷新设置与输入框中的选择列表）
    static func list(from ids: [String]) -> [DSHModel] {
        let unique = Array(Set(ids.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }))
            .filter { !$0.isEmpty }
        return unique.sorted().map { describe(id: $0) }
    }
}

// MARK: - 思考强度

enum ReasoningEffort: String, Codable, CaseIterable, Identifiable {
    case low
    case high
    case max

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .low: return "快速"
        case .high: return "标准"
        case .max: return "深入"
        }
    }

    var detail: String {
        switch self {
        case .low: return "简单任务，响应更快"
        case .high: return "日常使用，平衡速度与质量"
        case .max: return "复杂问题，思考更充分"
        }
    }
}

// MARK: - 功能开关（主页保持简洁，高级能力按需开启）

struct FeatureFlags: Codable, Equatable {
    /// 顶栏的「会话日志」入口
    var sessionLog: Bool = false
    /// 输入框的插件命令面板（输入 / 呼出）
    var pluginCommands: Bool = false
    /// 输入框右侧的模型选择器
    var modelPicker: Bool = false
    /// 底部运行指标行（轮次 / tokens）
    var usageMetrics: Bool = false
    /// 主页「深度思考」开关
    var deepThinkingToggle: Bool = true
    /// 空会话示例提示
    var examplePrompts: Bool = true

    init() {}

    /// 宽容解码：新增开关在旧数据中缺失时取默认值
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let fallback = FeatureFlags()
        self.sessionLog = try container.decodeIfPresent(Bool.self, forKey: .sessionLog) ?? fallback.sessionLog
        self.pluginCommands = try container.decodeIfPresent(Bool.self, forKey: .pluginCommands) ?? fallback.pluginCommands
        self.modelPicker = try container.decodeIfPresent(Bool.self, forKey: .modelPicker) ?? fallback.modelPicker
        self.usageMetrics = try container.decodeIfPresent(Bool.self, forKey: .usageMetrics) ?? fallback.usageMetrics
        self.deepThinkingToggle = try container.decodeIfPresent(Bool.self, forKey: .deepThinkingToggle) ?? fallback.deepThinkingToggle
        self.examplePrompts = try container.decodeIfPresent(Bool.self, forKey: .examplePrompts) ?? fallback.examplePrompts
    }

    init(
        sessionLog: Bool,
        pluginCommands: Bool,
        modelPicker: Bool,
        usageMetrics: Bool,
        deepThinkingToggle: Bool,
        examplePrompts: Bool
    ) {
        self.sessionLog = sessionLog
        self.pluginCommands = pluginCommands
        self.modelPicker = modelPicker
        self.usageMetrics = usageMetrics
        self.deepThinkingToggle = deepThinkingToggle
        self.examplePrompts = examplePrompts
    }

    static let allOn = FeatureFlags(
        sessionLog: true,
        pluginCommands: true,
        modelPicker: true,
        usageMetrics: true,
        deepThinkingToggle: true,
        examplePrompts: true
    )
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
    /// 深度思考（发送 thinking 参数）
    var thinkingEnabled: Bool
    var reasoningEffort: ReasoningEffort
    var features: FeatureFlags

    static let `default` = AppSettings(
        baseURL: "https://api.deepseek.com",
        defaultModel: DSHModel.defaultModelID,
        temperature: 0.7,
        systemPrompt: "",
        streamEnabled: true,
        requestTimeout: 120,
        hapticsEnabled: true,
        appTheme: .system,
        thinkingEnabled: true,
        reasoningEffort: .high,
        features: FeatureFlags()
    )

    init(
        baseURL: String,
        defaultModel: String,
        temperature: Double,
        systemPrompt: String,
        streamEnabled: Bool,
        requestTimeout: Double,
        hapticsEnabled: Bool,
        appTheme: AppThemePreference,
        thinkingEnabled: Bool,
        reasoningEffort: ReasoningEffort,
        features: FeatureFlags
    ) {
        self.baseURL = baseURL
        self.defaultModel = defaultModel
        self.temperature = temperature
        self.systemPrompt = systemPrompt
        self.streamEnabled = streamEnabled
        self.requestTimeout = requestTimeout
        self.hapticsEnabled = hapticsEnabled
        self.appTheme = appTheme
        self.thinkingEnabled = thinkingEnabled
        self.reasoningEffort = reasoningEffort
        self.features = features
    }

    /// 宽容解码：旧版本写入的设置缺少新增字段时按默认值补齐，避免升级后偏好被整体重置
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let fallback = AppSettings.default
        self.baseURL = try container.decodeIfPresent(String.self, forKey: .baseURL) ?? fallback.baseURL
        self.defaultModel = try container.decodeIfPresent(String.self, forKey: .defaultModel) ?? fallback.defaultModel
        self.temperature = try container.decodeIfPresent(Double.self, forKey: .temperature) ?? fallback.temperature
        self.systemPrompt = try container.decodeIfPresent(String.self, forKey: .systemPrompt) ?? fallback.systemPrompt
        self.streamEnabled = try container.decodeIfPresent(Bool.self, forKey: .streamEnabled) ?? fallback.streamEnabled
        self.requestTimeout = try container.decodeIfPresent(Double.self, forKey: .requestTimeout) ?? fallback.requestTimeout
        self.hapticsEnabled = try container.decodeIfPresent(Bool.self, forKey: .hapticsEnabled) ?? fallback.hapticsEnabled
        self.appTheme = try container.decodeIfPresent(AppThemePreference.self, forKey: .appTheme) ?? fallback.appTheme
        self.thinkingEnabled = try container.decodeIfPresent(Bool.self, forKey: .thinkingEnabled) ?? fallback.thinkingEnabled
        self.reasoningEffort = try container.decodeIfPresent(ReasoningEffort.self, forKey: .reasoningEffort) ?? fallback.reasoningEffort
        self.features = try container.decodeIfPresent(FeatureFlags.self, forKey: .features) ?? fallback.features
    }
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