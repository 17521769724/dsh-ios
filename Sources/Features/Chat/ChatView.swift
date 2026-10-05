import SwiftUI
import UIKit

/// 聊天主界面：对话/轨迹切换 + 消息流 + 输入舱。
struct ChatView: View {
    @EnvironmentObject private var engine: ChatEngine
    @EnvironmentObject private var plugins: PluginManager

    enum ContentTab: String, CaseIterable, Identifiable {
        case chat = "对话"
        case trajectory = "轨迹"
        var id: String { rawValue }
    }

    @State private var tab: ContentTab = .chat

    var body: some View {
        VStack(spacing: 0) {
            tabBar
            Divider().opacity(0.4)

            switch tab {
            case .chat:
                messageList
                InputBar()
            case .trajectory:
                TrajectoryView()
            }
        }
        .background(DSHTheme.pageBackground)
    }

    // MARK: - 标签栏（下划线指示器，对齐桌面端）

    private var tabBar: some View {
        HStack(spacing: DSHTheme.Spacing.section) {
            ForEach(ContentTab.allCases) { item in
                Button {
                    withAnimation(DSHAnim.standard) { tab = item }
                } label: {
                    VStack(spacing: 6) {
                        Text(item.rawValue)
                            .font(.system(size: 14, weight: tab == item ? .semibold : .regular))
                            .foregroundStyle(tab == item ? .primary : .secondary)
                        Rectangle()
                            .fill(tab == item ? DSHTheme.brand : Color.clear)
                            .frame(height: 2)
                            .clipShape(Capsule())
                    }
                    .fixedSize()
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier(item == .chat ? "tab.chat" : "tab.trajectory")
            }
            Spacer()
            if tab == .chat, let count = engine.currentConversation?.messages.count, count > 0 {
                Text("\(count) 条消息")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, DSHTheme.Spacing.large)
        .padding(.top, 10)
        .animation(DSHAnim.standard, value: tab)
    }

    // MARK: - 消息流

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(engine.currentConversation?.messages ?? []) { message in
                        MessageBubble(
                            message: message,
                            isLastAssistant: isLastAssistant(message),
                            isStreaming: engine.isStreaming,
                            onCopy: {
                                UIPasteboard.general.string = message.content
                                engine.showToast("已复制到剪贴板")
                            },
                            onDelete: {
                                withAnimation(DSHAnim.list) {
                                    engine.deleteMessage(message)
                                }
                            },
                            onEdit: {
                                engine.editAndResend(message)
                            },
                            onRegenerate: {
                                engine.regenerateLast()
                            },
                            onRate: { value in
                                engine.rate(message, value: value)
                            }
                        )
                        .id(message.id)
                    }

                    if isConversationEmpty {
                        WelcomeView()
                            .padding(.top, DSHTheme.Spacing.section)
                    }

                    Color.clear
                        .frame(height: 1)
                        .id("bottom-anchor")
                }
                .padding(.vertical, DSHTheme.Spacing.medium)
            }
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: engine.currentConversation?.messages.count ?? 0) { _ in
                withAnimation(DSHAnim.list) {
                    proxy.scrollTo("bottom-anchor", anchor: .bottom)
                }
            }
            .onChange(of: engine.streamingTick) { _ in
                guard engine.isStreaming else { return }
                proxy.scrollTo("bottom-anchor", anchor: .bottom)
            }
        }
    }

    private var isConversationEmpty: Bool {
        (engine.currentConversation?.messages.isEmpty ?? true)
    }

    private func isLastAssistant(_ message: ChatMessage) -> Bool {
        guard message.role == .assistant else { return false }
        let messages = engine.currentConversation?.messages ?? []
        return messages.last(where: { $0.role == .assistant })?.id == message.id
    }
}

// MARK: - 空态欢迎页

struct WelcomeView: View {
    @EnvironmentObject private var engine: ChatEngine

    private let suggestions: [(icon: String, title: String, prompt: String)] = [
        ("chevron.left.forwardslash.chevron.right", "写代码", "用 Swift 写一个防抖函数，并解释它的用途。"),
        ("text.alignleft", "润色文案", "把下面这段话润色得更专业：\n"),
        ("lightbulb", "头脑风暴", "给我 5 个适合移动端 AI 助手的功能点子。"),
        ("doc.text.magnifyingglass", "总结长文", "帮我总结下面这段内容的要点：\n")
    ]

    var body: some View {
        VStack(spacing: DSHTheme.Spacing.section) {
            VStack(spacing: DSHTheme.Spacing.medium) {
                ZStack {
                    Circle()
                        .fill(LinearGradient(
                            colors: [DSHTheme.brand, DSHTheme.brandDeep],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ))
                        .frame(width: 60, height: 60)
                        .shadow(color: DSHTheme.brand.opacity(0.35), radius: 14, y: 6)
                    Image(systemName: "sparkles")
                        .font(.system(size: 26, weight: .semibold))
                        .foregroundStyle(.white)
                }
                VStack(spacing: 4) {
                    Text("有什么可以帮你？")
                        .font(.system(size: 20, weight: .bold))
                    Text("基于 DeepSeek Harness 的原生移动客户端")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }
            }

            LazyVGrid(
                columns: [GridItem(.flexible(), spacing: DSHTheme.Spacing.medium),
                          GridItem(.flexible(), spacing: DSHTheme.Spacing.medium)],
                spacing: DSHTheme.Spacing.medium
            ) {
                ForEach(suggestions, id: \.title) { item in
                    Button {
                        engine.send(item.prompt)
                    } label: {
                        VStack(alignment: .leading, spacing: DSHTheme.Spacing.small) {
                            Image(systemName: item.icon)
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(DSHTheme.brand)
                            Text(item.title)
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(.primary)
                            Text(item.prompt.replacingOccurrences(of: "\n", with: " "))
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                                .multilineTextAlignment(.leading)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(DSHTheme.Spacing.medium)
                        .dshCard(background: DSHTheme.inputBackground)
                    }
                    .buttonStyle(PressableCardStyle())
                }
            }
            .padding(.horizontal, DSHTheme.Spacing.large)
        }
        .padding(.horizontal, DSHTheme.Spacing.small)
    }
}