import Foundation

/// GitHub OAuth 设备码登录（Device Flow）。
/// App 内点一次「登录 GitHub」→ 自动打开 GitHub 授权页 → 输入 App 显示的设备码 → App 自动换取 Token。
/// Client ID 是公开信息，可以随 App 分发；设备码模式不需要 client secret。
enum GitHubAuthService {

    /// 在 GitHub 上注册的 OAuth App（已启用 Device Flow）
    static let clientID = "Ov23ctxygWNUdtgxirPP"
    /// repo 权限：读写仓库文件、创建 Issue
    static let scope = "repo"

    struct DeviceCode {
        let deviceCode: String
        /// 展示给用户在网页上输入的短码，例如 236B-D071
        let userCode: String
        let verificationURL: URL
        let interval: TimeInterval
        let expiresIn: TimeInterval
    }

    enum AuthError: LocalizedError {
        case http(Int, String)
        case malformed
        case denied
        case expired

        var errorDescription: String? {
            switch self {
            case .http(let code, let detail):
                return "GitHub 登录失败（HTTP \(code)）：\(detail)"
            case .malformed:
                return "GitHub 返回内容异常，请稍后重试"
            case .denied:
                return "已取消授权"
            case .expired:
                return "设备码已过期，请重新发起登录"
            }
        }
    }

    // MARK: - 设备码流程

    /// 第一步：申请设备码
    static func requestDeviceCode() async throws -> DeviceCode {
        let json = try await post(
            path: "/login/device/code",
            fields: ["client_id": clientID, "scope": scope]
        )
        guard let deviceCode = json["device_code"] as? String,
              let userCode = json["user_code"] as? String,
              let uriString = json["verification_uri"] as? String,
              let uri = URL(string: uriString) else {
            throw AuthError.malformed
        }
        return DeviceCode(
            deviceCode: deviceCode,
            userCode: userCode,
            verificationURL: uri,
            interval: TimeInterval(json["interval"] as? Int ?? 5),
            expiresIn: TimeInterval(json["expires_in"] as? Int ?? 900)
        )
    }

    /// 第二步：轮询等待用户在网页完成授权，返回 access_token
    static func waitForToken(for device: DeviceCode) async throws -> String {
        var interval = max(5, device.interval)
        let deadline = Date().addingTimeInterval(device.expiresIn)

        while Date() < deadline {
            try Task.checkCancellation()
            try await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))

            let json = try await post(
                path: "/login/oauth/access_token",
                fields: [
                    "client_id": clientID,
                    "device_code": device.deviceCode,
                    "grant_type": "urn:ietf:params:oauth:grant-type:device_code"
                ]
            )
            if let token = json["access_token"] as? String, !token.isEmpty {
                return token
            }

            let error = json["error"] as? String
            switch error {
            case nil, "authorization_pending":
                continue
            case "slow_down":
                interval += 5
            case "expired_token":
                throw AuthError.expired
            case "access_denied":
                throw AuthError.denied
            default:
                throw AuthError.http(200, (json["error_description"] as? String) ?? error ?? "未知错误")
            }
        }
        throw AuthError.expired
    }

    // MARK: - 网络

    /// 两个接口都是表单编码请求 + JSON 响应
    private static func post(path: String, fields: [String: String]) async throws -> [String: Any] {
        guard let url = URL(string: "https://github.com" + path) else { throw AuthError.malformed }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("DSH-iOS", forHTTPHeaderField: "User-Agent")
        request.httpBody = formEncode(fields).data(using: .utf8)

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

    private static func formEncode(_ fields: [String: String]) -> String {
        var components = URLComponents()
        components.queryItems = fields.map { URLQueryItem(name: $0.key, value: $0.value) }
        return components.percentEncodedQuery ?? ""
    }
}