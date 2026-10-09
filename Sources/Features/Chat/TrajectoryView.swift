import SwiftUI

/// 「轨迹」视图：按时间顺序展示会话事件，对齐桌面端的轨迹/会话日志面板。
///
/// 性能注意（用户反馈过「打开要等很久」）：
/// - `events` 只在 body 里算一次（此前每行都会重新读一遍计算属性，行数一多是 O(n²)）；
/// - 用 `LazyVStack` 只渲染可见行；
/// - 长内容（模型回复、工具输出）默认只显示摘要，点这一行才展开完整内容，
///   避免一次性排版整段长文本。
struct TrajectoryView: View {
    @EnvironmentObject private var engine: ChatEngine

    private struct Event: Identifiable {
        let id: UUID
        let icon: String
        let title: String
        /// 折叠时显示的一行摘要
        let summary: String
        /// 展开后显示的完整内容（为空表示没有可展开的内容）
        let full: String
        let timestamp: Date
        let tint: Color

        var isExpandable: Bool { !full.isEmpty }
    }

    /// 展开的事件 id
    @State private var expanded: Set<UUID> = []

    /// 单条内容展开时的长度上限，避免超长文本拖慢排版
    private static let expandLimit = 8_000
    /// 折叠摘要的长度
    private static let summaryLimit = 60

    private var events: [Event] {
        guard let conversation = engine.currentConversation else { return [] }
        var result: [Event] = [
            Event(
                id: conversation.id,
                icon: "flag",
                title: "会话创建",
                summary: "模型 \(conversation.model)",
                full: "",
                timestamp: conversation.createdAt,
                tint: DSHTheme.brand
            )
        ]
        for message in conversation.messages where message.role != .system {
            switch message.role {
            case .user:
                result.append(Event(
                    id: message.id,
                    icon: "arrow.up.circle",
                    title: "用户输入",
                    summary: Self.summaryLine(message.content, prefix: "\(message.content.count) 字"),
                    full: Self.trimmed(message.content),
                    timestamp: message.createdAt,
                    tint: .secondary
                ))
            case .assistant:
                let tokens = message.completionTokens.map { "\($0) tok" } ?? "—"
                let hasReasoning = (message.reasoning?.isEmpty == false)
                result.append(Event(
                    id: message.id,
                    icon: message.errorText != nil ? "exclamationmark.triangle" : "sparkles",
                    title: message.errorText != nil ? "回复失败" : "模型回复",
                    summary: Self.summaryLine(
                        message.content,
                        prefix: "\(message.content.count) 字 · 输出 \(tokens)\(hasReasoning ? " · 含思考" : "")"
                    ),
                    full: Self.trimmed(message.content),
                    timestamp: message.createdAt,
                    tint: message.errorText != nil ? DSHTheme.danger : DSHTheme.brand
                ))
            case .tool:
                result.append(Event(
                    id: message.id,
                    icon: "wrench.and.screwdriver",
                    title: Self.toolTitle(message),
                    summary: Self.summaryLine(message.content, prefix: "\(message.content.count) 字"),
                    full: Self.trimmed(message.content),
                    timestamp: message.createdAt,
                    tint: DSHTheme.warning
                ))
            case .system:
                continue
            }
        }
        return result.sorted { $0.timestamp < $1.timestamp }
    }

    var body: some View {
        // events 只算一次：此前在 body 里反复读取计算属性，行数一多就是 O(n²) 重建，弹窗迟迟打不开
        let list = events
        return Group {
            if list.isEmpty {
                VStack(spacing: DSHTheme.Spacing.small) {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.system(size: 24))
                        .foregroundStyle(.tertiary)
                    Text("当前会话还没有轨迹记录")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    // 只渲染可见的行：会话很长时也能秒开
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(list.enumerated()), id: \.element.id) { index, event in
                            row(event, isLast: index == list.count - 1)
                        }
                    }
                    .padding(DSHTheme.Spacing.large)
                }
            }
        }
        .background(DSHTheme.page)
    }

    // MARK: - 单行

    private func row(_ event: Event, isLast: Bool) -> some View {
        let isExpanded = expanded.contains(event.id)
        return HStack(alignment: .top, spacing: DSHTheme.Spacing.medium) {
            VStack(spacing: 0) {
                ZStack {
                    Circle()
                        .fill(event.tint.opacity(0.16))
                        .frame(width: 26, height: 26)
                    Image(systemName: event.icon)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(event.tint)
                }
                if !isLast {
                    Rectangle()
                        .fill(DSHTheme.separator)
                        .frame(width: 1)
                        .frame(maxHeight: .infinity)
                }
            }
            .frame(width: 26)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(event.title)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Text(event.timestamp.formatted(date: .omitted, time: .standard))
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.tertiary)
                    // 可展开的行：右侧给一个箭头，点整行展开 / 收起
                    if event.isExpandable {
                        Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.tertiary)
                    }
                }
                Text(event.summary)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if isExpanded {
                    Text(event.full)
                        .font(.system(size: 12))
                        .foregroundStyle(DSHTheme.tertiaryText)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(DSHTheme.Spacing.small)
                        .background(DSHTheme.grouped)
                        .clipShape(RoundedRectangle(cornerRadius: DSHTheme.Radius.chip, style: .continuous))
                }
            }
            .padding(.bottom, DSHTheme.Spacing.large)
            .contentShape(Rectangle())
            .onTapGesture {
                guard event.isExpandable else { return }
                withAnimation(DSHAnim.list) {
                    if isExpanded {
                        expanded.remove(event.id)
                    } else {
                        expanded.insert(event.id)
                    }
                }
            }
            .accessibilityIdentifier(event.isExpandable ? "log.row.expandable" : "log.row")
        }
    }

    // MARK: - 文案

    /// 折叠时的一行摘要：先给统计信息，再接一句内容预览
    private static func summaryLine(_ text: String, prefix: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return prefix }
        let preview = trimmed
            .replacingOccurrences(of: "\n", with: " ")
            .prefix(summaryLimit)
        return "\(prefix) · \(preview)\(trimmed.count > summaryLimit ? "…" : "")"
    }

    private static func trimmed(_ text: String) -> String {
        text.count > expandLimit ? String(text.prefix(expandLimit)) + "\n…（内容过长，已截断）" : text
    }

    /// 工具消息的标题：直接写清调用了什么工具
    private static func toolTitle(_ message: ChatMessage) -> String {
        let name = message.toolName ?? ""
        switch name {
        case AgentToolCatalog.browserOpenName: return "调用内置浏览器打开网页"
        case AgentToolCatalog.browserReadName: return "读取网页正文"
        case AgentToolCatalog.sshExecName: return "在 SSH 服务器执行命令"
        case AgentToolCatalog.workspaceName: return "读写工作区文件"
        case AgentToolCatalog.clipboardName: return "读写剪贴板"
        case AgentToolCatalog.reminderName: return "读写提醒事项与日历"
        case AgentToolCatalog.screenshotName: return "查看画面（截图 + OCR）"
        case AgentToolCatalog.githubName: return "操作 GitHub 仓库"
        case AgentToolCatalog.giteeName: return "操作 Gitee 仓库"
        case AgentToolCatalog.skillName: return "读取技能说明"
        default:
            if AgentToolCatalog.isMCPTool(name) {
                // 模型侧工具名形如 mcp_<服务器别名>_<工具名>
                let parts = name.split(separator: "_")
                if parts.count > 2 {
                    return "调用 MCP 工具（\(parts[1])）"
                }
                return "调用 MCP 工具"
            }
            return name.isEmpty ? "工具执行" : "调用 \(name)"
        }
    }
}