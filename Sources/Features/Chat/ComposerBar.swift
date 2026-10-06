import SwiftUI
import UIKit

/// 底部输入区，对齐 iOS DeepSeek 官方客户端：
/// 一张圆角灰卡片，上半是输入行，下半左侧为「深度思考 / 模型」胶囊，右侧为「+」与发送键。
struct ComposerBar: View {
    @EnvironmentObject private var engine: ChatEngine
    @EnvironmentObject private var settingsStore: SettingsStore
    @EnvironmentObject private var plugins: PluginManager

    @FocusState.Binding var focused: Bool

    /// 输入行可用宽度（用于按真实换行计算输入框高度）
    @State private var inputWidth: CGFloat = 0

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
        VStack(alignment: .leading, spacing: DSHTheme.Spacing.small) {
            // 输入以「/」开头时就展示命令面板（不再要求已聚焦），
            // 这样从「+ → 插件命令」插入斜杠后一定看得到命令列表。
            if !matchedCommands.isEmpty {
                commandPanel
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }

            inputCard

            if features.usageMetrics {
                metricsLine
            }
        }
        .padding(.horizontal, DSHTheme.Spacing.medium)
        .padding(.top, DSHTheme.Spacing.small)
        .padding(.bottom, 4)
        .background(DSHTheme.page)
        // 输入区高度只跟随内容：避免（键盘弹出时）被拉伸到铺满整屏
        .fixedSize(horizontal: false, vertical: true)
        .animation(DSHAnim.standard, value: matchedCommands.count)
        .animation(DSHAnim.standard, value: engine.isStreaming)
    }

    // MARK: - 输入卡片

    private var inputCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            inputField
            controlRow
        }
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .padding(.bottom, 10)
        .frame(height: cardHeight, alignment: .top)
        .background(DSHTheme.composerCard)
        .clipShape(RoundedRectangle(cornerRadius: DSHTheme.Radius.composer, style: .continuous))
    }

    /// 卡片总高完全由内容决定（输入行 + 间距 + 操作行 + 内边距），
    /// 不参与外层空间分配，聚焦/收起键盘时高度都不会变。
    private var cardHeight: CGFloat {
        measuredInputHeight + 8 + 32 + 12 + 10
    }

    /// 卡片底部一行：左侧快捷胶囊，右侧「+」与发送键
    private var controlRow: some View {
        HStack(spacing: 8) {
            if features.deepThinkingToggle {
                thinkingChip
            }
            if features.modelPicker {
                modelChip
            }
            Spacer(minLength: 0)
            if features.pluginCommands {
                plusButton
            }
            sendButton
        }
        // 行高固定，键盘聚焦/收起时胶囊与「+」不会上下偏移
        .frame(height: 32)
    }

    /// 「深度思考」开关：开启后整颗胶囊转为品牌蓝
    private var thinkingChip: some View {
        let on = settings.thinkingEnabled
        return Button {
            engine.toggleDeepThinking()
            if settings.hapticsEnabled {
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "brain.head.profile")
                    .font(.system(size: 11, weight: .semibold))
                Text("深度思考")
                    .font(.system(size: 13, weight: .medium))
            }
            .foregroundStyle(on ? DSHTheme.brand : DSHTheme.assistantText)
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background(on ? DSHTheme.brandSoft : DSHTheme.chipFill)
            .clipShape(Capsule())
            .overlay(
                Capsule().stroke(on ? DSHTheme.brand.opacity(0.45) : Color.clear, lineWidth: 1)
            )
            .contentShape(Capsule())
        }
        .buttonStyle(DSHPressStyle(scale: 0.95))
        .animation(DSHAnim.standard, value: on)
        .accessibilityIdentifier("composer.thinking")
        .accessibilityLabel("深度思考")
        .accessibilityValue(on ? "已开启" : "已关闭")
    }

    /// 模型选择：与「深度思考」同为灰底胶囊，文字保持正文色
    private var modelChip: some View {
        Menu {
            ForEach(engine.availableModels) { model in
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
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "cpu")
                    .font(.system(size: 10, weight: .semibold))
                Text(engine.activeModelName)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .bold))
                    .opacity(0.55)
            }
            .foregroundStyle(DSHTheme.assistantText)
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background(DSHTheme.chipFill)
            .clipShape(Capsule())
            .contentShape(Capsule())
        }
        .accessibilityIdentifier("composer.model")
        .accessibilityLabel("选择模型")
    }

    /// 输入框：高度由内容行数精确算出（1–5 行），不依赖父视图建议的尺寸，
    /// 因此聚焦、收起键盘时高度都不会跳变或残留（此前点击输入框后模型/＋号会偏移、
    /// 收键盘后卡片被拉高，都是因为输入框会向上填充 maxHeight 空间）。
    private var inputField: some View {
        TextField("给 DeepSeek 发送消息", text: $engine.draft, axis: .vertical)
            .textFieldStyle(.plain)
            .font(.system(size: 16))
            .foregroundStyle(DSHTheme.assistantText)
            .lineLimit(1...5)
            .focused($focused)
            .submitLabel(.return)
            .frame(height: measuredInputHeight, alignment: .top)
            .background(inputWidthReader)
            .onPreferenceChange(ComposerInputWidthKey.self) { inputWidth = $0 }
            .accessibilityIdentifier("composer.input")
    }

    /// 读取输入行可用宽度，用于按真实换行结果计算高度
    private var inputWidthReader: some View {
        GeometryReader { geometry in
            Color.clear.preference(key: ComposerInputWidthKey.self, value: geometry.size.width)
        }
    }

    private var measuredInputHeight: CGFloat {
        let font = UIFont.systemFont(ofSize: 16)
        guard inputWidth > 40 else { return font.lineHeight + 6 }
        let raw = engine.draft
        var lines = 1
        if !raw.isEmpty {
            let rect = (raw as NSString).boundingRect(
                with: CGSize(width: inputWidth, height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading],
                attributes: [.font: font],
                context: nil
            )
            lines = Int((rect.height / font.lineHeight).rounded(.up))
            if raw.hasSuffix("\n") { lines += 1 }
        }
        let clamped = min(5, max(1, lines))
        return font.lineHeight * CGFloat(clamped) + 6
    }

    private var plusButton: some View {
        Menu {
            Button {
                // 插入「/」后命令面板会立即出现（面板不再依赖聚焦状态）
                if !engine.draft.hasPrefix("/") {
                    engine.draft = "/" + engine.draft
                }
                focusInputSoon()
            } label: {
                Label("插件命令", systemImage: "command")
            }
            Button {
                engine.openBrowser(defaultURL)
            } label: {
                Label("内置浏览器", systemImage: "safari")
            }
            if !engine.draft.isEmpty {
                Button {
                    // 只清空内容，不在这里改动焦点，避免输入卡片高度被异常撑开
                    engine.draft = ""
                } label: {
                    Label("清空输入", systemImage: "eraser")
                }
            }
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(DSHTheme.secondaryText)
                .frame(width: 30, height: 30)
                .background(Circle().fill(DSHTheme.chipFill))
                .contentShape(Circle())
        }
        .disabled(engine.isStreaming)
        .accessibilityIdentifier("composer.plus")
        .accessibilityLabel("更多")
    }

    /// 菜单收起后再聚焦，避免菜单退场动画期间聚焦失败导致命令面板不出现
    private func focusInputSoon() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { focused = true }
    }

    /// 手动打开内置浏览器时的默认首页
    private var defaultURL: URL {
        URL(string: "https://www.deepseek.com")!
    }

    /// 发送 / 停止：空闲灰底灰箭头，有内容时整颗转为品牌蓝
    @ViewBuilder
    private var sendButton: some View {
        if engine.isStreaming {
            Button {
                engine.stopStreaming()
            } label: {
                Image(systemName: "stop.fill")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(DSHTheme.page)
                    .frame(width: 32, height: 32)
                    .background(Circle().fill(DSHTheme.assistantText))
                    .contentShape(Circle())
            }
            .buttonStyle(DSHPressStyle(scale: 0.9))
            .accessibilityIdentifier("composer.stop")
            .accessibilityLabel("停止生成")
        } else {
            Button {
                focused = false
                engine.send()
            } label: {
                Image(systemName: "arrow.up")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(canSend ? Color.white : DSHTheme.sendIdleIcon)
                    .frame(width: 32, height: 32)
                    .background(Circle().fill(canSend ? DSHTheme.brand : DSHTheme.sendIdle))
                    .contentShape(Circle())
            }
            .buttonStyle(DSHPressStyle(scale: 0.9))
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
        HStack(spacing: 6) {
            Text("\(rounds) 轮")
            Text("·")
            Text("输入 \(lastPromptTokens) tok")
            Text("·")
            Text("输出 \(lastCompletionTokens) tok")
            Spacer(minLength: 0)
            Text(engine.isStreaming ? "生成中" : settings.thinkingEnabled ? "已开启深度思考" : "已关闭深度思考")
        }
        .font(.system(size: 11))
        .foregroundStyle(DSHTheme.tertiaryText)
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
                                .foregroundStyle(DSHTheme.secondaryText)
                                .lineLimit(1)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(DSHTheme.chipFill)
                        .clipShape(RoundedRectangle(cornerRadius: DSHTheme.Radius.chip, style: .continuous))
                    }
                    .buttonStyle(DSHPressStyle(scale: 0.96))
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
        focusInputSoon()
    }
}

/// 输入行宽度上报（用于按真实换行结果计算输入框高度）
private struct ComposerInputWidthKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}
