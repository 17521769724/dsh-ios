import SwiftUI

/// 技能库：自行添加「做事方法与规范」，交给模型按需取用。
/// 与插件中心并列，入口在左侧菜单栏底部。
struct SkillsView: View {
    @EnvironmentObject private var skillStore: SkillStore
    @EnvironmentObject private var settingsStore: SettingsStore

    private var listSkills: [Skill] {
        skillStore.skills.sorted { $0.updatedAt > $1.updatedAt }
    }

    var body: some View {
        List {
            // 总开关放在顶部：技能库整体「能不能被智能体调用」只在这里控制
            Section {
                Toggle(isOn: $settingsStore.settings.features.skillTool) {
                    SettingsRowLabel(symbol: "sparkles", color: .orange, title: "允许智能体调用技能")
                }
                .accessibilityIdentifier("skills.agentToggle")
            } footer: {
                Text("关闭后技能仍保留在本地，但不会出现在对话中，模型也不会调用。")
            }

            Section {
                ForEach(listSkills) { skill in
                    NavigationLink {
                        SkillEditorPage(original: skill)
                    } label: {
                        rowLabel(skill)
                    }
                    .accessibilityIdentifier("skills.row")
                    // 行背景自绘成圆角卡片：系统默认行背景在「左滑后再右滑」时会残留直角
                    .listRowBackground(
                        RoundedRectangle(cornerRadius: DSHTheme.Radius.row, style: .continuous)
                            .fill(DSHTheme.page)
                            .padding(.vertical, 3)
                    )
                    .listRowSeparator(.hidden)
                    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                        Button(role: .destructive) {
                            skillStore.delete(id: skill.id)
                        } label: {
                            Label("删除", systemImage: "trash")
                        }
                        // 明确指定红色：列表上的品牌色 tint 会把破坏性按钮一起染蓝
                        .tint(DSHTheme.danger)
                    }
                }
                if listSkills.isEmpty {
                    Text("还没有技能，点右上角「+」添加")
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("skills.empty")
                }
            } header: {
                Text("技能库（\(skillStore.skills.count)）")
            } footer: {
                Text("技能与工具不重合、可同时使用：工具负责执行操作（执行命令、打开网页、读写仓库），技能负责规定「该怎么做」（步骤、规范、检查清单）。启用后模型会在需要时调用 skill 工具读取技能全文。")
            }

            Section {
                Text("编写建议：技能名用「动作 + 对象」的形式，例如「周报整理」「SQL 审核」；摘要写清什么时候该用它；正文写清步骤与要求，可以直接描述输出格式与检查项。")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("技能")
        .navigationBarTitleDisplayMode(.inline)
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

    private func rowLabel(_ skill: Skill) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(skill.name)
                    .font(.system(size: 16))
                    .foregroundStyle(DSHTheme.assistantText)
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
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        // 行背景是自绘的圆角卡片，这里给内容留出上下内边距
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
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