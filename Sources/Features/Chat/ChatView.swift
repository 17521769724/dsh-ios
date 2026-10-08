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

    var body: some View {
        // 输入框与消息列表同处一个竖向栈：键盘弹出/收起时整栈跟随系统安全区平滑位移，
        // 不再使用 safeAreaInset（此前会导致收起键盘瞬间输入框先弹到高处再落回底部）。
        VStack(spacing: 0) {
            conversationScroll
            ComposerBar(focused: $inputFocused)
        }
        .background(DSHTheme.page)
    }

    // MARK: - 对话区

    private var conversationScroll: some View {
        let messages = engine.currentConversation?.messages ?? []
        // 一次遍历算出：可见消息（工具结果折进「过程」弹窗，不再单独占行）、
        // 最后一条助手消息、每条助手消息的过程摘要
        let visibleMessages = messages.filter { $0.role != .tool }
        let lastAssistantID = messages.last(where: { $0.role == .assistant })?.id
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
                            onRate: { engine.rate(message, value: $0) }
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
            .onReceive(streamRevision) { _ in
                guard followsBottom, !isConversationEmpty else { return }
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