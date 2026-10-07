import Foundation

/// 生成过程中的增量文本缓冲。
///
/// 为什么单独成一个对象：
/// 之前每刷新一次都直接改 `ChatEngine.currentConversation`，一次 `objectWillChange`
/// 会让整棵视图树（对话列表、输入区、侧栏抽屉、导航栏）全部重算，
/// 于是「生成时滑动卡、打开侧栏也卡」。现在只有订阅它的那一个子视图会刷新，
/// 其余界面在生成期间完全不动。
///
/// 为什么按块保存：
/// 文本越长，一次性排版整段的成本越高。这里把已定型的内容切成固定上限的块，
/// 块一旦定型就不再改动，视图只做「追加新块 + 更新末尾一块」，
/// 每次刷新的排版量只与末尾一块有关，与全文长度无关。
final class StreamingText: ObservableObject {

    /// 单块长度上限（字符）
    static let blockLimit = 600

    /// 这条缓冲对应的助手消息 id（工具调用后的新一轮会切换）
    private(set) var messageID: UUID

    init(messageID: UUID) {
        self.messageID = messageID
    }

    /// 切换到新一轮助手消息（工具调用之后）：换 id 并清空
    func restart(for messageID: UUID) {
        self.messageID = messageID
        reset()
    }

    /// 完整正文与思考：不驱动界面，仅用于生成结束时落库、估算 token
    private(set) var content = ""
    private(set) var reasoning = ""

    /// 已定型的正文块（只追加，元素不再变化 → 视图可整块复用排版）
    @Published private(set) var contentBlocks: [String] = []
    /// 正在增长的正文块
    @Published private(set) var contentTail = ""

    /// 已定型的思考块 / 正在增长的思考块
    @Published private(set) var reasoningBlocks: [String] = []
    @Published private(set) var reasoningTail = ""

    /// 每次写入自增：用于驱动跟随滚动等一次性动作，不参与视图重算
    @Published private(set) var revision = 0

    var hasContent: Bool { !contentBlocks.isEmpty || !contentTail.isEmpty }
    var hasReasoning: Bool { !reasoningBlocks.isEmpty || !reasoningTail.isEmpty }

    /// 开始新的一条消息（工具调用后的新一轮）
    func reset() {
        content = ""
        reasoning = ""
        contentBlocks = []
        contentTail = ""
        reasoningBlocks = []
        reasoningTail = ""
        revision &+= 1
    }

    func appendContent(_ delta: String) {
        guard !delta.isEmpty else { return }
        content += delta
        append(delta, blocks: &contentBlocks, tail: &contentTail)
        revision &+= 1
    }

    func appendReasoning(_ delta: String) {
        guard !delta.isEmpty else { return }
        reasoning += delta
        append(delta, blocks: &reasoningBlocks, tail: &reasoningTail)
        revision &+= 1
    }

    // MARK: - 分块

    private func append(_ delta: String, blocks: inout [String], tail: inout String) {
        tail += delta
        while tail.count > Self.blockLimit {
            let cut = Self.splitIndex(in: tail, limit: Self.blockLimit)
            blocks.append(String(tail[tail.startIndex..<cut]))
            // 段落分隔由块间距表达，这里去掉块首的空行，避免正文里出现多余空行
            tail = String(tail[cut...].drop { $0 == "\n" })
        }
    }

    /// 在 limit 附近挑一个自然切点：优先空行，其次换行，其次空格。
    /// 切点只取决于前面的内容，因此已定型的块不会因后续增量而改变。
    private static func splitIndex(in text: String, limit: Int) -> String.Index {
        let head = text.prefix(limit)
        if let blank = head.range(of: "\n\n", options: .backwards) {
            return blank.lowerBound
        }
        if let newline = head.lastIndex(of: "\n") {
            return text.index(after: newline)
        }
        if let space = head.lastIndex(of: " ") {
            return text.index(after: space)
        }
        return head.endIndex
    }
}