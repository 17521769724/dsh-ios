import Foundation

/// 提供给模型的工具定义（OpenAI 兼容 function calling）
enum AgentToolCatalog {

    static let sshExecName = "ssh_exec"
    static let browserOpenName = "browser_open"
    static let browserReadName = "browser_read"
    static let githubName = "github"
    static let giteeName = "gitee"
    /// 读取用户自定义技能（技能规定做法，工具执行操作，两者互补）
    static let skillName = "skill"
    /// 查看画面：截取界面 / 内置浏览器并用本地 OCR 识别文字
    static let screenshotName = "screenshot"
    /// 工作区文件：读写内置文件管理器与 IDE 所在的文件夹
    static let workspaceName = "workspace"
    /// MCP 工具名前缀（模型侧形如 mcp_<服务器别名>_<工具名>）
    static let mcpToolPrefix = "mcp_"

    /// 是否为 MCP 服务器提供的工具
    static func isMCPTool(_ name: String) -> Bool {
        name.hasPrefix(mcpToolPrefix)
    }

    /// 当前可用的工具：只有开启且可用的工具才下发给模型，
    /// 避免模型调用必然失败的工具（SSH 未配置、浏览器功能关闭等）。
    static func tools(
        sshEnabled: Bool,
        browserEnabled: Bool,
        browserReadEnabled: Bool,
        githubEnabled: Bool = false,
        giteeEnabled: Bool = false,
        visionEnabled: Bool = false,
        fileEnabled: Bool = false,
        mcpTools: [APITool] = [],
        skillNames: [String] = []
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
        if visionEnabled {
            tools.append(screenshot)
        }
        if fileEnabled {
            tools.append(workspace)
        }
        // MCP 服务器提供的工具由各自的服务器描述，这里原样追加
        tools.append(contentsOf: mcpTools)
        if githubEnabled {
            tools.append(github)
        }
        if giteeEnabled {
            tools.append(gitee)
        }
        // 只有存在已启用技能时才下发，避免模型调用空技能库
        if !skillNames.isEmpty {
            tools.append(skill(names: skillNames))
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

    /// 查看画面：截取界面并用本地 OCR 识别文字，同时把截图作为图片发给模型。
    /// 视觉模型可以直接「看到」用户界面或浏览器页面，纯文本模型也有 OCR 文本可用。
    static let screenshot = APITool(
        name: screenshotName,
        description: """
        截取画面并识别其中的文字（本地 OCR），同时把截图作为图片发给你。\
        target=screen 截取 App 当前界面（用户正在看的内容），target=browser 截取内置浏览器当前页面。\
        适合用户说「你看看这个」「这页里写了什么」「帮我确认报错」这类需要你亲眼看一眼的场景；\
        要看某个网址时先调用 browser_open 打开它，再用 target=browser 截图。
        """,
        parameters: schema("""
        {
          "type": "object",
          "properties": {
            "target": {
              "type": "string",
              "description": "要查看的位置：screen=App 当前界面（默认），browser=内置浏览器页面",
              "enum": ["screen", "browser"]
            },
            "reason": {
              "type": "string",
              "description": "想通过画面确认什么，例如「读出页面上的价格」「确认报错提示」"
            }
          },
          "required": []
        }
        """)
    )

    /// 工作区文件：与内置文件管理器 / IDE 共用同一批文件，
    /// 模型写下的代码可以直接在 App 里用编辑器打开继续改。
    static let workspace = APITool(
        name: workspaceName,
        description: """
        读写 App 工作区里的文件（内置「文件」页与 IDE 所在的文件夹，用户也能在系统「文件」App 里看到）。\
        可用动作：list（列出目录）、read（读取文本文件）、write（新建或覆盖文件）、mkdir（新建文件夹）、delete（删除文件或文件夹）。\
        路径使用相对工作区的写法，例如 src/main.swift；省略 path 表示工作区根目录。
        """,
        parameters: schema("""
        {
          "type": "object",
          "properties": {
            "action": {
              "type": "string",
              "description": "操作类型：list / read / write / mkdir / delete",
              "enum": ["list", "read", "write", "mkdir", "delete"]
            },
            "path": {
              "type": "string",
              "description": "相对工作区的路径，例如 src/main.swift；省略表示工作区根目录"
            },
            "content": {
              "type": "string",
              "description": "文件内容（write 时必填），原样写入，不做裁剪"
            }
          },
          "required": ["action"]
        }
        """)
    )

    static let github = APITool(
        name: githubName,
        description: """
        操作 GitHub 仓库与 Issue。需要用户先在「设置 → 智能体工具」登录 GitHub 账号并开启 GitHub 工具。
        可用动作：list_repos（列出账号下的仓库）、read_file（读取仓库文件）、write_file（新建或更新文件）、create_issue（创建 Issue）。
        """,
        parameters: gitParameters
    )

    static let gitee = APITool(
        name: giteeName,
        description: """
        操作 Gitee 仓库与 Issue。需要用户先在「设置 → 智能体工具」登录 Gitee 账号并开启 Gitee 工具。
        可用动作：list_repos（列出账号下的仓库）、read_file（读取仓库文件）、write_file（新建或更新文件）、create_issue（创建 Issue）。
        """,
        parameters: gitParameters
    )

    /// 技能工具：把用户自己写的技能全文取回来照着做。
    /// 入参带上当前已启用的技能名，模型就能准确选中要用的那一个。
    private static func skill(names: [String]) -> APITool {
        let list = names.map { "「\($0)」" }.joined(separator: "、")
        let escaped = names
            .map { $0.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") }
            .map { "\"\($0)\"" }
            .joined(separator: ", ")
        return APITool(
            name: skillName,
            description: """
            读取用户自定义技能的完整说明，然后按该技能规定的步骤与要求完成任务。
            可用技能：\(list)。
            技能规定「该怎么做」，工具负责「真正执行」；与当前请求相关的技能应先取回说明再动手。
            """,
            parameters: schema("""
            {
              "type": "object",
              "properties": {
                "name": {
                  "type": "string",
                  "description": "技能名，必须是可用技能之一",
                  "enum": [\(escaped)]
                }
              },
              "required": ["name"]
            }
            """)
        )
    }

    /// GitHub 与 Gitee 的动作和参数完全一致，共用同一套参数描述
    private static let gitParameters = schema("""
    {
      "type": "object",
      "properties": {
        "action": {
          "type": "string",
          "description": "操作类型：list_repos / read_file / write_file / create_issue",
          "enum": ["list_repos", "read_file", "write_file", "create_issue"]
        },
        "repo": {
          "type": "string",
          "description": "仓库名，格式 owner/name，例如 deepseek-ai/DeepSeek-V3"
        },
        "path": {
          "type": "string",
          "description": "文件路径，例如 src/main.swift"
        },
        "branch": {
          "type": "string",
          "description": "分支名，默认使用仓库默认分支"
        },
        "content": {
          "type": "string",
          "description": "文件内容（write_file 时必填）"
        },
        "message": {
          "type": "string",
          "description": "提交信息（write_file 时可选）"
        },
        "title": {
          "type": "string",
          "description": "Issue 标题（create_issue 时必填）"
        },
        "body": {
          "type": "string",
          "description": "Issue 内容（create_issue 时可选）"
        }
      },
      "required": ["action"]
    }
    """)

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

    /// 读取字符串参数并保留原始空白：写文件内容时用，
    /// 代码里的缩进、换行与结尾空行不能被裁掉。
    static func rawString(_ key: String, in raw: String) -> String? {
        guard let data = raw.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let value = object[key] as? String else {
            return nil
        }
        return value
    }
}