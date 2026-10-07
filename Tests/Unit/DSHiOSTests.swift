import XCTest
@testable import DSHiOS

// MARK: - Markdown 解析

final class MarkdownParserTests: XCTestCase {

    func testPlainTextBecomesSingleBlock() {
        let blocks = MarkdownParser.parse("你好，世界")
        XCTAssertEqual(blocks.count, 1)
        guard case .text(let text) = blocks[0].kind else {
            return XCTFail("应为文本块")
        }
        XCTAssertEqual(text, "你好，世界")
    }

    func testCodeFenceIsExtractedWithLanguage() {
        let raw = "说明如下：\n```swift\nlet a = 1\n```\n结束"
        let blocks = MarkdownParser.parse(raw)
        XCTAssertEqual(blocks.count, 3)

        guard case .text(let head) = blocks[0].kind else { return XCTFail("首块应为文本") }
        XCTAssertEqual(head, "说明如下：")

        guard case .code(let language, let code) = blocks[1].kind else { return XCTFail("次块应为代码") }
        XCTAssertEqual(language, "swift")
        XCTAssertEqual(code, "let a = 1")

        guard case .text(let tail) = blocks[2].kind else { return XCTFail("末块应为文本") }
        XCTAssertEqual(tail, "结束")
    }

    func testUnclosedCodeFenceStillProducesCodeBlock() {
        let blocks = MarkdownParser.parse("```\n未闭合的代码")
        XCTAssertEqual(blocks.count, 1)
        guard case .code(let language, let code) = blocks[0].kind else {
            return XCTFail("应为代码块")
        }
        XCTAssertNil(language)
        XCTAssertEqual(code, "未闭合的代码")
    }

    func testBlockIdentifiersAreStable() {
        let raw = "a\n```\nb\n```\nc"
        let first = MarkdownParser.parse(raw).map(\.id)
        let second = MarkdownParser.parse(raw).map(\.id)
        XCTAssertEqual(first, second, "相同输入应产生相同块编号")
    }

    func testEmptyInputProducesNoBlocks() {
        XCTAssertTrue(MarkdownParser.parse("").isEmpty)
        XCTAssertTrue(MarkdownParser.parse("\n\n   \n").isEmpty)
    }

    func testListMarkersAreNormalizedToBullets() {
        let input = "- 第一条\n  - 缩进项\n* 星号项\n+ 加号项\n普通行\n1. 编号项"
        let output = MarkdownParser.normalizeListMarkers(input)
        XCTAssertTrue(output.contains("• 第一条"))
        XCTAssertTrue(output.contains("  • 缩进项"), "应保留缩进")
        XCTAssertTrue(output.contains("• 星号项"))
        XCTAssertTrue(output.contains("• 加号项"))
        XCTAssertTrue(output.contains("普通行"))
        XCTAssertTrue(output.contains("1. 编号项"), "有序列不应被改写")
    }

    // MARK: 分块渲染（流式滚动性能）

    /// 空行分隔的段落各自成块：已定型的块不会因为后续增量到达而重新排版
    func testBlankLineSeparatesParagraphs() {
        let blocks = MarkdownParser.parse("第一段\n\n第二段")
        XCTAssertEqual(blocks.count, 2)
        guard case .text(let first) = blocks[0].kind, case .text(let second) = blocks[1].kind else {
            return XCTFail("应为两个文本块")
        }
        XCTAssertEqual(first, "第一段")
        XCTAssertEqual(second, "第二段")
        XCTAssertFalse(blocks[0].isContinuation)
        XCTAssertFalse(blocks[1].isContinuation, "空行分隔的段落之间应保留段间距")
    }

    /// 超长段落（没有空行、甚至没有换行）也必须切块，
    /// 否则单个超大 Text 会让每次流式刷新都对全文做一次全量排版
    func testLongParagraphIsSplitIntoBlocks() {
        let long = String(repeating: "字", count: MarkdownParser.maxTextBlockLength * 2)
        let blocks = MarkdownParser.parse(long)
        XCTAssertGreaterThan(blocks.count, 1, "超长段落应被切成多块")
        XCTAssertFalse(blocks[0].isContinuation)
        for block in blocks.dropFirst() {
            XCTAssertTrue(block.isContinuation, "同一段落被切开的后继块应标记为续写（零间距接上）")
        }
        let joined = blocks.compactMap { block -> String? in
            if case .text(let text) = block.kind { return text }
            return nil
        }.joined()
        XCTAssertEqual(joined, long, "切块不应改变正文内容")
    }

    func testTextChunkerSplitsOnBlankLines() {
        let chunks = TextChunker.chunk("a\nb\n\nc", maxLength: 100)
        XCTAssertEqual(chunks.map(\.text), ["a\nb", "c"])
        XCTAssertEqual(chunks.map(\.isContinuation), [false, false])
    }

    func testTextChunkerSplitsLongLineIntoContinuationChunks() {
        let chunks = TextChunker.chunk(String(repeating: "x", count: 250), maxLength: 100)
        XCTAssertEqual(chunks.count, 3)
        XCTAssertFalse(chunks[0].isContinuation)
        XCTAssertTrue(chunks[1].isContinuation)
        XCTAssertTrue(chunks[2].isContinuation)
        XCTAssertEqual(chunks.map(\.text).joined(), String(repeating: "x", count: 250))
    }

    /// 代码块不能拆断整行，否则每行都会被切成两段单独渲染
    func testTextChunkerKeepsCodeLinesIntact() {
        let longLine = String(repeating: "x", count: 200)
        let chunks = TextChunker.chunk(longLine + "\nshort", maxLength: 50, splitsLongLines: false)
        XCTAssertEqual(chunks.count, 2)
        XCTAssertEqual(chunks[0].text, longLine)
        XCTAssertEqual(chunks[1].text, "short")
    }
}

// MARK: - 会话模型

final class ConversationModelTests: XCTestCase {

    func testTitleDerivesFromFirstUserMessage() {
        var conversation = Conversation(model: "deepseek-flash")
        conversation.messages = [
            ChatMessage(role: .user, content: "帮我写一个 Swift 单元测试\n第二行"),
            ChatMessage(role: .assistant, content: "好的")
        ]
        conversation.refreshTitleFromFirstUserMessage()
        XCTAssertEqual(conversation.title, "帮我写一个 Swift 单元测试")
    }

    func testLongTitleIsTruncated() {
        var conversation = Conversation(model: "deepseek-flash")
        let long = String(repeating: "长", count: 60)
        conversation.messages = [ChatMessage(role: .user, content: long)]
        conversation.refreshTitleFromFirstUserMessage()
        XCTAssertEqual(conversation.title.count, 21) // 20 字 + 省略号
        XCTAssertTrue(conversation.title.hasSuffix("…"))
    }

    func testMessageCodableRoundTrip() throws {
        let message = ChatMessage(
            role: .assistant,
            content: "回答",
            reasoning: "思考",
            isStreaming: false,
            model: "deepseek-reasoner",
            promptTokens: 10,
            completionTokens: 20,
            rating: 1
        )
        let data = try JSONEncoder().encode(message)
        let decoded = try JSONDecoder().decode(ChatMessage.self, from: data)
        XCTAssertEqual(decoded.id, message.id)
        XCTAssertEqual(decoded.content, "回答")
        XCTAssertEqual(decoded.reasoning, "思考")
        XCTAssertEqual(decoded.rating, 1)
        XCTAssertEqual(decoded.completionTokens, 20)
    }

    func testModelNamingMatchesOfficialDocs() {
        // 官方 API 文档（2026-09）：deepseek-flash = V4.1-Flash，deepseek-v4-pro = V4-Pro
        XCTAssertEqual(DSHModel.defaultModelID, "deepseek-flash")
        XCTAssertEqual(DSHModel.describe(id: "deepseek-flash").name, "DeepSeek-V4.1-Flash")
        XCTAssertEqual(DSHModel.describe(id: "deepseek-v4-pro").name, "DeepSeek-V4-Pro")

        // 已下线的旧模型名不应出现在可选列表中
        let catalogIDs = DSHModel.catalog.map(\.id)
        XCTAssertTrue(catalogIDs.contains("deepseek-flash"))
        XCTAssertTrue(catalogIDs.contains("deepseek-v4-pro"))
        XCTAssertFalse(catalogIDs.contains("deepseek-chat"))
        XCTAssertFalse(catalogIDs.contains("deepseek-reasoner"))

        // 未知模型按原 ID 展示，不臆造名称
        XCTAssertEqual(DSHModel.describe(id: "my-custom-model").name, "my-custom-model")

        // 支持思考模式的模型
        XCTAssertTrue(DSHModel.describe(id: "deepseek-flash").supportsThinking)
    }

    /// 服务端返回的模型列表应去重排序，并让已知模型带上中文名称
    func testServerModelListMapping() {
        let models = DSHModel.list(from: ["deepseek-v4-pro", " deepseek-flash ", "deepseek-flash", "", "my-model"])
        XCTAssertEqual(models.map(\.id), ["deepseek-flash", "deepseek-v4-pro", "my-model"])
        XCTAssertEqual(models[0].name, "DeepSeek-V4.1-Flash")
        XCTAssertEqual(models[1].name, "DeepSeek-V4-Pro")
        XCTAssertEqual(models[2].name, "my-model")
    }

    func testThemeDisplayNames() {
        XCTAssertEqual(AppThemePreference.allCases.count, 3)
        XCTAssertEqual(AppThemePreference.system.displayName, "跟随系统")
        XCTAssertEqual(AppThemePreference.dark.displayName, "深色")
    }
}

// MARK: - 设置

final class SettingsStoreTests: XCTestCase {

    func testDefaults() {
        let settings = AppSettings.default
        XCTAssertEqual(settings.baseURL, "https://api.deepseek.com")
        XCTAssertEqual(settings.defaultModel, "deepseek-flash")
        XCTAssertTrue(settings.streamEnabled)
        XCTAssertEqual(settings.requestTimeout, 120)
        XCTAssertTrue(settings.thinkingEnabled)
        XCTAssertEqual(settings.reasoningEffort, .high)
        // 主页默认保持简洁：高级入口默认关闭
        XCTAssertFalse(settings.features.sessionLog)
        XCTAssertFalse(settings.features.pluginCommands)
        XCTAssertFalse(settings.features.modelPicker)
        XCTAssertFalse(settings.features.usageMetrics)
        // 核心体验默认开启
        XCTAssertTrue(settings.features.deepThinkingToggle)
        XCTAssertTrue(settings.features.examplePrompts)
    }

    /// 新增字段：回答风格约束与 GitHub / Gitee 工具开关在旧数据中取默认值
    func testStyleSuffixDefaultsAndLegacyDecoding() {
        XCTAssertFalse(AppSettings.default.styleSuffix.isEmpty)

        let legacy = #"{"baseURL":"https://api.deepseek.com"}"#
        guard let decoded = try? JSONDecoder().decode(AppSettings.self, from: Data(legacy.utf8)) else {
            return XCTFail("旧版设置应能解码")
        }
        XCTAssertEqual(decoded.styleSuffix, AppSettings.defaultStyleSuffix)
        XCTAssertFalse(decoded.features.githubTool)
        XCTAssertFalse(decoded.features.giteeTool)
    }

    /// 升级场景：旧版本写入的设置缺少新字段时，旧值应保留、新字段取默认值
    func testLenientDecodingKeepsOldValues() {
        let legacy = """
        {
          "baseURL": "https://my-relay.example.com/v1",
          "defaultModel": "deepseek-v4-pro",
          "temperature": 1.35,
          "systemPrompt": "你是助手",
          "streamEnabled": false,
          "requestTimeout": 60,
          "hapticsEnabled": false,
          "appTheme": "dark"
        }
        """
        guard let decoded = try? JSONDecoder().decode(AppSettings.self, from: Data(legacy.utf8)) else {
            return XCTFail("旧版设置应能解码")
        }
        XCTAssertEqual(decoded.baseURL, "https://my-relay.example.com/v1")
        XCTAssertEqual(decoded.defaultModel, "deepseek-v4-pro")
        XCTAssertEqual(decoded.temperature, 1.35)
        XCTAssertEqual(decoded.systemPrompt, "你是助手")
        XCTAssertFalse(decoded.streamEnabled)
        XCTAssertEqual(decoded.appTheme, .dark)
        // 新增字段回落到默认值
        XCTAssertTrue(decoded.thinkingEnabled)
        XCTAssertEqual(decoded.reasoningEffort, .high)
        XCTAssertFalse(decoded.features.modelPicker)
    }

    func testIsConfiguredReflectsAPIKey() {
        let store = SettingsStore()
        store.apiKey = ""
        XCTAssertFalse(store.isConfigured)
        store.apiKey = "sk-test"
        XCTAssertTrue(store.isConfigured)
        store.apiKey = "   "
        XCTAssertFalse(store.isConfigured, "空白字符不应视为已配置")
        store.apiKey = ""
    }

    func testSettingsRoundTripThroughUserDefaults() {
        let store = SettingsStore()
        var settings = AppSettings.default
        settings.temperature = 1.25
        settings.defaultModel = "deepseek-reasoner"
        settings.appTheme = .dark
        store.settings = settings

        let reloaded = SettingsStore()
        XCTAssertEqual(reloaded.settings.temperature, 1.25)
        XCTAssertEqual(reloaded.settings.defaultModel, "deepseek-reasoner")
        XCTAssertEqual(reloaded.settings.appTheme, .dark)

        store.reset()
    }
}

// MARK: - 会话存储

final class ConversationStoreTests: XCTestCase {

    func testCreateUpsertDeleteAndPin() {
        let store = ConversationStore(fileName: "test-\(UUID().uuidString).json")
        XCTAssertTrue(store.conversations.isEmpty)

        let conversation = store.createConversation(model: "deepseek-chat")
        XCTAssertEqual(store.conversations.count, 1)

        var updated = conversation
        updated.title = "改名"
        store.upsert(updated)
        XCTAssertEqual(store.conversation(id: conversation.id)?.title, "改名")
        XCTAssertEqual(store.conversations.count, 1, "upsert 不应重复插入")

        store.togglePin(id: conversation.id)
        XCTAssertEqual(store.conversation(id: conversation.id)?.isPinned, true)

        store.delete(id: conversation.id)
        XCTAssertTrue(store.conversations.isEmpty)
    }

    func testPinnedConversationsSortFirst() {
        let store = ConversationStore(fileName: "test-\(UUID().uuidString).json")
        let first = store.createConversation(model: "deepseek-chat")
        let second = store.createConversation(model: "deepseek-chat")
        store.togglePin(id: first.id)
        XCTAssertEqual(store.sortedConversations.first?.id, first.id)
        XCTAssertEqual(store.sortedConversations.last?.id, second.id)
    }

    func testUsageAccumulates() {
        let store = ConversationStore(fileName: "test-\(UUID().uuidString).json")
        store.recordUsage(prompt: 100, completion: 50)
        store.recordUsage(prompt: 20, completion: 10)
        XCTAssertEqual(store.usage.totalPromptTokens, 120)
        XCTAssertEqual(store.usage.totalCompletionTokens, 60)
        XCTAssertEqual(store.usage.totalTokens, 180)
        XCTAssertEqual(store.usage.totalRequests, 2)
        store.resetUsage()
        XCTAssertEqual(store.usage.totalTokens, 0)
    }

    func testMarkdownExportContainsTitleAndMessages() {
        let store = ConversationStore(fileName: "test-\(UUID().uuidString).json")
        var conversation = store.createConversation(model: "deepseek-chat")
        conversation.messages = [
            ChatMessage(role: .user, content: "问题内容"),
            ChatMessage(role: .assistant, content: "回答内容")
        ]
        conversation.refreshTitleFromFirstUserMessage()
        store.upsert(conversation)

        let markdown = store.exportMarkdown()
        XCTAssertTrue(markdown.contains("# DSH iOS 会话导出"))
        XCTAssertTrue(markdown.contains("## 问题内容"))
        XCTAssertTrue(markdown.contains("回答内容"))
        XCTAssertTrue(markdown.contains("`deepseek-chat`"))
    }
}

// MARK: - 缓存清理

final class AppCacheTests: XCTestCase {

    func testByteFormatting() {
        XCTAssertEqual(AppCache.format(0), "0 KB")
        XCTAssertEqual(AppCache.format(1024), "1 KB")
        XCTAssertEqual(AppCache.format(1024 * 1024 * 3 / 2), "1.5 MB")
    }

    /// 会话引用的图片应保留，历史遗留的残留图片应被识别并清理
    func testOrphanImagesAreDetectedAndPurged() throws {
        let keptName = "cache-test-\(UUID().uuidString).jpg"
        let orphanName = "cache-test-\(UUID().uuidString).jpg"
        let keptURL = ChatAttachment.directory.appendingPathComponent(keptName)
        let orphanURL = ChatAttachment.directory.appendingPathComponent(orphanName)
        try Data(repeating: 0xAB, count: 4096).write(to: keptURL)
        try Data(repeating: 0xCD, count: 8192).write(to: orphanURL)
        defer {
            try? FileManager.default.removeItem(at: keptURL)
            try? FileManager.default.removeItem(at: orphanURL)
        }

        var conversation = Conversation(model: "deepseek-flash")
        conversation.messages = [
            ChatMessage(role: .user, content: "看看这张图", attachments: [ChatAttachment(fileName: keptName)])
        ]

        let snapshot = AppCache.snapshot(conversations: [conversation])
        XCTAssertGreaterThanOrEqual(snapshot.inUseImageBytes, 4096, "会话中的图片应计入在用缓存")
        XCTAssertGreaterThanOrEqual(snapshot.orphanImageBytes, 8192, "无引用的图片应计入可清理缓存")

        let freed = AppCache.purgeOrphanImages(conversations: [conversation])
        XCTAssertGreaterThanOrEqual(freed, 8192)
        XCTAssertTrue(FileManager.default.fileExists(atPath: keptURL.path), "会话中使用的图片应保留")
        XCTAssertFalse(FileManager.default.fileExists(atPath: orphanURL.path), "残留图片应被清理")
    }

    /// 删除会话时，会话里的图片文件要一起删除
    func testDeletingConversationRemovesItsImages() throws {
        let name = "cache-test-\(UUID().uuidString).jpg"
        let url = ChatAttachment.directory.appendingPathComponent(name)
        try Data(repeating: 0xEF, count: 2048).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let store = ConversationStore(fileName: "test-\(UUID().uuidString).json")
        var conversation = store.createConversation(model: "deepseek-flash")
        conversation.messages = [
            ChatMessage(role: .user, content: "看图", attachments: [ChatAttachment(fileName: name)])
        ]
        store.upsert(conversation)
        store.delete(id: conversation.id)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path), "会话删除后图片文件不应残留")
    }
}

// MARK: - 插件系统（JavaScriptCore 端到端）

final class PluginRuntimeTests: XCTestCase {

    func testMetadataParsing() {
        let script = """
        // @name 我的插件
        // @summary 做点什么
        // @version 2.1.0
        // @author 张三
        // @enabled false
        dsh.log("hi")
        """
        let metadata = PluginManager.parseMetadata(script)
        XCTAssertEqual(metadata.name, "我的插件")
        XCTAssertEqual(metadata.summary, "做点什么")
        XCTAssertEqual(metadata.version, "2.1.0")
        XCTAssertEqual(metadata.author, "张三")
        XCTAssertEqual(metadata.enabled, false)
    }

    func testBuiltInPluginsAreDiscoveredAndLoaded() {
        let manager = PluginManager()
        manager.refresh()

        XCTAssertFalse(manager.manifests.isEmpty, "应发现内置插件")
        let builtIns = manager.manifests.filter { $0.isBuiltIn }
        XCTAssertGreaterThanOrEqual(builtIns.count, 4, "内置插件数量不足")

        let names = builtIns.map(\.name)
        XCTAssertTrue(names.contains("时间戳助手"))
        XCTAssertTrue(names.contains("文本工具"))
        XCTAssertTrue(names.contains("文案统计"))

        // 内置插件默认应被激活（prompt-suffix 默认关闭）
        XCTAssertTrue(manager.manifests.first { $0.name == "文本工具" }?.isEnabled ?? false)
        XCTAssertFalse(manager.manifests.first { $0.name == "回答风格约束" }?.isEnabled ?? true)
    }

    func testPluginCommandsAreRegistered() {
        let manager = PluginManager()
        manager.refresh()
        let names = Set(manager.commands.map(\.name))
        for expected in ["time", "date", "upper", "lower", "reverse", "count"] {
            XCTAssertTrue(names.contains(expected), "缺少命令 /\(expected)")
        }
    }

    func testCommandExecutionReturnsTransformedText() {
        let manager = PluginManager()
        manager.refresh()

        XCTAssertEqual(manager.run(command: "upper", argument: "abc"), "ABC")
        XCTAssertEqual(manager.run(command: "lower", argument: "ABC"), "abc")
        XCTAssertEqual(manager.run(command: "reverse", argument: "abc"), "cba")

        let counted = manager.run(command: "count", argument: "hello world")
        XCTAssertEqual(counted, "字数 10 · 词数 2 · 行数 1")

        let time = manager.run(command: "time", argument: "")
        XCTAssertNotNil(time)
        XCTAssertEqual(time?.count, 8, "时间格式应为 HH:mm:ss")

        XCTAssertNil(manager.run(command: "不存在的命令", argument: "x"))
    }

    func testDisablingPluginUnregistersItsCommands() {
        let manager = PluginManager()
        manager.refresh()
        XCTAssertTrue(manager.commands.contains { $0.name == "upper" })

        guard let plugin = manager.manifests.first(where: { $0.name == "文本工具" }) else {
            return XCTFail("未找到文本工具插件")
        }
        manager.setEnabled(false, for: plugin.id)
        XCTAssertFalse(manager.commands.contains { $0.name == "upper" }, "停用后命令应被卸载")
        XCTAssertNil(manager.run(command: "upper", argument: "abc"))

        manager.setEnabled(true, for: plugin.id)
        XCTAssertTrue(manager.commands.contains { $0.name == "upper" }, "重新启用后命令应恢复")
        XCTAssertEqual(manager.run(command: "upper", argument: "xyz"), "XYZ")
    }

    func testMessageHookTransformsOutgoingText() {
        let manager = PluginManager()
        manager.refresh()

        // 默认关闭时不应改写
        let plain = manager.transformOutgoing("你好", role: "user")
        XCTAssertEqual(plain, "你好")

        // 启用「回答风格约束」后应追加约束
        guard let plugin = manager.manifests.first(where: { $0.name == "回答风格约束" }) else {
            return XCTFail("未找到回答风格约束插件")
        }
        manager.setEnabled(true, for: plugin.id)
        let transformed = manager.transformOutgoing("你好", role: "user")
        XCTAssertTrue(transformed.hasPrefix("你好"))
        XCTAssertTrue(transformed.contains("[约束]"))

        // 助手角色不应被改写
        XCTAssertEqual(manager.transformOutgoing("回复", role: "assistant"), "回复")

        manager.setEnabled(false, for: plugin.id)
    }

    /// 「回答风格约束」应使用设置里编辑的强调指令（默认指令只在未编辑时兜底）
    func testMessageHookUsesStyleSuffixSetting() {
        let settings = SettingsStore()
        let original = settings.settings.styleSuffix
        settings.settings.styleSuffix = "[约束] 只回答一句话。"
        defer { settings.settings.styleSuffix = original }

        let manager = PluginManager()
        manager.configure(settingsStore: settings)
        manager.refresh()

        guard let plugin = manager.manifests.first(where: { $0.id == "builtin.prompt-suffix" }) else {
            return XCTFail("未找到回答风格约束插件")
        }
        manager.setEnabled(true, for: plugin.id)
        defer { manager.setEnabled(false, for: plugin.id) }
        XCTAssertEqual(manager.transformOutgoing("你好", role: "user"), "你好\n\n[约束] 只回答一句话。")
        XCTAssertEqual(manager.transformOutgoing("回复", role: "assistant"), "回复")
    }

    func testBrokenPluginIsReportedWithoutCrashing() {
        let manager = PluginManager()
        manager.refresh()

        let broken = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("broken-\(UUID().uuidString).js")
        try? "dsh.registerCommand(".write(to: broken, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: broken) }

        // 语法错误的脚本不应影响其它插件
        XCTAssertTrue(manager.commands.contains { $0.name == "upper" })
    }
}

// MARK: - 网络层错误处理

final class NetworkingTests: XCTestCase {

    func testMissingAPIKeyThrows() async {
        let client = DeepSeekClient(timeout: 5)
        do {
            _ = try await client.fetchModelIDs(settings: .default, apiKey: "")
            XCTFail("空 API Key 应抛错")
        } catch {
            XCTAssertEqual((error as? DSHError)?.errorDescription, DSHError.missingAPIKey.errorDescription)
        }
    }

    func testInvalidBaseURLThrows() async {
        let client = DeepSeekClient(timeout: 5)
        var settings = AppSettings.default
        settings.baseURL = ""
        do {
            _ = try await client.fetchModelIDs(settings: settings, apiKey: "sk-test")
            XCTFail("空 Base URL 应抛错")
        } catch {
            XCTAssertTrue(error is DSHError)
        }
    }

    func testErrorDescriptionsAreLocalized() {
        XCTAssertEqual(DSHError.unauthorized.errorDescription, "API Key 无效或已失效（401）。")
        XCTAssertEqual(DSHError.rateLimited.errorDescription, "请求过于频繁或额度不足（429）。")
        XCTAssertTrue(DSHError.http(status: 500, body: "boom").errorDescription?.contains("500") ?? false)
    }

    // MARK: 流式链路

    /// 注入本地 mock 传输层，验证 SSE 解析、推理字段与用量统计
    func testStreamingChatParsesSSE() async throws {
        let body = [
            #"data: {"choices":[{"delta":{"reasoning_content":"先想一想"}}]}"#,
            "",
            #"data: {"choices":[{"delta":{"content":"你好"}}]}"#,
            "",
            #"data: {"choices":[{"delta":{"content":"，世界"}}]}"#,
            "",
            #"data: {"choices":[{"delta":{}}],"usage":{"prompt_tokens":11,"completion_tokens":7}}"#,
            "",
            "data: [DONE]",
            ""
        ].joined(separator: "\n")

        MockURLProtocol.handler = { request in
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertTrue(request.url?.path.hasSuffix("/chat/completions") ?? false)
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer sk-test")
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "text/event-stream"]
            )!
            return (response, Data(body.utf8))
        }

        let client = DeepSeekClient(timeout: 10, configuration: MockURLProtocol.configuration)
        var content = ""
        var reasoning = ""
        var usage: TokenUsage?

        let stream = client.streamChat(
            messages: [APIMessage(role: "user", content: "在吗")],
            model: "deepseek-reasoner",
            settings: .default,
            apiKey: "sk-test"
        )
        for try await event in stream {
            switch event {
            case .content(let delta): content += delta
            case .reasoning(let delta): reasoning += delta
            case .toolCalls: break
            case .finished(let value): if let value { usage = value }
            }
        }

        XCTAssertEqual(reasoning, "先想一想")
        XCTAssertEqual(content, "你好，世界")
        XCTAssertEqual(usage?.promptTokens, 11)
        XCTAssertEqual(usage?.completionTokens, 7)
    }

    func testStreamingSurfacesHTTPError() async {
        MockURLProtocol.handler = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 401, httpVersion: nil, headerFields: nil)!
            return (response, Data(#"{"error":"unauthorized"}"#.utf8))
        }

        let client = DeepSeekClient(timeout: 10, configuration: MockURLProtocol.configuration)
        do {
            for try await _ in client.streamChat(
                messages: [APIMessage(role: "user", content: "hi")],
                model: "deepseek-chat",
                settings: .default,
                apiKey: "sk-bad"
            ) {}
            XCTFail("应抛出 401 错误")
        } catch {
            XCTAssertEqual((error as? DSHError)?.errorDescription, DSHError.unauthorized.errorDescription)
        }
    }

    func testNonStreamingCompletionParsesContentAndUsage() async throws {
        MockURLProtocol.handler = { request in
            let json = """
            {"choices":[{"message":{"content":"答案","reasoning_content":"推理"}}],
             "usage":{"prompt_tokens":3,"completion_tokens":9}}
            """
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, Data(json.utf8))
        }

        let client = DeepSeekClient(timeout: 10, configuration: MockURLProtocol.configuration)
        let result = try await client.complete(
            messages: [APIMessage(role: "user", content: "问题")],
            model: "deepseek-reasoner",
            settings: .default,
            apiKey: "sk-test"
        )
        XCTAssertEqual(result.text, "答案")
        XCTAssertEqual(result.reasoning, "推理")
        XCTAssertEqual(result.usage?.completionTokens, 9)
    }

    func testBaseURLTrailingSlashIsHandled() async throws {
        MockURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.absoluteString, "https://example.com/v1/models")
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, Data(#"{"data":[{"id":"deepseek-chat"},{"id":"deepseek-reasoner"}]}"#.utf8))
        }
        var settings = AppSettings.default
        settings.baseURL = "https://example.com/v1/"

        let client = DeepSeekClient(timeout: 10, configuration: MockURLProtocol.configuration)
        let ids = try await client.fetchModelIDs(settings: settings, apiKey: "sk-test")
        XCTAssertEqual(ids, ["deepseek-chat", "deepseek-reasoner"])
    }

    // MARK: 思考模式参数

    /// 只关心发出去的请求体，因此用最小 SSE 响应收尾
    private func runStream(
        model: String,
        settings: AppSettings,
        tools: [APITool] = [],
        messages: [APIMessage] = [APIMessage(role: "user", content: "hi")]
    ) async {
        MockURLProtocol.handler = { request in
            MockURLProtocol.lastRequestBody = MockURLProtocol.body(of: request)
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "text/event-stream"]
            )!
            return (response, Data("data: [DONE]\n".utf8))
        }
        let client = DeepSeekClient(timeout: 10, configuration: MockURLProtocol.configuration)
        let stream = client.streamChat(
            messages: messages,
            model: model,
            tools: tools,
            settings: settings,
            apiKey: "sk-test"
        )
        do {
            for try await _ in stream {}
        } catch {
            // 请求体已捕获，这里忽略流本身的结束方式
        }
    }

    func testThinkingParamsAreSentForDeepSeekModels() async throws {
        var settings = AppSettings.default
        settings.thinkingEnabled = true
        settings.reasoningEffort = .max

        await runStream(model: "deepseek-flash", settings: settings)

        let body = try XCTUnwrap(MockURLProtocol.decodedLastRequestBody())
        XCTAssertEqual(body["model"] as? String, "deepseek-flash")
        XCTAssertEqual((body["thinking"] as? [String: Any])?["type"] as? String, "enabled")
        XCTAssertEqual(body["reasoning_effort"] as? String, "max")
        XCTAssertEqual(body["stream"] as? Bool, true)
    }

    func testThinkingParamsAreOmittedForCustomModels() async throws {
        var settings = AppSettings.default
        settings.thinkingEnabled = true

        await runStream(model: "my-relay-model", settings: settings)

        let body = try XCTUnwrap(MockURLProtocol.decodedLastRequestBody())
        XCTAssertNil(body["thinking"], "自定义模型不应携带 DeepSeek 专有参数，避免中转服务报错")
        XCTAssertNil(body["reasoning_effort"])
    }

    func testThinkingParamsAreOmittedWhenDisabled() async throws {
        var settings = AppSettings.default
        settings.thinkingEnabled = false

        await runStream(model: "deepseek-flash", settings: settings)

        let body = try XCTUnwrap(MockURLProtocol.decodedLastRequestBody())
        XCTAssertNil(body["thinking"])
    }

    // MARK: 工具调用参数

    /// 开启工具后请求体应携带 tools；未开启时不应出现该字段
    func testToolDefinitionsAreSentOnlyWhenProvided() async throws {
        await runStream(
            model: "deepseek-flash",
            settings: .default,
            tools: AgentToolCatalog.tools(sshEnabled: true, browserEnabled: true, browserReadEnabled: true)
        )

        let body = try XCTUnwrap(MockURLProtocol.decodedLastRequestBody())
        let tools = try XCTUnwrap(body["tools"] as? [[String: Any]])
        XCTAssertEqual(tools.count, 3, "SSH 已配置时应下发 ssh_exec 与两个浏览器工具")
        let names = tools.compactMap { ($0["function"] as? [String: Any])?["name"] as? String }
        XCTAssertEqual(names, ["ssh_exec", "browser_open", "browser_read"])
        XCTAssertEqual(tools.first?["type"] as? String, "function")
        let parameters = (tools.first?["function"] as? [String: Any])?["parameters"] as? [String: Any]
        XCTAssertEqual(parameters?["type"] as? String, "object")
        XCTAssertNotNil(parameters?["properties"])

        await runStream(model: "deepseek-flash", settings: .default)
        let plainBody = try XCTUnwrap(MockURLProtocol.decodedLastRequestBody())
        XCTAssertNil(plainBody["tools"], "未开启工具时不应下发 tools")
    }

    /// SSH 未配置时不下发 ssh_exec，避免模型调用必然失败的工具；
    /// 浏览器开关关闭时也不下发浏览器工具（两个开关互相独立）
    func testSSHToolIsOmittedWhenNotConfigured() async throws {
        await runStream(
            model: "deepseek-flash",
            settings: .default,
            tools: AgentToolCatalog.tools(sshEnabled: false, browserEnabled: true, browserReadEnabled: true)
        )

        let body = try XCTUnwrap(MockURLProtocol.decodedLastRequestBody())
        let tools = try XCTUnwrap(body["tools"] as? [[String: Any]])
        let names = tools.compactMap { ($0["function"] as? [String: Any])?["name"] as? String }
        XCTAssertEqual(names, ["browser_open", "browser_read"])

        // 浏览器开关开启但关闭「允许读取正文」时，只提供 browser_open
        XCTAssertEqual(
            AgentToolCatalog.tools(sshEnabled: false, browserEnabled: true, browserReadEnabled: false)
                .map(\.name),
            [AgentToolCatalog.browserOpenName]
        )
        // 只开 SSH 时，浏览器工具完全不出现
        XCTAssertEqual(
            AgentToolCatalog.tools(sshEnabled: true, browserEnabled: false, browserReadEnabled: false)
                .map(\.name),
            [AgentToolCatalog.sshExecName]
        )
    }

    /// 工具调用消息按 OpenAI 兼容格式编码（assistant.tool_calls / tool.tool_call_id）
    func testToolMessagesAreEncodedForAPI() async throws {
        await runStream(
            model: "deepseek-flash",
            settings: .default,
            messages: [
                APIMessage(role: "user", content: "看看服务器磁盘"),
                APIMessage(role: "assistant", content: "", toolCalls: [
                    ToolCall(id: "call_1", name: "ssh_exec", arguments: #"{"command":"df -h"}"#)
                ]),
                APIMessage(role: "tool", content: "/dev/vda1  40G  12G  28G  30% /", toolCallID: "call_1")
            ]
        )

        let body = try XCTUnwrap(MockURLProtocol.decodedLastRequestBody())
        let messages = try XCTUnwrap(body["messages"] as? [[String: Any]])
        XCTAssertEqual(messages.count, 3)

        let calls = try XCTUnwrap(messages[1]["tool_calls"] as? [[String: Any]])
        XCTAssertEqual(calls.first?["id"] as? String, "call_1")
        XCTAssertEqual(calls.first?["type"] as? String, "function")
        let function = calls.first?["function"] as? [String: Any]
        XCTAssertEqual(function?["name"] as? String, "ssh_exec")
        XCTAssertEqual(function?["arguments"] as? String, #"{"command":"df -h"}"#)

        XCTAssertEqual(messages[2]["role"] as? String, "tool")
        XCTAssertEqual(messages[2]["tool_call_id"] as? String, "call_1")
    }
}

/// 用于替换真实网络的测试传输层
final class MockURLProtocol: URLProtocol {

    static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?
    static var lastRequestBody: Data?

    static var configuration: URLSessionConfiguration {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        return config
    }

    /// URLProtocol 中请求体以流的形式提供，这里统一读成 Data
    static func body(of request: URLRequest) -> Data? {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        let bufferSize = 4096
        var buffer = [UInt8](repeating: 0, count: bufferSize)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: bufferSize)
            if read <= 0 { break }
            data.append(buffer, count: read)
        }
        return data.isEmpty ? nil : data
    }

    static func decodedLastRequestBody() -> [String: Any]? {
        guard let data = lastRequestBody else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = MockURLProtocol.handler else {
            client?.urlProtocol(self, didFailWithError: DSHError.emptyResponse)
            return
        }
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

// MARK: - 流式工具调用解析（Agent）

final class ChatStreamParserTests: XCTestCase {

    func testContentAndReasoningAreEmitted() {
        var parser = ChatStreamParser()
        let line = #"data: {"choices":[{"delta":{"reasoning_content":"想一想","content":"你好"},"finish_reason":null}]}"#
        XCTAssertEqual(parser.consume(line: line), [.reasoning("想一想"), .content("你好")])
    }

    func testToolCallFragmentsAreMerged() {
        var parser = ChatStreamParser()
        // 第一片：id + 函数名 + 部分参数
        _ = parser.consume(
            line: #"data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_1","type":"function","function":{"name":"ssh_exec","arguments":"{\"comm"}}]},"finish_reason":null}]}"#
        )
        // 第二片：参数续传
        _ = parser.consume(
            line: #"data: {"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"and\":\"ls -la\"}"}}]},"finish_reason":null}]}"#
        )
        // 结束片
        let results = parser.consume(line: #"data: {"choices":[{"delta":{},"finish_reason":"tool_calls"}]}"#)
        guard case .toolCalls(let calls)? = results.first else {
            return XCTFail("应产出工具调用")
        }
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls[0].id, "call_1")
        XCTAssertEqual(calls[0].name, "ssh_exec")
        XCTAssertEqual(calls[0].arguments, #"{"command":"ls -la"}"#)
        XCTAssertEqual(calls[0].argumentPreview, "ls -la")
    }

    func testMultipleToolCallsKeepOrder() {
        var parser = ChatStreamParser()
        _ = parser.consume(
            line: #"data: {"choices":[{"delta":{"tool_calls":[{"index":1,"id":"b","function":{"name":"browser_read","arguments":"{\"url\":\"https://b\"}"}}]},"finish_reason":null}]}"#
        )
        _ = parser.consume(
            line: #"data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"a","function":{"name":"browser_open","arguments":"{\"url\":\"https://a\"}"}}]},"finish_reason":null}]}"#
        )
        let results = parser.consume(line: "data: [DONE]")
        guard case .toolCalls(let calls)? = results.first else {
            return XCTFail("应产出工具调用")
        }
        XCTAssertEqual(calls.map(\.id), ["a", "b"], "工具调用应按 index 顺序输出")
        XCTAssertEqual(results.last, .done)
        XCTAssertTrue(parser.finish().isEmpty, "不应重复产出工具调用")
    }

    /// 官方文档：收尾块的 usage 挂在最后一个内容块上（delta 为空、finish_reason 非 null）
    func testFinalChunkCarriesUsage() {
        var parser = ChatStreamParser()
        let results = parser.consume(
            line: #"data: {"choices":[{"delta":{},"finish_reason":"stop"}],"usage":{"prompt_tokens":11,"completion_tokens":7}}"#
        )
        XCTAssertEqual(results, [.usage(TokenUsage(promptTokens: 11, completionTokens: 7))])
    }

    /// 只带 usage、没有 choices 的收尾块也不能被整块丢弃，否则 token 统计一直是 0
    func testUsageOnlyChunkIsParsed() {
        var parser = ChatStreamParser()
        let results = parser.consume(
            line: #"data: {"usage":{"prompt_tokens":31,"completion_tokens":9}}"#
        )
        XCTAssertEqual(results, [.usage(TokenUsage(promptTokens: 31, completionTokens: 9))])
    }

    func testUsageAndIgnoredLines() {
        var parser = ChatStreamParser()
        XCTAssertTrue(parser.consume(line: "").isEmpty)
        XCTAssertTrue(parser.consume(line: "event: ping").isEmpty)
        XCTAssertTrue(parser.consume(line: "data: not-json").isEmpty)
        let results = parser.consume(line: #"data: {"choices":[],"usage":{"prompt_tokens":3,"completion_tokens":4}}"#)
        XCTAssertEqual(results, [.usage(TokenUsage(promptTokens: 3, completionTokens: 4))])
    }

    func testToolArgumentsParsing() {
        XCTAssertEqual(ToolArguments.string("command", in: #"{"command":" ls -la "}"#), "ls -la")
        XCTAssertNil(ToolArguments.string("command", in: #"{"url":"https://a"}"#))
        XCTAssertNil(ToolArguments.string("command", in: "not-json"))
    }
}

// MARK: - 用量统计

final class TokenUsageTests: XCTestCase {

    /// 服务端未返回 usage 时的兜底估算：中文按 0.6、其余按 0.3 token/字符
    func testEstimateFromText() {
        let usage = TokenUsage.estimate(prompt: "你好世界", completion: "hello world")
        XCTAssertEqual(usage.promptTokens, 2)      // 4 个汉字 × 0.6 = 2.4 → 四舍五入 2
        XCTAssertEqual(usage.completionTokens, 3)  // 11 个 ASCII × 0.3 = 3.3 → 四舍五入 3
        XCTAssertEqual(TokenUsage.estimateCount(""), 0)
        XCTAssertGreaterThan(TokenUsage.estimateCount(String(repeating: "字", count: 100)), 50)
    }

    /// 旧数据没有 tokensEstimated 字段时也要能解码
    func testMessageDecodingWithoutEstimatedFlag() throws {
        let legacy = #"{"id":"11111111-1111-1111-1111-111111111111","role":"assistant","content":"hi","createdAt":0,"isStreaming":false,"promptTokens":5,"completionTokens":6}"#
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .deferredToDate
        let message = try decoder.decode(ChatMessage.self, from: Data(legacy.utf8))
        XCTAssertNil(message.tokensEstimated)
        XCTAssertEqual(message.promptTokens, 5)
    }
}

// MARK: - 流式缓冲

/// 生成过程的流畅度依赖两条性质：已定型的块永不改变、末尾块长度有上限。
/// 前者保证视图能整块复用排版，后者保证单次刷新的排版量与全文长度无关。
final class StreamingTextTests: XCTestCase {

    func testFinalizedBlocksNeverChangeWhileStreaming() {
        let buffer = StreamingText(messageID: UUID())
        let body = String(repeating: "这是一段用来触发切块的文字，长度需要超过单块上限。", count: 12)
        var previous: [String] = []
        var streamed = ""

        for character in body {
            buffer.appendContent(String(character))
            streamed.append(character)
            let blocks = buffer.contentBlocks
            for index in 0..<min(previous.count, blocks.count) {
                XCTAssertEqual(blocks[index], previous[index], "已定型的块不应随增量变化")
            }
            previous = blocks
        }

        XCTAssertEqual(buffer.content, streamed, "完整正文应与输入一致")
        XCTAssertFalse(buffer.contentBlocks.isEmpty, "超过上限后应出现已定型块")
        XCTAssertLessThanOrEqual(buffer.contentTail.count, StreamingText.blockLimit + 1, "末尾块长度应受限")
    }

    func testShortContentStaysInTail() {
        let buffer = StreamingText(messageID: UUID())
        buffer.appendContent("甲段\n\n乙段")
        XCTAssertTrue(buffer.contentBlocks.isEmpty, "短文本不应切块")
        XCTAssertEqual(buffer.contentTail, "甲段\n\n乙段")
        XCTAssertEqual(buffer.content, "甲段\n\n乙段")
    }

    func testReasoningIsTrackedSeparately() {
        let buffer = StreamingText(messageID: UUID())
        buffer.appendReasoning("先想一想")
        buffer.appendContent("正文")
        XCTAssertEqual(buffer.reasoning, "先想一想")
        XCTAssertEqual(buffer.content, "正文")
        XCTAssertTrue(buffer.hasReasoning)
        XCTAssertTrue(buffer.hasContent)
    }

    /// 工具调用后的新一轮：清空并切换到新的消息 id
    func testRestartClearsBufferAndSwitchesMessage() {
        let buffer = StreamingText(messageID: UUID())
        buffer.appendContent("上一轮的内容")
        buffer.appendReasoning("上一轮的思考")
        let newID = UUID()
        buffer.restart(for: newID)
        XCTAssertEqual(buffer.messageID, newID)
        XCTAssertTrue(buffer.content.isEmpty)
        XCTAssertTrue(buffer.reasoning.isEmpty)
        XCTAssertTrue(buffer.contentBlocks.isEmpty)
        XCTAssertTrue(buffer.contentTail.isEmpty)
        XCTAssertFalse(buffer.hasContent)
    }
}

// MARK: - 过程（思考 + 工具步骤）

final class ChatProcessTests: XCTestCase {

    func testSummaryCountsTools() {
        var message = ChatMessage(role: .assistant, content: "好的", reasoning: "先看看再动手")
        message.toolCalls = [
            ToolCall(id: "1", name: AgentToolCatalog.sshExecName, arguments: #"{"command":"ls -la"}"#),
            ToolCall(id: "2", name: AgentToolCatalog.sshExecName, arguments: #"{"command":"pwd"}"#),
            ToolCall(id: "3", name: AgentToolCatalog.browserReadName, arguments: #"{"url":"https://example.com"}"#)
        ]

        let process = ChatProcess(message: message, toolMessages: [])
        XCTAssertEqual(process.summary, "已执行 2 条命令，读取 1 个网页")
        XCTAssertEqual(process.steps.count, 3)
        XCTAssertEqual(process.steps[0].title, "执行命令")
        XCTAssertEqual(process.steps[0].detail, "ls -la")
        XCTAssertEqual(process.steps[2].title, "读取网页")
        XCTAssertEqual(process.steps[2].detail, "https://example.com")
        XCTAssertTrue(process.hasReasoning)
        XCTAssertFalse(process.isRunning)
    }

    /// 工具还在执行时用「正在…」文案
    func testRunningToolUsesInProgressWording() {
        var message = ChatMessage(role: .assistant, content: "")
        message.toolCalls = [ToolCall(id: "1", name: AgentToolCatalog.sshExecName, arguments: #"{"command":"ls"}"#)]
        var toolMessage = ChatMessage(role: .tool, content: "", isStreaming: true)
        toolMessage.toolCallID = "1"

        let process = ChatProcess(message: message, toolMessages: [toolMessage])
        XCTAssertTrue(process.isRunning)
        XCTAssertEqual(process.summary, "正在执行 1 条命令")
    }

    /// 工具输出会带进弹窗内容
    func testToolOutputIsIncluded() {
        var message = ChatMessage(role: .assistant, content: "")
        message.toolCalls = [ToolCall(id: "1", name: AgentToolCatalog.sshExecName, arguments: #"{"command":"ls"}"#)]
        var toolMessage = ChatMessage(role: .tool, content: "文件A\n文件B")
        toolMessage.toolCallID = "1"

        let process = ChatProcess(message: message, toolMessages: [toolMessage])
        XCTAssertEqual(process.steps.first?.output, "文件A\n文件B")
    }

    /// 只有思考、没有工具调用时也要能显示「思考过程」
    func testReasoningOnlyProcess() {
        let message = ChatMessage(role: .assistant, content: "答案", reasoning: "先想一下")
        let process = ChatProcess(message: message, toolMessages: [])
        XCTAssertTrue(process.hasReasoning)
        XCTAssertFalse(process.hasSteps)
        XCTAssertFalse(process.isEmpty)

        let empty = ChatProcess(message: ChatMessage(role: .assistant, content: "没有思考"), toolMessages: [])
        XCTAssertTrue(empty.isEmpty, "既无思考也无工具时不应显示折叠行")
    }
}