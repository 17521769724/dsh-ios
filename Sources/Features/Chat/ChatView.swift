import SwiftUI
import Combine
import UIKit

/// 对话主界面，对齐 iOS DeepSeek 官方客户端：
/// 空会话时展示鲸鱼标识 + 问候语 + 示例卡片；有消息时整宽消息流。
struct ChatView: View {
    @EnvironmentObject private var engine: ChatEngine

    @FocusState private var inputFocused: Bool
    /// 用户是否停留在底部（向上翻阅历史时暂停自动跟随）
    @State private var followsBottom = true
    /// 上一次跟随滚动的时间：限制跟随频率，避免长回复生成时反复重排导致卡顿
    @State private var lastFollowScroll = Date.distantPast
    /// 正在查看「思考过程 / 工具过程」的目标
    @State private var processTarget: ProcessTarget?

    var body: some View {
        // 输入框与消息列表同处一个竖向栈：键盘弹出/收起时整栈跟随系统安全区平滑位移，
        // 不再使用 safeAreaInset（此前会导致收起键盘瞬间输入框先弹到高处再落回底部）。
        VStack(spacing: 0) {
            conversationScroll
            ComposerBar(focused: $inputFocused)
        }
        .background(DSHTheme.page)
        // 「思考过程 / 工具过程」弹窗由对话页持有：生成过程中消息在高速重绘，
        // 挂在气泡上会偶发点不开或刚打开就被顶掉
        .sheet(item: $processTarget) { target in
            ProcessSheet(
                mode: target.mode,
                steps: processesSnapshot[target.messageID]?.steps ?? [],
                reasoning: messageSnapshot(target.messageID)?.reasoning,
                liveReasoning: target.mode == .reasoning ? engine.streaming : nil
            )
        }
    }

    /// 弹窗要展示的目标（消息 + 展示哪一段）
    private struct ProcessTarget: Identifiable {
        let id = UUID()
        let messageID: UUID
        let mode: ProcessSheetMode
    }

    private var processesSnapshot: [UUID: ChatProcess] {
        Self.processes(in: engine.currentConversation?.messages ?? [])
    }

    private func messageSnapshot(_ id: UUID) -> ChatMessage? {
        engine.currentConversation?.messages.first { $0.id == id }
    }

    // MARK: - 对话区

    private var conversationScroll: some View {
        let messages = engine.currentConversation?.messages ?? []
        // 一次遍历算出：可见消息（工具结果折进「过程」弹窗，不再单独占行）、
        // 最后一条助手消息、每条助手消息的过程摘要
        let visibleMessages = messages.filter { $0.role != .tool }
        let lastAssistantID = messages.last(where: { $0.role == .assistant })?.id
        // 操作图标（复制 / 点赞 / 重新生成）只给每一轮的最终回复：工具调用中的中间回复不显示
        let finalReplies = messages.finalReplyIDs
        let processes = Self.processes(in: messages)
        // 跟随滚动由流式缓冲的版本号驱动：只有真正写入新内容时才滚动，
        // 而且不会让 ChatView 整体重算（onReceive 不触发 body）
        let streamRevision = engine.streaming?.$revision.eraseToAnyPublisher()
            ?? Empty<Int, Never>().eraseToAnyPublisher()
        // 只有最近 6 秒内新增的消息才播放入场动画：
        // 滚动时 LazyVStack 会回收并重建行，若每次都重播动画，滑动就会反复闪动、看起来像掉帧
        let freshAfter = Date().addingTimeInterval(-6)

        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: DSHTheme.Spacing.large) {
                    ForEach(visibleMessages) { message in
                        MessageBubble(
                            message: message,
                            isLastAssistant: message.role == .assistant && message.id == lastAssistantID,
                            showsActions: finalReplies.contains(message.id),
                            streaming: engine.streaming,
                            process: processes[message.id],
                            onCopy: {
                                UIPasteboard.general.string = message.content
                                engine.showToast("已复制")
                            },
                            onDelete: {
                                withAnimation(DSHAnim.list) { engine.deleteMessage(message) }
                            },
                            onEdit: { engine.editAndResend(message) },
                            onRegenerate: { engine.regenerateLast() },
                            onRate: { engine.rate(message, value: $0) },
                            onOpenProcess: { mode in
                                processTarget = ProcessTarget(messageID: message.id, mode: mode)
                            }
                        )
                        // 内容没变就不重绘：生成过程中只有正在输出的那条消息刷新
                        .equatable()
                        .id(message.id)
                        .modifier(AppearFade(enabled: message.createdAt > freshAfter))
                    }

                    if isConversationEmpty {
                        EmptyChatView(onPick: { prompt in
                            inputFocused = false
                            engine.send(prompt)
                        })
                        .transition(.opacity)
                    }

                    // 模型正在本地跑工具（这一阶段没有流式输出）时，在最下方显示三点动画。
                    // 注意：正在流式输出的那条消息自己会显示同一套三点动画，
                    // 这里只在「没有任何消息在显示动画」时才补一行，避免出现两行
                    if showsToolRunningIndicator {
                        TypingIndicator()
                            .padding(.horizontal, DSHTheme.messageHorizontalPadding)
                            .transition(.opacity)
                    }

                    Color.clear
                        .frame(height: 1)
                        .id(Self.bottomAnchor)
                        // 底部锚点是否可见 = 用户是否正在看最新内容：
                        // 向上翻阅历史时不再强制拉回底部，避免和用户抢滚动
                        .onAppear { followsBottom = true }
                        .onDisappear { followsBottom = false }
                }
                .padding(.top, DSHTheme.Spacing.medium)
                .padding(.bottom, DSHTheme.Spacing.small)
                .animation(DSHAnim.list, value: engine.currentConversation?.messages.count ?? 0)
            }
            .scrollDismissesKeyboard(.immediately)
            .background(DSHTheme.page)
            // 回到底部按钮：向上翻阅历史时出现在对话区右下角（输入框上方）
            .overlay(alignment: .bottomTrailing) {
                if !followsBottom, !isConversationEmpty {
                    Button {
                        withAnimation(DSHAnim.standard) {
                            proxy.scrollTo(Self.bottomAnchor, anchor: .bottom)
                        }
                    } label: {
                        Image(systemName: "arrow.down")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(DSHTheme.assistantText)
                            .frame(width: 34, height: 34)
                            .background(DSHTheme.page)
                            .clipShape(Circle())
                            .overlay(
                                Circle().stroke(DSHTheme.separator.opacity(0.6), lineWidth: 0.5)
                            )
                    }
                    .buttonStyle(DSHPressStyle(scale: 0.94))
                    .padding(.trailing, DSHTheme.Spacing.large)
                    .padding(.bottom, DSHTheme.Spacing.small)
                    .accessibilityIdentifier("chat.scrollToBottom")
                    .accessibilityLabel("回到底部")
                    .transition(.opacity)
                }
            }
            .onReceive(streamRevision) { _ in
                guard followsBottom, !isConversationEmpty else { return }
                // 长文本生成时每次增量都滚动会拖慢排版（总结这种长回复会明显卡顿）：
                // 限制到约 4 次/秒，视觉上依然是平滑跟随
                let now = Date()
                guard now.timeIntervalSince(lastFollowScroll) > 0.25 else { return }
                lastFollowScroll = now
                proxy.scrollTo(Self.bottomAnchor, anchor: .bottom)
            }
            .onChange(of: engine.currentConversation?.messages.count ?? 0) { _ in
                followsBottom = true
                withAnimation(DSHAnim.list) {
                    proxy.scrollTo(Self.bottomAnchor, anchor: .bottom)
                }
            }
        }
    }

    private static let bottomAnchor = "chat.bottom"

    private var isConversationEmpty: Bool {
        (engine.currentConversation?.messages.isEmpty ?? true)
    }

    /// 是否在对话最下方补一行三点动画：模型正在本地执行工具。
    /// 这一段没有任何流式输出（上一轮回复已经写完），补一行动画才不会看起来像卡住；
    /// 正在流式输出的那条消息自己也会显示同一套三点动画，两处条件互斥，不会同时出现
    private var showsToolRunningIndicator: Bool {
        engine.isStreaming && engine.runningToolName != nil
    }

    /// 每条助手消息的「过程」：把紧随其后的工具结果消息折进来，
    /// 界面上只显示一行摘要，细节放进「过程」弹窗。
    private static func processes(in messages: [ChatMessage]) -> [UUID: ChatProcess] {
        var result: [UUID: ChatProcess] = [:]
        var assistant: ChatMessage?
        var toolMessages: [ChatMessage] = []

        func flush() {
            guard let assistant else { return }
            let process = ChatProcess(message: assistant, toolMessages: toolMessages)
            if !process.isEmpty { result[assistant.id] = process }
        }

        for message in messages {
            switch message.role {
            case .assistant:
                flush()
                assistant = message
                toolMessages = []
            case .tool:
                toolMessages.append(message)
            case .user, .system:
                flush()
                assistant = nil
                toolMessages = []
            }
        }
        flush()
        return result
    }
}

/// 消息出现动效：轻微上移 + 淡入，只在消息刚生成时播放一次。
/// 滚动时 LazyVStack 会回收重建行视图，若每次重建都重播动画，滑动就会反复闪动、像掉帧，
/// 因此由外部按「消息是否刚生成」决定是否启用。
private struct AppearFade: ViewModifier {
    let enabled: Bool

    @State private var appeared = false

    func body(content: Content) -> some View {
        content
            .opacity(appeared || !enabled ? 1 : 0)
            .offset(y: appeared || !enabled ? 0 : 6)
            .onAppear {
                guard enabled, !appeared else { return }
                withAnimation(DSHAnim.list) { appeared = true }
            }
    }
}

// MARK: - 空会话

struct EmptyChatView: View {
    @EnvironmentObject private var settingsStore: SettingsStore

    var onPick: (String) -> Void

    private let suggestions: [(String, String)] = [
        ("写一段代码", "用 Swift 写一个防抖函数，并说明使用场景。"),
        ("润色文案", "把下面这段话润色得更专业："),
        ("总结要点", "帮我总结下面这段内容的要点："),
        ("头脑风暴", "给我 5 个适合移动端 AI 助手的功能点子。")
    ]

    private var features: FeatureFlags { settingsStore.settings.features }

    var body: some View {
        VStack(spacing: DSHTheme.Spacing.section) {
            VStack(spacing: DSHTheme.Spacing.medium) {
                DSHWhaleMark(size: 56)
                Text("有什么可以帮你的吗？")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(DSHTheme.assistantText)
            }

            if features.examplePrompts {
                LazyVGrid(
                    columns: [
                        GridItem(.flexible(), spacing: DSHTheme.Spacing.medium),
                        GridItem(.flexible(), spacing: DSHTheme.Spacing.medium)
                    ],
                    spacing: DSHTheme.Spacing.medium
                ) {
                    ForEach(Array(suggestions.enumerated()), id: \.offset) { index, item in
                        Button {
                            onPick(item.1)
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(item.0)
                                    .font(.system(size: 15, weight: .medium))
                                    .foregroundStyle(DSHTheme.assistantText)
                                Text(item.1)
                                    .font(.system(size: 12))
                                    .foregroundStyle(DSHTheme.tertiaryText)
                                    .lineLimit(2)
                                    .multilineTextAlignment(.leading)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 12)
                            .background(DSHTheme.grouped)
                            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                            .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                        }
                        .buttonStyle(DSHPressStyle(scale: 0.97))
                        .accessibilityIdentifier("empty.suggestion.\(index)")
                    }
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, DSHTheme.Spacing.large)
        .padding(.top, 32)
    }
}
// MARK: - 三点动画已统一使用 MessageBubble 里的 TypingIndicator
