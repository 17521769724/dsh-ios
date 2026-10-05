import SwiftUI
import UIKit

/// 底部输入区，对齐 DeepSeek iOS 客户端：
/// 圆角容器内上方是「深度思考 / 模型」胶囊，下方是输入框与圆形发送键。
struct ComposerBar: View {
    @EnvironmentObject private var engine: ChatEngine
    @EnvironmentObject private var settingsStore: SettingsStore
    @EnvironmentObject private var plugins: PluginManager

    @FocusState.Binding var focused: Bool

    private var settings: AppSettings { settingsStore.settings }
    private var features: FeatureFlags { settings.features }

    /// 与输入框联动的插件命令候选
    private var matchedCommands: [PluginCommand] {
        guard features.pluginCommands else { return [] }
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
                    .transition(.opacity)
            }

            inputContainer

            if features.usageMetrics {
                metricsLine
            }
        }
        .padding(.horizontal, DSHTheme.Spacing.medium)
        .padding(.top, DSHTheme.Spacing.small)
        .padding(.bottom, 6)
        .background(.bar)
        .animation(DSHAnim.standard, value: matchedCommands.count)
        .animation(DSHAnim.standard, value: engine.isStreaming)
    }

    // MARK: - 输入容器

    private var inputContainer: some View {
        VStack(alignment: .leading, spacing: DSHTheme.Spacing.small) {
            if showsTopChips {
                topChips
            }

            HStack(alignment: .bottom, spacing: DSHTheme.Spacing.small) {
                if features.pluginCommands {
                    plusButton
                }

                inputField

                sendButton
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .background(DSHTheme.inputBackground)
        .clipShape(RoundedRectangle(cornerRadius: DSHTheme.Radius.composer, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: DSHTheme.Radius.composer, style: .continuous)
                .stroke(focused ? DSHTheme.brand.opacity(0.6) : Color.clear, lineWidth: 1)
        )
        .animation(DSHAnim.standard, value: focused)
    }

    private var showsTopChips: Bool {
        features.deepThinkingToggle || features.modelPicker
    }

    private var topChips: some View {
        HStack(spacing: DSHTheme.Spacing.small) {
            if features.deepThinkingToggle {
                thinkingChip
            }
            if features.modelPicker {
                modelChip
            }
            Spacer(minLength: 0)
        }
    }

    /// 「深度思考」开关：对应官方 API 的 thinking 参数
    private var thinkingChip: some View {
        Button {
            engine.toggleDeepThinking()
        } label: {
            HStack(spacing: 5) {
                Image(systemName: settings.thinkingEnabled ? "brain.fill" : "brain")
                    .font(.system(size: 11, weight: .semibold))
                Text("深度思考")
                    .font(.system(size: 12, weight: .medium))
            }
            .foregroundStyle(settings.thinkingEnabled ? DSHTheme.brand : Color.secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(settings.thinkingEnabled ? DSHTheme.brandSoft : Color(uiColor: .tertiarySystemFill))
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("composer.thinking")
        .accessibilityLabel("深度思考")
        .accessibilityValue(settings.thinkingEnabled ? "已开启" : "已关闭")
    }

    private var modelChip: some View {
        Menu {
            ForEach(engine.availableModels.filter { !$0.isDeprecated }) { model in
                Button {
                    engine.selectModel(model.id)
                } label: {
                    if engine.activeModelID == model.id {
                        Label(model.name, systemImage: "checkmark")
                    } else {
                        Text(model.name)
                    }
                }
            }
            Divider()
            Button {
                engine.refreshModels()
            } label: {
                Label("从服务端获取模型列表", systemImage: "arrow.triangle.2.circlepath")
            }
        } label: {
            HStack(spacing: 4) {
                Text(engine.activeModelName)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .bold))
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Color(uiColor: .tertiarySystemFill))
            .clipShape(Capsule())
        }
        .accessibilityIdentifier("composer.model")
        .accessibilityLabel("选择模型")
    }

    /// 输入框：空态保持单行高度，随内容增长，最多 5 行后内部滚动。
    /// 不额外套 frame(maxHeight:)，否则纵向 TextField 会按上限高度占位、撑高输入区。
    /// 键盘回车键换行（与官方客户端一致），发送由右侧按钮触发。
    private var inputField: some View {
        TextField("给 DeepSeek 发送消息", text: $engine.draft, axis: .vertical)
            .textFieldStyle(.plain)
            .font(.system(size: 16))
            .lineLimit(1...5)
            .focused($focused)
            .submitLabel(.return)
            .padding(.vertical, 6)
            .padding(.leading, 4)
            .accessibilityIdentifier("composer.input")
    }

    private var plusButton: some View {
        Menu {
            Button {
                withAnimation(DSHAnim.standard) {
                    engine.draft = engine.draft.isEmpty ? "/" : "/" + engine.draft
                }
                focused = true
            } label: {
                Label("插件命令", systemImage: "command")
            }
            Button {
                engine.draft = ""
                focused = true
            } label: {
                Label("清空输入", systemImage: "eraser")
            }
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .disabled(engine.isStreaming)
        .accessibilityIdentifier("composer.plus")
        .accessibilityLabel("更多")
    }

    @ViewBuilder
    private var sendButton: some View {
        if engine.isStreaming {
            Button {
                engine.stopStreaming()
            } label: {
                Image(systemName: "stop.fill")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 30, height: 30)
                    .background(Color(uiColor: .systemGray))
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("composer.stop")
            .accessibilityLabel("停止生成")
        } else {
            Button {
                focused = false
                engine.send()
            } label: {
                Image(systemName: "arrow.up")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(canSend ? .white : Color.secondary)
                    .frame(width: 30, height: 30)
                    .background(canSend ? DSHTheme.brand : Color(uiColor: .tertiarySystemFill))
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
            .disabled(!canSend)
            .animation(DSHAnim.standard, value: canSend)
            .accessibilityIdentifier("composer.send")
            .accessibilityLabel("发送")
        }
    }

    private var canSend: Bool {
        !engine.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // MARK: - 指标行（可选）

    private var metricsLine: some View {
        HStack(spacing: 8) {
            Text("\(rounds) 轮")
            Text("·")
            Text("输入 \(lastPromptTokens) tok")
            Text("·")
            Text("输出 \(lastCompletionTokens) tok")
            Spacer(minLength: 0)
            Text(engine.isStreaming ? "生成中" : settings.thinkingEnabled ? "已开启深度思考" : "已关闭深度思考")
        }
        .font(.system(size: 10))
        .foregroundStyle(.tertiary)
        .padding(.horizontal, 6)
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

    // MARK: - 插件命令面板（可选）

    private var commandPanel: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: DSHTheme.Spacing.small) {
                ForEach(matchedCommands) { command in
                    Button {
                        run(command)
                    } label: {
                        VStack(alignment: .leading, spacing: 1) {
                            Text("/" + command.name)
                                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                                .foregroundStyle(DSHTheme.brand)
                            Text(command.summary)
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .dshCard()
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("plugin.command.\(command.name)")
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
            engine.draft = ""
        }
        focused = true
    }
}