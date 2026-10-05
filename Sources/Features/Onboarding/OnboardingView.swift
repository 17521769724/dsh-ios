import SwiftUI

/// 首次启动引导：必须先完成 API Key 配置，才能进入主页。
struct OnboardingView: View {
    @EnvironmentObject private var engine: ChatEngine
    @EnvironmentObject private var settingsStore: SettingsStore

    @State private var keyInput: String = ""
    @State private var baseURLInput: String = AppSettings.default.baseURL
    @State private var showAdvanced = false
    @State private var isValidating = false
    @State private var errorText: String?
    @State private var revealed = false
    @FocusState private var focusedField: Field?

    private enum Field { case key, baseURL }

    private var canSubmit: Bool {
        !keyInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isValidating
    }

    var body: some View {
        ScrollView {
            VStack(spacing: DSHTheme.Spacing.section) {
                header
                keyCard
                actions
                footer
            }
            .padding(.horizontal, DSHTheme.Spacing.section)
            .padding(.vertical, 40)
            .frame(maxWidth: 520)
            .frame(maxWidth: .infinity)
        }
        .background(DSHTheme.page)
        .scrollDismissesKeyboard(.interactively)
        .onTapGesture { focusedField = nil }
        .onAppear {
            baseURLInput = settingsStore.settings.baseURL
            keyInput = settingsStore.apiKey
        }
    }

    // MARK: - 顶部说明

    private var header: some View {
        VStack(spacing: DSHTheme.Spacing.medium) {
            Image(systemName: "sparkles")
                .font(.system(size: 34, weight: .medium))
                .foregroundStyle(.white)
                .frame(width: 76, height: 76)
                .background(
                    LinearGradient(
                        colors: [DSHTheme.brand, DSHTheme.brandDeep],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))

            VStack(spacing: 6) {
                Text("欢迎使用 DeepSeek")
                    .font(.system(size: 24, weight: .bold))
                Text("先填写 API Key，即可开始对话")
                    .font(.system(size: 15))
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - 表单

    private var keyCard: some View {
        VStack(alignment: .leading, spacing: DSHTheme.Spacing.large) {
            VStack(alignment: .leading, spacing: DSHTheme.Spacing.small) {
                Text("API Key")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)

                HStack(spacing: DSHTheme.Spacing.small) {
                    Group {
                        if revealed {
                            TextField("sk-…", text: $keyInput)
                        } else {
                            SecureField("sk-…", text: $keyInput)
                        }
                    }
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(.system(size: 15, design: .monospaced))
                    .focused($focusedField, equals: .key)
                    .submitLabel(.go)
                    .accessibilityIdentifier("onboarding.key")
                    .onSubmit { if canSubmit { validateAndEnter() } }

                    Button {
                        revealed.toggle()
                    } label: {
                        Image(systemName: revealed ? "eye.slash" : "eye")
                            .font(.system(size: 14))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 11)
                .background(DSHTheme.inputBackground)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

                Link(destination: URL(string: "https://platform.deepseek.com/api_keys")!) {
                    HStack(spacing: 4) {
                        Text("前往 DeepSeek 开放平台获取 Key")
                        Image(systemName: "arrow.up.right")
                            .font(.system(size: 10, weight: .semibold))
                    }
                    .font(.system(size: 12))
                }
            }

            DisclosureGroup(isExpanded: $showAdvanced) {
                VStack(alignment: .leading, spacing: DSHTheme.Spacing.small) {
                    Text("API 地址")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.secondary)
                    TextField("https://api.deepseek.com", text: $baseURLInput)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                        .font(.system(size: 14, design: .monospaced))
                        .focused($focusedField, equals: .baseURL)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 11)
                        .background(DSHTheme.inputBackground)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    Text("兼容任意 OpenAI 格式接口，可填自建或中转地址。")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                .padding(.top, DSHTheme.Spacing.small)
            } label: {
                Text("高级选项")
                    .font(.system(size: 14, weight: .medium))
            }
            .tint(.secondary)

            if let errorText {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "exclamationmark.circle.fill")
                        .font(.system(size: 12))
                    Text(errorText)
                        .font(.system(size: 13))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .foregroundStyle(DSHTheme.danger)
            }
        }
        .padding(DSHTheme.Spacing.large)
        .background(DSHTheme.grouped)
        .clipShape(RoundedRectangle(cornerRadius: DSHTheme.Radius.card, style: .continuous))
    }

    // MARK: - 操作

    private var actions: some View {
        VStack(spacing: DSHTheme.Spacing.medium) {
            Button {
                validateAndEnter()
            } label: {
                HStack(spacing: DSHTheme.Spacing.small) {
                    if isValidating {
                        ProgressView()
                            .controlSize(.small)
                            .tint(.white)
                    }
                    Text(isValidating ? "正在验证…" : "验证并进入")
                        .font(.system(size: 16, weight: .semibold))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(canSubmit ? DSHTheme.brand : Color.secondary.opacity(0.35))
                .foregroundStyle(.white)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .buttonStyle(.plain)
            .disabled(!canSubmit)

            Button {
                save()
            } label: {
                Text("跳过验证，直接保存")
                    .font(.system(size: 14))
                    .foregroundStyle(DSHTheme.brand)
            }
            .buttonStyle(.plain)
            .disabled(!canSubmit)
        }
    }

    private var footer: some View {
        Text("API Key 仅保存在本机钥匙串，不会上传到任何第三方服务。")
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
    }

    // MARK: - 行为

    private func save() {
        let key = keyInput.trimmingCharacters(in: .whitespacesAndNewlines)
        settingsStore.apiKey = key
        let base = baseURLInput.trimmingCharacters(in: .whitespacesAndNewlines)
        settingsStore.settings.baseURL = base.isEmpty ? AppSettings.default.baseURL : base
        focusedField = nil
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
                engine.availableModels = ids.sorted().map { DSHModel.describe(id: $0) }
                if !ids.isEmpty, !ids.contains(settingsStore.settings.defaultModel) {
                    settingsStore.settings.defaultModel = ids[0]
                }
            } catch {
                errorText = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }
    }
}