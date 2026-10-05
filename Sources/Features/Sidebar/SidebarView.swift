import SwiftUI

/// 侧边栏：新会话入口、会话列表、插件与设置入口。
struct SidebarView: View {
    @EnvironmentObject private var engine: ChatEngine
    @EnvironmentObject private var plugins: PluginManager

    var close: () -> Void
    var openPlugins: () -> Void
    var openSettings: () -> Void

    @State private var query = ""
    @State private var showClearConfirm = false

    private var filtered: [Conversation] {
        let all = engine.conversationStore.sortedConversations
        let keyword = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !keyword.isEmpty else { return all }
        return all.filter { conversation in
            conversation.title.lowercased().contains(keyword)
                || conversation.messages.contains { $0.content.lowercased().contains(keyword) }
        }
    }

    private var pinned: [Conversation] { filtered.filter { $0.isPinned } }
    private var recent: [Conversation] { filtered.filter { !$0.isPinned } }

    var body: some View {
        VStack(spacing: 0) {
            header
            newConversationButton
            searchField
            list
            Divider().opacity(0.4)
            footer
        }
        .background(DSHTheme.elevatedBackground)
        .confirmationDialog("确定要清空全部会话吗？", isPresented: $showClearConfirm, titleVisibility: .visible) {
            Button("清空全部", role: .destructive) {
                withAnimation(DSHAnim.list) { engine.deleteAllConversations() }
            }
            Button("取消", role: .cancel) {}
        }
    }

    // MARK: - 顶部

    private var header: some View {
        HStack(spacing: DSHTheme.Spacing.small) {
            ZStack {
                Circle()
                    .fill(LinearGradient(
                        colors: [DSHTheme.brand, DSHTheme.brandDeep],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ))
                Image(systemName: "sparkle")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.white)
            }
            .frame(width: 24, height: 24)

            HStack(spacing: 5) {
                Text("DSH")
                    .font(.system(size: 13, weight: .bold))
                Text("HARNESS")
                    .font(.system(size: 9, weight: .heavy))
                    .tracking(1.1)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1.5)
                    .overlay(
                        RoundedRectangle(cornerRadius: 3)
                            .stroke(DSHTheme.separator, lineWidth: 0.8)
                    )
            }

            Spacer()

            Text("\(engine.conversationStore.conversations.count)")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, DSHTheme.Spacing.large)
        .padding(.top, DSHTheme.Spacing.large)
        .padding(.bottom, DSHTheme.Spacing.medium)
    }

    /// 与桌面端一致的「新会话」整行按钮
    private var newConversationButton: some View {
        Button {
            withAnimation(DSHAnim.list) { engine.newConversation() }
            close()
        } label: {
            HStack(spacing: 7) {
                Image(systemName: "plus")
                    .font(.system(size: 13, weight: .semibold))
                Text("新会话")
                    .font(.system(size: 14, weight: .medium))
                Spacer()
            }
            .foregroundStyle(.primary)
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(DSHTheme.pageBackground)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(DSHTheme.separator, lineWidth: 0.5)
            )
        }
        .buttonStyle(PressableCardStyle())
        .padding(.horizontal, DSHTheme.Spacing.medium)
        .padding(.bottom, DSHTheme.Spacing.medium)
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            TextField("搜索会话", text: $query)
                .font(.system(size: 13))
                .textFieldStyle(.plain)
            if !query.isEmpty {
                Button {
                    query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(DSHTheme.pageBackground)
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        .padding(.horizontal, DSHTheme.Spacing.medium)
        .padding(.bottom, DSHTheme.Spacing.small)
    }

    // MARK: - 列表

    private var list: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 1) {
                if !pinned.isEmpty {
                    sectionLabel("置顶")
                    ForEach(pinned) { row($0) }
                }
                if !recent.isEmpty {
                    sectionLabel(pinned.isEmpty ? "会话" : "全部会话")
                    ForEach(recent) { row($0) }
                }
                if filtered.isEmpty {
                    VStack(spacing: 6) {
                        Image(systemName: "bubble.left.and.bubble.right")
                            .font(.system(size: 22))
                            .foregroundStyle(.tertiary)
                        Text(query.isEmpty ? "还没有会话" : "没有匹配的会话")
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 40)
                }
            }
            .padding(.horizontal, DSHTheme.Spacing.small)
            .padding(.bottom, DSHTheme.Spacing.small)
        }
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, DSHTheme.Spacing.small)
            .padding(.top, DSHTheme.Spacing.small)
            .padding(.bottom, 3)
    }

    private func row(_ conversation: Conversation) -> some View {
        let selected = engine.currentConversation?.id == conversation.id
        return Button {
            engine.select(conversation)
            close()
        } label: {
            HStack(spacing: DSHTheme.Spacing.small) {
                Image(systemName: "bubble.left")
                    .font(.system(size: 12))
                    .foregroundStyle(selected ? DSHTheme.brand : .secondary)
                    .frame(width: 16)

                Text(conversation.title)
                    .font(.system(size: 13.5, weight: selected ? .semibold : .regular))
                    .foregroundStyle(selected ? .primary : Color.primary.opacity(0.88))
                    .lineLimit(1)

                Spacer(minLength: 4)

                if conversation.isPinned {
                    Image(systemName: "pin.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(DSHTheme.brand)
                } else {
                    Text(relativeTime(conversation.updatedAt))
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 8)
            .background(selected ? DSHTheme.brandSoft : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button {
                withAnimation(DSHAnim.list) { engine.togglePin(conversation) }
            } label: {
                Label(conversation.isPinned ? "取消置顶" : "置顶", systemImage: "pin")
            }
            Button(role: .destructive) {
                withAnimation(DSHAnim.list) { engine.delete(conversation) }
            } label: {
                Label("删除", systemImage: "trash")
            }
        }
    }

    private func relativeTime(_ date: Date) -> String {
        let elapsed = Date().timeIntervalSince(date)
        if elapsed < 60 { return "刚刚" }
        if elapsed < 3_600 { return "\(Int(elapsed / 60)) 分钟前" }
        if elapsed < 86_400 { return "\(Int(elapsed / 3_600)) 小时前" }
        let formatter = DateFormatter()
        formatter.dateFormat = "MM-dd"
        return formatter.string(from: date)
    }

    // MARK: - 底部入口

    private var footer: some View {
        VStack(spacing: 2) {
            entryRow(icon: "puzzlepiece.extension", title: "插件中心", badge: "\(plugins.manifests.filter { $0.isEnabled }.count)", action: openPlugins)
            entryRow(icon: "gearshape", title: "设置", badge: nil, action: openSettings)

            HStack(spacing: DSHTheme.Spacing.small) {
                statChip(icon: "number", value: formatted(engine.usage.totalTokens), label: "tokens")
                statChip(icon: "arrow.up.arrow.down", value: "\(engine.usage.totalRequests)", label: "请求")
            }
            .padding(.top, DSHTheme.Spacing.small)

            Button(role: .destructive) {
                showClearConfirm = true
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "trash")
                        .font(.system(size: 11))
                    Text("清空全部会话")
                        .font(.system(size: 12, weight: .medium))
                }
                .foregroundStyle(DSHTheme.danger)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 7)
                .background(DSHTheme.danger.opacity(0.10))
                .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            }
            .buttonStyle(.plain)
            .disabled(engine.conversationStore.conversations.isEmpty)
            .opacity(engine.conversationStore.conversations.isEmpty ? 0.4 : 1)
            .padding(.top, 6)
        }
        .padding(.horizontal, DSHTheme.Spacing.medium)
        .padding(.vertical, DSHTheme.Spacing.small)
    }

    private func entryRow(icon: String, title: String, badge: String?, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: DSHTheme.Spacing.small) {
                Image(systemName: icon)
                    .font(.system(size: 13))
                    .frame(width: 18)
                Text(title)
                    .font(.system(size: 13.5))
                Spacer()
                if let badge {
                    Text(badge)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1.5)
                        .background(DSHTheme.pageBackground)
                        .clipShape(Capsule())
                }
            }
            .foregroundStyle(.primary)
            .padding(.horizontal, 9)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func statChip(icon: String, value: String, label: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 10))
                .foregroundStyle(DSHTheme.brand)
            Text(value)
                .font(.system(size: 11, weight: .semibold))
            Text(label)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 6)
        .dshCard(background: DSHTheme.pageBackground)
    }

    private func formatted(_ value: Int) -> String {
        if value >= 10_000 {
            return String(format: "%.1fk", Double(value) / 1_000)
        }
        return "\(value)"
    }
}