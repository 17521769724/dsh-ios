import Foundation

/// 提供给模型的工具定义（OpenAI 兼容 function calling）
enum AgentToolCatalog {

    static let sshExecName = "ssh_exec"
    static let browserOpenName = "browser_open"
    static let browserReadName = "browser_read"

    /// 当前可用的工具：只有开启且可用的工具才下发给模型，
    /// 避免模型调用必然失败的工具（SSH 未配置、浏览器功能关闭等）。
    static func tools(
        sshEnabled: Bool,
        browserEnabled: Bool,
        browserReadEnabled: Bool
    ) -> [APITool] {
        var tools: [APITool] = []
        if sshEnabled {
            tools.append(sshExec)
        }
        if browserEnabled {
            tools.append(browserOpen)
            if browserReadEnabled {
                tools.append(browserRead)
            }
        }
        return tools
    }

    static let sshExec = APITool(
        name: sshExecName,
        description: """
        在用户已配置的云服务器上通过 SSH 执行一条 shell 命令，返回命令输出（stdout 与 stderr 合并，超长会截断）。\
        适合查看服务器状态、安装软件、部署代码、修改配置等操作。执行前先用一句话说明你要做什么。
        """,
        parameters: schema("""
        {
          "type": "object",
          "properties": {
            "command": {
              "type": "string",
              "description": "要执行的完整 shell 命令，例如 ls -la /var/www"
            }
          },
          "required": ["command"]
        }
        """)
    )

    static let browserOpen = APITool(
        name: browserOpenName,
        description: "在 App 的内置浏览器中打开网页，用户会直接看到这个页面。参数是完整网址（http/https）。",
        parameters: schema("""
        {
          "type": "object",
          "properties": {
            "url": {
              "type": "string",
              "description": "要打开的完整网址，例如 https://example.com"
            }
          },
          "required": ["url"]
        }
        """)
    )

    static let browserRead = APITool(
        name: browserReadName,
        description: "用内置浏览器打开并读取网页正文纯文本（用户看不到页面），适合总结文章、查询资料。参数是完整网址。",
        parameters: schema("""
        {
          "type": "object",
          "properties": {
            "url": {
              "type": "string",
              "description": "要读取的完整网址，例如 https://example.com/article"
            }
          },
          "required": ["url"]
        }
        """)
    )

    /// JSON 文本 → [String: Any]，避免手写嵌套字典字面量的类型推断问题
    private static func schema(_ json: String) -> [String: Any] {
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return ["type": "object", "properties": [String: Any]()]
        }
        return object
    }
}

/// 工具参数解析
enum ToolArguments {
    /// 读取字符串参数并去除首尾空白
    static func string(_ key: String, in raw: String) -> String? {
        guard let data = raw.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let value = object[key] as? String else {
            return nil
        }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}