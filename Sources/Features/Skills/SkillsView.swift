import SwiftUI

/// 技能库：自行添加「做事方法与规范」，交给模型按需取用。
/// 与插件中心并列，入口在左侧菜单栏底部。
///
/// 列表不用 `List` 的 swipeActions：系统会在卡片圆角外露出直角、删除区还比卡片高，
/// 因此这里用自绘的 `SwipeToDeleteRow`（圆角、尺寸与卡片完全一致，删除背景为红色）。
struct SkillsView: View {
    @EnvironmentObject private var skillStore: SkillStore
    @EnvironmentObject private var settingsStore: SettingsStore

    private var listSkills: [Skill] {
        skillStore.skills.sorted { $0.updatedAt > $1.updatedAt }
    }

    /// 正在编辑的技能：点卡片后推入编辑页。
    /// 卡片上还挂着左滑手势，若用 NavigationLink（本质是 Button）会互相抢手势、左滑失效，
    /// 因此改为「普通视图 + onTapGesture + navigationDestination」。
    @State private var editingSkill: Skill?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DSHTheme.Spacing.medium) {
                // 总开关放在顶部：技能库整体「能不能被智能体调用」只在这里控制
                agentToggleCard

                sectionLabel("技能库（\(skillStore.skills.count)）")
                    .padding(.top, DSHTheme.Spacing.small)

                if listSkills.isEmpty {
                    emptyCard
                } else {
                    ForEach(listSkills) { skill in
                        skillCard(skill)
                    }
                }

                libraryFooter

                tipsCard
                    .padding(.top, DSHTheme.Spacing.small)
            }
            .padding(.horizontal, DSHTheme.Spacing.large)
            .padding(.top, DSHTheme.Spacing.small)
            .padding(.bottom, DSHTheme.Spacing.section)
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .navigationTitle("技能")
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(isPresented: editingPresented) {
            if let skill = editingSkill {
                SkillEditorPage(original: skill)
            }
        }
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                NavigationLink {
                    SkillEditorPage(original: nil)
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityIdentifier("skills.add")
                .accessibilityLabel("添加技能")
            }
        }
        .tint(DSHTheme.brand)
    }

    // MARK: - 顶部开关

    private var agentToggleCard: some View {
        VStack(alignment: .leading, spacing: DSHTheme.Spacing.small) {
            Toggle(isOn: $settingsStore.settings.features.skillTool) {
                SettingsRowLabel(symbol: "sparkles", color: .orange, title: "允许智能体调用技能")
            }
            .accessibilityIdentifier("skills.agentToggle")
            .padding(.horizontal, DSHTheme.Spacing.medium)
            .padding(.vertical, 8)
            .background(DSHTheme.page)
            .clipShape(RoundedRectangle(cornerRadius: DSHTheme.Radius.row, style: .continuous))

            Text("关闭后技能仍保留在本地，但不会出现在对话中，模型也不会调用。")
                .font(.system(size: 12))
                .foregroundStyle(DSHTheme.secondaryText)
                .padding(.horizontal, DSHTheme.Spacing.small)
        }
    }

    // MARK: - 技能行

    private func skillCard(_ skill: Skill) -> some View {
        SwipeToDeleteRow(
            onDelete: { skillStore.delete(id: skill.id) },
            onTap: { editingSkill = skill }
        ) {
            HStack(spacing: DSHTheme.Spacing.small) {
                rowLabel(skill)
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(DSHTheme.tertiaryText)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(DSHTheme.page)
            .contentShape(Rectangle())
        }
    }

    private var editingPresented: Binding<Bool> {
        Binding(
            get: { editingSkill != nil },
            set: { if !$0 { editingSkill = nil } }
        )
    }

    private func rowLabel(_ skill: Skill) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(skill.name)
                    .font(.system(size: 16))
                    .foregroundStyle(DSHTheme.assistantText)
                    // 标识放在名字上：若挂在整行容器上，会传播到删除按钮，
                    // 让系统把它当成整行来点击（点删除变成了只把卡片合上）
                    .accessibilityIdentifier("skills.row")
                if !skill.isEnabled {
                    Text("已关闭")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(DSHTheme.tertiaryText)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(DSHTheme.chipFill)
                        .clipShape(Capsule())
                }
            }
            if !skill.summary.isEmpty {
                Text(skill.summary)
                    .font(.system(size: 12))
                    .foregroundStyle(DSHTheme.secondaryText)
                    .lineLimit(2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var emptyCard: some View {
        Text("还没有技能，点右上角「+」添加")
            .font(.system(size: 14))
            .foregroundStyle(DSHTheme.secondaryText)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(DSHTheme.Spacing.medium)
            .background(DSHTheme.page)
            .clipShape(RoundedRectangle(cornerRadius: DSHTheme.Radius.row, style: .continuous))
            .accessibilityIdentifier("skills.empty")
    }

    // MARK: - 说明文案

    private var libraryFooter: some View {
        Text("技能与工具不重合、可同时使用：工具负责执行操作（执行命令、打开网页、读写仓库），技能负责规定「该怎么做」（步骤、规范、检查清单）。启用后模型会在需要时调用 skill 工具读取技能全文。")
            .font(.system(size: 12))
            .foregroundStyle(DSHTheme.secondaryText)
            .padding(.horizontal, DSHTheme.Spacing.small)
    }

    private var tipsCard: some View {
        Text("编写建议：技能名用「动作 + 对象」的形式，例如「周报整理」「SQL 审核」；摘要写清什么时候该用它；正文写清步骤与要求，可以直接描述输出格式与检查项。")
            .font(.system(size: 13))
            .foregroundStyle(DSHTheme.secondaryText)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(DSHTheme.Spacing.medium)
            .background(DSHTheme.page)
            .clipShape(RoundedRectangle(cornerRadius: DSHTheme.Radius.card, style: .continuous))
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 13))
            .foregroundStyle(DSHTheme.secondaryText)
            .padding(.horizontal, DSHTheme.Spacing.small)
    }
}

// MARK: - 左滑删除行

/// 自绘的左滑删除行：删除背景与卡片同高、同圆角，颜色固定为红色。
/// 卡片与删除区共用一个圆角裁剪，滑开时不会露出直角，也不会比卡片高出一截。
struct SwipeToDeleteRow<Content: View>: View {
    let onDelete: () -> Void
    /// 点击卡片（未滑开时）：进入编辑页等
    let onTap: () -> Void
    @ViewBuilder var content: Content

    /// 删除按钮展开宽度
    private let actionWidth: CGFloat = 84

    @State private var offset: CGFloat = 0
    @State private var opened = false

    var body: some View {
        ZStack(alignment: .trailing) {
            Button {
                delete()
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: actionWidth)
                    .frame(maxHeight: .infinity)
                    .background(DSHTheme.danger)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("删除")

            content
                .offset(x: offset)
                // 滑动与点击都挂在卡片本体上：卡片不是 Button，两者不会互相抢手势
                .contentShape(Rectangle())
                .gesture(drag)
                .onTapGesture {
                    if opened {
                        close()
                    } else {
                        onTap()
                    }
                }

            // 展开后在整个删除区上再压一层透明点击层：
            // 不管系统把这次点击派发给谁，点红色区域都等于「删除」
            if opened {
                Color.clear
                    .frame(width: actionWidth)
                    .frame(maxHeight: .infinity)
                    .contentShape(Rectangle())
                    .onTapGesture { delete() }
                    .accessibilityHidden(true)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: DSHTheme.Radius.row, style: .continuous))
    }

    /// 删除这条记录：立即移除，不做多余动画
    private func delete() {
        opened = false
        offset = 0
        onDelete()
    }

    private func close() {
        withAnimation(DSHAnim.list) {
            opened = false
            offset = 0
        }
    }

    private var drag: some Gesture {
        DragGesture(minimumDistance: 12)
            .onChanged { value in
                // 纵向滑动交给外层滚动，避免抢手势
                guard abs(value.translation.width) > abs(value.translation.height) else { return }
                let base = opened ? -actionWidth : 0
                offset = min(0, max(-actionWidth, base + value.translation.width))
            }
            .onEnded { value in
                guard abs(value.translation.width) > abs(value.translation.height) else { return }
                let dx = value.translation.width
                let shouldOpen = opened ? !(dx > actionWidth * 0.4) : (dx < -actionWidth * 0.4)
                withAnimation(DSHAnim.list) {
                    opened = shouldOpen
                    offset = shouldOpen ? -actionWidth : 0
                }
            }
    }
}

// MARK: - 编辑页

/// 新增 / 编辑技能：名称与正文必填，保存后立即生效。
/// 用页内推入而不是弹窗：技能页本身已经是一个 sheet，
/// 再叠一层带键盘的编辑弹窗在测试机上出现过进程异常退出。
private struct SkillEditorPage: View {
    @EnvironmentObject private var skillStore: SkillStore
    @Environment(\.dismiss) private var dismiss

    /// 传入原技能表示编辑，nil 表示新增
    let original: Skill?

    @State private var name = ""
    @State private var summary = ""
    @State private var content = ""
    @State private var isEnabled = true
    @State private var invalidMessage: String?

    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        Form {
            Section("名称") {
                TextField("例如：周报整理", text: $name)
                    .accessibilityIdentifier("skills.editor.name")
            }

            Section {
                TextField("一句话说明什么时候该用它", text: $summary, axis: .vertical)
                    .lineLimit(2...4)
                    .accessibilityIdentifier("skills.editor.summary")
            } header: {
                Text("摘要")
            } footer: {
                Text("摘要会出现在系统提示的可用技能清单里，写清楚能提高被正确调用的概率。")
            }

            Section {
                TextField(
                    "写清步骤与要求，例如：\n1. 先确认数据范围\n2. 按「本周完成 / 下周计划 / 风险」三段输出",
                    text: $content,
                    axis: .vertical
                )
                .font(.system(size: 14))
                .lineLimit(6...14)
                .accessibilityIdentifier("skills.editor.content")
            } header: {
                Text("技能说明")
            } footer: {
                Text("模型调用该技能时会读到这里的全文。")
            }

            Section {
                Toggle(isOn: $isEnabled) {
                    Text("启用该技能")
                }
                .accessibilityIdentifier("skills.toggle")
            } footer: {
                Text("关闭后技能仍保留在本地，但不会出现在对话里。")
            }

            if let invalidMessage {
                Section {
                    Text(invalidMessage)
                        .font(.system(size: 13))
                        .foregroundStyle(DSHTheme.danger)
                }
            }
        }
        .navigationTitle(original == nil ? "新建技能" : "编辑技能")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button("保存") { save() }
                    .disabled(!canSave)
                    .accessibilityIdentifier("skills.editor.save")
            }
        }
        .onAppear {
            guard let original, name.isEmpty, content.isEmpty else { return }
            name = original.name
            summary = original.summary
            content = original.content
            isEnabled = original.isEnabled
        }
    }

    private func save() {
        if let original {
            var edited = original
            edited.name = name
            edited.summary = summary
            edited.content = content
            edited.isEnabled = isEnabled
            guard skillStore.update(edited) else {
                invalidMessage = "名称与技能说明不能为空"
                return
            }
        } else if skillStore.add(name: name, summary: summary, content: content) == nil {
            invalidMessage = "名称与技能说明不能为空"
            return
        }
        dismiss()
    }
}