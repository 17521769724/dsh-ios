import Foundation

/// 「过程」弹窗里的一步（一次工具调用）
struct ChatProcessStep: Identifiable, Equatable {
    let id: String
    /// 步骤小标题，例如「执行命令」「读取网页」
    let title: String
    /// SF Symbol 名称
    let icon: String
    /// 步骤详情（命令行、URL、文件路径…），等宽字体展示
    let detail: String
    /// 工具返回内容
    let output: String?
    /// 工具产生的截图（「查看画面」），在弹窗里直接显示
    let image: ChatAttachment?
}

/// 一条助手消息的「过程」：折叠行摘要 + 弹窗里的步骤与思考内容。
/// 对齐 TraeCode 的呈现方式：正文只展示叙述性内容，工具过程折叠为一行，点击弹窗看细节。
struct ChatProcess: Equatable {

    /// 弹窗里的步骤（按调用顺序）
    let steps: [ChatProcessStep]
    /// 折叠行文案，例如「已执行 2 条命令，读取 1 个网页」
    let summary: String
    /// 还有工具正在执行（文案用「正在…」）
    let isRunning: Bool
    /// 思考内容
    let reasoning: String?

    var hasSteps: Bool { !steps.isEmpty }
    var hasReasoning: Bool { !(reasoning?.isEmpty ?? true) }
    var isEmpty: Bool { steps.isEmpty && !hasReasoning }

    init(message: ChatMessage, toolMessages: [ChatMessage]) {
        let calls = message.toolCalls ?? []
        var steps: [ChatProcessStep] = []
        var forms: [String: Form] = [:]
        var counts: [String: Int] = [:]
        var order: [String] = []

        for call in calls {
            let form = Form.of(toolName: call.name)
            forms[form.key] = form
            counts[form.key, default: 0] += 1
            if !order.contains(form.key) { order.append(form.key) }
            let toolMessage = toolMessages.first { $0.toolCallID == call.id }
            let output = toolMessage?.content
            steps.append(ChatProcessStep(
                id: call.id,
                title: form.title,
                icon: form.icon,
                detail: Self.detail(for: call),
                output: (output?.isEmpty ?? true) ? nil : output,
                image: toolMessage?.attachments?.first
            ))
        }

        let running = calls.contains { call in
            toolMessages.contains { $0.toolCallID == call.id && $0.isStreaming }
        }

        self.steps = steps
        self.reasoning = (message.reasoning?.isEmpty ?? true) ? nil : message.reasoning
        self.isRunning = running
        // 前缀只加一次，和参考样式一致：「已执行 2 条命令，读取 1 个网页」
        let parts = order.compactMap { key -> String? in
            guard let form = forms[key], let count = counts[key], count > 0 else { return nil }
            return "\(form.verb) \(count) \(form.unit)"
        }
        self.summary = parts.isEmpty ? "" : (running ? "正在" : "已") + parts.joined(separator: "，")
    }

    /// 只有思考、没有工具调用（折叠行只显示「思考过程」）
    init(reasoning: String?) {
        self.steps = []
        self.summary = ""
        self.isRunning = false
        self.reasoning = (reasoning?.isEmpty ?? true) ? nil : reasoning
    }

    // MARK: - 文案

    private struct Form {
        let key: String
        let title: String
        let icon: String
        let verb: String
        let unit: String

        static func of(toolName: String) -> Form {
            switch toolName {
            case AgentToolCatalog.sshExecName:
                return Form(key: "ssh", title: "执行命令", icon: "terminal", verb: "执行", unit: "条命令")
            case AgentToolCatalog.browserOpenName:
                return Form(key: "open", title: "打开网页", icon: "safari", verb: "打开", unit: "个网页")
            case AgentToolCatalog.browserReadName:
                return Form(key: "read", title: "读取网页", icon: "doc.text.magnifyingglass", verb: "读取", unit: "个网页")
            case AgentToolCatalog.githubName:
                return Form(key: "github", title: "GitHub 操作", icon: "chevron.left.forwardslash.chevron.right", verb: "调用", unit: "次 GitHub")
            case AgentToolCatalog.giteeName:
                return Form(key: "gitee", title: "Gitee 操作", icon: "chevron.left.forwardslash.chevron.right", verb: "调用", unit: "次 Gitee")
            case AgentToolCatalog.skillName:
                return Form(key: "skill", title: "调用技能", icon: "sparkles", verb: "调用", unit: "个技能")
            case AgentToolCatalog.screenshotName:
                return Form(key: "vision", title: "查看画面", icon: "eye", verb: "查看", unit: "次画面")
            case AgentToolCatalog.workspaceName:
                return Form(key: "workspace", title: "文件操作", icon: "folder", verb: "操作", unit: "次文件")
            case let name where AgentToolCatalog.isMCPTool(name):
                // MCP 工具按服务器提供的名字展示，摘要里合并计数
                return Form(key: "mcp", title: "MCP 工具", icon: "puzzlepiece.extension", verb: "调用", unit: "次 MCP 工具")
            default:
                return Form(key: toolName, title: "工具调用", icon: "wrench.and.screwdriver", verb: "调用", unit: "次工具")
            }
        }
    }

    /// 步骤详情：命令行 / URL / Git 动作与路径
    private static func detail(for call: ToolCall) -> String {
        switch call.name {
        case AgentToolCatalog.sshExecName:
            return ToolArguments.string("command", in: call.arguments) ?? call.arguments
        case AgentToolCatalog.browserOpenName, AgentToolCatalog.browserReadName:
            return ToolArguments.string("url", in: call.arguments) ?? call.arguments
        case AgentToolCatalog.githubName, AgentToolCatalog.giteeName:
            let action = ToolArguments.string("action", in: call.arguments) ?? "操作"
            if let path = ToolArguments.string("path", in: call.arguments) {
                return "\(action) · \(path)"
            }
            return action
        case AgentToolCatalog.skillName:
            return ToolArguments.string("name", in: call.arguments) ?? call.arguments
        case AgentToolCatalog.screenshotName:
            let target = ToolArguments.string("target", in: call.arguments) ?? "screen"
            return target.lowercased() == "browser" ? "内置浏览器页面" : "App 当前界面"
        case AgentToolCatalog.workspaceName:
            let action = ToolArguments.string("action", in: call.arguments) ?? "操作"
            if let path = ToolArguments.string("path", in: call.arguments) {
                return "\(action) · \(path)"
            }
            return action
        default:
            // MCP 工具的参数是服务器自定义的，直接展示第一个字符串参数
            if AgentToolCatalog.isMCPTool(call.name) {
                return call.argumentPreview
            }
            return call.arguments
        }
    }
}