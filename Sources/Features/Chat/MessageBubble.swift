import SwiftUI
import UIKit

/// 消息视图，对齐 DeepSeek iOS 客户端：
/// 用户消息为右侧灰色气泡，助手消息无气泡、整宽排版，附折叠「思考」与操作行。
struct MessageBubble: View {
    let message: ChatMessage
    let isLastAssistant: Bool
    var onCopy: () -> Void
    var onDelete: () -> Void
    var onEdit: () -> Void
    var onRegenerate: () -> Void
    var onRate: (Int) -> Void

    @State private var showReasoning = false
    @State private var showToolOutput = false

    private var isUser: Bool { message.role == .user }

    var body: some View {
        Group {
            if message.role == .tool {
                toolRow
            } else if isUser {
                userRow
            } else {
                assistantRow
            }
        }
        .padding(.horizontal, DSHTheme.messageHorizontalPadding)
    }

    // MARK: - 用户消息

    private var userRow: some View {
        HStack {
            Spacer(minLength: 56)
            Text(message.content)
                .font(.system(size: 16))
                .foregroundStyle(DSHTheme.userText)
                .textSelection(.enabled)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(DSHTheme.userBubble)
                .clipShape(RoundedRectangle(cornerRadius: DSHTheme.Radius.bubble, style: .continuous))
                .contextMenu {
                    Button { onCopy() } label: { Label("复制", systemImage: "doc.on.doc") }
                    Button { onEdit() } label: { Label("编辑并重发", systemImage: "pencil") }
                    Button(role: .destructive) { onDelete() } label: { Label("删除", systemImage: "trash") }
                }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
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
                HStack(alignment: .bottom, spacing: 4) {
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

            if let calls = message.toolCalls, !calls.isEmpty {
                toolCallList(calls)
            }

            if !message.isStreaming && !message.content.isEmpty {
                actionRow
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - 工具调用（Agent）

    /// 助手消息里的工具调用记录
    private func toolCallList(_ calls: [ToolCall]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(calls) { call in
                HStack(spacing: 5) {
                    Image(systemName: Self.toolIcon(for: call.name))
                        .font(.system(size: 11, weight: .semibold))
                    Text(call.name)
                        .font(.system(size: 12, weight: .medium))
                    Text(call.argumentPreview)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 0)
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DSHTheme.brandSoft)
        .clipShape(RoundedRectangle(cornerRadius: DSHTheme.Radius.chip, style: .continuous))
        .accessibilityIdentifier("message.toolCall")
    }

    /// 工具执行结果消息
    private var toolRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: Self.toolIcon(for: message.toolName))
                    .font(.system(size: 12))
                Text(message.toolName ?? "工具")
                    .font(.system(size: 12, weight: .medium))
                Text(message.isStreaming ? "执行中…" : "已完成")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                if !message.isStreaming && !message.content.isEmpty {
                    Button {
                        withAnimation(DSHAnim.standard) { showToolOutput.toggle() }
                    } label: {
                        Image(systemName: "chevron.down")
                            .font(.system(size: 10, weight: .semibold))
                            .rotationEffect(.degrees(showToolOutput ? 180 : 0))
                            .frame(width: 22, height: 22)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(showToolOutput ? "收起输出" : "展开输出")
                }
            }
            .foregroundStyle(.secondary)

            if message.isStreaming {
                Text("正在执行…")
                    .font(.system(size: 12))
                    .foregroundStyle(.tertiary)
            } else if showToolOutput {
                Text(message.content)
                    .font(.system(size: 12, design: .monospaced))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(DSHTheme.Spacing.small)
                    .background(DSHTheme.reasoningBackground)
                    .clipShape(RoundedRectangle(cornerRadius: DSHTheme.Radius.chip, style: .continuous))
                    .transition(.opacity)
            } else {
                Text(preview(message.content))
                    .font(.system(size: 12))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        }
        .padding(DSHTheme.Spacing.medium)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DSHTheme.grouped)
        .clipShape(RoundedRectangle(cornerRadius: DSHTheme.Radius.card, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: DSHTheme.Radius.card, style: .continuous)
                .stroke(DSHTheme.separator.opacity(0.4), lineWidth: 0.6)
        )
        .accessibilityIdentifier("message.toolResult")
    }

    private static func toolIcon(for name: String?) -> String {
        switch name {
        case AgentToolCatalog.sshExecName: return "terminal"
        case AgentToolCatalog.browserOpenName: return "safari"
        case AgentToolCatalog.browserReadName: return "doc.text.magnifyingglass"
        default: return "wrench.and.screwdriver"
        }
    }

    /// 折叠的「思考」行
    private func reasoningRow(_ text: String) -> some View {
        VStack(alignment: .leading, spacing: DSHTheme.Spacing.small) {
            Button {
                withAnimation(DSHAnim.standard) { showReasoning.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "brain.head.profile")
                        .font(.system(size: 12))
                    Text("已思考")
                        .font(.system(size: 13, weight: .medium))
                    if !showReasoning {
                        Text(preview(text))
                            .font(.system(size: 13))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 10, weight: .semibold))
                        .rotationEffect(.degrees(showReasoning ? 180 : 0))
                }
                .foregroundStyle(.secondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("message.thinking")

            if showReasoning {
                Text(text)
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(DSHTheme.Spacing.medium)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(DSHTheme.reasoningBackground)
                    .clipShape(RoundedRectangle(cornerRadius: DSHTheme.Radius.chip, style: .continuous))
                    .transition(.opacity)
            }
        }
    }

    private func preview(_ text: String) -> String {
        let flat = text.replacingOccurrences(of: "\n", with: " ")
        return flat.count > 40 ? String(flat.prefix(40)) + "…" : flat
    }

    private var actionRow: some View {
        HStack(spacing: 20) {
            actionButton(icon: "doc.on.doc", active: false, label: "复制", action: onCopy)
            actionButton(icon: "hand.thumbsup", active: message.rating == 1, label: "有帮助") { onRate(1) }
            actionButton(icon: "hand.thumbsdown", active: message.rating == -1, label: "没帮助") { onRate(-1) }
            if isLastAssistant {
                actionButton(icon: "arrow.clockwise", active: false, label: "重新生成", action: onRegenerate)
            }
            Spacer(minLength: 0)
        }
        .padding(.top, 2)
    }

    private func actionButton(
        icon: String,
        active: Bool,
        label: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: active ? icon + ".fill" : icon)
                .font(.system(size: 14))
                .foregroundStyle(active ? DSHTheme.brand : Color.secondary)
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    private func errorView(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "exclamationmark.circle.fill")
                .font(.system(size: 13))
            Text(text)
                .font(.system(size: 14))
                .fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(DSHTheme.danger)
        .padding(DSHTheme.Spacing.medium)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DSHTheme.danger.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: DSHTheme.Radius.chip, style: .continuous))
    }
}

// MARK: - 生成中

struct TypingIndicator: View {
    @State private var animating = false

    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<3, id: \.self) { index in
                Circle()
                    .fill(Color.secondary.opacity(0.5))
                    .frame(width: 6, height: 6)
                    .opacity(animating ? 1 : 0.35)
                    .animation(
                        Animation.easeInOut(duration: 0.5)
                            .repeatForever(autoreverses: true)
                            .delay(Double(index) * 0.15),
                        value: animating
                    )
            }
        }
        .padding(.vertical, 6)
        .onAppear { animating = true }
    }
}

/// 流式输出末尾的光标
struct StreamingCursor: View {
    @State private var dim = false

    var body: some View {
        RoundedRectangle(cornerRadius: 1)
            .fill(DSHTheme.brand)
            .frame(width: 2, height: 15)
            .opacity(dim ? 0.25 : 1)
            .animation(Animation.easeInOut(duration: 0.5).repeatForever(autoreverses: true), value: dim)
            .onAppear { dim = true }
    }
}