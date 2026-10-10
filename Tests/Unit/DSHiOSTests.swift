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
        // 文本必须明显超过 StreamingText.blockLimit，否则末尾块永远不会定型，断言失去意义
        let unit = "这是一段用来触发切块的文字，长度需要超过单块上限。"
        var body = ""
        while body.count <= StreamingText.blockLimit * 2 { body += unit }
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

// MARK: - 删除消息的连带范围

final class MessageDeletionTests: XCTestCase {

    /// 删除用户消息时，它的回复要一起删掉，下一轮对话不受影响
    func testDeletingUserMessageAlsoRemovesItsReply() {
        let user1 = ChatMessage(role: .user, content: "第一个问题")
        let assistant1 = ChatMessage(role: .assistant, content: "第一个回答")
        let user2 = ChatMessage(role: .user, content: "第二个问题")
        let assistant2 = ChatMessage(role: .assistant, content: "第二个回答")
        let messages = [user1, assistant1, user2, assistant2]

        let removed = ChatEngine.deletionIDs(for: user1, in: messages)
        XCTAssertEqual(removed, [user1.id, assistant1.id])

        let kept = messages.filter { !removed.contains($0.id) }.map(\.id)
        XCTAssertEqual(kept, [user2.id, assistant2.id], "后续轮次不应被误删")
    }

    /// 这一轮里用到的工具结果也一并删除，不留下孤立的 tool 消息
    func testDeletingUserMessageRemovesToolStepsOfThatTurn() {
        var assistant = ChatMessage(role: .assistant, content: "先执行命令")
        assistant.toolCalls = [ToolCall(id: "call_1", name: AgentToolCatalog.sshExecName, arguments: #"{"command":"ls"}"#)]
        var tool = ChatMessage(role: .tool, content: "文件A")
        tool.toolCallID = "call_1"
        let user = ChatMessage(role: .user, content: "看看目录")
        let tail = ChatMessage(role: .assistant, content: "看完了")

        let messages = [user, assistant, tool, tail]
        let removed = ChatEngine.deletionIDs(for: user, in: messages)
        XCTAssertEqual(removed, [user.id, assistant.id, tool.id, tail.id])
    }

    /// 删除助手回复时，只删这条回复与它的工具结果，提问保留
    func testDeletingAssistantMessageRemovesItsToolResults() {
        var assistant = ChatMessage(role: .assistant, content: "先执行命令")
        assistant.toolCalls = [ToolCall(id: "call_1", name: AgentToolCatalog.sshExecName, arguments: #"{"command":"ls"}"#)]
        var tool = ChatMessage(role: .tool, content: "文件A")
        tool.toolCallID = "call_1"
        var otherTool = ChatMessage(role: .tool, content: "文件B")
        otherTool.toolCallID = "call_2"
        let user = ChatMessage(role: .user, content: "看看目录")

        let messages = [user, assistant, tool, otherTool]
        let removed = ChatEngine.deletionIDs(for: assistant, in: messages)
        XCTAssertEqual(removed, [assistant.id, tool.id], "只删本轮的 tool 结果")
    }
}

// MARK: - 技能

final class SkillStoreTests: XCTestCase {

    private func makeFileName() -> String { "skills-test-\(UUID().uuidString).json" }

    private func removeFile(_ name: String) {
        let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(name)
        try? FileManager.default.removeItem(at: url)
    }

    func testAddEditDeleteAndPersist() {
        let name = makeFileName()
        defer { removeFile(name) }

        let store = SkillStore(fileName: name)
        XCTAssertTrue(store.skills.isEmpty)

        let added = store.add(name: " 周报整理 ", summary: " 每周五整理 ", content: " 1. 汇总本周提交 ")
        XCTAssertNotNil(added)
        XCTAssertEqual(store.skills.count, 1)
        XCTAssertEqual(store.skills[0].name, "周报整理", "名称首尾空白应去掉")
        XCTAssertEqual(store.skills[0].summary, "每周五整理")
        XCTAssertEqual(store.skills[0].content, "1. 汇总本周提交")

        // 同名技能覆盖，不新增第二条（否则模型会拿到两份冲突说明）
        store.add(name: "周报整理", summary: "改写摘要", content: "新步骤")
        XCTAssertEqual(store.skills.count, 1)
        XCTAssertEqual(store.skills[0].content, "新步骤")

        // 落盘后重新打开应一致
        let reloaded = SkillStore(fileName: name)
        XCTAssertEqual(reloaded.skills, store.skills)

        reloaded.delete(id: store.skills[0].id)
        XCTAssertTrue(reloaded.skills.isEmpty)
        XCTAssertTrue(SkillStore(fileName: name).skills.isEmpty)
    }

    func testEmptyNameOrContentIsRejected() {
        let name = makeFileName()
        defer { removeFile(name) }

        let store = SkillStore(fileName: name)
        XCTAssertNil(store.add(name: "   ", summary: "摘要", content: "步骤"))
        XCTAssertNil(store.add(name: "技能", summary: "摘要", content: "  "))
        XCTAssertTrue(store.skills.isEmpty)
    }

    func testDisabledSkillIsNotOfferedToAgent() {
        let name = makeFileName()
        defer { removeFile(name) }

        let store = SkillStore(fileName: name)
        let skill = store.add(name: "SQL 审核", summary: "审核 SQL", content: "检查索引")
        XCTAssertEqual(store.enabledSkills.count, 1)

        store.toggle(id: skill?.id ?? UUID())
        XCTAssertTrue(store.enabledSkills.isEmpty)
        XCTAssertEqual(store.skills.count, 1, "关闭只是不启用，技能仍保留在本地")
    }

    /// 模型可能带上大小写或前后空白，取用时放宽匹配
    func testSkillLookupIsForgiving() {
        let name = makeFileName()
        defer { removeFile(name) }

        let store = SkillStore(fileName: name)
        store.add(name: "SQL 审核", summary: "审核 SQL", content: "内容")
        XCTAssertNotNil(store.skill(named: " sql 审核 "))
        XCTAssertNil(store.skill(named: "不存在的技能"))
    }
}

/// 技能与工具的分工：工具执行操作，技能规定做法；技能清单进系统提示，全文由 skill 工具取回
final class SkillAgentTests: XCTestCase {

    func testSystemPromptIncludesSkillCatalog() {
        let skills = [
            Skill(name: "周报整理", summary: "每周五整理", content: "步骤"),
            Skill(name: "SQL 审核", content: "检查索引")
        ]
        let prompt = ChatEngine.systemPrompt(base: "你是助手", skills: skills)
        XCTAssertTrue(prompt.hasPrefix("你是助手"), "不应覆盖用户自己的系统提示")
        XCTAssertTrue(prompt.contains("周报整理：每周五整理"))
        XCTAssertTrue(prompt.contains("SQL 审核：（未写摘要）"))
        XCTAssertTrue(prompt.contains("skill 工具"), "应告诉模型用 skill 工具取全文")

        XCTAssertEqual(ChatEngine.systemPrompt(base: "你是助手", skills: []), "你是助手")
        XCTAssertTrue(ChatEngine.systemPrompt(base: "", skills: skills).contains("周报整理"))
    }

    /// 只有存在已启用技能时才下发 skill 工具，且技能名进 enum（模型只能选真实存在的技能）
    func testSkillToolIsOfferedOnlyWhenSkillsExist() throws {
        let plain = AgentToolCatalog.tools(sshEnabled: false, browserEnabled: false, browserReadEnabled: false)
        XCTAssertTrue(plain.isEmpty, "没有技能时不应出现任何工具")

        let tools = AgentToolCatalog.tools(
            sshEnabled: false,
            browserEnabled: false,
            browserReadEnabled: false,
            skillNames: ["周报整理", "SQL 审核"]
        )
        XCTAssertEqual(tools.map(\.name), [AgentToolCatalog.skillName])

        let properties = try XCTUnwrap(tools[0].parameters["properties"] as? [String: Any])
        let nameField = try XCTUnwrap(properties["name"] as? [String: Any])
        XCTAssertEqual(nameField["enum"] as? [String], ["周报整理", "SQL 审核"])
    }

    /// 技能与工具同时开启时一并下发，二者互不影响
    func testSkillToolCoexistsWithOtherTools() {
        let tools = AgentToolCatalog.tools(
            sshEnabled: true,
            browserEnabled: true,
            browserReadEnabled: true,
            skillNames: ["周报整理"]
        )
        XCTAssertEqual(
            tools.map(\.name),
            ["ssh_exec", "browser_open", "browser_read", AgentToolCatalog.skillName]
        )
    }

    /// 查看画面与工作区文件工具：各自独立开关，默认不下发（旧调用行为不变）
    func testVisionAndWorkspaceToolsAreGatedByFlags() {
        XCTAssertFalse(
            AgentToolCatalog.tools(sshEnabled: false, browserEnabled: false, browserReadEnabled: false)
                .contains { $0.name == AgentToolCatalog.screenshotName }
        )

        let withVision = AgentToolCatalog.tools(
            sshEnabled: false,
            browserEnabled: false,
            browserReadEnabled: false,
            visionEnabled: true
        )
        XCTAssertEqual(withVision.map(\.name), [AgentToolCatalog.screenshotName])
        let target = withVision[0].parameters["properties"] as? [String: Any]
        let targetField = target?["target"] as? [String: Any]
        XCTAssertEqual(targetField?["enum"] as? [String], ["screen", "browser"])

        let withFiles = AgentToolCatalog.tools(
            sshEnabled: false,
            browserEnabled: false,
            browserReadEnabled: false,
            fileEnabled: true
        )
        XCTAssertEqual(withFiles.map(\.name), [AgentToolCatalog.workspaceName])

        let all = AgentToolCatalog.tools(
            sshEnabled: true,
            browserEnabled: true,
            browserReadEnabled: true,
            visionEnabled: true,
            fileEnabled: true,
            skillNames: ["周报整理"]
        )
        XCTAssertEqual(
            all.map(\.name),
            ["ssh_exec", "browser_open", "browser_read", "screenshot", "workspace", AgentToolCatalog.skillName]
        )
    }
}

// MARK: - 工作区文件（文件管理器 / IDE / 智能体工具）

final class WorkspaceStoreTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("workspace-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    func testCreateWriteReadRenameDelete() throws {
        let store = WorkspaceStore(root: root)
        XCTAssertTrue(store.items.isEmpty, "新工作区应为空")

        // 新建文件并写入代码：内容必须原样保存（含缩进与换行）
        let code = "func main() {\n    print(\"hi\")\n}\n"
        let fileURL = try XCTUnwrap(store.createFile(named: "main.swift"))
        XCTAssertTrue(store.write(code, to: fileURL))
        XCTAssertEqual(store.read(fileURL), code)
        XCTAssertEqual(store.items.map(\.name), ["main.swift"])

        // 新建文件夹后进入，再返回上级
        let folder = try XCTUnwrap(store.createFolder(named: "src"))
        store.enter(WorkspaceStore.Item(url: folder, isDirectory: true, size: 0, modifiedAt: Date()))
        XCTAssertTrue(store.items.isEmpty)
        store.goUp()
        XCTAssertEqual(store.items.count, 2, "返回上级后应看到文件夹与文件")

        // 重命名与删除
        let item = try XCTUnwrap(store.items.first { $0.name == "main.swift" })
        XCTAssertTrue(store.rename(item, to: "app.swift"))
        XCTAssertTrue(store.items.contains { $0.name == "app.swift" })
        let renamed = try XCTUnwrap(store.items.first { $0.name == "app.swift" })
        XCTAssertTrue(store.delete(renamed))
        XCTAssertFalse(store.items.contains { $0.name == "app.swift" })
    }

    func testDisplayNameSanitizingRejectsBadNames() {
        let store = WorkspaceStore(root: root)
        XCTAssertNil(store.createFile(named: "   "))
        XCTAssertNil(store.createFile(named: "../evil.swift"))
        XCTAssertNil(store.createFolder(named: "a/b"))
    }

    func testResolveRejectsPathsOutsideWorkspace() {
        XCTAssertNil(WorkspaceStore.resolve(path: "/etc/passwd", root: root))
        XCTAssertNil(WorkspaceStore.resolve(path: "../escape", root: root))
        XCTAssertEqual(WorkspaceStore.resolve(path: "", root: root)?.path, root.path)
        XCTAssertEqual(
            WorkspaceStore.resolve(path: "src/main.swift", root: root)?.path,
            root.appendingPathComponent("src/main.swift").path
        )
    }

    func testTextAndImageDetection() {
        XCTAssertTrue(WorkspaceStore.isTextFile(root.appendingPathComponent("a.swift")))
        XCTAssertTrue(WorkspaceStore.isTextFile(root.appendingPathComponent("b.md")))
        XCTAssertFalse(WorkspaceStore.isTextFile(root.appendingPathComponent("c.png")))
        XCTAssertTrue(WorkspaceStore.isImageFile(root.appendingPathComponent("c.png")))
        XCTAssertFalse(WorkspaceStore.isImageFile(root.appendingPathComponent("a.swift")))
    }

    /// 智能体工具的文本结果：list / read / write / mkdir / delete 五种动作
    func testAgentPerformActions() {
        let store = WorkspaceStore(root: root)

        let written = store.perform(action: "write", path: "src/app.js", content: "console.log(1)\n")
        XCTAssertTrue(written.contains("已写入"), written)

        let listed = store.perform(action: "list", path: "src", content: "")
        XCTAssertTrue(listed.contains("app.js"), listed)

        let read = store.perform(action: "read", path: "src/app.js", content: "")
        XCTAssertTrue(read.contains("console.log(1)"), read)

        let made = store.perform(action: "mkdir", path: "docs", content: "")
        XCTAssertTrue(made.contains("已创建文件夹"), made)

        let removed = store.perform(action: "delete", path: "src/app.js", content: "")
        XCTAssertTrue(removed.contains("已删除"), removed)

        XCTAssertTrue(store.perform(action: "list", path: "src", content: "").contains("空目录"))
        XCTAssertTrue(store.perform(action: "read", path: "nope.txt", content: "").contains("不存在"))
        XCTAssertTrue(store.perform(action: "bad", path: "", content: "").contains("不支持的动作"))
        // 越界路径必须被拒绝
        XCTAssertTrue(store.perform(action: "read", path: "../state.json", content: "").contains("路径不合法"))
    }

    /// 工作区检索：search 动作返回「文件:行号: 内容」，只取相关行（省 token）
    func testAgentSearchAction() {
        let store = WorkspaceStore(root: root)
        _ = store.perform(action: "write", path: "notes/a.md", content: "第一行\n项目代号 DSH\n第三行\n")
        _ = store.perform(action: "write", path: "notes/b.md", content: "无关内容\n")

        let hit = store.perform(action: "search", path: "notes", content: "", query: "DSH")
        XCTAssertTrue(hit.contains("a.md:2"), hit)
        XCTAssertTrue(hit.contains("项目代号 DSH"), hit)
        XCTAssertFalse(hit.contains("b.md"), hit)

        let miss = store.perform(action: "search", path: "notes", content: "", query: "不存在的内容")
        XCTAssertTrue(miss.contains("没有找到"), miss)

        let empty = store.perform(action: "search", path: "notes", content: "", query: "")
        XCTAssertTrue(empty.contains("关键词"), empty)
    }

    /// 单文件内的关键词匹配：不区分大小写、行号从 1 开始、limit 生效、命中行截断
    func testSearchMatchesLines() {
        let text = "第一行\nHello World\n第三行 hello 又出现\n" + String(repeating: "长", count: 300)
        let matches = WorkspaceStore.searchMatches(in: text, query: "hello", limit: 5)
        XCTAssertEqual(matches.map(\.line), [2, 3])
        XCTAssertEqual(matches.first?.text, "Hello World")
        XCTAssertEqual(WorkspaceStore.searchMatches(in: text, query: "hello", limit: 1).count, 1)
        XCTAssertTrue(WorkspaceStore.searchMatches(in: text, query: "", limit: 5).isEmpty)

        let longLine = WorkspaceStore.searchMatches(in: text, query: "长", limit: 1)
        XCTAssertEqual(longLine.count, 1)
        XCTAssertLessThanOrEqual(
            longLine[0].text.count,
            WorkspaceStore.searchLineCharacters + 1,
            "命中行应截断到上限（含省略号）"
        )
    }
}

// MARK: - 查看画面（OCR 文本处理）

final class ScreenVisionTests: XCTestCase {

    func testTargetParsing() {
        XCTAssertEqual(ScreenVision.Target(rawValue: "screen"), .screen)
        XCTAssertEqual(ScreenVision.Target(rawValue: "browser"), .browser)
        XCTAssertNil(ScreenVision.Target(rawValue: "unknown"))
    }

    func testLongTextIsTruncated() {
        let short = "识别结果"
        XCTAssertEqual(ScreenVision.truncated(short), short)

        let long = String(repeating: "字", count: ScreenVision.maxTextLength + 100)
        let result = ScreenVision.truncated(long)
        XCTAssertTrue(result.hasPrefix(String(repeating: "字", count: 50)))
        XCTAssertTrue(result.count < long.count)
        XCTAssertTrue(result.contains("已截断"))
    }
}

// MARK: - 新增功能开关的默认值与旧数据兼容

final class FeatureFlagCompatibilityTests: XCTestCase {

    func testVisionAndFileToolsDefaultOn() {
        let flags = FeatureFlags()
        XCTAssertTrue(flags.visionTool, "查看画面默认开启（用户要求新增该能力）")
        XCTAssertTrue(flags.fileTool, "工作区文件默认开启")

        XCTAssertTrue(FeatureFlags.allOn.visionTool)
        XCTAssertTrue(FeatureFlags.allOn.fileTool)
    }

    /// 旧版本写入的设置里没有这两个开关时，解码后应取默认值而不是 false
    func testLegacyDataDecodesToDefaults() throws {
        let legacy = #"{"sessionLog":true}"#
        let decoded = try JSONDecoder().decode(FeatureFlags.self, from: Data(legacy.utf8))
        XCTAssertTrue(decoded.sessionLog)
        XCTAssertTrue(decoded.visionTool)
        XCTAssertTrue(decoded.fileTool)
        XCTAssertTrue(decoded.mcpTool)
        XCTAssertTrue(decoded.skillTool)
        XCTAssertTrue(decoded.autoCompact)
    }

    func testMCPToolDefaultsOn() {
        XCTAssertTrue(FeatureFlags().mcpTool)
        XCTAssertTrue(FeatureFlags.allOn.mcpTool)
        XCTAssertTrue(FeatureFlags().clipboardTool)
        XCTAssertTrue(FeatureFlags().reminderTool)
        XCTAssertTrue(FeatureFlags.allOn.clipboardTool)
        XCTAssertTrue(FeatureFlags.allOn.reminderTool)
    }
}

// MARK: - 剪贴板 / 提醒事项工具

final class SystemToolsTests: XCTestCase {

    /// 两个新工具各自独立下发，默认不下发
    func testClipboardAndReminderFollowFlags() {
        let defaults = AgentToolCatalog.tools(sshEnabled: false, browserEnabled: false, browserReadEnabled: false)
        XCTAssertTrue(defaults.isEmpty, "默认不应下发任何工具")

        let list = AgentToolCatalog.tools(
            sshEnabled: false,
            browserEnabled: false,
            browserReadEnabled: false,
            clipboardEnabled: true,
            reminderEnabled: true
        )
        XCTAssertEqual(list.map(\.name), [AgentToolCatalog.clipboardName, AgentToolCatalog.reminderName])

        // 剪贴板支持 read / write 两种动作
        let clipboard = try? XCTUnwrap(list.first)
        let properties = clipboard?.parameters["properties"] as? [String: Any]
        let action = properties?["action"] as? [String: Any]
        XCTAssertEqual(action?["enum"] as? [String], ["read", "write"])

        // 提醒工具覆盖提醒与日历四类动作
        let reminder = list.last
        let reminderProperties = reminder?.parameters["properties"] as? [String: Any]
        let reminderAction = reminderProperties?["action"] as? [String: Any]
        XCTAssertEqual(
            reminderAction?["enum"] as? [String],
            ["list_reminders", "create_reminder", "list_events", "create_event"]
        )
    }

    /// 时间写法解析：支持常见格式，只给日期时按 09:00
    func testParseDateVariants() throws {
        let calendar = Calendar.current

        func parts(_ text: String) throws -> [Int?] {
            let date = try XCTUnwrap(RemindersService.parseDate(text), "应能解析：\(text)")
            let components = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
            return [components.year, components.month, components.day, components.hour, components.minute]
        }

        XCTAssertEqual(try parts("2026-10-10 09:30"), [2026, 10, 10, 9, 30])
        XCTAssertEqual(try parts("2026-10-10"), [2026, 10, 10, 9, 0])
        XCTAssertEqual(try parts("2026/10/10 15:00"), [2026, 10, 10, 15, 0])
        XCTAssertEqual(try parts("2026年10月10日 15:00"), [2026, 10, 10, 15, 0])
        XCTAssertEqual(try parts("2026-10-10T15:00"), [2026, 10, 10, 15, 0])

        // 只给时间：按今天算
        let timeOnly = try XCTUnwrap(RemindersService.parseDate("08:15"))
        let timeParts = calendar.dateComponents([.hour, .minute], from: timeOnly)
        XCTAssertEqual([timeParts.hour, timeParts.minute], [8, 15])

        XCTAssertNil(RemindersService.parseDate("明天"))
        XCTAssertNil(RemindersService.parseDate(""))
    }
}

// MARK: - 上下文压缩

final class ContextCompactorTests: XCTestCase {

    private func message(_ role: MessageRole, _ text: String) -> ChatMessage {
        ChatMessage(role: role, content: text)
    }

    /// 中文按字、英文按 4 字符估算
    func testTokenEstimator() {
        XCTAssertEqual(TokenEstimator.estimate("你好世界"), 4)
        XCTAssertEqual(TokenEstimator.estimate("abcdefgh"), 2)
        XCTAssertEqual(TokenEstimator.estimate(""), 0)
        XCTAssertGreaterThan(TokenEstimator.estimate(String(repeating: "字", count: 100)), 90)
        // 工具调用与图片会额外计入
        var withCall = message(.assistant, "")
        withCall.toolCalls = [ToolCall(id: "1", name: "ssh_exec", arguments: #"{"command":"ls"}"#)]
        XCTAssertGreaterThan(TokenEstimator.estimate(message: withCall), TokenEstimator.messageOverhead)
    }

    /// 太短的对话不压缩
    func testShortConversationSkipsCompaction() {
        let model = DSHModel.catalog[0]
        let messages = (0..<4).map { message($0 % 2 == 0 ? .user : .assistant, String(repeating: "字", count: 200)) }
        XCTAssertFalse(ContextCompactor.needsCompaction(messages, model: model))
    }

    /// 长对话触发压缩：保留最近一段、摘要更早的历史，且保留段从用户消息开始
    func testCompactionPlanKeepsRecentAndStartsAtUser() throws {
        let model = DSHModel.catalog[0]
        var messages: [ChatMessage] = []
        for index in 0..<40 {
            messages.append(message(index % 2 == 0 ? .user : .assistant, String(repeating: "字", count: 5_000)))
        }
        XCTAssertTrue(ContextCompactor.needsCompaction(messages, model: model))

        let plan = try XCTUnwrap(ContextCompactor.plan(for: messages, keepBudget: 20_000))
        XCTAssertFalse(plan.summarized.isEmpty)
        XCTAssertFalse(plan.kept.isEmpty)
        XCTAssertEqual(plan.kept.first?.role, .user, "保留段必须从用户消息开始")
        XCTAssertEqual(plan.kept.last?.id, messages.last?.id, "最后一条必须保留")
        XCTAssertGreaterThan(plan.freedTokens, 0)
        // 压缩后总量应明显小于压缩前
        let after = TokenEstimator.estimate(messages: plan.kept) + ContextCompactor.summaryTokens
        XCTAssertLessThan(after, TokenEstimator.estimate(messages: messages))
    }

    /// 保留段不会以工具结果开头（工具调用与它的结果不能被拆开）
    func testPlanNeverStartsKeptPartWithToolMessage() throws {
        var messages: [ChatMessage] = []
        for index in 0..<10 {
            messages.append(message(.user, String(repeating: "字", count: 2_000) + "\(index)"))
            var assistant = message(.assistant, "")
            assistant.toolCalls = [ToolCall(id: "call-\(index)", name: "ssh_exec", arguments: "{}")]
            messages.append(assistant)
            var tool = message(.tool, "结果 \(index)")
            tool.toolCallID = "call-\(index)"
            tool.toolName = "ssh_exec"
            messages.append(tool)
        }
        let plan = try XCTUnwrap(ContextCompactor.plan(for: messages, keepBudget: 4_000))
        XCTAssertEqual(plan.kept.first?.role, .user)
        // 被压缩的那一段可以以工具结果结尾（整段都不会再进上下文），保留段则以用户消息开头
        XCTAssertLessThanOrEqual(plan.kept.count, 6)
    }

    /// 手动压缩：未达自动阈值时也应给出方案（只压掉较早的几条）
    func testManualPlanWorksBelowThreshold() throws {
        let messages = (0..<8).map { message($0 % 2 == 0 ? .user : .assistant, String(repeating: "字", count: 600)) }
        // 未达阈值：自动压缩不触发
        XCTAssertFalse(ContextCompactor.needsCompaction(messages, model: DSHModel.catalog[0]))

        let plan = try XCTUnwrap(ContextCompactor.plan(for: messages, keepBudget: 2_000, minSummarized: 2))
        XCTAssertEqual(plan.kept.first?.role, .user)
        XCTAssertGreaterThanOrEqual(plan.summarized.count, 2)
        XCTAssertEqual(plan.kept.last?.id, messages.last?.id)

        // 只有两轮对话时连手动压缩也不做（保留段之外凑不出两条历史）
        let tiny = (0..<4).map { message($0 % 2 == 0 ? .user : .assistant, String(repeating: "字", count: 600)) }
        XCTAssertNil(ContextCompactor.plan(for: tiny, keepBudget: 2_000, minSummarized: 2))
    }

    /// 摘要请求与注入文本
    func testSummaryMessagesAndInjection() {
        let messages = [
            message(.user, "帮我读一下 README"),
            message(.assistant, "读完了，内容是 DSH iOS 客户端")
        ]
        let request = ContextCompactor.summaryMessages(for: messages)
        XCTAssertEqual(request.count, 2)
        XCTAssertEqual(request.first?.role, "system")
        XCTAssertTrue(request.last?.content.contains("用户：帮我读一下 README") == true)
        XCTAssertTrue(request.last?.content.contains("助手：读完了") == true)

        let injected = ContextCompactor.injectedContent("要点一")
        XCTAssertTrue(injected.contains(ContextCompactor.summaryHeader))
        XCTAssertTrue(injected.hasSuffix("要点一"))
    }

    /// 模型返回带外壳时要去掉，卡片里只显示正文
    func testSummaryContentTrimsHeader() {
        let raw = ContextCompactor.summaryHeader + "\n\n- 要点一\n- 要点二"
        XCTAssertEqual(ContextCompactor.summaryContent(from: raw), "- 要点一\n- 要点二")
        XCTAssertEqual(ContextCompactor.summaryContent(from: "  直接给摘要  "), "直接给摘要")
    }

    /// 摘要标记能过一遍 Codable；老数据没有该字段时不影响解码
    func testSummaryFlagRoundTrip() throws {
        var summary = ChatMessage(role: .assistant, content: "摘要")
        summary.isContextSummary = true
        let decoded = try JSONDecoder().decode(ChatMessage.self, from: try JSONEncoder().encode(summary))
        XCTAssertEqual(decoded.isContextSummary, true)

        let legacy = #"{"id":"\#(UUID().uuidString)","role":"assistant","content":"旧消息","createdAt":0,"isStreaming":false}"#
        let old = try JSONDecoder().decode(ChatMessage.self, from: Data(legacy.utf8))
        XCTAssertNil(old.isContextSummary)
        XCTAssertEqual(old.content, "旧消息")
    }

    /// 窗口越大越不容易触发压缩；模型窗口按模型区分
    func testLargerWindowDelaysCompaction() {
        var messages: [ChatMessage] = []
        for index in 0..<20 {
            messages.append(message(index % 2 == 0 ? .user : .assistant, String(repeating: "字", count: 4_000)))
        }
        let small = DSHModel(id: "small", name: "Small", contextWindow: 32_768)
        let large = DSHModel(id: "large", name: "Large", contextWindow: 262_144)
        XCTAssertTrue(ContextCompactor.needsCompaction(messages, model: small))
        XCTAssertFalse(ContextCompactor.needsCompaction(messages, model: large))
        XCTAssertEqual(DSHModel.describe(id: "deepseek-flash").contextWindow, 131_072)
    }
}

// MARK: - 工具调用配对修复

final class ToolCallRepairTests: XCTestCase {

    private func assistant(_ text: String, calls: [(String, String)] = []) -> ChatMessage {
        ChatMessage(
            role: .assistant,
            content: text,
            toolCalls: calls.map { ToolCall(id: $0.0, name: $0.1, arguments: "{}") }
        )
    }

    private func tool(_ callID: String, _ text: String) -> ChatMessage {
        ChatMessage(role: .tool, content: text, toolCallID: callID, toolName: "workspace")
    }

    /// 完整的配对保持不变
    func testCompletePairIsUntouched() {
        let messages: [ChatMessage] = [
            ChatMessage(role: .user, content: "查一下"),
            assistant("先查", calls: [("1", "workspace")]),
            tool("1", "结果一"),
            assistant("结论")
        ]
        let repaired = ToolCallRepair.repaired(messages)
        XCTAssertEqual(repaired.count, messages.count)
        XCTAssertEqual(repaired[1].toolCalls?.count, 1)
    }

    /// 工具消息为空 → 补占位（否则发送时会被跳过，配对又缺了）
    func testEmptyToolResultGetsPlaceholder() {
        let messages: [ChatMessage] = [
            ChatMessage(role: .user, content: "查一下"),
            assistant("先查", calls: [("1", "workspace")]),
            tool("1", "   ")
        ]
        let repaired = ToolCallRepair.repaired(messages)
        XCTAssertEqual(repaired.count, 3)
        XCTAssertEqual(repaired[2].content, ToolCallRepair.missingResult)
    }

    /// 调用完全没有结果（中途停止）→ 去掉调用，避免 400
    func testDanglingCallsAreStripped() {
        let messages: [ChatMessage] = [
            ChatMessage(role: .user, content: "查一下"),
            assistant("先查", calls: [("1", "workspace"), ("2", "workspace")]),
            ChatMessage(role: .user, content: "继续"),
            assistant("结论")
        ]
        let repaired = ToolCallRepair.repaired(messages)
        XCTAssertNil(repaired[1].toolCalls, "缺少结果的调用应被移除")
        XCTAssertFalse(repaired.contains { $0.role == .tool })
        XCTAssertEqual(repaired.filter { $0.role == .assistant }.count, 2, "助手正文要保留")
    }

    /// 部分调用有结果 → 只保留有结果的那些
    func testPartialCallsKeepAnsweredOnes() {
        let messages: [ChatMessage] = [
            ChatMessage(role: .user, content: "查一下"),
            assistant("先查", calls: [("1", "workspace"), ("2", "browser")]),
            tool("1", "结果一")
        ]
        let repaired = ToolCallRepair.repaired(messages)
        XCTAssertEqual(repaired[1].toolCalls?.map(\.id), ["1"])
        XCTAssertEqual(repaired.count, 3, "有结果的工具消息保留")
    }

    /// 孤儿工具消息（前面没有对应调用）直接删除
    func testOrphanToolMessageIsDropped() {
        let messages: [ChatMessage] = [
            ChatMessage(role: .user, content: "你好"),
            assistant("直接回答，不调用工具", calls: []),
            tool("9", "不该存在的工具结果")
        ]
        let repaired = ToolCallRepair.repaired(messages)
        XCTAssertEqual(repaired.count, 2)
        XCTAssertFalse(repaired.contains { $0.role == .tool })
    }

    /// 用户报错场景的回归：停止过的一轮 + 继续对话，修复后序列里不再有孤立调用
    func testUserReportedScenarioIsRepaired() {
        let messages: [ChatMessage] = [
            ChatMessage(role: .user, content: "看看 gitee 上的项目"),
            assistant("先读两个网页", calls: [("call-a", "browser"), ("call-b", "browser")]),
            tool("call-a", "网页一的内容"),
            // call-b 因用户点了停止而没有结果
            ChatMessage(role: .user, content: "你好"),
            assistant("你好，有什么可以帮你？")
        ]
        let repaired = ToolCallRepair.repaired(messages)
        let assistantWithCalls = repaired.first { !($0.toolCalls ?? []).isEmpty }
        XCTAssertEqual(assistantWithCalls?.toolCalls?.map(\.id), ["call-a"], "只保留有结果的调用")
        // 每个调用都能在紧随其后的工具消息里找到响应
        for (index, message) in repaired.enumerated() where !(message.toolCalls ?? []).isEmpty {
            var cursor = index + 1
            var answered: Set<String> = []
            while cursor < repaired.count, repaired[cursor].role == .tool {
                answered.insert(repaired[cursor].toolCallID ?? "")
                cursor += 1
            }
            XCTAssertTrue(Set((message.toolCalls ?? []).map(\.id)).isSubset(of: answered), "配对必须完整")
        }
    }
}

// MARK: - 一轮回复的最终回复判定

final class FinalReplyTests: XCTestCase {

    private func assistant(_ text: String, calls: [ToolCall]? = nil) -> ChatMessage {
        ChatMessage(role: .assistant, content: text, toolCalls: calls)
    }

    /// 普通一轮：唯一的助手回复就是最终回复
    func testSingleReplyIsFinal() {
        let messages: [ChatMessage] = [
            ChatMessage(role: .user, content: "你好"),
            assistant("你好，有什么可以帮你？")
        ]
        XCTAssertEqual(messages.finalReplyIDs, [messages[1].id])
    }

    /// 工具调用轮：中间回复不算最终回复，只有最后一条助手才是
    func testToolRoundsOnlyLastAssistantIsFinal() {
        let intermediate = assistant("先查一下", calls: [ToolCall(id: "1", name: "workspace", arguments: "{}")])
        let final = assistant("结论如下")
        let messages: [ChatMessage] = [
            ChatMessage(role: .user, content: "查一下"),
            intermediate,
            ChatMessage(role: .tool, content: "结果", toolCallID: "1", toolName: "workspace"),
            final
        ]
        XCTAssertEqual(messages.finalReplyIDs, [final.id], "中间回复不应算最终回复")
        XCTAssertFalse(messages.finalReplyIDs.contains(intermediate.id))
    }

    /// 多轮对话：每一轮的最终回复都保留（历史回复仍可复制/点赞）
    func testEachTurnKeepsItsFinalReply() {
        let first = assistant("第一轮回答")
        let second = assistant("第二轮回答")
        let messages: [ChatMessage] = [
            ChatMessage(role: .user, content: "Q1"),
            first,
            ChatMessage(role: .user, content: "Q2"),
            second
        ]
        XCTAssertEqual(messages.finalReplyIDs, [first.id, second.id])
    }

    /// 正在生成的空助手消息不算最终回复（要等生成结束）
    func testStreamingPlaceholderIsNotFinal() {
        var placeholder = assistant("")
        placeholder.isStreaming = true
        let messages: [ChatMessage] = [ChatMessage(role: .user, content: "Q"), placeholder]
        // 算法本身只看角色顺序，界面再叠加「生成已停止」的判断
        XCTAssertEqual(messages.finalReplyIDs, [placeholder.id])
        XCTAssertTrue(placeholder.isStreaming)
    }
}

// MARK: - 权限中心

final class PermissionCenterTests: XCTestCase {

    /// 权限清单覆盖提醒事项 / 日历 / 剪贴板 / 本地网络 / 网络 / 照片 / 文件
    @MainActor
    func testPermissionItemsCoverAppNeeds() {
        let center = PermissionCenter()
        let ids = center.items.map(\.id)
        XCTAssertEqual(ids, ["reminders", "calendar", "clipboard", "localNetwork", "internet", "photos", "files"])

        // 只有提醒事项 / 日历 / 剪贴板可以主动申请，其余展示为无需授权或使用时询问
        let requestable = center.items.filter(\.canRequest).map(\.id)
        XCTAssertEqual(requestable, ["reminders", "calendar", "clipboard"])

        let notRequired = center.items.filter { $0.status == .notRequired }.map(\.id)
        XCTAssertEqual(notRequired, ["internet", "photos", "files"])

        // 状态文案与「是否就绪」一一对应
        XCTAssertTrue(PermissionCenter.Status.granted.isSatisfied)
        XCTAssertTrue(PermissionCenter.Status.notRequired.isSatisfied)
        XCTAssertFalse(PermissionCenter.Status.denied.isSatisfied)
        XCTAssertFalse(PermissionCenter.Status.notDetermined.isSatisfied)
        XCTAssertEqual(PermissionCenter.Status.systemPrompt.title, "使用时询问")
    }

    /// 首次启动引导标记可读写（UI 测试用它控制引导是否弹出）
    @MainActor
    func testPrimerFlagRoundTrip() {
        let center = PermissionCenter()
        let original = center.hasPrimed
        defer { center.hasPrimed = original }

        center.hasPrimed = false
        XCTAssertFalse(center.hasPrimed)
        center.hasPrimed = true
        XCTAssertTrue(center.hasPrimed)
    }
}

// MARK: - MCP 客户端（JSON-RPC over Streamable HTTP）

final class MCPClientTests: XCTestCase {

    private func makeClient(_ url: String = "https://mcp.example.com/mcp") throws -> MCPClient {
        var config = MCPServerConfig(name: "示例", urlString: url)
        config.headerLines = "Authorization: Bearer token-1"
        return try MCPClient(config: config, session: URLSession(configuration: MockURLProtocol.configuration))
    }

    /// 握手：initialize 请求格式正确、解析 SSE 结果、记住会话 id 并在后续请求里带上
    func testInitializeHandshakeAndSessionHeader() async throws {
        var requests: [String] = []
        MockURLProtocol.handler = { request in
            let body = MockURLProtocol.body(of: request) ?? Data()
            if let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any] {
                requests.append(object["method"] as? String ?? "")
            }
            let headers = [
                "Content-Type": "text/event-stream",
                "Mcp-Session-Id": "session-42"
            ]
            let payload: String
            if requests.last == "initialize" {
                payload = """
                {"jsonrpc":"2.0","id":1,"result":{"protocolVersion":"2025-03-26","capabilities":{"tools":{},"prompts":{"listChanged":true}},"serverInfo":{"name":"Demo","version":"1.2"},"instructions":"示例服务"}}
                """
            } else {
                payload = #"{"jsonrpc":"2.0","id":2,"result":{"tools":[]}}"#
            }
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: headers
            )!
            return (response, Data("event: message\ndata: \(payload)\n\n".utf8))
        }

        let client = try makeClient()
        try await client.connect()
        XCTAssertEqual(client.negotiatedVersion, "2025-03-26")
        XCTAssertEqual(client.serverName, "Demo")
        XCTAssertEqual(client.instructions, "示例服务")
        XCTAssertTrue(client.supports("prompts"))
        XCTAssertTrue(client.isConnected)
        XCTAssertEqual(requests.first, "initialize")

        // 握手后应自动发送 initialized 通知（无 id）
        XCTAssertTrue(requests.contains("notifications/initialized"))
        // 通知与后续请求都要带上会话头
        _ = try await client.listTools()
        XCTAssertTrue(requests.contains("tools/list"))
    }

    /// 通知请求不应携带 id（JSON-RPC 通知）
    func testInitializedNotificationHasNoID() async throws {
        var notificationBody: [String: Any] = [:]
        MockURLProtocol.handler = { request in
            let body = MockURLProtocol.body(of: request) ?? Data()
            let object = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:]
            if object["method"] as? String == "notifications/initialized" {
                notificationBody = object
            }
            let payload = #"{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":"2025-03-26","capabilities":{},"serverInfo":{"name":"Demo","version":"1"}}}"#
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "text/event-stream"])!
            return (response, Data("data: \(payload)\n\n".utf8))
        }

        let client = try makeClient()
        try await client.connect()
        XCTAssertEqual(notificationBody["method"] as? String, "notifications/initialized")
        XCTAssertNil(notificationBody["id"], "通知不应带 id")
    }

    /// tools/list：解析名称、说明与 inputSchema
    func testListToolsParsesSchema() async throws {
        MockURLProtocol.handler = { request in
            let payload = """
            {"jsonrpc":"2.0","id":1,"result":{"tools":[{"name":"search","description":"搜索资料","inputSchema":{"type":"object","properties":{"q":{"type":"string"}},"required":["q"]}}]}}
            """
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "text/event-stream"])!
            return (response, Data("event: message\ndata: \(payload)\n\n".utf8))
        }

        let client = try makeClient()
        let tools = try await client.listTools()
        XCTAssertEqual(tools.count, 1)
        XCTAssertEqual(tools[0].name, "search")
        XCTAssertEqual(tools[0].description, "搜索资料")
        let properties = tools[0].parameters["properties"] as? [String: Any]
        XCTAssertNotNil(properties?["q"])
    }

    /// tools/call：文本内容拼接返回，图片等非文本内容转成说明
    func testCallToolFlattensContent() async throws {
        try await callToolAndAssert(
            content: #"[{"type":"text","text":"第一段"},{"type":"text","text":"第二段"},{"type":"image","mimeType":"image/png","data":"aGk="}]"#,
            expecting: ["第一段", "第二段", "图片"]
        )
    }

    /// 服务端把执行失败放在 result.isError 里时，也要明确告诉模型
    func testCallToolErrorFlag() async throws {
        try await callToolAndAssert(
            content: #"[{"type":"text","text":"参数不合法"}]"#,
            isError: true,
            expecting: ["工具执行出错", "参数不合法"]
        )
    }

    private func callToolAndAssert(content: String, isError: Bool = false, expecting fragments: [String]) async throws {
        MockURLProtocol.handler = { request in
            let body = MockURLProtocol.body(of: request) ?? Data()
            let object = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:]
            XCTAssertEqual(object["method"] as? String, "tools/call")
            let params = object["params"] as? [String: Any] ?? [:]
            XCTAssertEqual(params["name"] as? String, "search")
            let payload = #"{"jsonrpc":"2.0","id":\#(object["id"] ?? 1),"result":{"content":\#(content),"isError":\#(isError ? "true" : "false")}}"#
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
            return (response, Data(payload.utf8))
        }

        let client = try makeClient()
        let output = try await client.callTool(name: "search", argumentsJSON: #"{"q":"天气"}"#)
        for fragment in fragments {
            XCTAssertTrue(output.contains(fragment), "结果应包含「\(fragment)」：\(output)")
        }
    }

    /// JSON-RPC 错误应带出 code 与 message
    func testRPCErrorSurfaces() async throws {
        MockURLProtocol.handler = { request in
            let payload = #"{"jsonrpc":"2.0","id":1,"error":{"code":-32602,"message":"Invalid request parameters"}}"#
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "text/event-stream"])!
            return (response, Data("data: \(payload)\n\n".utf8))
        }

        let client = try makeClient()
        do {
            _ = try await client.listTools()
            XCTFail("应抛出 MCP 错误")
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? ""
            XCTAssertTrue(message.contains("-32602"), message)
            XCTAssertTrue(message.contains("Invalid request parameters"), message)
        }
    }

    /// HTTP 层错误（例如 401）应给出带状态码的说明
    func testHTTPErrorSurfaces() async throws {
        MockURLProtocol.handler = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 401, httpVersion: nil, headerFields: nil)!
            return (response, Data("unauthorized".utf8))
        }

        let client = try makeClient()
        do {
            try await client.connect()
            XCTFail("应抛出 HTTP 错误")
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? ""
            XCTAssertTrue(message.contains("401"), message)
        }
    }

    /// 非 http(s) 地址直接拒绝
    func testInvalidURLIsRejected() {
        var config = MCPServerConfig(name: "坏地址", urlString: "ftp://example.com")
        config.headerLines = ""
        XCTAssertThrowsError(try MCPClient(config: config))
    }
}

// MARK: - MCP 服务器管理

final class MCPStoreTests: XCTestCase {

    private func makeStore() -> MCPStore {
        MCPStore(fileName: "mcp-test-\(UUID().uuidString).json")
    }

    func testAddValidatesAndPersists() {
        let store = makeStore()
        XCTAssertNil(store.add(name: "", urlString: "https://a.com/mcp"), "名称为空应拒绝")
        XCTAssertNil(store.add(name: "A", urlString: "ftp://a.com"), "非 http(s) 地址应拒绝")

        let server = store.add(name: "DeepWiki 文档", urlString: "https://mcp.deepwiki.com/mcp")
        XCTAssertNotNil(server)
        XCTAssertEqual(store.servers.count, 1)
        XCTAssertEqual(server?.alias, "deepwiki")   // 中文与空格被清洗掉，保留 ASCII 部分
    }

    /// 别名要互不重复：同名服务器自动加序号
    func testAliasUniqueness() {
        let store = makeStore()
        store.add(name: "demo", urlString: "https://a.example.com/mcp")
        store.add(name: "demo", urlString: "https://b.example.com/mcp")
        XCTAssertEqual(store.servers.map(\.alias), ["demo", "demo2"])
    }

    /// 换取请求头：多行 "Key: Value"
    func testHeaderParsing() {
        let config = MCPServerConfig(
            name: "带鉴权",
            urlString: "https://a.example.com/mcp",
            headerLines: "Authorization: Bearer abc\n\nX-Trace: 1\n错误行没有冒号"
        )
        let headers = config.headers
        XCTAssertEqual(headers["Authorization"], "Bearer abc")
        XCTAssertEqual(headers["X-Trace"], "1")
        XCTAssertEqual(headers.count, 2)
    }

    /// 模型侧工具名清洗与长度限制
    func testModelToolNaming() {
        XCTAssertEqual(
            MCPStore.modelToolName(alias: "deepwiki", tool: "read-wiki"),
            "mcp_deepwiki_read_wiki"
        )
        let long = MCPStore.modelToolName(alias: "server", tool: String(repeating: "x", count: 120))
        XCTAssertLessThanOrEqual(long.count, 64)
    }

    /// 工具名里的连字符会被清洗成下划线，路由必须仍能还原成服务端的原始工具名
    func testRouteRestoresOriginalToolName() throws {
        let store = makeStore()
        let server = try XCTUnwrap(store.add(name: "DeepWiki", urlString: "https://mcp.deepwiki.com/mcp"))
        store.update(id: server.id) { config in
            config.tools = [MCPToolInfo(name: "read-wiki-structure", description: "结构", schemaJSON: "{}")]
        }
        let route = try XCTUnwrap(store.route(forModelToolName: "mcp_deepwiki_read_wiki_structure"))
        XCTAssertEqual(route.tool, "read-wiki-structure")
        XCTAssertEqual(route.server.id, server.id)
        XCTAssertNil(store.route(forModelToolName: "mcp_unknown_tool"))
    }

    /// 下发给模型的工具：名称带前缀、说明带服务器名、参数来自 inputSchema
    func testAvailableToolsMapping() throws {
        let store = makeStore()
        let server = try XCTUnwrap(store.add(name: "DeepWiki", urlString: "https://mcp.deepwiki.com/mcp"))
        store.update(id: server.id) { config in
            config.tools = [
                MCPToolInfo(
                    name: "ask",
                    description: "提问",
                    schemaJSON: #"{"type":"object","properties":{"q":{"type":"string"}}}"#
                )
            ]
        }

        let tools = store.availableTools()
        XCTAssertEqual(tools.count, 1)
        XCTAssertEqual(tools[0].name, "mcp_deepwiki_ask")
        XCTAssertTrue(tools[0].description.contains("DeepWiki"))
        XCTAssertTrue(tools[0].description.contains("提问"))
        XCTAssertNotNil(tools[0].parameters["properties"])

        // 关闭服务器后不再下发
        store.setEnabled(false, id: server.id)
        XCTAssertTrue(store.availableTools().isEmpty)
    }

    /// 落盘后重新读取应一致（含工具缓存）
    func testPersistenceRoundTrip() throws {
        let name = "mcp-test-\(UUID().uuidString).json"
        let store = MCPStore(fileName: name)
        let server = try XCTUnwrap(store.add(name: "Demo", urlString: "https://a.example.com/mcp", headerLines: "X-A: 1"))
        store.update(id: server.id) { config in
            config.tools = [MCPToolInfo(name: "ping", description: "心跳", schemaJSON: "{}")]
            config.lastConnectedAt = Date()
        }

        let reloaded = MCPStore(fileName: name)
        XCTAssertEqual(reloaded.servers.count, 1)
        XCTAssertEqual(reloaded.servers[0].name, "Demo")
        XCTAssertEqual(reloaded.servers[0].tools.map(\.name), ["ping"])
        XCTAssertEqual(reloaded.servers[0].headers["X-A"], "1")
        XCTAssertNotNil(reloaded.servers[0].lastConnectedAt)

        let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent(name)
        try? FileManager.default.removeItem(at: url)
    }
}

// MARK: - MCP 工具接入智能体

final class MCPAgentIntegrationTests: XCTestCase {

    /// MCP 工具按顺序追加在其它工具之后，前缀识别用于路由
    func testMCPToolsAreAppendedAfterBuiltins() {
        let tool = APITool(name: "mcp_demo_search", description: "[MCP · Demo] 搜索", parameters: [:])
        let list = AgentToolCatalog.tools(
            sshEnabled: true,
            browserEnabled: false,
            browserReadEnabled: false,
            mcpTools: [tool],
            skillNames: ["周报整理"]
        )
        XCTAssertEqual(list.map(\.name), ["ssh_exec", "mcp_demo_search", AgentToolCatalog.skillName])
        XCTAssertTrue(AgentToolCatalog.isMCPTool("mcp_demo_search"))
        XCTAssertFalse(AgentToolCatalog.isMCPTool("ssh_exec"))
    }

    /// 过程面板把 MCP 调用合并为「调用 N 次 MCP 工具」
    func testProcessSummaryCountsMCPCalls() {
        var message = ChatMessage(role: .assistant, content: "好了")
        message.toolCalls = [
            ToolCall(id: "1", name: "mcp_demo_search", arguments: #"{"q":"天气"}"#),
            ToolCall(id: "2", name: "mcp_demo_search", arguments: #"{"q":"新闻"}"#)
        ]
        let process = ChatProcess(message: message, toolMessages: [])
        XCTAssertEqual(process.summary, "已调用 2 次 MCP 工具")
        XCTAssertEqual(process.steps.first?.title, "MCP 工具")
    }
}

// MARK: - 工具结果老化（省 token）

final class ToolOutputAgingTests: XCTestCase {

    private func message(_ role: MessageRole, _ text: String) -> ChatMessage {
        ChatMessage(role: role, content: text)
    }

    /// 较早轮次的工具结果发送前只剩开头摘要；当前轮（最后一条用户消息之后）完整保留
    func testAgesOnlyPreviousTurns() {
        let long = String(repeating: "字", count: 1_000)
        var oldTool = message(.tool, long)
        oldTool.toolCallID = "old"
        var newTool = message(.tool, long)
        newTool.toolCallID = "new"
        let messages: [ChatMessage] = [
            message(.user, "第一轮"),
            oldTool,
            message(.assistant, "第一轮答复"),
            message(.user, "第二轮"),
            newTool,
            message(.assistant, "")
        ]

        let aged = ToolOutputAging.aged(messages)
        // 较早轮次：开头摘要 + 省略说明，长度明显变小
        XCTAssertTrue(aged[1].content.hasPrefix(String(repeating: "字", count: ToolOutputAging.excerptCharacters)))
        XCTAssertTrue(aged[1].content.contains("较早的工具结果已省略"))
        XCTAssertLessThan(aged[1].content.count, long.count)
        // 当前轮的工具结果完整保留
        XCTAssertEqual(aged[4].content, long)
        // 用户与助手消息不受影响
        XCTAssertEqual(aged[0].content, "第一轮")
        XCTAssertEqual(aged[2].content, "第一轮答复")
    }

    /// 较早轮次工具结果上的截图不再重复发送；当前轮的截图保留
    func testDropsOldToolImages() {
        let attachment = ChatAttachment(fileName: "shot.jpg")
        var oldTool = message(.tool, "较早结果")
        oldTool.attachments = [attachment]
        var newTool = message(.tool, "当前结果")
        newTool.attachments = [attachment]
        let messages: [ChatMessage] = [
            message(.user, "第一轮"),
            oldTool,
            message(.user, "第二轮"),
            newTool
        ]

        let aged = ToolOutputAging.aged(messages)
        XCTAssertNil(aged[1].attachments, "较早轮次工具结果上的截图不应再发送")
        XCTAssertEqual(aged[3].attachments?.count, 1, "当前轮的截图应保留（视觉模型需要看）")
        // 老化不改动原数组
        XCTAssertEqual(messages[1].attachments?.count, 1)
    }

    /// 没有用户消息时不做任何处理（防御性）
    func testNoUserMessageIsUntouched() {
        let messages = [message(.assistant, "你好"), message(.tool, String(repeating: "字", count: 1_000))]
        XCTAssertEqual(ToolOutputAging.aged(messages).map(\.content), messages.map(\.content))
    }

    /// 工具输出兜底上限：超长输出会被截断并附说明，短输出原样返回
    func testLimitedToolOutput() {
        let short = String(repeating: "a", count: 100)
        XCTAssertEqual(ChatEngine.limitedToolOutput(short), short)

        let long = String(repeating: "a", count: ChatEngine.maxToolOutputCharacters + 500)
        let limited = ChatEngine.limitedToolOutput(long)
        XCTAssertTrue(limited.hasPrefix(String(repeating: "a", count: ChatEngine.maxToolOutputCharacters)))
        XCTAssertTrue(limited.contains("输出过长，已省略 500 字"))
    }

    /// 单轮工具输出预算：预算内原样返回；超出后收紧截断并累计，用尽后每条固定收紧
    func testToolOutputBudget() {
        var budget = ToolOutputBudget()
        let small = String(repeating: "a", count: 1_000)
        XCTAssertEqual(budget.limit(small), small)
        XCTAssertEqual(budget.usedCharacters, 1_000)

        // 一次超预算的大输出：按剩余额度截断
        let huge = String(repeating: "b", count: 100_000)
        let limited = budget.limit(huge)
        XCTAssertTrue(limited.hasPrefix(String(repeating: "b", count: ToolOutputBudget.totalCharacters - 1_000)))
        XCTAssertTrue(limited.contains("已收紧截断"))
        XCTAssertEqual(budget.usedCharacters, ToolOutputBudget.totalCharacters)

        // 预算用尽后：每条收紧到固定上限，仍会累计
        let another = String(repeating: "c", count: 10_000)
        let tightened = budget.limit(another)
        XCTAssertTrue(tightened.hasPrefix(String(repeating: "c", count: ToolOutputBudget.tightenedCharacters)))
        XCTAssertEqual(budget.usedCharacters, ToolOutputBudget.totalCharacters + ToolOutputBudget.tightenedCharacters)
    }
}

// MARK: - 云端推理

final class CloudAgentTests: XCTestCase {

    /// 随机令牌：32 位十六进制且互不相同
    func testRandomToken() {
        let token = CloudStore.randomToken()
        XCTAssertEqual(token.count, 32)
        XCTAssertTrue(token.allSatisfy { $0.isHexDigit })
        XCTAssertNotEqual(CloudStore.randomToken(), token)
    }

    /// 部署脚本：包含源码落盘、python 兜底、端口与令牌、本机健康检查
    func testDeployScriptContainsEssentials() {
        let source = "print('hi')\n# 源码里的 DSH_AGENT_EOF 字样不会误结束"
        let script = CloudDeploy.script(source: source, port: 8931, token: "abc123")
        XCTAssertTrue(script.contains("mkdir -p $HOME/.dsh/sandboxes"))
        XCTAssertTrue(script.contains("cat > $HOME/.dsh/dsh-agent.py <<'DSH_AGENT_EOF'"))
        XCTAssertTrue(script.contains(source))
        XCTAssertTrue(script.contains("command -v python3"))
        XCTAssertTrue(script.contains("--port 8931 --token abc123"))
        XCTAssertTrue(script.contains("http://127.0.0.1:8931/health"))
    }

    /// 部署结果判定：成功输出 / python 缺失
    func testDeployResultDetection() {
        XCTAssertTrue(CloudDeploy.succeeded(#"{"ok": true, "version": "1.0"}"#))
        XCTAssertFalse(CloudDeploy.succeeded("bash: python: command not found"))
        XCTAssertTrue(CloudDeploy.missingPython("__DSH_NO_PYTHON__"))
        XCTAssertFalse(CloudDeploy.missingPython("ok"))
    }

    /// 事件批次解码（与 Agent 返回格式一致）：事件、状态、用量
    func testRunBatchDecoding() throws {
        let json = #"""
        {"ok": true, "state": "done", "error": null, "usage": {"promptTokens": 12, "completionTokens": 3},
         "events": [{"i": 0, "type": "reasoning", "text": "想一下"},
                    {"i": 1, "type": "content", "text": "你好"},
                    {"i": 2, "type": "usage", "usage": {"promptTokens": 12, "completionTokens": 3}}]}
        """#
        let batch = try JSONDecoder().decode(CloudRunBatch.self, from: Data(json.utf8))
        XCTAssertEqual(batch.state, "done")
        XCTAssertEqual(batch.events.count, 3)
        XCTAssertEqual(batch.events[1].text, "你好")
        XCTAssertEqual(batch.events[2].usage?.promptTokens, 12)
        XCTAssertTrue(batch.isTerminal)
    }

    /// 沙盒解码与状态文案
    func testSandboxDecoding() throws {
        let json = #"{"id":"main","state":"paused","createdAt":1.0,"runs":2,"files":3}"#
        let sandbox = try JSONDecoder().decode(CloudSandbox.self, from: Data(json.utf8))
        XCTAssertEqual(sandbox.id, "main")
        XCTAssertTrue(sandbox.isPaused)
        XCTAssertEqual(sandbox.stateText, "已暂停")
    }

    /// 旧设置数据没有云端开关时解码为关闭（不影响老用户）
    func testFeatureFlagDecodesCloudOffForLegacyData() throws {
        let legacy = #"{"sessionLog":false,"pluginCommands":false,"modelPicker":false,"usageMetrics":false,"deepThinkingToggle":true,"examplePrompts":true}"#
        let flags = try JSONDecoder().decode(FeatureFlags.self, from: Data(legacy.utf8))
        XCTAssertFalse(flags.cloudInference)
    }

    /// App 包内置的 Agent 脚本可读取，且包含核心接口（防止打包遗漏）
    func testBundledAgentSourceAvailable() throws {
        let source = try XCTUnwrap(CloudDeploy.agentSource(), "App 包内缺少 dsh-agent.py")
        XCTAssertTrue(source.contains("DSH 云端推理 Agent"))
        XCTAssertTrue(source.contains("def run_inference"))
        XCTAssertTrue(source.contains("/chat/completions"))
        XCTAssertTrue(source.contains("/sandboxes"))
    }
}

// MARK: - SSH 多服务器

final class SSHStoreMultiServerTests: XCTestCase {

    override func tearDown() {
        // 清理测试写入的持久化数据，避免影响其它用例
        UserDefaults.standard.removeObject(forKey: "dsh.ssh.servers.v2")
        super.tearDown()
    }

    /// 多台服务器的增删、按名称/主机解析、密码随删随清
    func testAddResolveAndDelete() {
        let store = SSHStore()
        store.servers = []
        let tokyo = store.add(SSHServer(name: "东京节点", host: "1.1.1.1", port: 22, username: "root"))
        let plain = store.add(SSHServer(name: "", host: "2.2.2.2", port: 2222, username: "ubuntu"))

        XCTAssertEqual(store.servers.count, 2)
        XCTAssertEqual(plain.displayName, "2.2.2.2", "没起名字时用主机地址展示")
        XCTAssertEqual(tokyo.displayTarget, "root@1.1.1.1:22")

        XCTAssertEqual(store.resolve(name: "东京节点")?.id, tokyo.id)
        XCTAssertEqual(store.resolve(name: "2.2.2.2")?.id, plain.id)
        XCTAssertEqual(store.resolve(name: "东京")?.id, tokyo.id, "支持模糊匹配")
        XCTAssertEqual(store.resolve(name: "")?.id, tokyo.id, "不指定时用第一台")
        XCTAssertNil(store.resolve(name: "不存在的服务器"))

        store.setPassword("secret", for: tokyo.id)
        XCTAssertEqual(store.password(for: tokyo.id), "secret")
        XCTAssertTrue(store.isConfigured, "有完整服务器且带密码时视为可用")

        store.update(id: plain.id) { $0.name = "备用机" }
        XCTAssertEqual(store.server(id: plain.id)?.name, "备用机")

        store.delete(id: tokyo.id)
        XCTAssertNil(store.server(id: tokyo.id))
        XCTAssertEqual(store.password(for: tokyo.id), "", "删除后密码也要从钥匙串清掉")
        XCTAssertEqual(store.resolve(name: "")?.id, plain.id, "默认服务器回退到剩下的那台")

        store.servers = []
    }

    /// 旧版单服务器配置会自动迁移成列表里的第一台，并把密码搬到新钥匙串条目
    func testLegacyMigration() {
        UserDefaults.standard.removeObject(forKey: "dsh.ssh.servers.v2")
        let legacy = #"{"host":"9.9.9.9","port":2222,"username":"root"}"#
        UserDefaults.standard.set(Data(legacy.utf8), forKey: "dsh.ssh.config.v1")
        Keychain.set("legacy-password", for: "ssh.password")

        let store = SSHStore()
        XCTAssertEqual(store.servers.count, 1, "旧配置应迁移成一台服务器")
        XCTAssertEqual(store.servers.first?.host, "9.9.9.9")
        XCTAssertEqual(store.servers.first?.port, 2222)
        XCTAssertEqual(store.password(for: store.servers[0].id), "legacy-password", "密码应随迁移搬到新条目")
        XCTAssertNil(UserDefaults.standard.data(forKey: "dsh.ssh.config.v1"), "迁移后旧配置键应删除")

        store.servers = []
        UserDefaults.standard.removeObject(forKey: "dsh.ssh.servers.v2")
        Keychain.remove("ssh.password")
    }
}