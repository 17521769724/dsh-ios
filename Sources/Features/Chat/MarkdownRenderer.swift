import SwiftUI
import UIKit

// MARK: - Markdown 块

struct MarkdownBlock: Identifiable {
    enum Kind {
        case text(String)
        case code(language: String?, content: String)
    }
    let id: Int
    let kind: Kind
    /// 是否承接上一块（同一段落因长度上限被切开），视图层据此收紧间距
    let isContinuation: Bool

    init(id: Int, kind: Kind, isContinuation: Bool = false) {
        self.id = id
        self.kind = kind
        self.isContinuation = isContinuation
    }
}

enum MarkdownParser {

    /// 单个文本块的长度上限。流式生成时「正在增长的那一块」每次刷新都要重新解析与排版，
    /// 若整篇回复（或一整段思考）就是一个大 Text，则每次刷新都对全文做一次全量排版，
    /// 长回复下这是界面卡顿的主因。按此上限切块后，每次刷新只处理最后一块。
    static let maxTextBlockLength = 600

    /// 把无序列表标记 `- ` / `* ` / `+ ` 归一化为圆点，贴近桌面端渲染效果
    static func normalizeListMarkers(_ text: String) -> String {
        text.components(separatedBy: "\n").map { line -> String in
            let stripped = line.drop(while: { $0 == " " || $0 == "\t" })
            let indent = String(line.prefix(line.count - stripped.count))
            for marker in ["- ", "* ", "+ "] where stripped.hasPrefix(marker) {
                return indent + "• " + stripped.dropFirst(marker.count)
            }
            return line
        }.joined(separator: "\n")
    }

    /// 将原始文本拆分为「普通文本块」与「代码块」，无需第三方依赖。
    /// id 由块序号生成，保证流式刷新期间视图标识稳定；
    /// 文本交给 TextChunker 分块（空行分段 + 长度上限），避免出现超大 Text。
    static func parse(_ raw: String) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        var buffer: [String] = []
        var codeLines: [String] = []
        var codeLanguage: String?
        var inCode = false

        func flushText() {
            guard !buffer.isEmpty else { return }
            let text = buffer.joined(separator: "\n")
            for chunk in TextChunker.chunk(text, maxLength: maxTextBlockLength) {
                blocks.append(MarkdownBlock(id: blocks.count, kind: .text(chunk.text), isContinuation: chunk.isContinuation))
            }
            buffer.removeAll()
        }

        func flushCode() {
            blocks.append(MarkdownBlock(
                id: blocks.count,
                kind: .code(language: codeLanguage, content: codeLines.joined(separator: "\n"))
            ))
            codeLines.removeAll()
            codeLanguage = nil
            inCode = false
        }

        for line in raw.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") {
                if inCode {
                    flushCode()
                } else {
                    flushText()
                    let language = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                    codeLanguage = language.isEmpty ? nil : language
                    inCode = true
                }
                continue
            }
            if inCode {
                codeLines.append(line)
            } else {
                buffer.append(line)
            }
        }

        if inCode {
            flushCode()
        } else {
            flushText()
        }
        return blocks
    }
}

// MARK: - 长文本分块

/// 把长文本切成多个小块，供「思考区正文」「代码块」这类原本整段一个 Text 的场景使用。
/// 流式生成时只有最后一块在增长，前面各块的排版结果可被复用，
/// 于是每次刷新的成本从「整篇长度」降到「单块长度」，长回复滚动才跟手。
enum TextChunker {

    struct Chunk: Identifiable, Equatable {
        let id: Int
        let text: String
        /// 承接上一块（同一段落被长度上限切开），视图层用零间距接上
        let isContinuation: Bool
    }

    /// - Parameters:
    ///   - maxLength: 单块长度上限
    ///   - splitsLongLines: 超长单行是否按空白处切开；代码块传 false（整行代码不能被拆断）
    static func chunk(_ text: String, maxLength: Int = 600, splitsLongLines: Bool = true) -> [Chunk] {
        var chunks: [Chunk] = []
        var buffer: [String] = []
        var bufferLength = 0
        var continuesPrevious = false

        func flush() {
            guard !buffer.isEmpty else { return }
            let joined = buffer.joined(separator: "\n")
            if !joined.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                chunks.append(Chunk(id: chunks.count, text: joined, isContinuation: continuesPrevious && !chunks.isEmpty))
            }
            buffer.removeAll()
            bufferLength = 0
            continuesPrevious = false
        }

        func append(_ piece: String) {
            buffer.append(piece)
            bufferLength += piece.count + 1
        }

        for line in text.components(separatedBy: "\n") {
            // 空行即段落边界
            if line.trimmingCharacters(in: .whitespaces).isEmpty {
                flush()
                continue
            }
            if splitsLongLines, line.count > maxLength {
                // 没有换行的超长段落：按空白处切开。切点只取决于前缀，前缀不变则切点稳定，
                // 因此已定型的块不会因为后续内容到达而改变。
                flush()
                var rest = Substring(line)
                while rest.count > maxLength {
                    let head = rest.prefix(maxLength)
                    let cut = head.lastIndex(of: " ") ?? head.endIndex
                    let piece = String(rest[rest.startIndex..<cut])
                    if !piece.isEmpty { append(piece) }
                    continuesPrevious = !chunks.isEmpty
                    flush()
                    rest = rest[cut...].drop { $0 == " " }
                }
                if !rest.isEmpty { append(String(rest)) }
                continuesPrevious = !chunks.isEmpty
                continue
            }
            append(line)
            if bufferLength >= maxLength { flush() }
        }
        flush()
        return chunks
    }
}

// MARK: - 单个文本块视图

/// 分块文本中的一块：按内容等值重绘。
/// 流式生成时只有最后一块在变，前面的块连 body 都不会重新求值，
/// 排版结果被完整复用——这是长回复（长思考）里上下滑动不掉帧的关键。
struct TextChunkView: View, Equatable {
    let text: String
    var font: Font = .system(size: 16)
    var lineSpacing: CGFloat = 0
    var color: Color = .primary
    /// 是否按行内 Markdown 渲染（正文里的 `**加粗**`、`` `代码` `` 等）
    var inlineMarkdown: Bool = false

    static func == (lhs: TextChunkView, rhs: TextChunkView) -> Bool {
        lhs.text == rhs.text && lhs.lineSpacing == rhs.lineSpacing && lhs.inlineMarkdown == rhs.inlineMarkdown
    }

    var body: some View {
        Group {
            if inlineMarkdown, let attributed = MarkdownRenderCache.shared.inline(for: text) {
                Text(attributed)
            } else {
                Text(text)
            }
        }
        .font(font)
        .foregroundStyle(color)
        .lineSpacing(lineSpacing)
        .textSelection(.enabled)
        .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - 代码块视图

struct CodeBlockView: View {
    let language: String?
    let code: String
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Text((language ?? "code").uppercased())
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    UIPasteboard.general.string = code
                    withAnimation(DSHAnim.standard) { copied = true }
                    Task {
                        try? await Task.sleep(nanoseconds: 1_400_000_000)
                        withAnimation(DSHAnim.standard) { copied = false }
                    }
                } label: {
                    Label(copied ? "已复制" : "复制", systemImage: copied ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 11, weight: .medium))
                }
                .buttonStyle(.plain)
                .foregroundStyle(copied ? DSHTheme.success : DSHTheme.brand)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            Divider().opacity(0.4)

            ScrollView(.horizontal, showsIndicators: false) {
                // 代码按行分块（不拆断整行）：长代码块在流式输出时也只有最后一块需要重排
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(TextChunker.chunk(code, maxLength: 800, splitsLongLines: false)) { chunk in
                        TextChunkView(text: chunk.text, font: .system(size: 13, design: .monospaced))
                            .equatable()
                    }
                }
                .padding(12)
            }
        }
        .background(Color(uiColor: .tertiarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: DSHTheme.Radius.chip, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: DSHTheme.Radius.chip, style: .continuous)
                .stroke(DSHTheme.separator, lineWidth: 0.5)
        )
    }
}

// MARK: - 渲染缓存

/// Markdown 渲染缓存：流式输出时同一段文本会被反复渲染，
/// 缓存块拆分结果与行内富文本，避免每个刷新周期都重新解析（长回复下开销明显）。
/// 只在主线程（视图 body）访问，故无需加锁。
final class MarkdownRenderCache {
    static let shared = MarkdownRenderCache()

    private var blocks = Cache<[MarkdownBlock]>(limit: 120)
    private var inlines = Cache<AttributedString>(limit: 240)

    func blocks(for content: String) -> [MarkdownBlock] {
        if let cached = blocks.value(for: content) { return cached }
        let parsed = MarkdownParser.parse(content)
        blocks.insert(parsed, for: content)
        return parsed
    }

    func inline(for text: String) -> AttributedString? {
        if let cached = inlines.value(for: text) { return cached }
        guard let attributed = try? AttributedString(
            markdown: text,
            options: AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        ) else {
            return nil
        }
        inlines.insert(attributed, for: text)
        return attributed
    }

    /// 超过上限时丢弃最早写入的条目
    private struct Cache<Value> {
        private var storage: [String: Value] = [:]
        private var keys: [String] = []
        private let limit: Int

        init(limit: Int) {
            self.limit = limit
        }

        mutating func value(for key: String) -> Value? {
            storage[key]
        }

        mutating func insert(_ value: Value, for key: String) {
            if storage[key] == nil {
                keys.append(key)
                if keys.count > limit {
                    let oldest = keys.removeFirst()
                    storage.removeValue(forKey: oldest)
                }
            }
            storage[key] = value
        }
    }
}

// MARK: - Markdown 内容

struct MarkdownContentView: View {
    let content: String
    var textColor: Color = .primary

    /// 段落之间的间距（VStack 统一间距会波及续写块，因此改为逐块 padding）
    private static let paragraphGap: CGFloat = DSHTheme.Spacing.medium

    var body: some View {
        let blocks = MarkdownRenderCache.shared.blocks(for: content)
        return VStack(alignment: .leading, spacing: 0) {
            ForEach(blocks) { block in
                switch block.kind {
                case .text(let text):
                    let normalized = MarkdownParser.normalizeListMarkers(text)
                    TextChunkView(
                        text: normalized,
                        font: .system(size: 16),
                        color: textColor,
                        inlineMarkdown: true
                    )
                    // 块内容没变就整块复用（含排版结果）：流式生成时只有末尾一块在重排
                    .equatable()
                    .padding(.top, topPadding(for: block))
                case .code(let language, let code):
                    CodeBlockView(language: language, code: code)
                        .padding(.top, topPadding(for: block))
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// 首块与「同段落续写块」不额外留白，段落之间才空开
    private func topPadding(for block: MarkdownBlock) -> CGFloat {
        (block.id == 0 || block.isContinuation) ? 0 : Self.paragraphGap
    }
}
