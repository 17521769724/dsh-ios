import SwiftUI

/// 「轨迹」视图：按时间顺序展示会话事件，对齐桌面端的轨迹/会话日志面板。
struct TrajectoryView: View {
    @EnvironmentObject private var engine: ChatEngine

    private struct Event: Identifiable {
        let id: UUID
        let icon: String
        let title: String
        let detail: String
        let timestamp: Date
        let tint: Color
    }

    private var events: [Event] {
        guard let conversation = engine.currentConversation else { return [] }
        var result: [Event] = [
            Event(
                id: conversation.id,
                icon: "flag",
                title: "会话创建",
                detail: "模型 \(conversation.model)",
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
                    detail: "\(message.content.count) 字",
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
                    detail: "\(message.content.count) 字 · 输出 \(tokens)\(hasReasoning ? " · 含思考" : "")",
                    timestamp: message.createdAt,
                    tint: message.errorText != nil ? DSHTheme.danger : DSHTheme.brand
                ))
            case .tool:
                result.append(Event(
                    id: message.id,
                    icon: "wrench.and.screwdriver",
                    title: "插件执行",
                    // 工具输出可能上万字：这里只留摘要，避免弹窗打开时排版整段长文本（打开很慢的原因之一）
                    detail: Self.summarized(message.content),
                    timestamp: message.createdAt,
                    tint: DSHTheme.warning
                ))
            case .system:
                continue
            }
        }
        return result.sorted { $0.timestamp < $1.timestamp }
    }

    /// 工具输出只取前若干字符做摘要
    private static let detailLimit = 160

    private static func summarized(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > detailLimit else { return trimmed }
        return String(trimmed.prefix(detailLimit)) + "…（共 \(trimmed.count) 字）"
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
                            HStack(alignment: .top, spacing: DSHTheme.Spacing.medium) {
                                VStack(spacing: 0) {
                                    ZStack {
                                        Circle()
                                            .fill(event.tint.opacity(0.16))
                                            .frame(width: 26, height: 26)
                                        Image(systemName: event.icon)
                                            .font(.system(size: 12, weight: .semibold))
                                            .foregroundStyle(event.tint)
                                    }
                                    if index < list.count - 1 {
                                        Rectangle()
                                            .fill(DSHTheme.separator)
                                            .frame(width: 1)
                                            .frame(maxHeight: .infinity)
                                    }
                                }
                                .frame(width: 26)

                                VStack(alignment: .leading, spacing: 3) {
                                    HStack {
                                        Text(event.title)
                                            .font(.system(size: 13, weight: .semibold))
                                        Spacer()
                                        Text(event.timestamp.formatted(date: .omitted, time: .standard))
                                            .font(.system(size: 10, design: .monospaced))
                                            .foregroundStyle(.tertiary)
                                    }
                                    Text(event.detail)
                                        .font(.system(size: 12))
                                        .foregroundStyle(.secondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                .padding(.bottom, DSHTheme.Spacing.large)
                            }
                        }
                    }
                    .padding(DSHTheme.Spacing.large)
                }
            }
        }
        .background(DSHTheme.page)
    }
}