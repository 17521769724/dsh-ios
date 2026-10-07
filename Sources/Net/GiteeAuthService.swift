import Foundation

/// Gitee 一键登录（OAuth2 授权码模式）。
///
/// Gitee 官方不提供设备码流程，所以用授权码模式做出同样的「一键」体验：
/// App 打开 Gitee 授权页 → 用户点「同意授权」→ Gitee 跳回应用登记的回调地址
/// → 内置浏览器拦下这次跳转拿到授权码 → App 自动换取 Token 完成登录。
enum GiteeAuthService {

    /// 在 Gitee「设置 → 第三方应用」创建的应用凭据
    static let clientID = "547ae1b7bc5d6d958c9cae0efd921941206a4bdb01ecbdd161ad701dfffd237a"
    static let clientSecret = "cdad2f1e0eab217df6d0c6e0c2449a256913759819e3cf617d788e8b0c486ff0"

    /// 应用里登记的回调地址，必须与 Gitee 后台填写的内容完全一致
    static let redirectURI = "https://dshdesktop.com/oauth/gitee"
    /// 兼容回调地址登记为自定义 URL Scheme 的情况
    static let schemeRedirectURI = "dshios://oauth/gitee"

    /// 需要的权限：projects 仓库读写、issues 任务读写
    static let scope = "projects issues"

    enum AuthError: LocalizedError {
        case notConfigured
        case network(String)
        case http(Int, String)
        case malformed
        case denied
        case stateMismatch

        var errorDescription: String? {
            switch self {
            case .notConfigured:
                return "尚未配置 Gitee 应用凭据。"
            case .network(let detail):
                return "连接 Gitee 失败（\(detail)），请检查网络后重试。"
            case .http(let code, let detail):
                return "Gitee 登录失败（HTTP \(code)）：\(detail)"
            case .malformed:
                return "Gitee 返回内容异常，请稍后重试。"
            case .denied:
                return "已取消 Gitee 授权。"
            case .stateMismatch:
                return "授权回调校验失败，请重新发起登录。"
            }
        }
    }

    static var isConfigured: Bool {
        !clientID.isEmpty && !clientSecret.isEmpty
    }

    // MARK: - 授权

    /// 生成授权页地址；state 用于确认回调确实来自本次登录
    static func authorizeURL(state: String) -> URL? {
        guard isConfigured else { return nil }
        var components = URLComponents(string: "https://gitee.com/oauth/authorize")
        components?.queryItems = [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: scope),
            URLQueryItem(name: "state", value: state)
        ]
        return components?.url
    }

    /// 是否是本次登录的回调地址
    static func isCallback(_ url: URL) -> Bool {
        let text = url.absoluteString
        return text.hasPrefix(redirectURI) || text.hasPrefix(schemeRedirectURI)
    }

    /// 从回调地址里取出授权码；state 不匹配时抛错
    static func authorizationCode(from callback: URL, expectedState: String) throws -> String {
        guard let components = URLComponents(url: callback, resolvingAgainstBaseURL: false) else {
            throw AuthError.malformed
        }
        let items = components.queryItems ?? []

        if let error = items.first(where: { $0.name == "error" })?.value {
            throw error == "access_denied" ? AuthError.denied : AuthError.http(200, error)
        }
        guard items.first(where: { $0.name == "state" })?.value == expectedState else {
            throw AuthError.stateMismatch
        }
        guard let code = items.first(where: { $0.name == "code" })?.value, !code.isEmpty else {
            throw AuthError.malformed
        }
        return code
    }

    /// 随机 state
    static func makeState() -> String {
        UUID().uuidString.replacingOccurrences(of: "-", with: "")
    }

    // MARK: - 换取 Token

    /// 用授权码换 access_token。Gitee 的 token 接口参数放在 URL 查询串里，
    /// 并且必须带 User-Agent，否则可能返回 403。
    static func exchangeToken(code: String) async throws -> String {
        guard isConfigured else { throw AuthError.notConfigured }
        var components = URLComponents(string: "https://gitee.com/oauth/token")
        components?.queryItems = [
            URLQueryItem(name: "grant_type", value: "authorization_code"),
            URLQueryItem(name: "code", value: code),
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "client_secret", value: clientSecret),
            URLQueryItem(name: "redirect_uri", value: redirectURI)
        ]
        guard let url = components?.url else { throw AuthError.malformed }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("DSH-iOS", forHTTPHeaderField: "User-Agent")

        let json = try await send(request)
        if let token = json["access_token"] as? String, !token.isEmpty {
            return token
        }
        if let error = json["error"] as? String {
            if error == "access_denied" { throw AuthError.denied }
            throw AuthError.http(200, (json["error_description"] as? String) ?? error)
        }
        throw AuthError.malformed
    }

    // MARK: - 网络

    /// 与 GitHub 设备码相同的重试策略：网络抖动时退避重试三次
    private static func send(_ request: URLRequest) async throws -> [String: Any] {
        var lastError: Error?
        for attempt in 0..<3 {
            do {
                return try await perform(request)
            } catch let error as URLError {
                lastError = AuthError.network(error.localizedDescription)
            } catch let error as AuthError {
                lastError = error
                // 拿到明确的服务端响应就没必要重试
                if case .http(let code, _) = error, (400..<600).contains(code) { throw error }
            } catch {
                throw error
            }
            if attempt < 2 {
                try? await Task.sleep(nanoseconds: UInt64(1_500_000_000) * UInt64(attempt + 1))
            }
        }
        throw lastError ?? AuthError.malformed
    }

    private static func perform(_ request: URLRequest) async throws -> [String: Any] {
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw AuthError.http(status, String(data: data.prefix(200), encoding: .utf8) ?? "")
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AuthError.malformed
        }
        return json
    }
}