import Foundation

// MARK: - 服务器配置

/// 一台 MCP 服务器（远程，Streamable HTTP 传输）。
/// 工具 / 提示清单会缓存到本地，离线时仍能在设置页里看到上次连接的结果。
struct MCPServerConfig: Identifiable, Codable, Equatable {
    var id: UUID
    var name: String
    var urlString: String
    /// 额外请求头，每行一条 "Key: Value"（例如 Authorization: Bearer xxx）
    var headerLines: String
    var isEnabled: Bool
    /// 工具名前缀用的别名（小写字母 / 数字 / 下划线，添加时生成并保持不变）
    var alias: String
    var createdAt: Date
    /// 最近一次连接成功后缓存的工具与提示清单
    var tools: [MCPToolInfo]
    var prompts: [MCPPromptInfo]
    /// 服务端自报的名称与协议版本（连接成功后记录）
    var serverName: String?
    var protocolVersion: String?
    var lastConnectedAt: Date?
    var lastError: String?

    init(
        id: UUID = UUID(),
        name: String,
        urlString: String,
        headerLines: String = "",
        isEnabled: Bool = true,
        alias: String = "",
        createdAt: Date = Date(),
        tools: [MCPToolInfo] = [],
        prompts: [MCPPromptInfo] = [],
        serverName: String? = nil,
        protocolVersion: String? = nil,
        lastConnectedAt: Date? = nil,
        lastError: String? = nil
    ) {
        self.id = id
        self.name = name
        self.urlString = urlString
        self.headerLines = headerLines
        self.isEnabled = isEnabled
        self.alias = alias
        self.createdAt = createdAt
        self.tools = tools
        self.prompts = prompts
        self.serverName = serverName
        self.protocolVersion = protocolVersion
        self.lastConnectedAt = lastConnectedAt
        self.lastError = lastError
    }

    /// 宽容解码：旧版本写入的字段缺失时按默认值补齐
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        self.name = try container.decodeIfPresent(String.self, forKey: .name) ?? "MCP 服务器"
        self.urlString = try container.decodeIfPresent(String.self, forKey: .urlString) ?? ""
        self.headerLines = try container.decodeIfPresent(String.self, forKey: .headerLines) ?? ""
        self.isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
        self.alias = try container.decodeIfPresent(String.self, forKey: .alias) ?? ""
        self.createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        self.tools = try container.decodeIfPresent([MCPToolInfo].self, forKey: .tools) ?? []
        self.prompts = try container.decodeIfPresent([MCPPromptInfo].self, forKey: .prompts) ?? []
        self.serverName = try container.decodeIfPresent(String.self, forKey: .serverName)
        self.protocolVersion = try container.decodeIfPresent(String.self, forKey: .protocolVersion)
        self.lastConnectedAt = try container.decodeIfPresent(Date.self, forKey: .lastConnectedAt)
        self.lastError = try container.decodeIfPresent(String.self, forKey: .lastError)
    }

    /// 服务器地址（非法时 nil）
    var url: URL? {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return URL(string: trimmed)
    }

    /// "Key: Value" 多行 → 请求头字典
    var headers: [String: String] {
        var result: [String: String] = [:]
        for line in headerLines.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard let separator = trimmed.firstIndex(of: ":") else { continue }
            let key = String(trimmed[..<separator]).trimmingCharacters(in: .whitespaces)
            let value = String(trimmed[trimmed.index(after: separator)...]).trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty, !value.isEmpty else { continue }
            result[key] = value
        }
        return result
    }

    var displayHost: String {
        url?.host ?? urlString
    }
}

// MARK: - 工具 / 提示

/// MCP 工具（服务端 tools/list 的结果）
struct MCPToolInfo: Codable, Equatable, Identifiable {
    var name: String
    var description: String
    /// inputSchema 的原始 JSON 文本，原样转交给模型
    var schemaJSON: String

    var id: String { name }

    init(name: String, description: String, schemaJSON: String) {
        self.name = name
        self.description = description
        self.schemaJSON = schemaJSON
    }

    /// inputSchema → JSON 对象（解析失败时给出空对象骨架，保证工具仍可下发）
    var parameters: [String: Any] {
        guard let data = schemaJSON.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return ["type": "object", "properties": [String: Any]()]
        }
        return object
    }
}

/// MCP 提示模板（prompts/list 的结果）
struct MCPPromptInfo: Codable, Equatable, Identifiable {
    struct Argument: Codable, Equatable {
        var name: String
        var description: String
        var required: Bool

        init(name: String, description: String, required: Bool) {
            self.name = name
            self.description = description
            self.required = required
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
            self.description = try container.decodeIfPresent(String.self, forKey: .description) ?? ""
            self.required = try container.decodeIfPresent(Bool.self, forKey: .required) ?? false
        }
    }

    var name: String
    var description: String
    var arguments: [Argument]

    var id: String { name }

    /// 有必填参数的模板暂不支持一键填入
    var needsArguments: Bool { arguments.contains(where: \.required) }
}

// MARK: - 错误

enum MCPError: LocalizedError {
    case invalidURL(String)
    case invalidResponse
    case http(status: Int, body: String)
    case rpc(code: Int, message: String)

    var errorDescription: String? {
        switch self {
        case .invalidURL(let raw):
            return "服务器地址无效：\(raw)"
        case .invalidResponse:
            return "服务器返回了无法解析的响应。"
        case .http(let status, let body):
            let snippet = body.count > 200 ? String(body.prefix(200)) + "…" : body
            return "服务器返回 HTTP \(status)\(snippet.isEmpty ? "" : "：\(snippet)")"
        case .rpc(let code, let message):
            return "MCP 错误（\(code)）：\(message)"
        }
    }
}

// MARK: - 客户端

/// MCP 客户端：JSON-RPC 2.0 over Streamable HTTP（MCP 2025-03-26 规范）。
///
/// 覆盖握手与常用能力：
/// - `initialize` 协议版本协商 + `notifications/initialized` 通知
/// - `Mcp-Session-Id` 会话头（服务端下发后，后续请求自动带上）
/// - `tools/list`、`tools/call`
/// - `resources/list`、`resources/read`
/// - `prompts/list`、`prompts/get`
///
/// 响应既可能是普通 JSON，也可能是 SSE（text/event-stream）流，两种都会解析。
final class MCPClient {

    /// 客户端支持的协议版本（与服务端不一致时以服务端返回的为准）
    static let supportedProtocolVersion = "2025-03-26"
    static let clientName = "dsh-ios"

    private let url: URL
    private let extraHeaders: [String: String]
    private let session: URLSession
    private var sessionID: String?
    private var nextRequestID = 1

    /// 服务端在 initialize 里返回的信息
    private(set) var negotiatedVersion: String?
    private(set) var capabilities: [String: Any] = [:]
    private(set) var serverName: String?
    private(set) var serverVersion: String?
    private(set) var instructions: String?
    private(set) var isConnected = false

    static var clientVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
    }

    /// 服务端是否声明支持某类能力（tools / resources / prompts）
    func supports(_ capability: String) -> Bool {
        capabilities[capability] != nil
    }

    init(config: MCPServerConfig, timeout: Double = 60) throws {
        guard let url = config.url, let scheme = url.scheme?.lowercased(), scheme.hasPrefix("http") else {
            throw MCPError.invalidURL(config.urlString)
        }
        self.url = url
        self.extraHeaders = config.headers
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout * 2
        configuration.waitsForConnectivity = false
        self.session = URLSession(configuration: configuration)
    }

    /// 便于测试：注入自定义 URLSession
    init(config: MCPServerConfig, session: URLSession) throws {
        guard let url = config.url, let scheme = url.scheme?.lowercased(), scheme.hasPrefix("http") else {
            throw MCPError.invalidURL(config.urlString)
        }
        self.url = url
        self.extraHeaders = config.headers
        self.session = session
    }

    // MARK: - 握手

    /// initialize 握手：协商协议版本、记录会话 id，并发送 initialized 通知
    func connect() async throws {
        let result = try await send(method: "initialize", params: [
            "protocolVersion": Self.supportedProtocolVersion,
            "capabilities": [String: Any](),
            "clientInfo": ["name": Self.clientName, "version": Self.clientVersion]
        ])
        negotiatedVersion = result["protocolVersion"] as? String
        capabilities = result["capabilities"] as? [String: Any] ?? [:]
        if let info = result["serverInfo"] as? [String: Any] {
            serverName = info["name"] as? String
            serverVersion = info["version"] as? String
        }
        instructions = result["instructions"] as? String
        // 握手完成后必须通知服务端「客户端已就绪」
        try await notify(method: "notifications/initialized", params: nil)
        isConnected = true
    }

    // MARK: - 能力

    func listTools() async throws -> [MCPToolInfo] {
        let result = try await send(method: "tools/list", params: nil)
        let tools = result["tools"] as? [[String: Any]] ?? []
        return tools.compactMap { raw in
            guard let name = raw["name"] as? String, !name.isEmpty else { return nil }
            return MCPToolInfo(
                name: name,
                description: raw["description"] as? String ?? "",
                schemaJSON: Self.jsonText(raw["inputSchema"])
            )
        }
    }

    /// 调用工具，返回给模型的文本结果（图片 / 资源等非文本内容会转成文字说明）
    func callTool(name: String, argumentsJSON: String) async throws -> String {
        var params: [String: Any] = ["name": name]
        if let arguments = Self.jsonObject(argumentsJSON), !arguments.isEmpty {
            params["arguments"] = arguments
        }
        let result = try await send(method: "tools/call", params: params)
        let text = Self.text(fromContent: result["content"])
        let isError = result["isError"] as? Bool ?? false
        if isError {
            return "工具执行出错：\n\(text.isEmpty ? "（服务端未给出原因）" : text)"
        }
        return text.isEmpty ? "（工具没有返回文本内容）" : text
    }

    func listResources() async throws -> [(uri: String, name: String, mimeType: String?)] {
        let result = try await send(method: "resources/list", params: nil)
        let resources = result["resources"] as? [[String: Any]] ?? []
        return resources.compactMap { raw in
            guard let uri = raw["uri"] as? String else { return nil }
            return (uri, raw["name"] as? String ?? uri, raw["mimeType"] as? String)
        }
    }

    /// 读取资源内容（文本资源返回正文，二进制只给说明）
    func readResource(uri: String) async throws -> String {
        let result = try await send(method: "resources/read", params: ["uri": uri])
        let contents = result["contents"] as? [[String: Any]] ?? []
        var parts: [String] = []
        for item in contents {
            if let text = item["text"] as? String {
                parts.append(text)
            } else if let mime = item["mimeType"] as? String {
                parts.append("（二进制资源 \(uri)，类型 \(mime)，已省略）")
            } else {
                parts.append("（资源 \(uri) 没有文本内容）")
            }
        }
        return parts.isEmpty ? "（资源 \(uri) 没有内容）" : parts.joined(separator: "\n\n")
    }

    func listPrompts() async throws -> [MCPPromptInfo] {
        let result = try await send(method: "prompts/list", params: nil)
        let prompts = result["prompts"] as? [[String: Any]] ?? []
        return prompts.compactMap { raw in
            guard let name = raw["name"] as? String, !name.isEmpty else { return nil }
            let arguments = (raw["arguments"] as? [[String: Any]] ?? []).map { item in
                MCPPromptInfo.Argument(
                    name: item["name"] as? String ?? "",
                    description: item["description"] as? String ?? "",
                    required: item["required"] as? Bool ?? false
                )
            }
            return MCPPromptInfo(
                name: name,
                description: raw["description"] as? String ?? "",
                arguments: arguments
            )
        }
    }

    /// 取回提示模板文本（把服务端返回的 messages 拼成一段可发送的内容）
    func getPrompt(name: String, arguments: [String: String]) async throws -> String {
        var params: [String: Any] = ["name": name]
        if !arguments.isEmpty { params["arguments"] = arguments }
        let result = try await send(method: "prompts/get", params: params)
        let messages = result["messages"] as? [[String: Any]] ?? []
        var parts: [String] = []
        for message in messages {
            let role = message["role"] as? String ?? "user"
            let content = message["content"] as? [String: Any] ?? [:]
            if let text = content["text"] as? String, !text.isEmpty {
                parts.append(role == "assistant" ? "【示例回答】\n\(text)" : text)
            }
        }
        if parts.isEmpty, let description = result["description"] as? String {
            return description
        }
        return parts.joined(separator: "\n\n")
    }

    // MARK: - JSON-RPC 传输

    /// 发送请求并等待响应
    private func send(method: String, params: [String: Any]?) async throws -> [String: Any] {
        let id = nextRequestID
        nextRequestID += 1
        var body: [String: Any] = ["jsonrpc": "2.0", "id": id, "method": method]
        if let params { body["params"] = params }

        let response = try await post(body)
        // 批量响应里挑出本次请求的那条
        let message = response.first { Self.matches($0["id"], id: id) } ?? response.first
        guard let message else { throw MCPError.invalidResponse }
        if let error = message["error"] as? [String: Any] {
            throw MCPError.rpc(
                code: error["code"] as? Int ?? -1,
                message: error["message"] as? String ?? "未知错误"
            )
        }
        return message["result"] as? [String: Any] ?? [:]
    }

    /// 发送通知（不需要响应，服务端通常回 202）
    private func notify(method: String, params: [String: Any]?) async throws {
        var body: [String: Any] = ["jsonrpc": "2.0", "method": method]
        if let params { body["params"] = params }
        _ = try? await post(body)
    }

    /// 把一条 JSON-RPC 消息 POST 给服务器，返回解析出的消息数组
    private func post(_ body: [String: Any]) async throws -> [[String: Any]] {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // Streamable HTTP 要求客户端同时声明可接受的两种响应类型
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        // 握手之后按规范带上协商好的协议版本
        if let negotiatedVersion {
            request.setValue(negotiatedVersion, forHTTPHeaderField: "MCP-Protocol-Version")
        }
        if let sessionID {
            request.setValue(sessionID, forHTTPHeaderField: "Mcp-Session-Id")
        }
        for (key, value) in extraHeaders {
            request.setValue(value, forHTTPHeaderField: key)
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw MCPError.invalidResponse }
        // 服务端在 initialize 响应里下发会话 id，后续请求必须带上
        if let sid = http.value(forHTTPHeaderField: "Mcp-Session-Id"), !sid.isEmpty {
            sessionID = sid
        }
        guard (200..<300).contains(http.statusCode) else {
            throw MCPError.http(status: http.statusCode, body: String(data: data, encoding: .utf8) ?? "")
        }
        let contentType = http.value(forHTTPHeaderField: "Content-Type")?.lowercased() ?? ""
        if contentType.contains("text/event-stream") {
            return Self.parseSSE(data)
        }
        return Self.parseJSON(data)
    }

    // MARK: - 解析

    /// JSON 响应：单条消息或批量数组
    private static func parseJSON(_ data: Data) -> [[String: Any]] {
        guard !data.isEmpty else { return [] }
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            return [object]
        }
        if let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
            return array
        }
        return []
    }

    /// SSE 响应：逐行取 `data:` 后的 JSON（`event:` / 空行 / 注释行忽略）
    private static func parseSSE(_ data: Data) -> [[String: Any]] {
        guard let text = String(data: data, encoding: .utf8) else { return [] }
        var messages: [[String: Any]] = []
        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("data:") else { continue }
            let payload = String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces)
            guard !payload.isEmpty, payload != "[DONE]" else { continue }
            if let message = try? JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any] {
                messages.append(message)
            }
        }
        return messages
    }

    private static func matches(_ value: Any?, id: Int) -> Bool {
        if let number = value as? Int { return number == id }
        if let number = value as? Double { return Int(number) == id }
        if let text = value as? String { return text == String(id) }
        return false
    }

    private static func jsonObject(_ json: String) -> [String: Any]? {
        guard let data = json.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    private static func jsonText(_ value: Any?) -> String {
        guard let value,
              JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value),
              let text = String(data: data, encoding: .utf8) else {
            return #"{"type":"object","properties":{}}"#
        }
        return text
    }

    /// MCP content 数组 → 文本：图片 / 音频等非文本内容转成一句说明，避免把 base64 塞进上下文
    private static func text(fromContent content: Any?) -> String {
        guard let items = content as? [[String: Any]] else { return "" }
        var parts: [String] = []
        for item in items {
            switch item["type"] as? String {
            case "text":
                if let text = item["text"] as? String { parts.append(text) }
            case "image":
                let mime = item["mimeType"] as? String ?? "image"
                parts.append("（返回了一张图片 \(mime)，当前无法直接查看）")
            case "audio":
                parts.append("（返回了一段音频）")
            case "resource":
                let resource = item["resource"] as? [String: Any] ?? [:]
                let uri = resource["uri"] as? String ?? ""
                if let text = resource["text"] as? String {
                    parts.append(text)
                } else {
                    parts.append("（返回了资源 \(uri)）")
                }
            case .none:
                continue
            case .some(let other):
                parts.append("（返回了 \(other) 类型的内容）")
            }
        }
        return parts.joined(separator: "\n\n")
    }
}