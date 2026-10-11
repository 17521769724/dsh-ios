import Foundation

/// 云端推理的工具集装配。
///
/// 从 `ChatEngine` 里抽出来单独成文件：一是让 `ChatEngine` 只关心「流程」，
/// 二是让「哪些工具会被下发」这件事可以直接单测（开关、账号状态、服务器配置的组合很多）。
///
/// 两类执行面：
/// - 云服务器执行：网页抓取 / 联网搜索 / 沙盒文件 / Python 执行 / 计算器 / 时间 / HTTP 调用 / MCP
/// - 手机执行：SSH / 内置浏览器 / 截图 OCR / 剪贴板 / 提醒事项与日历 / GitHub、Gitee / 技能库
enum CloudToolBuilder {
    /// 装配所需的上下文（由 `ChatEngine` 从各 Store 收集）
    struct Context {
        var switches: CloudToolSwitches
        var features: FeatureFlags
        var browser: BrowserSettings
        /// 已配置的 SSH 服务器名称（写进工具描述，让模型知道能指定哪台）
        var sshServerNames: [String] = []
        var sshConfigured: Bool = false
        /// 手机侧已连接（且启用）的 MCP 工具（模型侧名字已带前缀）
        var mcpTools: [APITool] = []
        var skillNames: [String] = []
        var githubConnected: Bool = false
        var giteeConnected: Bool = false
    }

    /// 按开关与账号状态装配下发给云端 Agent 的工具列表
    static func tools(for context: Context) -> [APITool] {
        let switches = context.switches
        let features = context.features
        var tools: [APITool] = []

        // ---- 云服务器执行 ----
        if switches.webFetch {
            tools.append(AgentToolCatalog.webFetch)
        }
        if switches.search {
            tools.append(AgentToolCatalog.webSearch)
        }
        if switches.workspace {
            tools.append(AgentToolCatalog.workspace)
        }
        if switches.code {
            tools.append(AgentToolCatalog.pythonExec)
        }
        if switches.calc {
            tools.append(AgentToolCatalog.calculator)
        }
        if switches.clock {
            tools.append(AgentToolCatalog.currentTime)
        }
        if switches.http {
            tools.append(AgentToolCatalog.httpRequest)
        }
        if switches.mcp, features.mcpTool {
            tools.append(contentsOf: context.mcpTools)
        }

        // ---- 手机执行（云端会回调手机，因此还要看本机功能开关）----
        if switches.shell, features.sshTool, context.sshConfigured {
            tools.append(AgentToolCatalog.sshExec(servers: context.sshServerNames))
        }
        if switches.browser, features.browserTool {
            tools.append(AgentToolCatalog.browserOpen)
            if context.browser.allowAgentRead {
                tools.append(AgentToolCatalog.browserRead)
            }
        }
        if switches.vision, features.visionTool {
            tools.append(AgentToolCatalog.screenshot)
        }
        if switches.clipboard, features.clipboardTool {
            tools.append(AgentToolCatalog.clipboard)
        }
        if switches.reminder, features.reminderTool {
            tools.append(AgentToolCatalog.reminder)
        }
        if switches.git, features.githubTool, context.githubConnected {
            tools.append(AgentToolCatalog.github)
        }
        if switches.git, features.giteeTool, context.giteeConnected {
            tools.append(AgentToolCatalog.gitee)
        }
        if switches.skill, !context.skillNames.isEmpty {
            tools.append(AgentToolCatalog.skill(names: context.skillNames))
        }
        return tools
    }

    /// 下发给云端 Agent 的 MCP 服务器配置（含「模型侧工具名 ↔ 真实工具名」映射）
    static func mcpServers(switches: CloudToolSwitches, features: FeatureFlags, servers: [MCPServerConfig]) -> [CloudMCPServerConfig] {
        guard switches.mcp, features.mcpTool else { return [] }
        return servers
            .filter { $0.isEnabled && $0.url != nil && !$0.tools.isEmpty }
            .map { server in
                let alias = server.alias.isEmpty ? "server" : server.alias
                return CloudMCPServerConfig(
                    name: alias,
                    url: server.urlString,
                    headers: server.headers,
                    tools: server.tools.map { tool in
                        (modelName: MCPStore.modelToolName(alias: alias, tool: tool.name), name: tool.name)
                    }
                )
            }
    }
}