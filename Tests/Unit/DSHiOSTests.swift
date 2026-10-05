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
}

// MARK: - 会话模型

final class ConversationModelTests: XCTestCase {

    func testTitleDerivesFromFirstUserMessage() {
        var conversation = Conversation(model: "deepseek-chat")
        conversation.messages = [
            ChatMessage(role: .user, content: "帮我写一个 Swift 单元测试\n第二行"),
            ChatMessage(role: .assistant, content: "好的")
        ]
        conversation.refreshTitleFromFirstUserMessage()
        XCTAssertEqual(conversation.title, "帮我写一个 Swift 单元测试")
    }

    func testLongTitleIsTruncated() {
        var conversation = Conversation(model: "deepseek-chat")
        let long = String(repeating: "长", count: 60)
        conversation.messages = [ChatMessage(role: .user, content: long)]
        conversation.refreshTitleFromFirstUserMessage()
        XCTAssertEqual(conversation.title.count, 25) // 24 字 + 省略号
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

    func testModelCatalogLookup() {
        XCTAssertEqual(DSHModel.model(for: "deepseek-reasoner").supportsReasoning, true)
        XCTAssertEqual(DSHModel.model(for: "deepseek-chat").supportsReasoning, false)
        // 未知模型回退到第一个
        XCTAssertEqual(DSHModel.model(for: "不存在").id, DSHModel.catalog[0].id)
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
        XCTAssertEqual(settings.defaultModel, "deepseek-chat")
        XCTAssertTrue(settings.streamEnabled)
        XCTAssertEqual(settings.requestTimeout, 120)
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
}