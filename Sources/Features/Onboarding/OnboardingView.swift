import SwiftUI
import UIKit

/// 首次启动引导：必须先完成 API Key 配置，才能进入主页。
/// API 地址与 API Key 都是常显的独立输入框（不再折叠在「高级选项」里），地址在上、Key 在下。
struct OnboardingView: View {
    @EnvironmentObject private var engine: ChatEngine
    @EnvironmentObject private var settingsStore: SettingsStore

    @State private var keyInput: String = ""
    @State private var baseURLInput: String = AppSettings.default.baseURL
    @State private var isValidating = false
    @State private var errorText: String?
    @State private var revealed = false
    /// 原生 Key 输入框的聚焦状态（用于输入框高亮描边）
    @State private var keyFieldFocused = false
    @FocusState private var focusedField: Field?

    private enum Field { case key, baseURL }

    private var canSubmit: Bool {
        !keyInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isValidating
    }

    var body: some View {
        // 背景与滚动内容分层：键盘弹出/收起时只有内容区随安全区变化，
        // 背景是独立的静态层，不会在状态栏附近出现闪动。
        ZStack {
            DSHTheme.page.ignoresSafeArea()

            ScrollView {
                VStack(spacing: DSHTheme.Spacing.section) {
                    header
                    formCard
                    actions
                    footer
                }
                .padding(.horizontal, DSHTheme.Spacing.section)
                .padding(.vertical, 40)
                .frame(maxWidth: 520)
                .frame(maxWidth: .infinity)
            }
            // 上下滑动页面即可收起键盘；点击空白收起由 RootView 的全局手势负责
            .scrollDismissesKeyboard(.immediately)
        }
        .onAppear {
            baseURLInput = settingsStore.settings.baseURL
            keyInput = settingsStore.apiKey
        }
    }

    // MARK: - 顶部说明

    private var header: some View {
        VStack(spacing: DSHTheme.Spacing.medium) {
            DSHWhaleMark(size: 72)
                .shadow(color: DSHTheme.brand.opacity(0.18), radius: 12, y: 5)

            VStack(spacing: 6) {
                Text("欢迎使用 DeepSeek")
                    .font(.system(size: 24, weight: .bold))
                    .foregroundStyle(DSHTheme.assistantText)
                Text("先填写 API Key，即可开始对话")
                    .font(.system(size: 15))
                    .foregroundStyle(DSHTheme.secondaryText)
                    .multilineTextAlignment(.center)
            }
        }
    }

    // MARK: - 表单

    private var formCard: some View {
        VStack(alignment: .leading, spacing: DSHTheme.Spacing.large) {
            inputGroup(
                title: "API 地址",
                symbol: "network",
                focused: focusedField == .baseURL,
                hint: "兼容任意 OpenAI 格式接口，可填自建或中转地址"
            ) {
                TextField("https://api.deepseek.com", text: $baseURLInput)
                    .keyboardType(.URL)
                    .focused($focusedField, equals: .baseURL)
                    .accessibilityIdentifier("onboarding.baseurl")
            }

            inputGroup(
                title: "API Key",
                symbol: "key.fill",
                focused: focusedField == .key || keyFieldFocused
            ) {
                HStack(spacing: DSHTheme.Spacing.small) {
                    // 明文 / 密文只切换同一个原生输入框的安全属性，视图不重建，
                    // 所以点击眼睛图标时「sk-…」占位符不会上下跳动。
                    SecureInputField(
                        text: $keyInput,
                        isSecure: !revealed,
                        placeholder: "sk-…",
                        onSubmit: { if canSubmit { validateAndEnter() } },
                        onFocusChange: { keyFieldFocused = $0 }
                    )
                    .frame(maxWidth: .infinity, alignment: .leading)

                    Button {
                        revealed.toggle()
                    } label: {
                        Image(systemName: revealed ? "eye.slash" : "eye")
                            .font(.system(size: 14))
                            .foregroundStyle(DSHTheme.secondaryText)
                            .frame(width: 26, height: 26)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    // 固定按钮尺寸，避免切换图标时挤压输入框
                    .frame(width: 26, height: 26)
                    .accessibilityLabel(revealed ? "隐藏 Key" : "显示 Key")
                }
            }

            Link(destination: URL(string: "https://platform.deepseek.com/api_keys")!) {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.up.right.square")
                        .font(.system(size: 11, weight: .semibold))
                    Text("前往 DeepSeek 开放平台获取 Key")
                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 10, weight: .semibold))
                }
                .font(.system(size: 12))
            }

            if let errorText {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "exclamationmark.circle.fill")
                        .font(.system(size: 12))
                    Text(errorText)
                        .font(.system(size: 13))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .foregroundStyle(DSHTheme.danger)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(DSHTheme.Spacing.large)
        .background(DSHTheme.grouped)
        .clipShape(RoundedRectangle(cornerRadius: DSHTheme.Radius.card, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: DSHTheme.Radius.card, style: .continuous)
                .stroke(DSHTheme.separator.opacity(0.4), lineWidth: 0.8)
        )
        .animation(DSHAnim.standard, value: errorText)
    }

    /// 统一的输入分组：小图标 + 标题 + 输入框（+ 可选说明）
    @ViewBuilder
    private func inputGroup<Content: View>(
        title: String,
        symbol: String,
        focused: Bool,
        hint: String? = nil,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: DSHTheme.Spacing.small) {
            HStack(spacing: 5) {
                Image(systemName: symbol)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(DSHTheme.brand)
                    .frame(width: 16)
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
            }

            content()
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                // 固定内容行高：地址框与 Key 框（含明文按钮）高度一致
                .frame(height: 26)
                .padding(.horizontal, 12)
                .padding(.vertical, 11)
                .background(DSHTheme.page)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(
                            focused ? DSHTheme.brand.opacity(0.55) : DSHTheme.separator.opacity(0.45),
                            lineWidth: 1
                        )
                )
                .animation(DSHAnim.standard, value: focused)

            if let hint {
                Text(hint)
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
        }
    }

    // MARK: - 操作

    private var actions: some View {
        VStack(spacing: DSHTheme.Spacing.medium) {
            // 验证失败（isValidating 回到 false）后按钮保持可见可用，
            // 只把错误信息展示在上方卡片里，不清空/隐藏入口。
            Button {
                validateAndEnter()
            } label: {
                HStack(spacing: DSHTheme.Spacing.small) {
                    if isValidating {
                        ProgressView()
                            .controlSize(.small)
                            .tint(.white)
                    } else {
                        Image(systemName: "checkmark.seal.fill")
                            .font(.system(size: 15, weight: .semibold))
                    }
                    Text(isValidating ? "正在验证…" : "验证并进入")
                        .font(.system(size: 16, weight: .semibold))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                // 不可用状态也要清晰可见：浅灰底 + 灰字，而不是白字贴在近白底上
                .background(
                    canSubmit
                        ? AnyShapeStyle(DSHTheme.brand)
                        : AnyShapeStyle(DSHTheme.chipFill)
                )
                .foregroundStyle(canSubmit ? Color.white : DSHTheme.secondaryText)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .buttonStyle(DSHPressStyle(scale: 0.98))
            .disabled(!canSubmit)
            .accessibilityIdentifier("onboarding.submit")

            Button {
                save()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.right.circle")
                        .font(.system(size: 13))
                    Text("跳过验证，直接保存")
                        .font(.system(size: 14))
                }
                .foregroundStyle(DSHTheme.brand)
            }
            .buttonStyle(.plain)
            .disabled(!canSubmit)
        }
        .animation(DSHAnim.standard, value: isValidating)
        .animation(DSHAnim.standard, value: canSubmit)
    }

    private var footer: some View {
        Text("API Key 仅保存在本机钥匙串，不会上传到任何第三方服务。")
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
    }

    // MARK: - 行为

    private func save() {
        let key = keyInput.trimmingCharacters(in: .whitespacesAndNewlines)
        settingsStore.apiKey = key
        let base = baseURLInput.trimmingCharacters(in: .whitespacesAndNewlines)
        settingsStore.settings.baseURL = base.isEmpty ? AppSettings.default.baseURL : base
        focusedField = nil
        // 原生 Key 输入框需要显式收起键盘
        UIApplication.shared.sendAction(
            #selector(UIResponder.resignFirstResponder),
            to: nil,
            from: nil,
            for: nil
        )
    }

    private func validateAndEnter() {
        let key = keyInput.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = baseURLInput.trimmingCharacters(in: .whitespacesAndNewlines)
        var probe = settingsStore.settings
        probe.baseURL = base.isEmpty ? AppSettings.default.baseURL : base

        isValidating = true
        errorText = nil

        Task { @MainActor in
            defer { isValidating = false }
            do {
                let ids = try await DeepSeekClient(timeout: 20).fetchModelIDs(settings: probe, apiKey: key)
                save()
                engine.availableModels = DSHModel.list(from: ids)
                if !ids.isEmpty, !ids.contains(settingsStore.settings.defaultModel) {
                    settingsStore.settings.defaultModel = ids[0]
                }
            } catch {
                errorText = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }
    }
}