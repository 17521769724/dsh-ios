import SwiftUI
import UIKit

/// 底部输入舱，对齐 DSH Desktop：
/// 圆角容器内左侧「+」，中间自适应输入框，右侧模型 chip 与圆形发送键，下方一行运行指标。
struct InputBar: View {
    @EnvironmentObject private var engine: ChatEngine
    @EnvironmentObject private var plugins: PluginManager

    @FocusState private var focused: Bool

    private var matchedCommands: [PluginCommand] {
        let text = engine.draft
        guard text.hasPrefix("/") else { return [] }
        let query = String(text.dropFirst()).split(separator: " ").first.map(String.init) ?? ""
        if query.isEmpty { return plugins.commands }
        return plugins.commands.filter { $0.name.lowercased().hasPrefix(query.lowercased()) }
    }

    var body: some View {
        VStack(spacing: DSHTheme.Spacing.small) {
            if !matchedCommands.isEmpty && focused {
                commandPanel
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }

            composer
            metricsLine
        }
        .padding(.horizontal, DSHTheme.Spacing.medium)
        .padding(.top, DSHTheme.Spacing.small)
        .padding(.bottom, 6)
        .background(DSHTheme.pageBackground)
        .animation(DSHAnim.standard, value: matchedCommands.count)
        .animation(DSHAnim.standard, value: engine.isStreaming)
    }

    // MARK: - 输入舱

    private var composer: some View {
        HStack(alignment: .bottom, spacing: DSHTheme.Spacing.small) {
            plusMenu

            TextField("给智能体发送消息", text: $engine.draft, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 15))
                .lineLimit(1...6)
                .focused($focused)
                .padding(.vertical, 8)
                .onSubmit {
                    if !engine.isStreaming { engine.send() }
                }

            modelChip
            sendButton
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(DSHTheme.inputBackground)
        .clipShape(RoundedRectangle(cornerRadius: DSHTheme.Radius.composer, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: DSHTheme.Radius.composer, style: .continuous)
                .stroke(focused ? DSHTheme.brand.opacity(0.55) : DSHTheme.separator, lineWidth: focused ? 1 : 0.5)
        )
        .animation(DSHAnim.standard, value: focused)
        .shadow(color: Color.black.opacity(0.18), radius: 10, y: 4)
    }

    private var plusMenu: some View {
        Menu {
            Button {
                withAnimation(DSHAnim.standard) {
                    engine.draft = engine.draft.isEmpty ? "/" : "/" + engine.draft
                }
                focused = true
            } label: {
                Label("插入插件命令", systemImage: "command")
            }
            Button {
                focused = true
            } label: {
                Label("清空输入", systemImage: "eraser")
            }
            Button {
                engine.newConversation()
            } label: {
                Label("新建会话", systemImage: "square.and.pencil")
            }
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 30, height: 30)
                .background(DSHTheme.elevatedBackground.opacity(0.9))
                .clipShape(Circle())
        }
        .disabled(engine.isStreaming)
        .accessibilityLabel("更多操作")
    }

    private var modelMenu: some View {
        Menu {
            ForEach(DSHModel.catalog) { model in
                Button {
                    engine.settingsStore.settings.defaultModel = model.id
                    engine.showToast("已切换到 \(model.name)")
                } label: {
                    if engine.settingsStore.settings.defaultModel == model.id {
                        Label(model.name, systemImage: "checkmark")
                    } else {
                        Text(model.name)
                    }
                }
            }
        } label: {
            HStack(spacing: 3) {
                Text(shortModelName)
                    .font(.system(size: 12, weight: .medium))
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .bold))
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .background(DSHTheme.elevatedBackground.opacity(0.9))
            .clipShape(Capsule())
        }
        .accessibilityLabel("选择模型")
    }

    private var modelChip: some View {
        modelMenu
    }

    private var shortModelName: String {
        let id = engine.settingsStore.settings.defaultModel
        switch id {
        case "deepseek-chat": return "DeepSeek-V3"
        case "deepseek-reasoner": return "DeepSeek-R1"
        default: return DSHModel.model(for: id).name
        }
    }

    @ViewBuilder
    private var sendButton: some View {
        if engine.isStreaming {
            Button {
                engine.stopStreaming()
            } label: {
                Image(systemName: "stop.fill")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 30, height: 30)
                    .background(DSHTheme.danger)
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
            .transition(.scale.combined(with: .opacity))
            .accessibilityLabel("停止生成")
        } else {
            Button {
                engine.send()
            } label: {
                Image(systemName: "arrow.up")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 30, height: 30)
                    .background(canSend ? DSHTheme.brand : Color.secondary.opacity(0.35))
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
            .disabled(!canSend)
            .scaleEffect(canSend ? 1 : 0.94)
            .animation(DSHAnim.emphasis, value: canSend)
            .transition(.scale.combined(with: .opacity))
            .accessibilityLabel("发送")
        }
    }

    private var canSend: Bool {
        !engine.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // MARK: - 指标行

    private var metricsLine: some View {
        HStack(spacing: 6) {
            metric("\(rounds) 轮", "bubble.left.and.bubble.right")
            Text("·").foregroundStyle(.tertiary)
            metric("\(lastPromptTokens) tok 输入", "arrow.down")
            Text("·").foregroundStyle(.tertiary)
            metric("\(lastCompletionTokens) tok 输出", "arrow.up")
            Spacer(minLength: 0)
            if engine.isStreaming {
                HStack(spacing: 4) {
                    Circle()
                        .fill(DSHTheme.brand)
                        .frame(width: 5, height: 5)
                    Text("生成中")
                }
                .font(.system(size: 10))
                .foregroundStyle(DSHTheme.brand)
            } else {
                Text(engine.settingsStore.isConfigured ? "就绪" : "未配置 API Key")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
        }
        .font(.system(size: 10))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 4)
    }

    private func metric(_ text: String, _ icon: String) -> some View {
        HStack(spacing: 3) {
            Image(systemName: icon)
                .font(.system(size: 9))
            Text(text)
        }
    }

    private var rounds: Int {
        (engine.currentConversation?.messages.filter { $0.role == .user }.count) ?? 0
    }

    private var lastPromptTokens: Int {
        engine.currentConversation?.messages.last(where: { $0.promptTokens != nil })?.promptTokens ?? 0
    }

    private var lastCompletionTokens: Int {
        engine.currentConversation?.messages.last(where: { $0.completionTokens != nil })?.completionTokens ?? 0
    }

    // MARK: - 命令面板

    private var commandPanel: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: DSHTheme.Spacing.small) {
                ForEach(matchedCommands) { command in
                    Button {
                        run(command)
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("/" + command.name)
                                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                                .foregroundStyle(DSHTheme.brand)
                            Text(command.summary)
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        .padding(.horizontal, 11)
                        .padding(.vertical, 7)
                        .dshCard(background: DSHTheme.inputBackground)
                    }
                    .buttonStyle(PressableCardStyle())
                }
            }
            .padding(.vertical, 2)
        }
    }

    private func run(_ command: PluginCommand) {
        var argument = ""
        let text = engine.draft
        if text.hasPrefix("/") {
            let remainder = text.dropFirst()
            if let spaceIndex = remainder.firstIndex(of: " ") {
                argument = String(remainder[spaceIndex...]).trimmingCharacters(in: .whitespaces)
            }
        }

        guard let output = plugins.run(command: command.name, argument: argument) else {
            engine.showToast("命令 /\(command.name) 执行失败")
            return
        }

        if output.count > 60 {
            engine.draft = output
        } else {
            engine.showToast("/\(command.name) → \(output)")
            if !argument.isEmpty {
                engine.draft = ""
            } else {
                engine.draft = ""
            }
        }
        focused = true
    }
}

/// 卡片按压反馈
struct PressableCardStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .opacity(configuration.isPressed ? 0.85 : 1)
            .animation(DSHAnim.emphasis, value: configuration.isPressed)
    }
}