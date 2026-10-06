import Foundation

/// Git 服务错误
enum GitServiceError: LocalizedError {
    case emptyToken
    case invalidArguments(String)
    case unauthorized(String)
    case http(Int, String)

    var errorDescription: String? {
        switch self {
        case .emptyToken:
            return "尚未在设置中填写 Token。"
        case .invalidArguments(let detail):
            return "工具参数错误：\(detail)"
        case .unauthorized(let detail):
            return "Token 无效或权限不足：\(detail)"
        case .http(let code, let detail):
            return "请求失败（HTTP \(code)）：\(detail)"
        }
    }
}

/// GitHub / Gitee 的 REST 封装：账号校验 + 供智能体调用的仓库操作。
enum GitService {

    /// 传给模型的输出上限
    static let maxCharacters = 8_000

    // MARK: - 账号

    /// 用 Token 拉取账号名，用于校验 Token 是否有效
    static func fetchAccount(provider: GitProvider, token: String) async throws -> String {
        let json = try await objectRequest(provider: provider, token: token, method: "GET", path: "/user")
        if let login = json["login"] as? String, !login.isEmpty { return login }
        if let name = json["name"] as? String, !name.isEmpty { return name }
        throw GitServiceError.unauthorized("无法读取账号信息")
    }

    // MARK: - 智能体动作

    /// 解析工具的 JSON 参数并执行对应动作
    static func perform(provider: GitProvider, arguments: String, token: String) async throws -> String {
        guard let action = ToolArguments.string("action", in: arguments) else {
            throw GitServiceError.invalidArguments("缺少 action（可用 list_repos / read_file / write_file / create_issue）")
        }

        switch action {
        case "list_repos":
            return try await listRepos(provider: provider, token: token, arguments: arguments)
        case "read_file":
            return try await readFile(provider: provider, token: token, arguments: arguments)
        case "write_file":
            return try await writeFile(provider: provider, token: token, arguments: arguments)
        case "create_issue":
            return try await createIssue(provider: provider, token: token, arguments: arguments)
        default:
            throw GitServiceError.invalidArguments("不支持的动作 \(action)，可用：list_repos / read_file / write_file / create_issue")
        }
    }

    // MARK: - 动作实现

    private static func listRepos(provider: GitProvider, token: String, arguments: String) async throws -> String {
        let list = try await listRequest(
            provider: provider,
            token: token,
            method: "GET",
            path: "/user/repos",
            query: ["per_page": "30", "sort": "updated"]
        )

        guard !list.isEmpty else { return "\(provider.displayName) 账号下没有可访问的仓库。" }

        let lines = list.prefix(30).map { repo -> String in
            let name = repo["full_name"] as? String ?? repo["path"] as? String ?? "(未知)"
            let isPrivate = (repo["private"] as? Bool) ?? false
            let branch = repo["default_branch"] as? String ?? "main"
            let description = (repo["description"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let suffix = description.isEmpty ? "" : "：\(description)"
            return "- \(name)（\(isPrivate ? "私有" : "公开")，默认分支 \(branch)）\(suffix)"
        }
        return "\(provider.displayName) 最近更新的仓库（\(list.count) 个）：\n" + lines.joined(separator: "\n")
    }

    private static func readFile(provider: GitProvider, token: String, arguments: String) async throws -> String {
        let (owner, repo) = try splitRepo(in: arguments)
        let path = try require("path", in: arguments)
        let branch = ToolArguments.string("branch", in: arguments)

        guard let json = try await fileInfo(
            provider: provider,
            token: token,
            owner: owner,
            repo: repo,
            path: path,
            branch: branch
        ) else {
            throw GitServiceError.invalidArguments("仓库或文件不存在：\(owner)/\(repo):\(path)")
        }
        guard let base64 = json["content"] as? String,
              let text = decodeBase64(base64) else {
            throw GitServiceError.invalidArguments("该路径不是可读的文本文件：\(path)")
        }
        let sha = json["sha"] as? String ?? ""
        return "文件 \(owner)/\(repo):\(path)\(sha.isEmpty ? "" : "（sha \(sha.prefix(7))）"):\n\n" + truncate(text)
    }

    private static func writeFile(provider: GitProvider, token: String, arguments: String) async throws -> String {
        let (owner, repo) = try splitRepo(in: arguments)
        let path = try require("path", in: arguments)
        let content = try require("content", in: arguments)
        let branch = ToolArguments.string("branch", in: arguments)
        let message = ToolArguments.string("message", in: arguments) ?? "通过 DeepSeek 智能体更新 \(path)"

        // 已存在则带上 sha 走更新，不存在则新建
        let existing = try await fileInfo(
            provider: provider,
            token: token,
            owner: owner,
            repo: repo,
            path: path,
            branch: branch
        )
        let sha = existing?["sha"] as? String

        var body: [String: Any] = [
            "message": message,
            "content": Data(content.utf8).base64EncodedString()
        ]
        if let branch { body["branch"] = branch }
        if let sha { body["sha"] = sha }

        let result = try await objectRequest(
            provider: provider,
            token: token,
            method: sha == nil ? "POST" : "PUT",
            path: "/repos/\(owner)/\(repo)/contents/\(path)",
            body: body
        )
        let url = ((result["content"] as? [String: Any])?["html_url"] as? String)
            ?? (result["commit"] as? [String: Any])?["html_url"] as? String
        let verb = sha == nil ? "已新建" : "已更新"
        return "\(verb) \(owner)/\(repo):\(path)\(branch.map { "（分支 \($0)）" } ?? "")。\(url ?? "")"
    }

    private static func createIssue(provider: GitProvider, token: String, arguments: String) async throws -> String {
        let (owner, repo) = try splitRepo(in: arguments)
        let title = try require("title", in: arguments)
        var body: [String: Any] = ["title": title]
        if let text = ToolArguments.string("body", in: arguments) { body["body"] = text }

        let result = try await objectRequest(
            provider: provider,
            token: token,
            method: "POST",
            path: "/repos/\(owner)/\(repo)/issues",
            body: body
        )
        let number = result["number"].map { "\($0)" } ?? ""
        let url = result["html_url"] as? String ?? ""
        return "已在 \(owner)/\(repo) 创建 Issue\(number.isEmpty ? "" : " #\(number)")：\(title) \(url)"
    }

    // MARK: - 网络

    /// 返回 JSON 对象
    private static func objectRequest(
        provider: GitProvider,
        token: String,
        method: String,
        path: String,
        query: [String: String] = [:],
        body: [String: Any]? = nil
    ) async throws -> [String: Any] {
        let raw = try await rawRequest(
            provider: provider,
            token: token,
            method: method,
            path: path,
            query: query,
            body: body
        )
        guard let object = raw as? [String: Any] else {
            throw GitServiceError.http(200, "返回内容不是 JSON 对象")
        }
        return object
    }

    /// 返回 JSON 数组
    private static func listRequest(
        provider: GitProvider,
        token: String,
        method: String,
        path: String,
        query: [String: String] = [:]
    ) async throws -> [[String: Any]] {
        let raw = try await rawRequest(
            provider: provider,
            token: token,
            method: method,
            path: path,
            query: query,
            body: nil
        )
        return (raw as? [[String: Any]]) ?? []
    }

    /// 读取文件元信息（含 sha）；仓库或文件不存在时返回 nil
    private static func fileInfo(
        provider: GitProvider,
        token: String,
        owner: String,
        repo: String,
        path: String,
        branch: String?
    ) async throws -> [String: Any]? {
        do {
            return try await objectRequest(
                provider: provider,
                token: token,
                method: "GET",
                path: "/repos/\(owner)/\(repo)/contents/\(path)",
                query: branch.map { ["ref": $0] } ?? [:]
            )
        } catch GitServiceError.http(let code, _) where code == 404 {
            return nil
        }
    }

    /// 发起请求；非 2xx 时抛出带状态码的错误
    private static func rawRequest(
        provider: GitProvider,
        token: String,
        method: String,
        path: String,
        query: [String: String],
        body: [String: Any]?
    ) async throws -> Any? {
        let base = provider == .github ? "https://api.github.com" : "https://gitee.com/api/v5"
        var components = URLComponents(string: base + path)
        var items = query.map { URLQueryItem(name: $0.key, value: $0.value) }
        if provider == .gitee {
            // Gitee 用 access_token 参数鉴权
            items.append(URLQueryItem(name: "access_token", value: token))
        }
        components?.queryItems = items.isEmpty ? nil : items
        guard let url = components?.url else {
            throw GitServiceError.invalidArguments("URL 拼接失败：\(path)")
        }

        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = method
        urlRequest.timeoutInterval = 30
        urlRequest.setValue("application/json", forHTTPHeaderField: "Accept")
        urlRequest.setValue("DSH-iOS", forHTTPHeaderField: "User-Agent")
        if provider == .github {
            urlRequest.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            urlRequest.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        }
        if let body {
            urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
            urlRequest.httpBody = try JSONSerialization.data(withJSONObject: body)
        }

        let (data, response) = try await URLSession.shared.data(for: urlRequest)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            if status == 401 || status == 403 {
                throw GitServiceError.unauthorized("HTTP \(status)，请检查 Token 是否有效、是否具备 repo 权限")
            }
            throw GitServiceError.http(status, message(from: data))
        }
        guard !data.isEmpty else { return nil }
        return try? JSONSerialization.jsonObject(with: data)
    }

    /// 从错误响应里提取 message 字段
    private static func message(from data: Data) -> String {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return String(data: data.prefix(200), encoding: .utf8) ?? ""
        }
        if let text = object["message"] as? String { return text }
        if let errors = object["errors"] as? [[String: Any]],
           let first = errors.first?["message"] as? String {
            return first
        }
        return ""
    }

    // MARK: - 工具

    /// "owner/name" → (owner, name)
    private static func splitRepo(in arguments: String) throws -> (String, String) {
        let raw = try require("repo", in: arguments)
        let parts = raw.split(separator: "/")
        guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else {
            throw GitServiceError.invalidArguments("repo 需要写成 owner/仓库名，例如 deepseek-ai/DeepSeek-V3")
        }
        return (String(parts[0]), String(parts[1]))
    }

    private static func require(_ key: String, in arguments: String) throws -> String {
        guard let value = ToolArguments.string(key, in: arguments) else {
            throw GitServiceError.invalidArguments("缺少 \(key)")
        }
        return value
    }

    private static func decodeBase64(_ raw: String) -> String? {
        let cleaned = raw.replacingOccurrences(of: "\n", with: "")
        guard let data = Data(base64Encoded: cleaned) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func truncate(_ text: String) -> String {
        guard text.count > maxCharacters else { return text }
        return String(text.prefix(maxCharacters)) + "\n…（内容过长，已截断）"
    }
}