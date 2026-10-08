import Foundation
import Combine

/// MCP 服务器管理：服务器列表、连接状态、工具缓存，
/// 并把各服务器提供的工具接到智能体的工具清单里（工具名前缀 `mcp_<服务器别名>_`）。
final class MCPStore: ObservableObject {

    @Published private(set) var servers: [MCPServerConfig] = []
    /// 正在连接 / 刷新中的服务器（界面展示进度）
    @Published private(set) var refreshing: Set<UUID> = []

    private let fileURL: URL
    /// 会话缓存：同一台服务器复用一次握手（失败后自动换新会话重试）
    private var clients: [UUID: MCPClient] = [:]

    init(fileName: String = "mcp-servers.json") {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        self.fileURL = dir.appendingPathComponent(fileName)
        load()
    }

    // MARK: - 查询

    var enabledServers: [MCPServerConfig] { servers.filter(\.isEnabled) }

    /// 已拿到工具清单的服务器数量
    var readyCount: Int { enabledServers.filter { !$0.tools.isEmpty }.count }

    /// 下发给模型的工具数量
    var availableToolCount: Int { enabledServers.reduce(0) { $0 + $1.tools.count } }

    func server(id: UUID) -> MCPServerConfig? { servers.first { $0.id == id } }

    // MARK: - 写入

    /// 添加服务器；名称或地址不合法时返回 nil
    @discardableResult
    func add(name: String, urlString: String, headerLines: String = "") -> MCPServerConfig? {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedURL = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { return nil }
        guard let url = URL(string: trimmedURL),
              let scheme = url.scheme?.lowercased(),
              scheme.hasPrefix("http") else { return nil }

        let config = MCPServerConfig(
            name: trimmedName,
            urlString: trimmedURL,
            headerLines: headerLines,
            alias: Self.makeAlias(name: trimmedName, existing: servers.map(\.alias))
        )
        servers.append(config)
        save()
        return config
    }

    func update(id: UUID, _ transform: (inout MCPServerConfig) -> Void) {
        guard let index = servers.firstIndex(where: { $0.id == id }) else { return }
        transform(&servers[index])
        if servers[index].alias.isEmpty {
            let taken = servers.filter { $0.id != id }.map(\.alias)
            servers[index].alias = Self.makeAlias(name: servers[index].name, existing: taken)
        }
        save()
    }

    func delete(id: UUID) {
        servers.removeAll { $0.id == id }
        clients[id] = nil
        save()
    }

    func setEnabled(_ enabled: Bool, id: UUID) {
        update(id: id) { $0.isEnabled = enabled }
    }

    // MARK: - 连接与刷新

    /// 连接服务器并刷新工具 / 提示清单
    func refresh(id: UUID) async {
        guard let server = server(id: id), !refreshing.contains(id) else { return }
        refreshing.insert(id)
        defer { refreshing.remove(id) }

        do {
            let client = try client(for: server, forceNew: true)
            try await client.connect()
            let tools = try await client.listTools()
            var prompts: [MCPPromptInfo] = []
            if client.supports("prompts") {
                prompts = (try? await client.listPrompts()) ?? []
            }
            update(id: id) { config in
                config.tools = tools
                config.prompts = prompts
                config.serverName = client.serverName
                config.protocolVersion = client.negotiatedVersion
                config.lastConnectedAt = Date()
                config.lastError = nil
            }
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            update(id: id) { $0.lastError = message }
        }
    }

    /// 依次刷新全部已启用服务器（设置页「全部刷新」）
    func refreshAll() async {
        for server in enabledServers {
            await refresh(id: server.id)
        }
    }

    // MARK: - 智能体工具

    /// 模型侧工具名：`mcp_<服务器别名>_<工具名>`，只保留合法字符并限制在 64 字符内
    static func modelToolName(alias: String, tool: String) -> String {
        let sanitizedTool = sanitize(tool)
        let raw = "mcp_\(alias)_\(sanitizedTool.isEmpty ? "tool" : sanitizedTool)"
        return raw.count > 64 ? String(raw.prefix(64)) : raw
    }

    /// 模型侧工具名 → （服务器，原始工具名）。
    /// 按实际注册的工具名反查，避免清洗规则（例如 `-` → `_`）导致还原错名字。
    func route(forModelToolName name: String) -> (server: MCPServerConfig, tool: String)? {
        for server in servers where server.isEnabled {
            for tool in server.tools where Self.modelToolName(alias: server.alias, tool: tool.name) == name {
                return (server, tool.name)
            }
        }
        return nil
    }

    /// 下发给模型的全部 MCP 工具
    func availableTools() -> [APITool] {
        enabledServers.flatMap { server in
            server.tools.map { tool in
                let body = tool.description.isEmpty ? "（该工具没有说明）" : tool.description
                return APITool(
                    name: Self.modelToolName(alias: server.alias, tool: tool.name),
                    description: "[MCP · \(server.name)] \(body)",
                    parameters: tool.parameters
                )
            }
        }
    }

    /// 执行一次 MCP 工具调用，返回给模型的文本结果
    func callTool(modelToolName: String, argumentsJSON: String) async -> String {
        guard let (server, toolName) = route(forModelToolName: modelToolName) else {
            return "未知工具：\(modelToolName)"
        }
        do {
            return try await perform(server: server, tool: toolName, argumentsJSON: argumentsJSON, reuseSession: true)
        } catch {
            // 会话可能已过期：换一个新会话重试一次
            do {
                return try await perform(server: server, tool: toolName, argumentsJSON: argumentsJSON, reuseSession: false)
            } catch {
                let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                return "调用 MCP 工具「\(server.name) · \(toolName)」失败：\(message)"
            }
        }
    }

    private func perform(
        server: MCPServerConfig,
        tool: String,
        argumentsJSON: String,
        reuseSession: Bool
    ) async throws -> String {
        let client = try client(for: server, forceNew: !reuseSession)
        if !client.isConnected {
            try await client.connect()
        }
        return try await client.callTool(name: tool, argumentsJSON: argumentsJSON)
    }

    /// 取回提示模板全文（设置页「填入输入框」）
    func loadPrompt(serverID: UUID, name: String) async -> String? {
        guard let server = server(id: serverID) else { return nil }
        do {
            let client = try client(for: server)
            if !client.isConnected { try await client.connect() }
            return try await client.getPrompt(name: name, arguments: [:])
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            update(id: serverID) { $0.lastError = message }
            return nil
        }
    }

    private func client(for server: MCPServerConfig, forceNew: Bool = false) throws -> MCPClient {
        if !forceNew, let cached = clients[server.id] { return cached }
        let client = try MCPClient(config: server)
        clients[server.id] = client
        return client
    }

    // MARK: - 命名

    /// 服务器别名：小写字母 / 数字 / 下划线，且互不重复
    private static func makeAlias(name: String, existing: [String]) -> String {
        var base = sanitize(name)
        if base.isEmpty { base = "server" }
        if base.count > 16 { base = String(base.prefix(16)) }
        var candidate = base
        var index = 2
        while existing.contains(candidate) {
            candidate = "\(base)\(index)"
            index += 1
        }
        return candidate
    }

    /// 只保留 ASCII 字母 / 数字，其它字符折叠成下划线
    private static func sanitize(_ raw: String) -> String {
        var result = ""
        var lastWasUnderscore = false
        for character in raw.lowercased() {
            if character.isASCII, character.isLetter || character.isNumber {
                result.append(character)
                lastWasUnderscore = false
            } else if !lastWasUnderscore {
                result.append("_")
                lastWasUnderscore = true
            }
        }
        return result.trimmingCharacters(in: CharacterSet(charactersIn: "_"))
    }

    // MARK: - 持久化

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        guard let decoded = try? JSONDecoder().decode([MCPServerConfig].self, from: data) else { return }
        servers = decoded
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted]
        guard let data = try? encoder.encode(servers) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}