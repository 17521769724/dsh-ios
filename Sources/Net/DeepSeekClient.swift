import Foundation

// MARK: - 传输模型

struct APIMessage: Codable, Hashable {
    let role: String
    let content: String
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

    init(timeout: Double = 120) {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout * 3
        configuration.waitsForConnectivity = false
        self.session = URLSession(configuration: configuration)
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

    private func payload(messages: [APIMessage], model: String, stream: Bool, settings: AppSettings) -> [String: Any] {
        var body: [String: Any] = [
            "model": model,
            "messages": messages.map { ["role": $0.role, "content": $0.content] },
            "stream": stream,
            "temperature": settings.temperature
        ]
        if stream {
            body["stream_options"] = ["include_usage": true]
        }
        return body
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
        settings: AppSettings,
        apiKey: String
    ) -> AsyncThrowingStream<StreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let request = try makeRequest(
                        path: "/chat/completions",
                        apiKey: apiKey,
                        body: payload(messages: messages, model: model, stream: true, settings: settings),
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

                    for try await rawLine in bytes.lines {
                        try Task.checkCancellation()
                        guard rawLine.hasPrefix("data:") else { continue }
                        let json = rawLine.dropFirst(5).trimmingCharacters(in: .whitespaces)
                        if json.isEmpty { continue }
                        if json == "[DONE]" {
                            continuation.yield(.finished(nil))
                            break
                        }
                        guard let data = json.data(using: .utf8),
                              let chunk = try? JSONDecoder().decode(StreamChunk.self, from: data) else {
                            continue
                        }
                        if let reasoning = chunk.choices.first?.delta?.reasoningContent, !reasoning.isEmpty {
                            continuation.yield(.reasoning(reasoning))
                        }
                        if let content = chunk.choices.first?.delta?.content, !content.isEmpty {
                            continuation.yield(.content(content))
                        }
                        if let usage = chunk.usage {
                            continuation.yield(.finished(usage))
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

    private struct StreamChunk: Decodable {
        struct Choice: Decodable {
            struct Delta: Decodable {
                let content: String?
                let reasoningContent: String?
                enum CodingKeys: String, CodingKey {
                    case content
                    case reasoningContent = "reasoning_content"
                }
            }
            let delta: Delta?
        }
        let choices: [Choice]
        let usage: TokenUsage?
    }

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
