import Foundation

/// 发送前修复「工具调用配对」。
///
/// 接口要求：带 `tool_calls` 的助手消息后面必须紧跟每个 `tool_call_id` 对应的工具消息。
/// 一旦生成被中途停止（工具还没跑完、占位消息还是空的），历史里就会留下一对不完整的记录，
/// 之后**每一次**请求都会被服务端以 400 拒绝（用户实测报错：
/// “An assistant message with 'tool_calls' must be followed by tool messages responding to each
/// 'tool_call_id'. (insufficient tool messages following tool_calls message)”）。
/// 这里在发送前统一修复：空结果补占位、配不上的调用与孤儿工具消息一并去掉。
enum ToolCallRepair {

    /// 工具没有产出结果时的占位文案
    static let missingResult = "（工具未返回结果）"

    static func repaired(_ messages: [ChatMessage]) -> [ChatMessage] {
        var result = messages

        // 1. 内容为空的工具结果补上占位：否则发送时会被整条跳过，配对再次缺失
        for index in result.indices where result[index].role == .tool {
            if result[index].content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                result[index].content = missingResult
            }
        }

        var dropped = Set<Int>()

        // 2. 逐个检查带 tool_calls 的助手消息：只保留「紧随其后确实有结果」的调用
        for index in result.indices where result[index].role == .assistant {
            guard let calls = result[index].toolCalls, !calls.isEmpty else { continue }
            var cursor = index + 1
            var followingTools: [Int] = []
            while cursor < result.count, result[cursor].role == .tool {
                followingTools.append(cursor)
                cursor += 1
            }
            let answered = Set(followingTools.compactMap { result[$0].toolCallID })
            let kept = calls.filter { answered.contains($0.id) }

            if kept.isEmpty {
                // 一个结果都没有：去掉调用，后面的工具消息也一并丢弃
                result[index].toolCalls = nil
                dropped.formUnion(followingTools)
            } else {
                result[index].toolCalls = kept
                let keptIDs = Set(kept.map(\.id))
                for toolIndex in followingTools where !keptIDs.contains(result[toolIndex].toolCallID ?? "") {
                    dropped.insert(toolIndex)
                }
            }
        }

        // 3. 没有对应调用的孤儿工具消息（例如被上面的处理摘掉了调用）也去掉
        for index in result.indices where result[index].role == .tool {
            var cursor = index - 1
            while cursor >= 0, result[cursor].role == .tool { cursor -= 1 }
            let matched = cursor >= 0
                && result[cursor].role == .assistant
                && (result[cursor].toolCalls?.contains { $0.id == result[index].toolCallID } ?? false)
            if !matched { dropped.insert(index) }
        }

        return result.enumerated()
            .filter { !dropped.contains($0.offset) }
            .map(\.element)
    }
}