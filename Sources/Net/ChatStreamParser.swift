import Foundation

/// 流式响应解析结果（对外转换为 `StreamEvent`）
enum ChatStreamParseResult: Equatable {
    case content(String)
    case reasoning(String)
    case toolCalls([ToolCall])
    case usage(TokenUsage)
    case done
}

/// OpenAI 兼容的 SSE 增量解析：
/// 负责拼接 content / reasoning_content 增量，并把分片的 tool_calls 拼装成完整调用。
struct ChatStreamParser {

    private var toolAccumulator: [Int: (id: String, name: String, arguments: String)] = [:]
    private var flushedToolCalls = false

    /// 消费一行 SSE 数据，返回本行产生的所有事件
    mutating func consume(line: String) -> [ChatStreamParseResult] {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("data:") else { return [] }
        let json = trimmed.dropFirst(5).trimmingCharacters(in: .whitespaces)
        guard !json.isEmpty else { return [] }

        if json == "[DONE]" {
            var results: [ChatStreamParseResult] = []
            if let calls = flushToolCalls() { results.append(.toolCalls(calls)) }
            results.append(.done)
            return results
        }

        guard let data = json.data(using: .utf8),
              let chunk = try? JSONDecoder().decode(ChatStreamChunk.self, from: data) else {
            return []
        }

        var results: [ChatStreamParseResult] = []
        let choice = chunk.choices.first

        if let reasoning = choice?.delta?.reasoningContent, !reasoning.isEmpty {
            results.append(.reasoning(reasoning))
        }
        if let content = choice?.delta?.content, !content.isEmpty {
            results.append(.content(content))
        }
        if let deltas = choice?.delta?.toolCalls, !deltas.isEmpty {
            merge(deltas)
        }
        if choice?.finishReason == "tool_calls", let calls = flushToolCalls() {
            results.append(.toolCalls(calls))
        }
        if let usage = chunk.usage {
            results.append(.usage(usage))
        }
        return results
    }

    /// 连接结束（可能没有 [DONE]）时补齐工具调用
    mutating func finish() -> [ChatStreamParseResult] {
        guard let calls = flushToolCalls() else { return [] }
        return [.toolCalls(calls)]
    }

    // MARK: - 工具调用拼接

    private mutating func merge(_ deltas: [ChatStreamToolCallDelta]) {
        for delta in deltas {
            var entry = toolAccumulator[delta.index] ?? (id: "", name: "", arguments: "")
            if let id = delta.id, !id.isEmpty { entry.id = id }
            if let name = delta.function?.name, !name.isEmpty { entry.name = name }
            if let arguments = delta.function?.arguments { entry.arguments += arguments }
            toolAccumulator[delta.index] = entry
        }
    }

    private mutating func flushToolCalls() -> [ToolCall]? {
        guard !flushedToolCalls, !toolAccumulator.isEmpty else { return nil }
        flushedToolCalls = true
        let calls = toolAccumulator.keys.sorted().compactMap { index -> ToolCall? in
            guard let entry = toolAccumulator[index], !entry.name.isEmpty else { return nil }
            return ToolCall(
                id: entry.id.isEmpty ? UUID().uuidString : entry.id,
                name: entry.name,
                arguments: entry.arguments
            )
        }
        toolAccumulator.removeAll()
        return calls.isEmpty ? nil : calls
    }
}

// MARK: - 解码结构

struct ChatStreamToolCallDelta: Decodable {
    struct Function: Decodable {
        let name: String?
        let arguments: String?
    }

    let index: Int
    let id: String?
    let function: Function?
}

struct ChatStreamChunk: Decodable {
    struct Choice: Decodable {
        struct Delta: Decodable {
            let content: String?
            let reasoningContent: String?
            let toolCalls: [ChatStreamToolCallDelta]?

            enum CodingKeys: String, CodingKey {
                case content
                case reasoningContent = "reasoning_content"
                case toolCalls = "tool_calls"
            }
        }

        let delta: Delta?
        let finishReason: String?

        enum CodingKeys: String, CodingKey {
            case delta
            case finishReason = "finish_reason"
        }
    }

    let choices: [Choice]
    let usage: TokenUsage?
}