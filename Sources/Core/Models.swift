import Foundation
import UIKit

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

// MARK: - 工具调用

/// 模型请求的一次工具调用（OpenAI 兼容的 function calling）
struct ToolCall: Codable, Hashable, Identifiable {
    var id: String
    var name: String
    /// 模型给出的 JSON 参数原文，例如 {"command":"ls -la"}
    var arguments: String

    /// 供 UI 展示的简短参数摘要
    var argumentPreview: String {
        guard let data = arguments.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let value = object.values.first as? String else {
            return arguments
        }
        return value
    }
}

// MARK: - 图片附件

/// 用户消息附带的一张图片。
/// 图片压缩后存到 Documents/attachments/ 下的独立文件，消息里只保存文件名，
/// 避免 state.json 因为内嵌 Base64 膨胀。
struct ChatAttachment: Identifiable, Codable, Hashable {
    var id: UUID
    var fileName: String
    var mimeType: String

    init(id: UUID = UUID(), fileName: String, mimeType: String = "image/jpeg") {
        self.id = id
        self.fileName = fileName
        self.mimeType = mimeType
    }

    static var directory: URL {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("attachments", isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }

    var fileURL: URL { Self.directory.appendingPathComponent(fileName) }

    var data: Data? { try? Data(contentsOf: fileURL) }

    /// 相册原图动辄几 MB，先缩到最长边 1280 再按 JPEG 存盘；
    /// 失败（不是图片 / 写盘错误）返回 nil。
    static func save(_ imageData: Data) -> ChatAttachment? {
        guard let image = UIImage(data: imageData) else { return nil }
        let scaled = AttachmentImageCache.downscaled(image, maxSide: 1280)
        guard let jpeg = scaled.jpegData(compressionQuality: 0.75) else { return nil }
        let fileName = UUID().uuidString + ".jpg"
        do {
            try jpeg.write(to: directory.appendingPathComponent(fileName))
        } catch {
            return nil
        }
        return ChatAttachment(fileName: fileName)
    }

    /// 删除图片文件与对应的内存缓存：
    /// 图片只被消息引用一次，删掉消息（或撤销待发图片）时文件也要一起删，
    /// 否则会一直留在磁盘上占空间。
    static func delete(_ attachments: [ChatAttachment]) {
        guard !attachments.isEmpty else { return }
        for attachment in attachments {
            try? FileManager.default.removeItem(at: attachment.fileURL)
        }
        AttachmentImageCache.removeAll()
    }
}

/// 图片解码缓存：输入框缩略图与消息气泡每次重绘都要用，
/// 缓存住解码结果，避免反复读盘 + 解码导致输入卡顿。
enum AttachmentImageCache {
    private static let cache = NSCache<NSString, UIImage>()

    static func image(for attachment: ChatAttachment, maxSide: CGFloat) -> UIImage? {
        let key = "\(attachment.fileName)@\(Int(maxSide))" as NSString
        if let cached = cache.object(forKey: key) { return cached }
        guard let data = attachment.data, let image = UIImage(data: data) else { return nil }
        let scaled = downscaled(image, maxSide: maxSide)
        cache.setObject(scaled, forKey: key)
        return scaled
    }

    /// 图片文件被删除或清理缓存时调用，避免内存里继续持有已删除的图片
    static func removeAll() {
        cache.removeAllObjects()
    }

    /// 等比缩放到最长边不超过 maxSide（原图更小则原样返回）
    static func downscaled(_ image: UIImage, maxSide: CGFloat) -> UIImage {
        let longest = max(image.size.width, image.size.height)
        guard longest > maxSide, longest > 0 else { return image }
        let scale = maxSide / longest
        let target = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let renderer = UIGraphicsImageRenderer(size: target)
        return renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: target))
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
    /// token 数为本地估算（服务端未返回 usage 时的兜底），界面会标注 ≈
    var tokensEstimated: Bool?
    /// 用户对回复的反馈：1 赞，-1 踩，nil 未评价
    var rating: Int?
    /// 助手消息发起的工具调用
    var toolCalls: [ToolCall]?
    /// 工具结果消息对应的调用 id 与工具名
    var toolCallID: String?
    var toolName: String?
    /// 用户消息附带的图片
    var attachments: [ChatAttachment]?
    /// 上下文压缩摘要（历史消息被压成这一条时置 true，发送时按系统提示注入）
    var isContextSummary: Bool?

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
        tokensEstimated: Bool? = nil,
        rating: Int? = nil,
        toolCalls: [ToolCall]? = nil,
        toolCallID: String? = nil,
        toolName: String? = nil,
        attachments: [ChatAttachment]? = nil,
        isContextSummary: Bool? = nil
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
        self.tokensEstimated = tokensEstimated
        self.rating = rating
        self.toolCalls = toolCalls
        self.toolCallID = toolCallID
        self.toolName = toolName
        self.attachments = attachments
        self.isContextSummary = isContextSummary
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
    /// 上下文窗口（token）：超过窗口比例上限时会自动压缩历史消息
    var contextWindow: Int

    init(id: String, name: String, supportsThinking: Bool = true, contextWindow: Int = 65_536) {
        self.id = id
        self.name = name
        self.supportsThinking = supportsThinking
        self.contextWindow = contextWindow
    }

    /// 宽容解码：旧数据里没有 contextWindow 字段时用默认值
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(String.self, forKey: .id)
        self.name = try container.decodeIfPresent(String.self, forKey: .name) ?? id
        self.supportsThinking = try container.decodeIfPresent(Bool.self, forKey: .supportsThinking) ?? true
        self.contextWindow = try container.decodeIfPresent(Int.self, forKey: .contextWindow) ?? 65_536
    }

    /// 内置兜底列表；实际使用时可用「获取模型列表」从服务端拉取真实 ID
    static let catalog: [DSHModel] = [
        DSHModel(id: "deepseek-flash", name: "DeepSeek-V4.1-Flash", contextWindow: 131_072),
        DSHModel(id: "deepseek-v4-pro", name: "DeepSeek-V4-Pro", contextWindow: 131_072)
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
    /// SSH 云服务器工具（智能体可通过 ssh_exec 在服务器执行命令）
    var sshTool: Bool = false
    /// 内置浏览器（顶栏菜单入口 + 智能体网页工具）
    var browserTool: Bool = false
    /// GitHub 工具（智能体可读写仓库、提 issue）
    var githubTool: Bool = false
    /// Gitee 工具（智能体可读写仓库、提 issue）
    var giteeTool: Bool = false
    /// 技能（智能体可按需取用用户自己写的技能说明；技能规定做法，工具执行操作）
    var skillTool: Bool = true
    /// 查看画面（智能体可截取当前界面或内置浏览器页面，并用本地 OCR 识别文字）
    var visionTool: Bool = true
    /// 工作区文件（智能体可读写「文件」页里的代码文件）
    var fileTool: Bool = true
    /// MCP 服务器（把远程 MCP 服务器的工具下发给模型）
    var mcpTool: Bool = true
    /// 系统剪贴板（智能体可读写复制内容）
    var clipboardTool: Bool = true
    /// 提醒事项与日历（智能体可读写待办与日程）
    var reminderTool: Bool = true
    /// 自动压缩上下文：接近当前模型的上下文窗口上限时，自动把较早的历史压成摘要
    var autoCompact: Bool = true
    /// 云端推理：会话交给「设置 → 云端推理」里部署的服务器 Agent 执行，App 只做遥控与显示
    var cloudInference: Bool = false

    init() {}

    /// 旧版本只有单一的总开关，解码时用于迁移
    private enum LegacyKeys: String, CodingKey {
        case agentTools
    }

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

        // 旧版本用 agentTools 一个开关同时控制 SSH 与浏览器，这里按它迁移到两个新开关
        let legacyContainer = try decoder.container(keyedBy: LegacyKeys.self)
        let legacy = try legacyContainer.decodeIfPresent(Bool.self, forKey: .agentTools) ?? fallback.sshTool
        self.sshTool = try container.decodeIfPresent(Bool.self, forKey: .sshTool) ?? legacy
        self.browserTool = try container.decodeIfPresent(Bool.self, forKey: .browserTool) ?? legacy
        self.githubTool = try container.decodeIfPresent(Bool.self, forKey: .githubTool) ?? fallback.githubTool
        self.giteeTool = try container.decodeIfPresent(Bool.self, forKey: .giteeTool) ?? fallback.giteeTool
        self.skillTool = try container.decodeIfPresent(Bool.self, forKey: .skillTool) ?? fallback.skillTool
        self.visionTool = try container.decodeIfPresent(Bool.self, forKey: .visionTool) ?? fallback.visionTool
        self.fileTool = try container.decodeIfPresent(Bool.self, forKey: .fileTool) ?? fallback.fileTool
        self.mcpTool = try container.decodeIfPresent(Bool.self, forKey: .mcpTool) ?? fallback.mcpTool
        self.clipboardTool = try container.decodeIfPresent(Bool.self, forKey: .clipboardTool) ?? fallback.clipboardTool
        self.reminderTool = try container.decodeIfPresent(Bool.self, forKey: .reminderTool) ?? fallback.reminderTool
        self.autoCompact = try container.decodeIfPresent(Bool.self, forKey: .autoCompact) ?? fallback.autoCompact
        self.cloudInference = try container.decodeIfPresent(Bool.self, forKey: .cloudInference) ?? fallback.cloudInference
    }

    init(
        sessionLog: Bool,
        pluginCommands: Bool,
        modelPicker: Bool,
        usageMetrics: Bool,
        deepThinkingToggle: Bool,
        examplePrompts: Bool,
        sshTool: Bool = false,
        browserTool: Bool = false,
        githubTool: Bool = false,
        giteeTool: Bool = false,
        skillTool: Bool = true,
        visionTool: Bool = true,
        fileTool: Bool = true,
        mcpTool: Bool = true,
        clipboardTool: Bool = true,
        reminderTool: Bool = true,
        autoCompact: Bool = true,
        cloudInference: Bool = false
    ) {
        self.sessionLog = sessionLog
        self.pluginCommands = pluginCommands
        self.modelPicker = modelPicker
        self.usageMetrics = usageMetrics
        self.deepThinkingToggle = deepThinkingToggle
        self.examplePrompts = examplePrompts
        self.sshTool = sshTool
        self.browserTool = browserTool
        self.githubTool = githubTool
        self.giteeTool = giteeTool
        self.skillTool = skillTool
        self.visionTool = visionTool
        self.fileTool = fileTool
        self.mcpTool = mcpTool
        self.clipboardTool = clipboardTool
        self.reminderTool = reminderTool
        self.autoCompact = autoCompact
        self.cloudInference = cloudInference
    }

    static let allOn = FeatureFlags(
        sessionLog: true,
        pluginCommands: true,
        modelPicker: true,
        usageMetrics: true,
        deepThinkingToggle: true,
        examplePrompts: true,
        sshTool: true,
        browserTool: true,
        githubTool: true,
        giteeTool: true,
        skillTool: true,
        visionTool: true,
        fileTool: true,
        mcpTool: true,
        clipboardTool: true,
        reminderTool: true,
        autoCompact: true,
        cloudInference: true
    )
}

// MARK: - 内置浏览器设置

struct BrowserSettings: Codable, Equatable {
    /// 打开浏览器时的首页
    var homeURL: String
    /// 允许智能体读取网页正文（browser_read）
    var allowAgentRead: Bool
    /// 以桌面版网站方式加载
    var desktopSite: Bool

    static let `default` = BrowserSettings(
        homeURL: "https://www.deepseek.com",
        allowAgentRead: true,
        desktopSite: false
    )

    /// 桌面版网站使用的 User-Agent
    static let desktopUserAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 "
        + "(KHTML, like Gecko) Version/17.0 Safari/605.1.15"

    init(homeURL: String, allowAgentRead: Bool, desktopSite: Bool) {
        self.homeURL = homeURL
        self.allowAgentRead = allowAgentRead
        self.desktopSite = desktopSite
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let fallback = BrowserSettings.default
        self.homeURL = try container.decodeIfPresent(String.self, forKey: .homeURL) ?? fallback.homeURL
        self.allowAgentRead = try container.decodeIfPresent(Bool.self, forKey: .allowAgentRead) ?? fallback.allowAgentRead
        self.desktopSite = try container.decodeIfPresent(Bool.self, forKey: .desktopSite) ?? fallback.desktopSite
    }

    /// 首页 URL（非法或为空时回退默认）
    var homeLink: URL {
        WebAddress.normalize(homeURL) ?? URL(string: "https://www.deepseek.com")!
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
    /// 深度思考（发送 thinking 参数）
    var thinkingEnabled: Bool
    var reasoningEffort: ReasoningEffort
    var features: FeatureFlags
    /// 内置浏览器设置
    var browser: BrowserSettings
    /// 「回答风格约束」插件追加在每条用户消息末尾的强调指令，可在设置里编辑
    var styleSuffix: String

    /// 强调指令的默认内容
    static let defaultStyleSuffix = "[约束] 请用简洁的中文回答，先给结论再给要点。"

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
        features: FeatureFlags(),
        browser: BrowserSettings.default,
        styleSuffix: AppSettings.defaultStyleSuffix
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
        features: FeatureFlags,
        browser: BrowserSettings = .default,
        styleSuffix: String = AppSettings.defaultStyleSuffix
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
        self.browser = browser
        self.styleSuffix = styleSuffix
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
        self.browser = try container.decodeIfPresent(BrowserSettings.self, forKey: .browser) ?? fallback.browser
        self.styleSuffix = try container.decodeIfPresent(String.self, forKey: .styleSuffix) ?? fallback.styleSuffix
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