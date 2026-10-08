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
    /// 系统剪贴板：读写复制内容
    static let clipboardName = "clipboard"
    /// 提醒事项与日历：本地读写待办与日程
    static let reminderName = "reminder"
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
        clipboardEnabled: Bool = false,
        reminderEnabled: Bool = false,
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
        if clipboardEnabled {
            tools.append(clipboard)
        }
        if reminderEnabled {
            tools.append(reminder)
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

    /// 系统剪贴板：写入 / 读取复制内容
    static let clipboard = APITool(
        name: clipboardName,
        description: """
        读写系统剪贴板。action=read 读取剪贴板里的文本（首次读取系统会弹出「允许粘贴」确认，需要用户点允许）；\
        action=write 把 text 写入剪贴板，用户之后可在任意 App 里粘贴。\
        适合「把这段复制给我」「读一下我刚复制的内容」这类请求。
        """,
        parameters: schema("""
        {
          "type": "object",
          "properties": {
            "action": {
              "type": "string",
              "description": "操作类型：read=读取，write=写入",
              "enum": ["read", "write"]
            },
            "text": {
              "type": "string",
              "description": "要写入剪贴板的文本（write 时必填），原样写入不做裁剪"
            }
          },
          "required": ["action"]
        }
        """)
    )

    /// 提醒事项与日历：本机 EventKit，读写待办与日程
    static let reminder = APITool(
        name: reminderName,
        description: """
        读写系统「提醒事项」与「日历」（只在本机操作，不上传任何服务器；首次使用会请求系统权限）。可用动作：
        list_reminders（列出未完成提醒，可用 days 指定往后看几天，默认 7，逾期 30 天内的也会列出）、
        create_reminder（新建提醒，需要 title，可选 due「2026-10-10 09:00」、notes、list 清单名）、
        list_events（列出未来日程，days 默认 7）、
        create_event（新建日程，需要 title 与 start，可选 end、location、notes，默认时长 1 小时）。
        """,
        parameters: schema("""
        {
          "type": "object",
          "properties": {
            "action": {
              "type": "string",
              "description": "操作类型，见工具说明",
              "enum": ["list_reminders", "create_reminder", "list_events", "create_event"]
            },
            "title": {
              "type": "string",
              "description": "标题（create_reminder / create_event 必填）"
            },
            "due": {
              "type": "string",
              "description": "提醒到期时间，例如 2026-10-10 09:00；只写日期时按当天 09:00"
            },
            "start": {
              "type": "string",
              "description": "日程开始时间，例如 2026-10-10 15:00"
            },
            "end": {
              "type": "string",
              "description": "日程结束时间（可省略，默认开始后 1 小时）"
            },
            "days": {
              "type": "integer",
              "description": "查询往后看几天，默认 7"
            },
            "notes": {
              "type": "string",
              "description": "备注"
            },
            "location": {
              "type": "string",
              "description": "地点（create_event）"
            },
            "list": {
              "type": "string",
              "description": "提醒清单名称（可省略，默认用系统默认清单）"
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

    /// 把参数整体解析成字典（提醒事项这类参数较多的工具用）
    static func dictionary(_ raw: String) -> [String: Any] {
        guard let data = raw.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return [:]
        }
        return object
    }
}