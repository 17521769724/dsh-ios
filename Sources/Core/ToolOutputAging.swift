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