import Foundation

// MARK: - 云端推理配置

/// 云端推理配置：Agent 部署在用户自己的 SSH 服务器上，
/// iOS 客户端只保存访问地址与令牌（令牌进钥匙串），不保存任何模型 Key。
struct CloudConfiguration: Codable, Equatable {
    /// Agent 服务端口（部署时可改，需在云服务器安全组放行）
    var port: Int = 8931
    /// 默认使用的沙盒 id；首次发送会话时若不存在会自动创建
    var sandboxID: String = "main"

    static let `default` = CloudConfiguration()
}

/// 云端推理存储：非敏感项存 UserDefaults，Agent 访问令牌存钥匙串。
/// 令牌只在部署时下发给服务器，之后每次请求用它鉴权（个人自用，不需要注册登录）。
final class CloudStore: ObservableObject {

    @Published var configuration: CloudConfiguration {
        didSet { persist() }
    }

    /// Agent 访问令牌（随机生成，保存在本机钥匙串）
    @Published var token: String {
        didSet { Keychain.set(token, for: Self.tokenAccount) }
    }

    /// 最近一次部署/检测的日志（设置页展示）
    @Published var lastDeployLog: String?
    /// 是否正在部署
    @Published var deploying = false
    /// 最近一次连接检测结果：nil 表示未检测
    @Published var healthText: String?
    @Published var lastError: String?

    private static let configKey = "dsh.cloud.config.v1"
    private static let tokenAccount = "cloud.agent.token"

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.configKey),
           let decoded = try? JSONDecoder().decode(CloudConfiguration.self, from: data) {
            configuration = decoded
        } else {
            configuration = .default
        }
        let stored = Keychain.get(Self.tokenAccount)
        token = stored.isEmpty ? Self.randomToken() : stored
        // init 里赋值不会触发 didSet，首次生成的令牌要手动落钥匙串
        if stored.isEmpty {
            Keychain.set(token, for: Self.tokenAccount)
        }
    }

    /// 32 位十六进制随机令牌
    static func randomToken() -> String {
        (0..<32).map { _ in String("0123456789abcdef".randomElement() ?? "0") }.joined()
    }

    /// Agent 服务地址（用 SSH 服务器地址 + 端口拼出）
    func baseURL(sshHost: String) -> URL? {
        let host = sshHost.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty, configuration.port > 0, configuration.port <= 65_535 else { return nil }
        return URL(string: "http://\(host):\(configuration.port)")
    }

    /// 是否具备云端推理条件（有地址与令牌）
    func isReady(sshHost: String) -> Bool {
        !token.isEmpty && baseURL(sshHost: sshHost) != nil
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(configuration) else { return }
        UserDefaults.standard.set(data, forKey: Self.configKey)
    }
}

// MARK: - 一键部署

/// 一键部署：把 Agent 源码通过 SSH 写到用户服务器上并以后台进程启动。
/// 脚本由纯函数生成，便于单测；执行时复用已有的 SSH 通道（SSHService）。
enum CloudDeploy {

    /// 远端目录与文件名
    static let remoteDirectory = "$HOME/.dsh"
    static let agentFileName = "dsh-agent.py"

    /// 读取 App 包内置的 Agent 源码
    static func agentSource() -> String? {
        let url = Bundle.main.url(forResource: "dsh-agent", withExtension: "py")
            ?? Bundle.main.url(forResource: "dsh-agent", withExtension: "py", subdirectory: "Resources")
        guard let url else { return nil }
        return try? String(contentsOf: url, encoding: .utf8)
    }

    /// 部署脚本：建目录 → 写源码 → 确保 python3 → 重启 Agent → 本机健康检查
    static func script(source: String, port: Int, token: String) -> String {
        """
        set -e
        mkdir -p \(remoteDirectory)/sandboxes
        cat > \(remoteDirectory)/\(agentFileName) <<'DSH_AGENT_EOF'
        \(source)
        DSH_AGENT_EOF
        command -v python3 >/dev/null 2>&1 || {
          if command -v apt-get >/dev/null 2>&1; then apt-get update -qq && apt-get install -y -qq python3; fi
          if command -v yum >/dev/null 2>&1; then yum install -y -q python3; fi
          if command -v dnf >/dev/null 2>&1; then dnf install -y -q python3; fi
        }
        PY="$(command -v python3 || command -v python || true)"
        [ -n "$PY" ] || { echo "__DSH_NO_PYTHON__"; exit 1; }
        pkill -f \(agentFileName) >/dev/null 2>&1 || true
        sleep 1
        nohup "$PY" \(remoteDirectory)/\(agentFileName) --port \(port) --token \(token) \
          > \(remoteDirectory)/agent.log 2>&1 < /dev/null &
        sleep 1
        echo "__DSH_DEPLOY_DONE__"
        curl -s -m 5 http://127.0.0.1:\(port)/health || echo "__DSH_HEALTH_FAILED__"
        """
    }

    /// 部署结果判定：脚本输出里是否出现成功标记 / python 缺失标记
    static func succeeded(_ output: String) -> Bool {
        output.contains("\"ok\": true") || output.contains("\"ok\":true")
    }

    static func missingPython(_ output: String) -> Bool {
        output.contains("__DSH_NO_PYTHON__")
    }
}