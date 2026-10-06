import Foundation

/// 支持的代码托管平台
enum GitProvider: String, Codable, CaseIterable, Identifiable {
    case github
    case gitee

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .github: return "GitHub"
        case .gitee: return "Gitee"
        }
    }

    /// 创建 Token 的页面
    var tokenPageURL: URL {
        switch self {
        case .github: return URL(string: "https://github.com/settings/tokens")!
        case .gitee: return URL(string: "https://gitee.com/profile/personal_access_tokens")!
        }
    }

    /// Token 需要的权限说明
    var scopeHint: String {
        switch self {
        case .github: return "勾选 repo（读写仓库、Issue），需要操作工作流再额外勾选 workflow。"
        case .gitee: return "勾选 projects（仓库读写）与 issues（Issue 读写）。"
        }
    }

    fileprivate var tokenKeychainKey: String { "git.\(rawValue).token" }
    fileprivate var accountDefaultsKey: String { "dsh.git.\(rawValue).account" }
}

/// GitHub / Gitee 账号存储：Token 存钥匙串，账号名存 UserDefaults。
final class GitAccountStore: ObservableObject {

    @Published var githubToken: String { didSet { Keychain.set(githubToken, for: GitProvider.github.tokenKeychainKey) } }
    @Published var giteeToken: String { didSet { Keychain.set(giteeToken, for: GitProvider.gitee.tokenKeychainKey) } }

    /// 已验证过的账号名
    @Published private(set) var accounts: [GitProvider: String] = [:]

    init() {
        githubToken = Keychain.get(GitProvider.github.tokenKeychainKey)
        giteeToken = Keychain.get(GitProvider.gitee.tokenKeychainKey)
        for provider in GitProvider.allCases {
            if let name = UserDefaults.standard.string(forKey: provider.accountDefaultsKey), !name.isEmpty {
                accounts[provider] = name
            }
        }
        // Token 被清空时同步清掉账号名
        for provider in GitProvider.allCases where token(for: provider).isEmpty {
            accounts[provider] = nil
        }
    }

    // MARK: - 读取

    func token(for provider: GitProvider) -> String {
        switch provider {
        case .github: return githubToken
        case .gitee: return giteeToken
        }
    }

    func account(for provider: GitProvider) -> String? {
        accounts[provider]
    }

    /// 是否已登录（有 Token 即可用，账号名用于界面展示）
    func isConnected(_ provider: GitProvider) -> Bool {
        !token(for: provider).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// 设置页展示用文案
    func statusText(for provider: GitProvider) -> String {
        guard isConnected(provider) else { return "未登录" }
        if let name = accounts[provider] {
            return "已登录 \(name)"
        }
        return "已登录"
    }

    // MARK: - 登录 / 退出

    /// 校验 Token 并保存；返回账号名
    @discardableResult
    func connect(_ provider: GitProvider, token rawToken: String) async throws -> String {
        let token = rawToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { throw GitServiceError.emptyToken }
        let name = try await GitService.fetchAccount(provider: provider, token: token)
        setToken(token, for: provider)
        setAccount(name, for: provider)
        return name
    }

    func signOut(_ provider: GitProvider) {
        setToken("", for: provider)
        setAccount(nil, for: provider)
    }

    // MARK: - 私有

    private func setToken(_ value: String, for provider: GitProvider) {
        switch provider {
        case .github: githubToken = value
        case .gitee: giteeToken = value
        }
    }

    private func setAccount(_ name: String?, for provider: GitProvider) {
        if let name, !name.isEmpty {
            accounts[provider] = name
            UserDefaults.standard.set(name, forKey: provider.accountDefaultsKey)
        } else {
            accounts[provider] = nil
            UserDefaults.standard.removeObject(forKey: provider.accountDefaultsKey)
        }
    }
}