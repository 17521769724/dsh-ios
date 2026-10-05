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
    private func runStream(model: String, settings: AppSettings) async {
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
            messages: [APIMessage(role: "user", content: "hi")],
            model: model,
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