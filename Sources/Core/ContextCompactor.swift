import Foundation

// MARK: - token 估算

/// 粗略的 token 估算：中文按 1 字 ≈ 1 token，英文与符号按 4 字符 ≈ 1 token。
/// 只用于判断「是否接近上下文窗口上限」，真实用量以服务端返回的 usage 为准。
enum TokenEstimator {

    /// 单条消息的固定开销（角色、分隔符等）
    static let messageOverhead = 4
    /// 一张图片占用的估算值（视觉模型按图块计费，这里取经验值）
    static let imageTokens = 320

    static func estimate(_ text: String) -> Int {
        guard !text.isEmpty else { return 0 }
        var cjk = 0
        var other = 0
        for scalar in text.unicodeScalars {
            if isCJK(scalar) {
                cjk += 1
            } else {
                other += 1
            }
        }
        // 中文 1 字 1 token；其余按 4 字符 1 token（不足 1 也按 1 算，宁可高估）
        let others = other == 0 ? 0 : max(1, Int(ceil(Double(other) / 4)))
        return cjk + others
    }

    static func estimate(message: ChatMessage) -> Int {
        var total = messageOverhead + estimate(message.content)
        if let reasoning = message.reasoning { total += estimate(reasoning) }
        if let calls = message.toolCalls, !calls.isEmpty {
            total += calls.reduce(0) { $0 + estimate($1.name) + estimate($1.arguments) + 8 }
        }
        if let attachments = message.attachments, !attachments.isEmpty {
            total += attachments.count * imageTokens
        }
        return total
    }

    static func estimate(messages: [ChatMessage]) -> Int {
        messages.reduce(0) { $0 + estimate(message: $1) }
    }

    private static func isCJK(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x3000...0x303F,      // 中文标点
             0x3040...0x30FF,      // 日文假名
             0x3400...0x4DBF,      // 扩展 A
             0x4E00...0x9FFF,      // 基本汉字
             0xF900...0xFAFF,      // 兼容汉字
             0xFF00...0xFFEF,      // 全角符号
             0x20000...0x2FA1F:    // 扩展 B 及以上
            return true
        default:
            return false
        }
    }
}

// MARK: - 压缩方案

/// 一次上下文压缩的方案（纯数据，便于单测）
struct CompactionPlan {
    /// 被压成摘要的历史消息
    let summarized: [ChatMessage]
    /// 保留原文的最近消息
    let kept: [ChatMessage]

    /// 压缩前的估算 token
    var summarizedTokens: Int { TokenEstimator.estimate(messages: summarized) }
    /// 压缩后可释放的估算 token（摘要本身按几百 token 计）
    var freedTokens: Int { max(0, summarizedTokens - ContextCompactor.summaryTokens) }
}

// MARK: - 上下文压缩

/// 上下文压缩：按当前模型的上下文窗口判断是否需要压缩，
/// 需要时把较早的历史消息交给模型压成一段摘要，再用摘要替换它们。
enum ContextCompactor {

    /// 触发阈值：估算用量达到模型窗口的这个比例就压缩
    static let triggerRatio = 0.75
    /// 压缩后保留的最近消息占窗口的比例（其余交给摘要）
    static let keepRatio = 0.35
    /// 少于这么多条消息时不压缩（压了反而更贵）
    static let minimumMessages = 6
    /// 至少要有这么多条历史值得压成摘要
    static let minimumSummarized = 3
    /// 摘要本身按这个 token 数计入（用于估算释放量）
    static let summaryTokens = 400

    /// 摘要内容注入上下文时的包裹说明
    static let summaryHeader = "【此前对话的压缩摘要】"
    private static let injectionWrapper = """
    \(summaryHeader)
    下面是你与用户此前对话的压缩摘要（原文已从上下文中移除）。请把它当作已经发生过的对话继续作答，
    需要细节时再向用户确认，不要凭空编造摘要里没有的事实。

    """

    // MARK: 判断

    /// 估算的上下文用量（token）
    static func estimatedTokens(for messages: [ChatMessage]) -> Int {
        TokenEstimator.estimate(messages: messages)
    }

    /// 窗口占用比例（0...1）
    static func usageRatio(for messages: [ChatMessage], model: DSHModel) -> Double {
        guard model.contextWindow > 0 else { return 0 }
        return min(1, Double(estimatedTokens(for: messages)) / Double(model.contextWindow))
    }

    /// 是否需要压缩
    static func needsCompaction(_ messages: [ChatMessage], model: DSHModel) -> Bool {
        guard messages.count >= minimumMessages else { return false }
        guard usageRatio(for: messages, model: model) >= triggerRatio else { return false }
        return plan(for: messages, keepBudget: Int(Double(model.contextWindow) * keepRatio)) != nil
    }

    // MARK: 方案

    /// 生成压缩方案：从末尾往前保留约 keepBudget token 的最近消息，
    /// 其余作为待压缩历史；保留段的开头必须落在一条用户消息上，
    /// 避免把「工具调用」与它的工具结果拆开导致接口配对不上。
    /// - Parameter minSummarized: 至少要压掉几条历史（手动压缩时可放宽，默认用 `minimumSummarized`）
    static func plan(for messages: [ChatMessage], keepBudget: Int, minSummarized: Int? = nil) -> CompactionPlan? {
        let required = minSummarized ?? minimumSummarized
        guard messages.count > required else { return nil }

        var keptCount = 0
        var keptTokens = 0
        for message in messages.reversed() {
            let cost = TokenEstimator.estimate(message: message)
            if keptCount >= 2, keptTokens + cost > keepBudget { break }
            keptCount += 1
            keptTokens += cost
        }

        // 保留段从用户消息开始；往前找不到用户消息就整体不压缩
        var startIndex = messages.count - keptCount
        while startIndex > 0, messages[startIndex].role != .user {
            startIndex -= 1
        }
        guard startIndex > 0 else { return nil }
        guard startIndex >= required else { return nil }

        let summarized = Array(messages[..<startIndex])
        let kept = Array(messages[startIndex...])
        guard !summarized.isEmpty, !kept.isEmpty else { return nil }
        return CompactionPlan(summarized: summarized, kept: kept)
    }

    // MARK: 提示词与结果

    /// 交给模型做压缩的消息
    static func summaryMessages(for messages: [ChatMessage]) -> [APIMessage] {
        let system = """
        你是上下文压缩助手。把用户给出的多轮对话压缩成一份要点摘要，供后续继续对话使用。要求：
        1. 保留所有关键事实、结论、数据、文件路径、命令、代码片段与待办事项；
        2. 保留用户的偏好、约束与明确要求；
        3. 记下已经做过的事与结论，避免后续重复劳动；
        4. 按时间顺序组织，用简短小标题分段，不要复述寒暄；
        5. 只输出摘要正文，不要加「好的」等开场白。
        """
        return [
            APIMessage(role: "system", content: system),
            APIMessage(role: "user", content: "以下是需要压缩的对话：\n\n" + transcript(messages))
        ]
    }

    /// 摘要消息注入上下文时的正文
    static func injectedContent(_ summary: String) -> String {
        injectionWrapper + summary
    }

    /// 把摘要正文整理成一条可入库的摘要消息内容（去掉模型可能加的外壳）
    static func summaryContent(from raw: String) -> String {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix(summaryHeader) {
            text = String(text.dropFirst(summaryHeader.count))
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return text
    }

    /// 历史消息 → 纯文本记录（工具调用与其结果合并成一条，便于模型理解）
    static func transcript(_ messages: [ChatMessage]) -> String {
        var lines: [String] = []
        for message in messages {
            let who: String
            switch message.role {
            case .system: who = "系统"
            case .user: who = "用户"
            case .assistant: who = "助手"
            case .tool: who = "工具"
            }
            var body = message.content
            if let calls = message.toolCalls, !calls.isEmpty {
                let names = calls.map(\.name).joined(separator: "、")
                body = body.isEmpty ? "（调用工具：\(names)）" : body + "（调用工具：\(names)）"
            }
            if let tool = message.toolName, !body.isEmpty, message.role == .tool {
                body = "\(tool)：\(body)"
            }
            if body.isEmpty { continue }
            lines.append("\(who)：\(body)")
        }
        return lines.joined(separator: "\n\n")
    }
}