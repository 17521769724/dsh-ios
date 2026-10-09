import SwiftUI

// MARK: - 长文本分块渲染

/// 长文本按块渲染：已定型的块整块复用排版结果，只有末尾一块随生成刷新。
/// 用于「过程」弹窗里的思考内容等场景。
struct ChunkedText: View {
    let text: String
    var font: Font = .system(size: 14)
    var lineSpacing: CGFloat = 3
    var color: Color = DSHTheme.secondaryText
    var inlineMarkdown: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(TextChunker.chunk(text)) { chunk in
                TextChunkView(
                    text: chunk.text,
                    font: font,
                    lineSpacing: lineSpacing,
                    color: color,
                    inlineMarkdown: inlineMarkdown
                )
                .equatable()
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, chunk.id == 0 || chunk.isContinuation ? 0 : DSHTheme.Spacing.small)
            }
        }
    }
}

// MARK: - 折叠行入口

/// 助手消息里的「过程」折叠行：一行文字 + 小箭头，点击弹出详情
struct ProcessRowButton: View {
    let icon: String
    let text: String
    /// 无障碍标识（沿用 message.thinking，界面测试依赖）
    var identifier: String = ""
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .medium))
                Text(text)
                    .font(.system(size: 13))
                    .lineLimit(1)
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                Spacer(minLength: 0)
            }
            .foregroundStyle(DSHTheme.tertiaryText)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(identifier)
    }
}

// MARK: - 过程弹窗

/// 弹窗内容类型：思考过程与工具步骤各自独立展示。
/// 此前两个入口都打开同一份「过程」，用户点开发现内容一模一样。
enum ProcessSheetMode: String, Identifiable {
    /// 只看思考过程
    case reasoning
    /// 只看工具步骤
    case steps

    var id: String { rawValue }

    var title: String {
        switch self {
        case .reasoning: return "思考过程"
        case .steps: return "工具过程"
        }
    }

    /// 没有对应内容时的说明
    var emptyHint: String {
        switch self {
        case .reasoning: return "这次回复没有思考内容。"
        case .steps: return "这次回复没有调用工具。"
        }
    }
}

/// 「过程」弹窗：按 `mode` 只展示思考内容或工具步骤
struct ProcessSheet: View {
    let mode: ProcessSheetMode
    var steps: [ChatProcessStep] = []
    var reasoning: String?
    /// 生成中的实时思考：弹窗打开期间内容继续增长
    var liveReasoning: StreamingText?

    /// 工具输出过长时截断，避免弹窗打开时排版过重
    private static let outputLimit = 4_000

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: DSHTheme.Spacing.section) {
                    switch mode {
                    case .steps:
                        if steps.isEmpty {
                            emptyHintText
                        } else {
                            ForEach(steps) { step in
                                stepSection(step)
                            }
                        }
                    case .reasoning:
                        if hasReasoning {
                            reasoningSection
                        } else {
                            emptyHintText
                        }
                    }
                }
                .padding(DSHTheme.Spacing.large)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(DSHTheme.page)
            .navigationTitle(mode.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button { dismiss() } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(DSHTheme.secondaryText)
                    }
                    .accessibilityLabel("关闭")
                }
            }
        }
    }

    // MARK: 步骤

    /// 是否有思考内容可展示
    private var hasReasoning: Bool {
        (reasoning?.isEmpty == false) || liveReasoning != nil
    }

    private var emptyHintText: some View {
        Text(mode.emptyHint)
            .font(.system(size: 13))
            .foregroundStyle(DSHTheme.tertiaryText)
    }

    private func stepSection(_ step: ChatProcessStep) -> some View {
        VStack(alignment: .leading, spacing: DSHTheme.Spacing.small) {
            ProcessSectionHeader(icon: step.icon, title: step.title)
            VStack(alignment: .leading, spacing: DSHTheme.Spacing.small) {
                Text(step.detail)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(DSHTheme.secondaryText)
                    .lineLimit(3)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
                // 「查看画面」的截图：让用户看到模型究竟看到了什么
                if let attachment = step.image,
                   let image = AttachmentImageCache.image(for: attachment, maxSide: 900) {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: .infinity)
                        .overlay(
                            RoundedRectangle(cornerRadius: DSHTheme.Radius.card, style: .continuous)
                                .stroke(DSHTheme.separator.opacity(0.8), lineWidth: 0.5)
                        )
                        .clipShape(RoundedRectangle(cornerRadius: DSHTheme.Radius.card, style: .continuous))
                }
                if let output = step.output {
                    Text(Self.trimmed(output))
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(DSHTheme.tertiaryText)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(DSHTheme.Spacing.small)
                        .background(DSHTheme.grouped)
                        .clipShape(RoundedRectangle(cornerRadius: DSHTheme.Radius.chip, style: .continuous))
                }
            }
            .padding(.leading, 22)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private static func trimmed(_ text: String) -> String {
        text.count > outputLimit ? String(text.prefix(outputLimit)) + "\n…（内容过长，已截断）" : text
    }

    // MARK: 思考过程

    @ViewBuilder
    private var reasoningSection: some View {
        if let liveReasoning {
            LiveReasoningSection(buffer: liveReasoning)
        } else if let reasoning, !reasoning.isEmpty {
            VStack(alignment: .leading, spacing: DSHTheme.Spacing.small) {
                ProcessSectionHeader(icon: "brain.head.profile", title: "思考过程")
                ChunkedText(text: reasoning)
                    .padding(.leading, 22)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// 生成中的思考内容：订阅流式缓冲，弹窗内实时刷新
private struct LiveReasoningSection: View {
    @ObservedObject var buffer: StreamingText

    var body: some View {
        VStack(alignment: .leading, spacing: DSHTheme.Spacing.small) {
            ProcessSectionHeader(icon: "brain.head.profile", title: "思考过程")
            if buffer.reasoning.isEmpty {
                Text("正在思考…")
                    .font(.system(size: 13))
                    .foregroundStyle(DSHTheme.tertiaryText)
                    .padding(.leading, 22)
            } else {
                ChunkedText(text: buffer.reasoning)
                    .padding(.leading, 22)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// 弹窗里的小标题：图标 + 文案
private struct ProcessSectionHeader: View {
    let icon: String
    let title: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .semibold))
            Text(title)
                .font(.system(size: 14, weight: .medium))
            Spacer(minLength: 0)
        }
        .foregroundStyle(DSHTheme.assistantText)
    }
}