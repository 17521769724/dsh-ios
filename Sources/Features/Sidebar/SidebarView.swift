import SwiftUI
import UIKit

/// 会话抽屉：新对话入口 + 按时间分组的会话列表 + 设置入口。
struct SidebarView: View {
    @EnvironmentObject private var engine: ChatEngine
    @EnvironmentObject private var settingsStore: SettingsStore
    @EnvironmentObject private var plugins: PluginManager

    var close: () -> Void
    var openSettings: () -> Void
    var openPlugins: () -> Void

    @State private var query = ""
    @State private var renameTarget: Conversation?
    @State private var renameText = ""

    private var features: FeatureFlags { settingsStore.settings.features }

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

    var body: some View {
        VStack(spacing: 0) {
            header
            newConversationButton
            searchField
            list
            Divider()
            footer
        }
        .background(DSHTheme.page)
        .alert("重命名对话", isPresented: renamePresented) {
            TextField("对话名称", text: $renameText)
            Button("保存") { commitRename() }
            Button("取消", role: .cancel) { renameTarget = nil }
        } message: {
            Text("输入新的对话名称")
        }
    }

    // MARK: - 重命名

    private var renamePresented: Binding<Bool> {
        Binding(
            get: { renameTarget != nil },
            set: { if !$0 { renameTarget = nil } }
        )
    }

    private func commitRename() {
        guard let target = renameTarget else { return }
        engine.rename(target, to: renameText)
        renameTarget = nil
    }

    // MARK: - 顶部

    private var header: some View {
        HStack(spacing: DSHTheme.Spacing.small) {
            Text("DeepSeek Harness")
                .font(.system(size: 17, weight: .semibold))
            Spacer()
            Text("\(engine.conversationStore.conversations.count)")
                .font(.system(size: 12))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, DSHTheme.Spacing.large)
        .padding(.top, DSHTheme.Spacing.large)
        .padding(.bottom, DSHTheme.Spacing.medium)
    }

    private var newConversationButton: some View {
        Button {
            engine.newConversation()
            close()
        } label: {
            HStack(spacing: DSHTheme.Spacing.small) {
                Image(systemName: "plus")
                    .font(.system(size: 14, weight: .semibold))
                Text("新对话")
                    .font(.system(size: 15, weight: .medium))
                Spacer()
            }
            .foregroundStyle(DSHTheme.brand)
            .padding(.horizontal, DSHTheme.Spacing.medium)
            .padding(.vertical, 11)
            .background(DSHTheme.brandSoft)
            .clipShape(RoundedRectangle(cornerRadius: DSHTheme.Radius.chip, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("sidebar.new")
        .padding(.horizontal, DSHTheme.Spacing.medium)
        .padding(.bottom, DSHTheme.Spacing.small)
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
            TextField("搜索", text: $query)
                .font(.system(size: 15))
                .textFieldStyle(.plain)
                .accessibilityIdentifier("sidebar.search")
            if !query.isEmpty {
                Button {
                    query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(DSHTheme.grouped)
        .clipShape(RoundedRectangle(cornerRadius: DSHTheme.Radius.chip, style: .continuous))
        .padding(.horizontal, DSHTheme.Spacing.medium)
        .padding(.bottom, DSHTheme.Spacing.small)
    }

    // MARK: - 列表（按时间分组）

    private var list: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 1) {
                if !pinned.isEmpty {
                    sectionLabel("置顶")
                    ForEach(pinned) { row($0) }
                }
                ForEach(groups, id: \.title) { group in
                    if !group.items.isEmpty {
                        sectionLabel(group.title)
                        ForEach(group.items) { row($0) }
                    }
                }
                if filtered.isEmpty {
                    VStack(spacing: 6) {
                        Image(systemName: "bubble.left.and.bubble.right")
                            .font(.system(size: 22))
                            .foregroundStyle(.tertiary)
                        Text(query.isEmpty ? "还没有对话" : "没有匹配的对话")
                            .font(.system(size: 14))
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

    private struct Group {
        let title: String
        let items: [Conversation]
    }

    private var groups: [Group] {
        let unpinned = filtered.filter { !$0.isPinned }
        let calendar = Calendar.current
        let now = Date()
        var today: [Conversation] = []
        var week: [Conversation] = []
        var month: [Conversation] = []
        var earlier: [Conversation] = []

        for conversation in unpinned {
            let date = conversation.updatedAt
            if calendar.isDateInToday(date) {
                today.append(conversation)
            } else if let days = calendar.dateComponents([.day], from: date, to: now).day, days < 7 {
                week.append(conversation)
            } else if let days = calendar.dateComponents([.day], from: date, to: now).day, days < 30 {
                month.append(conversation)
            } else {
                earlier.append(conversation)
            }
        }
        return [
            Group(title: "今天", items: today),
            Group(title: "最近 7 天", items: week),
            Group(title: "最近 30 天", items: month),
            Group(title: "更早", items: earlier)
        ]
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, DSHTheme.Spacing.small)
            .padding(.top, DSHTheme.Spacing.medium)
            .padding(.bottom, 3)
    }

    private func row(_ conversation: Conversation) -> some View {
        let selected = engine.currentConversation?.id == conversation.id
        return Button {
            engine.select(conversation)
            close()
        } label: {
            HStack(spacing: DSHTheme.Spacing.small) {
                Text(conversation.title)
                    .font(.system(size: 15, weight: selected ? .semibold : .regular))
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                Spacer(minLength: 4)

                if conversation.isPinned {
                    Image(systemName: "pin.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(DSHTheme.brand)
                }
                Text(relativeTime(conversation.updatedAt))
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, DSHTheme.Spacing.small)
            .padding(.vertical, 9)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("sidebar.row")
        .background(selected ? DSHTheme.grouped : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: DSHTheme.Radius.chip, style: .continuous))
        // 长按呼出菜单时的高亮与预览都按圆角绘制，避免出现直角背景
        .contentShape(
            .contextMenuPreview,
            RoundedRectangle(cornerRadius: DSHTheme.Radius.chip, style: .continuous)
        )
        .animation(DSHAnim.standard, value: selected)
        .contextMenu {
            Button {
                renameText = conversation.title
                renameTarget = conversation
            } label: {
                Label("重命名", systemImage: "pencil")
            }
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
        VStack(spacing: 0) {
            if features.pluginCommands {
                entryRow(icon: "puzzlepiece.extension", title: "插件中心", identifier: "sidebar.plugins", action: openPlugins)
            }
            entryRow(
                icon: "gearshape",
                title: "设置",
                identifier: "sidebar.settings",
                trailing: Self.appVersionText,
                action: openSettings
            )
        }
        .padding(.horizontal, DSHTheme.Spacing.small)
        .padding(.vertical, DSHTheme.Spacing.small)
    }

    /// 侧栏展示的版本号，例如 V1.0.1
    private static var appVersionText: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        return "V\(version)"
    }

    private func entryRow(
        icon: String,
        title: String,
        identifier: String,
        trailing: String? = nil,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: DSHTheme.Spacing.medium) {
                Image(systemName: icon)
                    .font(.system(size: 15))
                    .frame(width: 20)
                Text(title)
                    .font(.system(size: 15))
                Spacer()
                if let trailing {
                    Text(trailing)
                        .font(.system(size: 13))
                        .foregroundStyle(.tertiary)
                }
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .foregroundStyle(.primary)
            .padding(.horizontal, DSHTheme.Spacing.small)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(identifier)
    }
}