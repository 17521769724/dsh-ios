import Foundation

// MARK: - 工具结果老化

/// 工具结果「老化」（tool result clearing / observation masking）：
/// 较早轮次的工具输出（网页正文、命令输出、文件内容、截图等）体积大、对后续提问价值低，
/// 但每次请求都会把它们整段重发给模型，是 token 用量膨胀的最主要来源。
/// 发送前把较早轮次的结果替换成开头摘要、并丢弃截图；界面与会话日志仍显示完整内容，
/// 模型需要完整内容时可以重新执行该工具。
enum ToolOutputAging {

    /// 老化后保留的开头字符数（足够让模型想起「这条结果大概是什么」）
    static let excerptCharacters = 400

    /// 最后一条用户消息之后的工具结果属于「当前轮」，必须完整保留；
    /// 之前的全部老化（含截图：图片 token 高，且历史截图价值低）。
    static func aged(_ messages: [ChatMessage]) -> [ChatMessage] {
        guard let lastUserIndex = messages.lastIndex(where: { $0.role == .user }) else { return messages }
        return messages.enumerated().map { index, message in
            guard message.role == .tool, index < lastUserIndex else { return message }
            var copy = message
            if copy.content.count > excerptCharacters {
                let dropped = copy.content.count - excerptCharacters
                copy.content = String(copy.content.prefix(excerptCharacters))
                    + "\n…（较早的工具结果已省略 \(dropped) 字，需要完整内容时请重新执行该工具）"
            }
            copy.attachments = nil
            return copy
        }
    }
}

// MARK: - 单轮工具输出预算

/// 单轮（一次用户请求）内所有工具输出的累计预算。
/// 工具轮每多一轮，此前全部工具结果都会被重新发送一遍，累计输出越大，
/// 后续每一次请求都越贵；超出预算后把后续结果的截断长度收紧，压住单轮最坏情况。
struct ToolOutputBudget {

    /// 单轮累计上限（字符）
    static let totalCharacters = 30_000
    /// 超出预算后单条结果的收紧上限
    static let tightenedCharacters = 2_000

    private(set) var usedCharacters = 0

    /// 按预算截断一条工具输出，并累计实际发送量
    mutating func limit(_ text: String) -> String {
        let remaining = max(0, Self.totalCharacters - usedCharacters)
        guard text.count > remaining else {
            usedCharacters += text.count
            return text
        }
        let keep = max(Self.tightenedCharacters, remaining)
        usedCharacters += keep
        let dropped = text.count - keep
        return String(text.prefix(keep))
            + "\n…（本轮工具输出较多，已收紧截断 \(dropped) 字；请基于已有信息继续，必要时改用更精确的查询）"
    }
}