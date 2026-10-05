import Foundation

/// 设置存储：非敏感项写入 UserDefaults，API Key 写入 Keychain。
final class SettingsStore: ObservableObject {
    @Published var settings: AppSettings {
        didSet { persist() }
    }

    @Published var apiKey: String {
        didSet { Keychain.set(apiKey, for: Self.apiKeyAccount) }
    }

    /// 请求退回首次配置页（设置页显式「清除 API Key」时置位，由 RootView 消费）
    @Published var onboardingRequested = false

    private static let settingsKey = "dsh.settings.v1"
    private static let apiKeyAccount = "deepseek.api.key"

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.settingsKey),
           let decoded = try? JSONDecoder().decode(AppSettings.self, from: data) {
            self.settings = decoded
        } else {
            self.settings = .default
        }
        self.apiKey = Keychain.get(Self.apiKeyAccount)
    }

    var isConfigured: Bool {
        !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func reset() {
        settings = .default
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(settings) else { return }
        UserDefaults.standard.set(data, forKey: Self.settingsKey)
    }
}
