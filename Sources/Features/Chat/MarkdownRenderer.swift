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
}

enum MarkdownParser {
    /// 将原始文本拆分为「普通文本块」与「代码块」，无需第三方依赖。
    /// id 由块序号生成，保证流式刷新期间视图标识稳定。
    static func parse(_ raw: String) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        var buffer: [String] = []
        var codeLines: [String] = []
        var codeLanguage: String?
        var inCode = false

        func flushText() {
            let text = buffer.joined(separator: "\n")
            if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                blocks.append(MarkdownBlock(id: blocks.count, kind: .text(text)))
            }
            buffer.removeAll()
        }

        for line in raw.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") {
                if inCode {
                    blocks.append(MarkdownBlock(
                        id: blocks.count,
                        kind: .code(language: codeLanguage, content: codeLines.joined(separator: "\n"))
                    ))
                    codeLines.removeAll()
                    codeLanguage = nil
                    inCode = false
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
            blocks.append(MarkdownBlock(
                id: blocks.count,
                kind: .code(language: codeLanguage, content: codeLines.joined(separator: "\n"))
            ))
        } else {
            flushText()
        }
        return blocks
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
                Text(code)
                    .font(.system(size: 13, design: .monospaced))
                    .textSelection(.enabled)
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

// MARK: - Markdown 内容

struct MarkdownContentView: View {
    let content: String
    var textColor: Color = .primary

    var body: some View {
        VStack(alignment: .leading, spacing: DSHTheme.Spacing.small) {
            ForEach(MarkdownParser.parse(content)) { block in
                switch block.kind {
                case .text(let text):
                    if let attributed = try? AttributedString(
                        markdown: text,
                        options: AttributedString.MarkdownParsingOptions(
                            interpretedSyntax: .inlineOnlyPreservingWhitespace
                        )
                    ) {
                        Text(attributed)
                            .font(.system(size: 16))
                            .foregroundStyle(textColor)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        Text(text)
                            .font(.system(size: 16))
                            .foregroundStyle(textColor)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                case .code(let language, let code):
                    CodeBlockView(language: language, code: code)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
