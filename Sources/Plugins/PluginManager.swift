import Foundation
import SwiftUI

/// 插件管理器：负责发现、启停、加载插件，并把插件能力暴露给 UI。
final class PluginManager: ObservableObject {

    @Published private(set) var manifests: [PluginManifest] = []
    @Published private(set) var logs: [PluginLogEntry] = []
    @Published private(set) var commands: [PluginCommand] = []
    @Published private(set) var errors: [String: String] = [:]

    private let runtime = PluginRuntime()
    private let enabledKey = "dsh.plugins.enabled.v1"
    private let userPluginsDirectoryName = "Plugins"

    init() {
        refresh()
    }

    /// 由「设置 → 插件 → 回答风格约束」单独管理的内置插件，
    /// 不在插件中心重复展示（避免同一个插件出现两个开关）。
    static let settingsManagedPluginIDs: Set<String> = ["builtin.prompt-suffix"]

    // MARK: - 宿主设置

    /// 注入设置读取器：内置插件「回答风格约束」用它读取用户在设置里编辑的强调指令。
    func configure(settingsStore: SettingsStore) {
        runtime.settingProvider = { [weak settingsStore] key in
            guard let settingsStore else { return "" }
            switch key {
            case "styleSuffix": return settingsStore.settings.styleSuffix
            default: return ""
            }
        }
    }

    // MARK: - 目录

    var userPluginsDirectory: URL {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return documents.appendingPathComponent(userPluginsDirectoryName, isDirectory: true)
    }

    // MARK: - 发现与加载

    /// 重新扫描内置插件与用户插件目录，并按启用状态加载。
    func refresh() {
        var discovered: [String: PluginManifest] = [:]
        let enabled = enabledOverrides()

        // 1. 内置插件（App Bundle 根目录下的 .js）
        for url in bundledScriptURLs() {
            let script = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            let metadata = Self.parseMetadata(script)
            let id = "builtin." + url.deletingPathExtension().lastPathComponent
            let defaultEnabled = metadata.enabled ?? true
            discovered[id] = PluginManifest(
                id: id,
                name: metadata.name ?? url.deletingPathExtension().lastPathComponent,
                version: metadata.version ?? "1.0.0",
                author: metadata.author ?? "DSH 内置",
                summary: metadata.summary ?? "",
                sourceFile: url.path,
                isBuiltIn: true,
                isEnabled: enabled[id] ?? defaultEnabled
            )
        }

        // 2. 用户插件（Documents/Plugins/*.js）
        try? FileManager.default.createDirectory(at: userPluginsDirectory, withIntermediateDirectories: true)
        if let contents = try? FileManager.default.contentsOfDirectory(
            at: userPluginsDirectory,
            includingPropertiesForKeys: nil
        ) {
            for url in contents where url.pathExtension.lowercased() == "js" {
                let script = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
                let metadata = Self.parseMetadata(script)
                let id = "user." + url.deletingPathExtension().lastPathComponent
                discovered[id] = PluginManifest(
                    id: id,
                    name: metadata.name ?? url.deletingPathExtension().lastPathComponent,
                    version: metadata.version ?? "1.0.0",
                    author: metadata.author ?? "本地安装",
                    summary: metadata.summary ?? "",
                    sourceFile: url.path,
                    isBuiltIn: false,
                    isEnabled: enabled[id] ?? (metadata.enabled ?? false)
                )
            }
        }

        manifests = discovered.values.sorted {
            if $0.isBuiltIn != $1.isBuiltIn { return $0.isBuiltIn }
            return $0.name < $1.name
        }

        loadEnabledPlugins()
    }

    private func loadEnabledPlugins() {
        runtime.unloadAll()
        errors.removeAll()

        for manifest in manifests where manifest.isEnabled {
            guard let script = try? String(contentsOfFile: manifest.sourceFile, encoding: .utf8) else {
                errors[manifest.id] = "无法读取脚本文件"
                continue
            }
            runtime.load(manifest: manifest, script: script)
        }

        errors = runtime.failedPlugins
        commands = runtime.activeCommandSummary
        logs = runtime.logs
    }

    // MARK: - 操作

    func setEnabled(_ enabled: Bool, for id: String) {
        guard let index = manifests.firstIndex(where: { $0.id == id }) else { return }
        manifests[index].isEnabled = enabled
        persistEnabledOverrides()
        loadEnabledPlugins()
    }

    func reload() {
        refresh()
    }

    func clearLogs() {
        logs = []
    }

    /// 运行插件命令，返回要插入输入框的文本
    func run(command name: String, argument: String) -> String? {
        let result = runtime.runCommand(name: name, argument: argument)
        logs = runtime.logs
        errors = runtime.failedPlugins
        return result
    }

    /// 应用所有插件的出站消息改写钩子
    func transformOutgoing(_ text: String, role: String) -> String {
        runtime.transformOutgoing(text, role: role)
    }

    /// 删除用户插件
    func removeUserPlugin(id: String) {
        guard let manifest = manifests.first(where: { $0.id == id }), !manifest.isBuiltIn else { return }
        try? FileManager.default.removeItem(atPath: manifest.sourceFile)
        manifests.removeAll { $0.id == id }
        loadEnabledPlugins()
    }

    // MARK: - 持久化

    private func enabledOverrides() -> [String: Bool] {
        (UserDefaults.standard.dictionary(forKey: enabledKey) as? [String: Bool]) ?? [:]
    }

    private func persistEnabledOverrides() {
        var map: [String: Bool] = [:]
        for manifest in manifests {
            map[manifest.id] = manifest.isEnabled
        }
        UserDefaults.standard.set(map, forKey: enabledKey)
    }

    // MARK: - 工具

    private func bundledScriptURLs() -> [URL] {
        // XcodeGen 默认把资源平铺到 App Bundle 根目录，这里同时兼容子目录布局
        var urls = Bundle.main.urls(forResourcesWithExtension: "js", subdirectory: nil) ?? []
        let nested = Bundle.main.urls(forResourcesWithExtension: "js", subdirectory: "BuiltInPlugins") ?? []
        urls.append(contentsOf: nested)
        var seen = Set<String>()
        return urls
            .filter { seen.insert($0.lastPathComponent).inserted }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    struct ScriptMetadata {
        var name: String?
        var summary: String?
        var version: String?
        var author: String?
        var enabled: Bool?
    }

    /// 解析脚本头部的 `// @key value` 元数据
    static func parseMetadata(_ script: String) -> ScriptMetadata {
        var metadata = ScriptMetadata()
        for line in script.split(separator: "\n", omittingEmptySubsequences: true).prefix(40) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("//") else { continue }
            let body = trimmed.dropFirst(2).trimmingCharacters(in: .whitespaces)
            guard body.hasPrefix("@") else { continue }
            let parts = body.dropFirst().split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
            guard parts.count == 2 else { continue }
            let key = String(parts[0]).lowercased()
            let value = String(parts[1]).trimmingCharacters(in: .whitespaces)
            switch key {
            case "name": metadata.name = value
            case "summary", "description": metadata.summary = value
            case "version": metadata.version = value
            case "author": metadata.author = value
            case "enabled": metadata.enabled = !(value.lowercased() == "false" || value == "0")
            default: break
            }
        }
        return metadata
    }
}
