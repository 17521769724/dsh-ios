import SwiftUI
import UIKit

/// 消息视图，对齐 TraeCode 的呈现方式：
/// 用户消息为右侧灰色气泡；助手消息整宽排版，正文只展示叙述性内容，
/// 「思考过程」「工具过程」折叠为一行，点击弹出「过程」弹窗查看细节。
struct MessageBubble: View, Equatable {
    let message: ChatMessage
    let isLastAssistant: Bool
    /// 是否显示操作图标（复制 / 点赞 / 重新生成）：仅一轮里的最终回复，
    /// 且生成已完全停止（用户反馈：生成过程中每条中间回复都冒出图标太吵）
    let showsActions: Bool
    /// 会话正在生成的缓冲：只有正在输出的那条消息会用到
    let streaming: StreamingText?
    /// 这条消息的「过程」（思考 + 工具步骤），为空时不显示折叠行
    let process: ChatProcess?
    var onCopy: () -> Void
    var onDelete: () -> Void
    var onEdit: () -> Void
    var onRegenerate: () -> Void
    var onRate: (Int) -> Void

    /// 只按「消息内容 + 是否最后一条助手消息 + 过程 + 流式缓冲」判断是否需要重绘：
    /// 生成过程中其它气泡因此完全不参与重绘，是滚动流畅的关键。
    /// 回调闭包各自捕获本条消息，内容相同则行为一致，无需参与比较。
    static func == (lhs: MessageBubble, rhs: MessageBubble) -> Bool {
        lhs.message == rhs.message
            && lhs.isLastAssistant == rhs.isLastAssistant
            && lhs.showsActions == rhs.showsActions
            && lhs.process == rhs.process
            && lhs.streaming === rhs.streaming
    }

    @State private var processSheet: ProcessSheetMode?
    /// 上下文压缩摘要默认折叠，点标题展开看全文
    @State private var summaryExpanded = false

    private var isUser: Bool { message.role == .user }

    var body: some View {
        Group {
            if message.role == .tool {
                // 工具结果统一折进「过程」弹窗，不再单独占一行
                EmptyView()
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
            Spacer(minLength: 48)
            VStack(alignment: .trailing, spacing: 8) {
                if let attachments = message.attachments, !attachments.isEmpty {
                    ForEach(attachments) { attachment in
                        attachmentImage(attachment)
                    }
                }
                if !message.content.isEmpty {
                    Text(message.content)
                        .font(.system(size: 16))
                        .foregroundStyle(DSHTheme.userText)
                        .lineSpacing(2)
                        .textSelection(.enabled)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(DSHTheme.userBubble)
            .clipShape(RoundedRectangle(cornerRadius: DSHTheme.Radius.bubble, style: .continuous))
            // 长按呼出菜单时的抬起预览与高亮也按圆角绘制，避免出现直角背景
            .contentShape(
                .contextMenuPreview,
                RoundedRectangle(cornerRadius: DSHTheme.Radius.bubble, style: .continuous)
            )
            .contextMenu {
                Button { onCopy() } label: { Label("复制", systemImage: "doc.on.doc") }
                Button { onEdit() } label: { Label("编辑并重发", systemImage: "pencil") }
                Button(role: .destructive) { onDelete() } label: { Label("删除", systemImage: "trash") }
            }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
    }

    /// 用户消息附带的图片：等比展示，限制在气泡宽度内
    private func attachmentImage(_ attachment: ChatAttachment) -> some View {
        Group {
            if let image = AttachmentImageCache.image(for: attachment, maxSide: 720) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
            } else {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(DSHTheme.chipFill)
                    .frame(width: 160, height: 120)
                    .overlay(
                        Image(systemName: "photo")
                            .font(.system(size: 20))
                            .foregroundStyle(DSHTheme.secondaryText)
                    )
            }
        }
        .frame(maxWidth: 220, maxHeight: 280)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    // MARK: - 助手消息

    private var assistantRow: some View {
        VStack(alignment: .leading, spacing: DSHTheme.Spacing.medium) {
            if message.isContextSummary == true {
                // 上下文压缩后的摘要：单独一张可折叠卡片，不走「助手回复」样式
                contextSummaryCard
            } else {
                assistantHeader

                if let buffer = liveBuffer {
                    StreamingAssistantBody(buffer: buffer, onOpenProcess: { processSheet = .reasoning })
                } else {
                    // 过程行放在正文之前：先「怎么想的 / 做了什么」，再给结果。
                    // 两个入口各自打开自己的弹窗，内容互不混淆
                    if process?.hasReasoning == true {
                        ProcessRowButton(
                            icon: "brain.head.profile",
                            text: "思考过程",
                            identifier: "message.thinking"
                        ) { processSheet = .reasoning }
                    }

                    if let process, process.hasSteps {
                        ProcessRowButton(
                            icon: "wrench.and.screwdriver",
                            text: process.summary,
                            identifier: "message.process"
                        ) { processSheet = .steps }
                    }

                    if !message.content.isEmpty {
                        MarkdownContentView(content: message.content)
                    }

                    if let error = message.errorText {
                        errorView(error)
                    }

                    // 操作图标只在「这一轮的最终回复 + 生成已完全停止」时出现
                    if showsActions, !message.isStreaming, streaming == nil, !message.content.isEmpty {
                        actionRow
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // 「思考过程」与「已读取 N 个网页」各自打开独立弹窗，内容不再重复
        .sheet(item: $processSheet) { mode in
            ProcessSheet(
                mode: mode,
                steps: process?.steps ?? [],
                reasoning: process?.reasoning,
                liveReasoning: mode == .reasoning ? liveBuffer : nil
            )
        }
    }

    /// 正在输出这条消息时返回它的流式缓冲
    private var liveBuffer: StreamingText? {
        guard message.isStreaming, let streaming, streaming.messageID == message.id else { return nil }
        return streaming
    }

    // MARK: - 助手标识与压缩摘要

    /// 助手标识行：图标 + 名称，与参考实现一致（每条回复都有）
    private var assistantHeader: some View {
        HStack(spacing: DSHTheme.Spacing.small) {
            DSHAssistantAvatar(size: 22)
            Text(MessageRole.assistant.displayName)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(DSHTheme.assistantText)
            Spacer(minLength: 0)
        }
    }

    /// 上下文压缩摘要卡片：标题行 + 摘要正文（默认折叠 4 行，点标题展开）
    private var contextSummaryCard: some View {
        VStack(alignment: .leading, spacing: DSHTheme.Spacing.small) {
            Button {
                withAnimation(DSHAnim.list) { summaryExpanded.toggle() }
            } label: {
                HStack(spacing: DSHTheme.Spacing.small) {
                    Image(systemName: "arrow.down.right.and.arrow.up.left")
                        .font(.system(size: 12, weight: .semibold))
                    Text("已压缩的历史上下文")
                        .font(.system(size: 13, weight: .medium))
                    Spacer(minLength: 0)
                    Image(systemName: summaryExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(DSHTheme.tertiaryText)
                }
                .foregroundStyle(DSHTheme.brand)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("message.summary")

            if summaryExpanded {
                MarkdownContentView(content: message.content)
            } else {
                Text(message.content)
                    .font(.system(size: 13))
                    .foregroundStyle(DSHTheme.secondaryText)
                    .lineLimit(4)
            }
        }
        .padding(DSHTheme.Spacing.medium)
        .background(DSHTheme.brandSoft)
        .clipShape(RoundedRectangle(cornerRadius: DSHTheme.Radius.card, style: .continuous))
    }

    // MARK: - 操作行

    private var actionRow: some View {
        HStack(spacing: 18) {
            actionButton(icon: "doc.on.doc", active: false, label: "复制", action: onCopy)
            actionButton(icon: "hand.thumbsup", active: message.rating == 1, label: "有帮助") { onRate(1) }
            actionButton(icon: "hand.thumbsdown", active: message.rating == -1, label: "没帮助") { onRate(-1) }
            if isLastAssistant {
                actionButton(icon: "arrow.clockwise", active: false, label: "重新生成", action: onRegenerate)
            }
            Spacer(minLength: 0)
        }
    }

    private func actionButton(
        icon: String,
        active: Bool,
        label: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: active ? icon + ".fill" : icon)
                .font(.system(size: 15, weight: .regular))
                .foregroundStyle(active ? DSHTheme.brand : DSHTheme.tertiaryText)
                .frame(width: 26, height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(DSHPressStyle(scale: 0.86))
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

// MARK: - 正在生成的助手正文

/// 生成中的助手正文：只订阅流式缓冲。
/// 生成期间只有这一个子视图会刷新——会话列表、输入区、侧栏抽屉、导航栏都不参与重算，
/// 这是「边生成边滑动/开抽屉也不卡」的关键。
struct StreamingAssistantBody: View {
    @ObservedObject var buffer: StreamingText
    let onOpenProcess: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: DSHTheme.Spacing.medium) {
            if buffer.hasReasoning {
                ProcessRowButton(
                    icon: "brain.head.profile",
                    text: "思考过程",
                    identifier: "message.thinking",
                    action: onOpenProcess
                )
            }

            if buffer.hasContent {
                VStack(alignment: .leading, spacing: DSHTheme.Spacing.medium) {
                    // 已定型的块内容恒定：整块复用排版结果，不随生成刷新
                    ForEach(Array(buffer.contentBlocks.enumerated()), id: \.offset) { _, block in
                        TextChunkView(
                            text: block,
                            font: .system(size: 16),
                            color: DSHTheme.assistantText,
                            inlineMarkdown: true
                        )
                        .equatable()
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    // 只有末尾这一块随生成增长
                    HStack(alignment: .bottom, spacing: 4) {
                        TextChunkView(
                            text: buffer.contentTail,
                            font: .system(size: 16),
                            color: DSHTheme.assistantText,
                            inlineMarkdown: true
                        )
                        .equatable()
                        .frame(maxWidth: .infinity, alignment: .leading)
                        StreamingCursor()
                    }
                }
            } else {
                TypingIndicator()
            }
        }
    }
}

// MARK: - 生成中

/// 官方首页三个点依次呼吸的等待指示
struct TypingIndicator: View {
    @State private var animating = false

    var body: some View {
        HStack(spacing: 5) {
            ForEach(0..<3, id: \.self) { index in
                Circle()
                    .fill(DSHTheme.tertiaryText)
                    .frame(width: 6, height: 6)
                    .opacity(animating ? 1 : 0.3)
                    .scaleEffect(animating ? 1 : 0.8)
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
            .frame(width: 2, height: 16)
            .opacity(dim ? 0.25 : 1)
            .animation(Animation.easeInOut(duration: 0.5).repeatForever(autoreverses: true), value: dim)
            .onAppear { dim = true }
    }
}