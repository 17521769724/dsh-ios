import SwiftUI
import UIKit

/// 消息视图，对齐 DSH Desktop 的呈现方式：
/// - 用户消息：右对齐深色气泡
/// - 助手消息：无气泡纯文本，左对齐铺满，附折叠「思考」行与操作图标行
struct MessageBubble: View {
    let message: ChatMessage
    let isLastAssistant: Bool
    let isStreaming: Bool
    var onCopy: () -> Void
    var onDelete: () -> Void
    var onEdit: () -> Void
    var onRegenerate: () -> Void
    var onRate: (Int) -> Void

    @State private var showReasoning = false
    @State private var appeared = false

    private var isUser: Bool { message.role == .user }

    var body: some View {
        Group {
            if isUser {
                userRow
            } else {
                assistantRow
            }
        }
        .padding(.horizontal, DSHTheme.Spacing.large)
        .padding(.vertical, isUser ? 4 : 8)
        .opacity(appeared ? 1 : 0)
        .offset(y: appeared ? 0 : 8)
        .onAppear {
            withAnimation(DSHAnim.list.delay(0.015)) { appeared = true }
        }
    }

    // MARK: - 用户消息

    private var userRow: some View {
        HStack {
            Spacer(minLength: 48)
            Text(message.content)
                .font(.system(size: 15))
                .foregroundStyle(DSHTheme.userText)
                .textSelection(.enabled)
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .background(DSHTheme.userBubble)
                .clipShape(RoundedRectangle(cornerRadius: DSHTheme.Radius.bubble, style: .continuous))
                .contextMenu {
                    Button {
                        onCopy()
                    } label: {
                        Label("复制", systemImage: "doc.on.doc")
                    }
                    Button {
                        onEdit()
                    } label: {
                        Label("编辑并重发", systemImage: "pencil")
                    }
                    Button(role: .destructive) {
                        onDelete()
                    } label: {
                        Label("删除", systemImage: "trash")
                    }
                }
        }
    }

    // MARK: - 助手消息

    private var assistantRow: some View {
        VStack(alignment: .leading, spacing: DSHTheme.Spacing.small) {
            if let reasoning = message.reasoning, !reasoning.isEmpty {
                reasoningRow(reasoning)
            }

            if message.content.isEmpty && message.isStreaming {
                TypingIndicator()
            } else {
                VStack(alignment: .leading, spacing: 2) {
                    MarkdownContentView(content: message.content)
                    if message.isStreaming {
                        StreamingCursor()
                    }
                }
                .animation(DSHAnim.stream, value: message.content)
            }

            if let error = message.errorText {
                errorView(error)
            }

            if !message.isStreaming && !message.content.isEmpty {
                actionRow
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// 折叠的「思考」行，对齐桌面端 Think 行的交互
    private func reasoningRow(_ text: String) -> some View {
        VStack(alignment: .leading, spacing: DSHTheme.Spacing.small) {
            Button {
                withAnimation(DSHAnim.standard) { showReasoning.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "brain")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    Text("Think")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.secondary)
                    if !showReasoning {
                        Text(preview(text))
                            .font(.system(size: 13))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: showReasoning ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.tertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if showReasoning {
                Text(text)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(DSHTheme.reasoningBackground)
                    .clipShape(RoundedRectangle(cornerRadius: DSHTheme.Radius.chip, style: .continuous))
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(.bottom, 2)
    }

    private func preview(_ text: String) -> String {
        let flat = text.replacingOccurrences(of: "\n", with: " ")
        return flat.count > 64 ? String(flat.prefix(64)) + "…" : flat
    }

    /// 操作图标行：复制 / 赞 / 踩 / 重新生成
    private var actionRow: some View {
        HStack(spacing: 18) {
            actionButton(icon: "doc.on.doc", active: false, help: "复制") { onCopy() }
            actionButton(icon: "hand.thumbsup", active: message.rating == 1, help: "有帮助") {
                onRate(1)
            }
            actionButton(icon: "hand.thumbsdown", active: message.rating == -1, help: "没帮助") {
                onRate(-1)
            }
            if isLastAssistant {
                actionButton(icon: "arrow.clockwise", active: false, help: "重新生成") {
                    onRegenerate()
                }
            }
            Spacer(minLength: 0)
            if let tokens = message.completionTokens {
                Text("\(tokens) tok")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.top, 2)
    }

    private func actionButton(icon: String, active: Bool, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: active ? icon + ".fill" : icon)
                .font(.system(size: 13))
                .foregroundStyle(active ? DSHTheme.brand : Color.secondary)
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(help)
    }

    private func errorView(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 12))
                .foregroundStyle(DSHTheme.danger)
            Text(text)
                .font(.system(size: 13))
                .foregroundStyle(DSHTheme.danger)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DSHTheme.danger.opacity(0.10))
        .clipShape(RoundedRectangle(cornerRadius: DSHTheme.Radius.chip, style: .continuous))
    }
}

// MARK: - 打字指示器

struct TypingIndicator: View {
    @State private var animating = false

    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<3, id: \.self) { index in
                Circle()
                    .fill(Color.secondary.opacity(0.55))
                    .frame(width: 6, height: 6)
                    .scaleEffect(animating ? 1.3 : 0.85)
                    .animation(
                        Animation.easeInOut(duration: 0.5)
                            .repeatForever(autoreverses: true)
                            .delay(Double(index) * 0.15),
                        value: animating
                    )
            }
        }
        .padding(.vertical, 5)
        .onAppear { animating = true }
    }
}

/// 流式输出末尾的呼吸光标
struct StreamingCursor: View {
    @State private var dim = false

    var body: some View {
        RoundedRectangle(cornerRadius: 1)
            .fill(DSHTheme.brand)
            .frame(width: 2, height: 14)
            .opacity(dim ? 0.2 : 1)
            .animation(Animation.easeInOut(duration: 0.55).repeatForever(autoreverses: true), value: dim)
            .onAppear { dim = true }
    }
}