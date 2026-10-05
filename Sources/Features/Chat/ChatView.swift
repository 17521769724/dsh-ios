import SwiftUI
import UIKit

/// 对话主界面：极简主页，高级能力通过设置开关按需出现。
struct ChatView: View {
    @EnvironmentObject private var engine: ChatEngine

    @FocusState private var inputFocused: Bool

    var body: some View {
        conversation
            .background(DSHTheme.page)
    }

    // MARK: - 对话区

    private var conversation: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: DSHTheme.Spacing.large) {
                    ForEach(engine.currentConversation?.messages ?? []) { message in
                        MessageBubble(
                            message: message,
                            isLastAssistant: isLastAssistant(message),
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
                        .id(message.id)
                    }

                    if isConversationEmpty {
                        EmptyChatView(onPick: { prompt in
                            inputFocused = false
                            engine.send(prompt)
                        })
                    }

                    Color.clear
                        .frame(height: 1)
                        .id(Self.bottomAnchor)
                }
                .padding(.top, DSHTheme.Spacing.medium)
                .padding(.bottom, DSHTheme.Spacing.small)
            }
            .scrollDismissesKeyboard(.immediately)
            .background(DSHTheme.page)
            .contentShape(Rectangle())
            .onTapGesture { inputFocused = false }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                ComposerBar(focused: $inputFocused)
            }
            .toolbar {
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("完成") { inputFocused = false }
                        .accessibilityIdentifier("keyboard.done")
                }
            }
            .onChange(of: engine.streamingTick) { _ in
                guard engine.isStreaming, isConversationEmpty == false else { return }
                proxy.scrollTo(Self.bottomAnchor, anchor: .bottom)
            }
            .onChange(of: engine.currentConversation?.messages.count ?? 0) { _ in
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

    private func isLastAssistant(_ message: ChatMessage) -> Bool {
        guard message.role == .assistant else { return false }
        let messages = engine.currentConversation?.messages ?? []
        return messages.last(where: { $0.role == .assistant })?.id == message.id
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
            VStack(spacing: DSHTheme.Spacing.small) {
                Image(systemName: "sparkles")
                    .font(.system(size: 22, weight: .medium))
                    .foregroundStyle(.white)
                    .frame(width: 54, height: 54)
                    .background(
                        LinearGradient(
                            colors: [DSHTheme.brand, DSHTheme.brandDeep],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
                Text("有什么可以帮你的吗？")
                    .font(.system(size: 20, weight: .semibold))
                    .padding(.top, 6)
            }

            if features.examplePrompts {
                VStack(spacing: 0) {
                    ForEach(Array(suggestions.enumerated()), id: \.offset) { index, item in
                        Button {
                            onPick(item.1)
                        } label: {
                            HStack(spacing: DSHTheme.Spacing.medium) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(item.0)
                                        .font(.system(size: 15, weight: .medium))
                                        .foregroundStyle(.primary)
                                    Text(item.1)
                                        .font(.system(size: 13))
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                                Spacer(minLength: 0)
                                Image(systemName: "arrow.up.right")
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(.tertiary)
                            }
                            .padding(.horizontal, DSHTheme.Spacing.large)
                            .padding(.vertical, 13)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("empty.suggestion.\(index)")

                        if index < suggestions.count - 1 {
                            Divider().padding(.leading, DSHTheme.Spacing.large)
                        }
                    }
                }
                .background(DSHTheme.grouped)
                .clipShape(RoundedRectangle(cornerRadius: DSHTheme.Radius.card, style: .continuous))
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, DSHTheme.Spacing.large)
        .padding(.top, 40)
    }
}