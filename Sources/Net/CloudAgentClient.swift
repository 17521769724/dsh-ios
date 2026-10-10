import Foundation

// MARK: - 云端 Agent 数据模型

/// 沙盒（服务器上的工作目录）：可创建 / 暂停 / 恢复 / 销毁
struct CloudSandbox: Codable, Identifiable, Hashable {
    let id: String
    let state: String
    let createdAt: Double?
    let runs: Int?
    let files: Int?

    var isPaused: Bool { state == "paused" }

    var stateText: String {
        switch state {
        case "paused": return "已暂停"
        case "active": return "运行中"
        default: return state
        }
    }
}

/// 沙盒里的文件条目
struct CloudFileItem: Codable, Identifiable, Hashable {
    let name: String
    let size: Int
    let modified: Double?

    var id: String { name }

    var sizeText: String {
        ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)
    }
}

/// 推理事件（服务端按序号缓存，客户端用 after 游标续取，断线重连不丢内容）
struct CloudRunEvent: Codable, Hashable {
    let i: Int
    let type: String   // content / reasoning / usage / error
    let text: String?
    let usage: CloudUsage?
    let error: String?
}

struct CloudUsage: Codable, Hashable {
    let promptTokens: Int
    let completionTokens: Int

    var tokenUsage: TokenUsage {
        TokenUsage(promptTokens: promptTokens, completionTokens: completionTokens)
    }
}

/// 一次事件轮询的结果：events 为新增事件，state 为任务状态
struct CloudRunBatch: Codable {
    let events: [CloudRunEvent]
    let state: String   // running / done / error / stopped
    let error: String?
    let usage: CloudUsage?

    var isTerminal: Bool { state != "running" }
}

/// 发送给云端 Agent 的一条消息（纯文本角色）
struct CloudMessage: Codable, Hashable {
    let role: String
    let content: String
}

/// 一次云端推理请求（模型 Key 随请求下发，服务器不保存）
struct CloudChatRequest: Codable {
    let messages: [CloudMessage]
    let model: String
    let apiKey: String
    let baseURL: String
    let temperature: Double
    let thinking: Bool
    let reasoningEffort: String
}

// MARK: - 错误

enum CloudError: LocalizedError {
    case badURL
    case unauthorized
    case server(String)
    case notReachable(String)

    var errorDescription: String? {
        switch self {
        case .badURL:
            return "云端 Agent 地址无效：请先在「设置 → SSH 云服务器」填好主机，并在「设置 → 云端推理」确认端口。"
        case .unauthorized:
            return "云端 Agent 拒绝了访问：令牌不一致，请在「设置 → 云端推理」重新部署一次。"
        case .server(let message):
            return "云端 Agent 返回错误：\(message)"
        case .notReachable(let detail):
            return "连不上云端 Agent（\(detail)）。请确认服务器在运行、安全组已放行端口，必要时重新部署。"
        }
    }
}

// MARK: - 客户端

/// 云端 Agent 的 HTTP 客户端：管理沙盒、文件与推理事件流。
struct CloudAgentClient {

    let baseURL: URL
    let token: String

    private static let decoder = JSONDecoder()

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.default
        // 事件接口是长轮询（最长 25 秒），请求超时要留够余量
        configuration.timeoutIntervalForRequest = 40
        configuration.timeoutIntervalForResource = 120
        configuration.waitsForConnectivity = false
        return URLSession(configuration: configuration)
    }()

    // MARK: 基础请求

    private func request(_ method: String, path: String, query: [String: String] = [:], body: Data? = nil, contentType: String? = nil) throws -> URLRequest {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            throw CloudError.badURL
        }
        let trimmed = path.hasPrefix("/") ? String(path.dropFirst()) : path
        components.path = (components.path.hasSuffix("/") ? components.path : components.path + "/") + trimmed
        if !query.isEmpty {
            components.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) }
        }
        guard let url = components.url else { throw CloudError.badURL }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let body {
            request.httpBody = body
            request.setValue(contentType ?? "application/json", forHTTPHeaderField: "Content-Type")
        }
        return request
    }

    private func send(_ request: URLRequest) async throws -> Data {
        do {
            let (data, response) = try await Self.session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw CloudError.server("无响应")
            }
            if http.statusCode == 401 { throw CloudError.unauthorized }
            guard (200..<300).contains(http.statusCode) else {
                throw CloudError.server(Self.errorMessage(from: data) ?? "HTTP \(http.statusCode)")
            }
            return data
        } catch let error as CloudError {
            throw error
        } catch {
            throw CloudError.notReachable((error as? URLError)?.localizedDescription ?? error.localizedDescription)
        }
    }

    private static func errorMessage(from data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return object["error"] as? String
    }

    // MARK: 健康检查

    /// 检测连接并返回 Agent 版本；同时验证服务器端口可从手机访问
    func health() async throws -> String {
        let data = try await send(request("GET", path: "health"))
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let version = object["version"] as? String else {
            throw CloudError.server("健康检查返回格式不正确")
        }
        return version
    }

    // MARK: 沙盒

    func listSandboxes() async throws -> [CloudSandbox] {
        let data = try await send(request("GET", path: "sandboxes"))
        return try Self.decodeSandboxes(data)
    }

    /// 确保指定沙盒存在（不存在则由服务器自动创建）
    @discardableResult
    func ensureSandbox(_ id: String) async throws -> CloudSandbox {
        let body = try JSONEncoder().encode(["id": id])
        let data = try await send(request("POST", path: "sandboxes", body: body))
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let raw = object["sandbox"] else {
            throw CloudError.server("创建沙盒返回格式不正确")
        }
        let payload = try JSONSerialization.data(withJSONObject: raw)
        return try Self.decoder.decode(CloudSandbox.self, from: payload)
    }

    func pauseSandbox(_ id: String) async throws {
        _ = try await send(request("POST", path: "sandboxes/\(id)/pause"))
    }

    func resumeSandbox(_ id: String) async throws {
        _ = try await send(request("POST", path: "sandboxes/\(id)/resume"))
    }

    func destroySandbox(_ id: String) async throws {
        _ = try await send(request("DELETE", path: "sandboxes/\(id)"))
    }

    // MARK: 文件

    func listFiles(sandbox: String) async throws -> [CloudFileItem] {
        let data = try await send(request("GET", path: "sandboxes/\(sandbox)/files"))
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let raw = object["files"] else {
            throw CloudError.server("文件列表返回格式不正确")
        }
        let payload = try JSONSerialization.data(withJSONObject: raw)
        return try Self.decoder.decode([CloudFileItem].self, from: payload)
    }

    func uploadFile(sandbox: String, name: String, data: Data) async throws {
        _ = try await send(request(
            "PUT",
            path: "sandboxes/\(sandbox)/files/\(name)",
            body: data,
            contentType: "application/octet-stream"
        ))
    }

    func downloadFile(sandbox: String, name: String) async throws -> Data {
        try await send(request("GET", path: "sandboxes/\(sandbox)/files/\(name)"))
    }

    func deleteFile(sandbox: String, name: String) async throws {
        _ = try await send(request("DELETE", path: "sandboxes/\(sandbox)/files/\(name)"))
    }

    // MARK: 推理

    /// 发起一次推理，返回任务 id；推理在服务器上后台执行，客户端随后按游标取事件
    func startChat(sandbox: String, request chatRequest: CloudChatRequest) async throws -> String {
        let body = try JSONEncoder().encode(chatRequest)
        let data = try await send(request("POST", path: "sandboxes/\(sandbox)/chat", body: body))
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let runID = object["runId"] as? String else {
            throw CloudError.server("推理启动返回格式不正确")
        }
        return runID
    }

    /// 取 after 之后的新增事件（长轮询：没有新事件时在服务端等待，最多 timeout 秒）
    func runEvents(sandbox: String, runID: String, after: Int, timeout: Int = 25) async throws -> CloudRunBatch {
        let data = try await send(request(
            "GET",
            path: "sandboxes/\(sandbox)/runs/\(runID)",
            query: ["after": "\(after)", "timeout": "\(timeout)"]
        ))
        return try Self.decoder.decode(CloudRunBatch.self, from: data)
    }

    func stopRun(sandbox: String, runID: String) async throws {
        _ = try await send(request("POST", path: "sandboxes/\(sandbox)/runs/\(runID)/stop"))
    }

    // MARK: 解析辅助

    private static func decodeSandboxes(_ data: Data) throws -> [CloudSandbox] {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let raw = object["sandboxes"] else {
            throw CloudError.server("沙盒列表返回格式不正确")
        }
        let payload = try JSONSerialization.data(withJSONObject: raw)
        return try decoder.decode([CloudSandbox].self, from: payload)
    }
}