import Foundation

/// 技能：用户自己写的「做事方法与规范」，由模型在需要时按名字取用。
///
/// 与工具的区分（两者互补、不重合）：
/// - 工具（ssh_exec / browser_open / github …）负责**执行操作**，是模型的手脚；
/// - 技能负责**规定做法**（步骤、规范、话术、检查清单），是模型的经验。
///
/// 因此技能不需要任何外部服务配置，只把说明交给模型即可生效。
struct Skill: Identifiable, Codable, Equatable, Hashable {

    var id: UUID
    /// 技能名，模型通过这个名字取用，同一技能库内唯一
    var name: String
    /// 一句话摘要，进系统提示的清单里，让模型知道什么时候该用它
    var summary: String
    /// 技能正文（给模型的完整说明）
    var content: String
    var isEnabled: Bool
    var createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        name: String,
        summary: String = "",
        content: String,
        isEnabled: Bool = true,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.summary = summary
        self.content = content
        self.isEnabled = isEnabled
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

/// 技能库：落盘到 Documents/skills.json，支持自行添加、编辑、启停与删除。
final class SkillStore: ObservableObject {

    @Published private(set) var skills: [Skill] = []

    private let fileURL: URL

    init(fileName: String = "skills.json") {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        self.fileURL = dir.appendingPathComponent(fileName)
        load()
    }

    // MARK: - 查询

    /// 已启用的技能：只有这些会进系统提示清单并允许模型调用
    var enabledSkills: [Skill] { skills.filter(\.isEnabled) }

    /// 按名字取技能（模型可能带上多余空白或大小写差异）
    func skill(named name: String) -> Skill? {
        let key = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !key.isEmpty else { return nil }
        return skills.first { $0.name.lowercased() == key }
            ?? skills.first { $0.name.lowercased().contains(key) }
    }

    // MARK: - 写入

    /// 新增技能；同名技能直接覆盖（同名会让模型拿到两份冲突说明）。
    /// 名称或正文为空时返回 nil，不写库。
    @discardableResult
    func add(name: String, summary: String, content: String) -> Skill? {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedSummary = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedContent = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty, !trimmedContent.isEmpty else { return nil }

        if let index = skills.firstIndex(where: { $0.name.lowercased() == trimmedName.lowercased() }) {
            skills[index].summary = trimmedSummary
            skills[index].content = trimmedContent
            skills[index].updatedAt = Date()
            save()
            return skills[index]
        }

        let skill = Skill(name: trimmedName, summary: trimmedSummary, content: trimmedContent)
        skills.append(skill)
        save()
        return skill
    }

    /// 保存编辑结果：名称与正文仍然不能为空，否则忽略这次保存
    @discardableResult
    func update(_ skill: Skill) -> Bool {
        let trimmedName = skill.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedContent = skill.content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty, !trimmedContent.isEmpty else { return false }
        guard let index = skills.firstIndex(where: { $0.id == skill.id }) else { return false }

        skills[index].name = trimmedName
        skills[index].summary = skill.summary.trimmingCharacters(in: .whitespacesAndNewlines)
        skills[index].content = trimmedContent
        skills[index].isEnabled = skill.isEnabled
        skills[index].updatedAt = Date()
        save()
        return true
    }

    func delete(id: UUID) {
        skills.removeAll { $0.id == id }
        save()
    }

    func delete(at offsets: IndexSet) {
        skills.remove(atOffsets: offsets)
        save()
    }

    func toggle(id: UUID) {
        guard let index = skills.firstIndex(where: { $0.id == id }) else { return }
        skills[index].isEnabled.toggle()
        save()
    }

    func deleteAll() {
        skills.removeAll()
        save()
    }

    // MARK: - 持久化

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        guard let decoded = try? JSONDecoder().decode([Skill].self, from: data) else { return }
        skills = decoded
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted]
        guard let data = try? encoder.encode(skills) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}