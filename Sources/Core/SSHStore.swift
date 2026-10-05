import Foundation

/// SSH 服务器配置（非敏感字段存 UserDefaults，密码存钥匙串）
struct SSHConfiguration: Codable, Equatable {
    var host: String = ""
    var port: Int = 22
    var username: String = "root"

    static let `default` = SSHConfiguration()

    var isFilled: Bool {
        !host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && port > 0 && port <= 65_535
    }
}

/// SSH 配置存储：负责读取/保存配置与密码（钥匙串）。
final class SSHStore: ObservableObject {

    @Published var configuration: SSHConfiguration {
        didSet { persist() }
    }

    @Published var password: String {
        didSet { Keychain.set(password, for: Self.passwordAccount) }
    }

    private static let configKey = "dsh.ssh.config.v1"
    private static let passwordAccount = "ssh.password"

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.configKey),
           let decoded = try? JSONDecoder().decode(SSHConfiguration.self, from: data) {
            configuration = decoded
        } else {
            configuration = .default
        }
        password = Keychain.get(Self.passwordAccount)
    }

    /// 是否可以执行 SSH 命令
    var isConfigured: Bool {
        configuration.isFilled && !password.isEmpty
    }

    /// 展示用的连接目标，例如 root@1.2.3.4:22
    var displayTarget: String {
        guard configuration.isFilled else { return "未配置" }
        return "\(configuration.username)@\(configuration.host):\(configuration.port)"
    }

    func clearPassword() {
        password = ""
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(configuration) else { return }
        UserDefaults.standard.set(data, forKey: Self.configKey)
    }
}