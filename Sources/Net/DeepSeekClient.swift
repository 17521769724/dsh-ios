import Foundation

// MARK: - 传输模型

struct APIMessage: Codable, Hashable {
    let role: String
    let content: String
    /// 助手消息发起的工具调用（角色为 assistant 时使用）
    var toolCalls: [ToolCall]? = nil
    /// 工具结果消息对应的调用 id（角色为 tool 时使用）
    var toolCallID: String? = nil
    /// 用户消息附带的图片，作为多模态 content 数组发送
    var images: [ChatAttachment]? = nil
}

/// 提供给模型的可调用工具定义（OpenAI 兼容）
struct APITool: Hashable {
    let name: String
    let description: String
    /// JSON Schema 形式的参数描述
    let parameters: [String: Any]

    static func == (lhs: APITool, rhs: APITool) -> Bool {
        lhs.name == rhs.name && lhs.description == rhs.description
            && NSDictionary(dictionary: lhs.parameters).isEqual(to: rhs.parameters)
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(name)
        hasher.combine(description)
    }

    var jsonObject: [String: Any] {
        [
            "type": "function",
            "function": [
                "name": name,
                "description": description,
                "parameters": parameters
            ]
        ]
    }
}

struct TokenUsage: Codable, Hashable {
    let promptTokens: Int
    let completionTokens: Int

    enum CodingKeys: String, CodingKey {
        case promptTokens = "prompt_tokens"
        case completionTokens = "completion_tokens"
    }
}

enum StreamEvent: Hashable {
    case content(String)
    case reasoning(String)
    case toolCalls([ToolCall])
    case finished(TokenUsage?)
}

// MARK: - 错误

enum DSHError: LocalizedError {
    case missingAPIKey
    case invalidBaseURL(String)
    case unauthorized
    case rateLimited
    case http(status: Int, body: String)
    case emptyResponse
    case offline

    var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return "尚未配置 API Key，请到「设置」中填写。"
        case .invalidBaseURL(let raw):
            return "Base URL 无效：\(raw)"
        case .unauthorized:
            return "API Key 无效或已失效（401）。"
        case .rateLimited:
            return "请求过于频繁或额度不足（429）。"
        case .http(let status, let body):
            let snippet = body.count > 220 ? String(body.prefix(220)) + "…" : body
            return "服务返回错误 \(status)：\(snippet)"
        case .emptyResponse:
            return "服务返回了空响应。"
        case .offline:
            return "网络不可用，请检查连接后重试。"
        }
    }
}

// MARK: - 客户端

/// DeepSeek / OpenAI 兼容 Chat Completions 客户端，支持 SSE 流式输出。
struct DeepSeekClient {

    private let session: URLSession

    init(timeout: Double = 120, configuration: URLSessionConfiguration = .default) {
        let config = configuration.copy() as? URLSessionConfiguration ?? configuration
        config.timeoutIntervalForRequest = timeout
        config.timeoutIntervalForResource = timeout * 3
        config.waitsForConnectivity = false
        self.session = URLSession(configuration: config)
    }

    // MARK: URL 组装

    private func endpoint(_ path: String, base: String) throws -> URL {
        var trimmed = base.trimmingCharacters(in: .whitespacesAndNewlines)
        while trimmed.hasSuffix("/") { trimmed.removeLast() }
        guard !trimmed.isEmpty, let url = URL(string: trimmed + path) else {
            throw DSHError.invalidBaseURL(base)
        }
        return url
    }

    private func makeRequest(path: String, apiKey: String, body: [String: Any], base: String) throws -> URLRequest {
        guard !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw DSHError.missingAPIKey
        }
        var request = URLRequest(url: try endpoint(path, base: base))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("DSH-iOS/0.1", forHTTPHeaderField: "User-Agent")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    private func payload(
        messages: [APIMessage],
        model: String,
        stream: Bool,
        settings: AppSettings,
        tools: [APITool] = []
    ) -> [String: Any] {
        var body: [String: Any] = [
            "model": model,
            "messages": messages.map { Self.jsonObject(for: $0) },
            "stream": stream,
            "temperature": settings.temperature
        ]
        if stream {
            body["stream_options"] = ["include_usage": true]
        }
        if !tools.isEmpty {
            body["tools"] = tools.map(\.jsonObject)
        }
        // 思考模式为 DeepSeek 专有参数，仅在 DeepSeek 系模型上发送，
        // 避免自定义 OpenAI 兼容中转服务因未知字段报错。
        if settings.thinkingEnabled, model.lowercased().contains("deepseek") {
            body["thinking"] = ["type": "enabled"]
            body["reasoning_effort"] = settings.reasoningEffort.rawValue
        }
        return body
    }

    /// APIMessage → OpenAI 兼容的 JSON 对象（含 tool_calls / tool_call_id / 多模态图片）
    private static func jsonObject(for message: APIMessage) -> [String: Any] {
        var object: [String: Any] = ["role": message.role, "content": message.content]

        // 带图片时 content 换成 OpenAI 兼容的多模态数组：
        // [{type:"text",text:...}, {type:"image_url",image_url:{url:"data:image/jpeg;base64,..."}}]
        if let images = message.images, !images.isEmpty {
            var parts: [[String: Any]] = []
            if !message.content.isEmpty {
                parts.append(["type": "text", "text": message.content])
            }
            for image in images {
                guard let data = image.data, !data.isEmpty else { continue }
                let url = "data:\(image.mimeType);base64,\(data.base64EncodedString())"
                parts.append(["type": "image_url", "image_url": ["url": url]])
            }
            if !parts.isEmpty {
                object["content"] = parts
            }
        }

        if let calls = message.toolCalls, !calls.isEmpty {
            object["tool_calls"] = calls.map { call in
                [
                    "id": call.id,
                    "type": "function",
                    "function": ["name": call.name, "arguments": call.arguments]
                ]
            }
        }
        if let id = message.toolCallID {
            object["tool_call_id"] = id
        }
        return object
    }

    private func errorFor(status: Int, body: String) -> DSHError {
        switch status {
        case 401: return .unauthorized
        case 429: return .rateLimited
        default: return .http(status: status, body: body)
        }
    }

    // MARK: 流式

    func streamChat(
        messages: [APIMessage],
        model: String,
        tools: [APITool] = [],
        settings: AppSettings,
        apiKey: String
    ) -> AsyncThrowingStream<StreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let request = try makeRequest(
                        path: "/chat/completions",
                        apiKey: apiKey,
                        body: payload(messages: messages, model: model, stream: true, settings: settings, tools: tools),
                        base: settings.baseURL
                    )

                    let (bytes, response) = try await session.bytes(for: request)
                    guard let http = response as? HTTPURLResponse else {
                        throw DSHError.emptyResponse
                    }
                    guard http.statusCode == 200 else {
                        var collected = ""
                        for try await line in bytes.lines {
                            collected += line
                            if collected.count > 2000 { break }
                        }
                        throw errorFor(status: http.statusCode, body: collected)
                    }

                    var parser = ChatStreamParser()
                    for try await rawLine in bytes.lines {
                        try Task.checkCancellation()
                        for result in parser.consume(line: rawLine) {
                            switch result {
                            case .content(let text):
                                continuation.yield(.content(text))
                            case .reasoning(let text):
                                continuation.yield(.reasoning(text))
                            case .toolCalls(let calls):
                                continuation.yield(.toolCalls(calls))
                            case .usage(let usage):
                                continuation.yield(.finished(usage))
                            case .done:
                                continuation.yield(.finished(nil))
                            }
                        }
                    }
                    // 连接可能在未收到 [DONE] 时结束，补齐剩余工具调用
                    for result in parser.finish() {
                        if case .toolCalls(let calls) = result {
                            continuation.yield(.toolCalls(calls))
                        }
                    }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: 非流式

    func complete(
        messages: [APIMessage],
        model: String,
        settings: AppSettings,
        apiKey: String
    ) async throws -> (text: String, reasoning: String?, usage: TokenUsage?) {
        let request = try makeRequest(
            path: "/chat/completions",
            apiKey: apiKey,
            body: payload(messages: messages, model: model, stream: false, settings: settings),
            base: settings.baseURL
        )
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw DSHError.emptyResponse }
        guard http.statusCode == 200 else {
            throw errorFor(status: http.statusCode, body: String(data: data, encoding: .utf8) ?? "")
        }
        let decoded = try JSONDecoder().decode(CompletionResponse.self, from: data)
        guard let choice = decoded.choices.first else { throw DSHError.emptyResponse }
        return (
            choice.message?.content ?? "",
            choice.message?.reasoningContent,
            decoded.usage
        )
    }

    // MARK: 模型列表

    func fetchModelIDs(settings: AppSettings, apiKey: String) async throws -> [String] {
        guard !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw DSHError.missingAPIKey
        }
        var request = URLRequest(url: try endpoint("/models", base: settings.baseURL))
        request.httpMethod = "GET"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw errorFor(status: status, body: String(data: data, encoding: .utf8) ?? "")
        }
        struct ModelList: Decodable {
            struct Item: Decodable { let id: String }
            let data: [Item]
        }
        return try JSONDecoder().decode(ModelList.self, from: data).data.map(\.id)
    }

    // MARK: 解码结构

    private struct CompletionResponse: Decodable {
        struct Choice: Decodable {
            struct Message: Decodable {
                let content: String?
                let reasoningContent: String?
                enum CodingKeys: String, CodingKey {
                    case content
                    case reasoningContent = "reasoning_content"
                }
            }
            let message: Message?
        }
        let choices: [Choice]
        let usage: TokenUsage?
    }
}
