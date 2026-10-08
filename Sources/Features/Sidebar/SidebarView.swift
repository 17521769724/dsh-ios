import SwiftUI
import UIKit

/// 会话抽屉，对齐 iOS DeepSeek 官方客户端：
/// 顶部标识 + 新对话入口 + 搜索 + 按时间分组的会话列表，底部为插件与设置入口。
struct SidebarView: View {
    @EnvironmentObject private var engine: ChatEngine
    @EnvironmentObject private var settingsStore: SettingsStore
    @EnvironmentObject private var plugins: PluginManager
    @EnvironmentObject private var skillStore: SkillStore

    var close: () -> Void
    var openSettings: () -> Void
    var openPlugins: () -> Void
    var openSkills: () -> Void
    var openFiles: () -> Void

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
        // 顺序：标题 → 搜索 + 新对话（同一行）→ 对话记录 → 设置
        VStack(spacing: 0) {
            header
            searchRow
            list
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
            DSHWhaleMark(size: 22)
            Text("DeepSeek Harness")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(DSHTheme.assistantText)
            Spacer()
            Text("\(engine.conversationStore.conversations.count)")
                .font(.system(size: 12))
                .foregroundStyle(DSHTheme.tertiaryText)
        }
        .padding(.horizontal, DSHTheme.Spacing.large)
        .padding(.top, DSHTheme.Spacing.large)
        .padding(.bottom, DSHTheme.Spacing.medium)
    }

    /// 搜索框与新对话按钮同一行：新对话只保留一个图标按钮（黑色图标，与原文案色一致）
    private var searchRow: some View {
        HStack(spacing: DSHTheme.Spacing.small) {
            searchField
            newConversationButton
        }
        .padding(.horizontal, DSHTheme.Spacing.medium)
        .padding(.bottom, DSHTheme.Spacing.small)
    }

    private var newConversationButton: some View {
        Button {
            engine.newConversation()
            close()
        } label: {
            Image(systemName: "square.and.pencil")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(DSHTheme.assistantText)
                .frame(width: 38, height: 38)
                // 与搜索框同底色、同圆角，视觉上属于同一行
                .background(DSHTheme.composerCard)
                .clipShape(RoundedRectangle(cornerRadius: DSHTheme.Radius.row, style: .continuous))
                .contentShape(RoundedRectangle(cornerRadius: DSHTheme.Radius.row, style: .continuous))
        }
        .buttonStyle(DSHPressStyle(scale: 0.95))
        .accessibilityIdentifier("sidebar.new")
        .accessibilityLabel("新对话")
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 13))
                .foregroundStyle(DSHTheme.tertiaryText)
            TextField("搜索", text: $query)
                .font(.system(size: 15))
                .foregroundStyle(DSHTheme.assistantText)
                .textFieldStyle(.plain)
                .accessibilityIdentifier("sidebar.search")
            if !query.isEmpty {
                Button {
                    query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(DSHTheme.tertiaryText)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 38)
        // 与对话页输入卡片同色，扁平底色、无阴影
        .background(DSHTheme.composerCard)
        .clipShape(RoundedRectangle(cornerRadius: DSHTheme.Radius.row, style: .continuous))
    }

    // MARK: - 列表（按时间分组）

    private var list: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 2) {
                // 直接展示分组后的会话记录，不再单独加「对话记录」总标题
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
                    VStack(spacing: 8) {
                        Image(systemName: "bubble.left.and.bubble.right")
                            .font(.system(size: 24))
                            .foregroundStyle(DSHTheme.tertiaryText)
                        Text(query.isEmpty ? "还没有对话" : "没有匹配的对话")
                            .font(.system(size: 14))
                            .foregroundStyle(DSHTheme.secondaryText)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 44)
                    // 空状态只让自己淡入：被删除的行已经立即消失，两者不会重叠
                    .transition(.opacity)
                    .animation(DSHAnim.standard, value: filtered.isEmpty)
                }
            }
            .padding(.horizontal, DSHTheme.Spacing.small)
            .padding(.bottom, DSHTheme.Spacing.small)
            // 不做「列表整体动画」：删除后行必须立即消失，
            // 整段动画会让被删的行淡出与新出现的空状态图标同时存在、互相重合
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
            .foregroundStyle(DSHTheme.tertiaryText)
            .padding(.horizontal, DSHTheme.Spacing.small)
            .padding(.top, DSHTheme.Spacing.medium)
            .padding(.bottom, 2)
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
                    .foregroundStyle(selected ? DSHTheme.brand : DSHTheme.assistantText)
                    .lineLimit(1)

                Spacer(minLength: 4)

                if conversation.isPinned {
                    Image(systemName: "pin.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(DSHTheme.brand)
                }
                Text(relativeTime(conversation.updatedAt))
                    .font(.system(size: 11))
                    .foregroundStyle(DSHTheme.tertiaryText)
            }
            .padding(.horizontal, 12)
            .frame(height: 44)
            // 底色画在行内部：长按预览时不会变成透明。
            // 选中态用不透明的主题色（此前用 12% 透明度的品牌色，
            // 长按抬起时能透出下方内容，看起来像「半透明卡片」）。
            .background(selected ? DSHTheme.rowSelected : DSHTheme.composerCard)
            .clipShape(RoundedRectangle(cornerRadius: DSHTheme.Radius.row, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: DSHTheme.Radius.row, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("sidebar.row")
        .animation(DSHAnim.standard, value: selected)
        // 长按呼出菜单时的高亮与预览也按圆角绘制，避免出现直角背景
        .contentShape(
            .contextMenuPreview,
            RoundedRectangle(cornerRadius: DSHTheme.Radius.row, style: .continuous)
        )
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
                // 不加动画：删掉的会话必须立刻从列表消失，
                // 否则淡出过程中会和下方的空状态图标叠在一起
                engine.delete(conversation)
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
            Rectangle()
                .fill(DSHTheme.separator.opacity(0.7))
                .frame(height: 0.5)
                .padding(.bottom, DSHTheme.Spacing.small)

            if features.pluginCommands {
                entryRow(icon: "puzzlepiece.extension", title: "插件中心", identifier: "sidebar.plugins", action: openPlugins)
            }
            entryRow(
                icon: "sparkles",
                title: "技能",
                identifier: "sidebar.skills",
                trailing: skillStore.skills.isEmpty ? "未添加" : "\(skillStore.skills.count) 个",
                action: openSkills
            )
            entryRow(
                icon: "folder",
                title: "文件",
                identifier: "sidebar.files",
                action: openFiles
            )
            entryRow(
                icon: "gearshape",
                title: "设置",
                identifier: "sidebar.settings",
                trailing: Self.appVersionText,
                action: openSettings
            )
        }
        .padding(.horizontal, DSHTheme.Spacing.small)
        .padding(.bottom, DSHTheme.Spacing.small)
    }

    /// 侧栏展示的版本，例如 V1.2.4 (76)：带上构建号，
    /// 手机上不用进设置就能确认装的是哪一次构建（避免装到旧包却看不出来）
    private static var appVersionText: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = info?["CFBundleVersion"] as? String ?? "1"
        return "V\(version) (\(build))"
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
                    .font(.system(size: 16))
                    .foregroundStyle(DSHTheme.assistantText)
                    .frame(width: 22)
                Text(title)
                    .font(.system(size: 15))
                    .foregroundStyle(DSHTheme.assistantText)
                Spacer()
                if let trailing {
                    Text(trailing)
                        .font(.system(size: 13))
                        .foregroundStyle(DSHTheme.tertiaryText)
                }
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(DSHTheme.tertiaryText)
            }
            .padding(.horizontal, 10)
            .frame(height: 46)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(identifier)
    }
}
