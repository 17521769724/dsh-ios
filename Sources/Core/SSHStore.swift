import Foundation

/// 一台 SSH 云服务器配置（密码单独存钥匙串，按服务器 id 区分）
struct SSHServer: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var name: String = ""
    var host: String = ""
    var port: Int = 22
    var username: String = "root"

    /// 是否已填写完整（可连接）
    var isFilled: Bool {
        !host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && port > 0 && port <= 65_535
    }

    /// 列表与选择器里的显示名（没起名字就用主机地址）
    var displayName: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? host : trimmed
    }

    /// 连接目标，例如 root@1.2.3.4:22
    var displayTarget: String {
        "\(username)@\(host):\(port)"
    }
}

/// SSH 配置存储：支持添加多台云服务器；密码按服务器 id 存钥匙串。
/// 旧版本只保存一台服务器，首次读取时会自动迁移成列表里的第一台。
final class SSHStore: ObservableObject {

    @Published var servers: [SSHServer] {
        didSet { persist() }
    }

    /// 内存中的密码缓存（界面绑定用；写入即落钥匙串）
    @Published private var passwords: [UUID: String] = [:]

    private static let serversKey = "dsh.ssh.servers.v2"
    private static let legacyConfigKey = "dsh.ssh.config.v1"
    private static let legacyPasswordAccount = "ssh.password"

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.serversKey),
           let decoded = try? JSONDecoder().decode([SSHServer].self, from: data) {
            servers = decoded
        } else {
            servers = []
        }
        for server in servers {
            passwords[server.id] = Keychain.get(Self.account(server.id))
        }
        migrateLegacyIfNeeded()
    }

    // MARK: - 查询

    /// 是否至少有一台可用（主机、用户名、密码齐全）
    var isConfigured: Bool {
        servers.contains { $0.isFilled && !password(for: $0.id).isEmpty }
    }

    /// 默认服务器：列表里第一台填写完整的
    var defaultServer: SSHServer? {
        servers.first { $0.isFilled }
    }

    /// 展示用的服务器概览（未配置时返回提示文案）
    var displaySummary: String {
        let targets = servers.map(\.displayTarget)
        return targets.isEmpty ? "未配置" : targets.joined(separator: "、")
    }

    func server(id: UUID) -> SSHServer? {
        servers.first { $0.id == id }
    }

    /// 按名称或主机匹配服务器（智能体 ssh_exec 的 server 参数用它）：
    /// 先精确匹配名称/主机，再模糊匹配；名字为空时用默认服务器。
    func resolve(name: String) -> SSHServer? {
        let key = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !key.isEmpty else { return defaultServer }
        return servers.first { $0.displayName.lowercased() == key || $0.host.lowercased() == key }
            ?? servers.first { $0.displayName.lowercased().contains(key) || $0.host.lowercased().contains(key) }
    }

    // MARK: - 密码

    func password(for id: UUID) -> String {
        passwords[id] ?? ""
    }

    func setPassword(_ value: String, for id: UUID) {
        passwords[id] = value
        Keychain.set(value, for: Self.account(id))
    }

    // MARK: - 增删改

    @discardableResult
    func add(_ server: SSHServer) -> SSHServer {
        servers.append(server)
        return server
    }

    func delete(id: UUID) {
        servers.removeAll { $0.id == id }
        passwords[id] = nil
        Keychain.remove(Self.account(id))
    }

    func update(id: UUID, _ mutate: (inout SSHServer) -> Void) {
        guard let index = servers.firstIndex(where: { $0.id == id }) else { return }
        mutate(&servers[index])
    }

    // MARK: - 落盘

    private static func account(_ id: UUID) -> String {
        "ssh.password.\(id.uuidString)"
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(servers) else { return }
        UserDefaults.standard.set(data, forKey: Self.serversKey)
    }

    /// 旧版单台服务器配置 → 迁移成列表里的一台，并把旧密码搬到新的钥匙串条目
    private func migrateLegacyIfNeeded() {
        guard servers.isEmpty,
              let data = UserDefaults.standard.data(forKey: Self.legacyConfigKey),
              let legacy = try? JSONDecoder().decode(LegacyConfiguration.self, from: data),
              legacy.isFilled else { return }
        let server = SSHServer(
            name: "默认服务器",
            host: legacy.host,
            port: legacy.port,
            username: legacy.username
        )
        servers = [server]
        let password = Keychain.get(Self.legacyPasswordAccount)
        if !password.isEmpty {
            setPassword(password, for: server.id)
            Keychain.remove(Self.legacyPasswordAccount)
        }
        UserDefaults.standard.removeObject(forKey: Self.legacyConfigKey)
    }

    /// 旧版（单服务器）配置结构，仅用于迁移
    private struct LegacyConfiguration: Codable {
        var host: String = ""
        var port: Int = 22
        var username: String = "root"

        var isFilled: Bool {
            !host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && !username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && port > 0 && port <= 65_535
        }
    }
}