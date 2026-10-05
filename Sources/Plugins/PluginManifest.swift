import Foundation

/// 插件清单，描述一个可加载的 DSH 插件。
struct PluginManifest: Identifiable, Codable, Hashable {
    var id: String
    var name: String
    var version: String
    var author: String
    var summary: String
    var sourceFile: String
    var isBuiltIn: Bool
    var isEnabled: Bool

    init(
        id: String,
        name: String,
        version: String = "1.0.0",
        author: String = "unknown",
        summary: String = "",
        sourceFile: String,
        isBuiltIn: Bool,
        isEnabled: Bool = true
    ) {
        self.id = id
        self.name = name
        self.version = version
        self.author = author
        self.summary = summary
        self.sourceFile = sourceFile
        self.isBuiltIn = isBuiltIn
        self.isEnabled = isEnabled
    }
}

/// 插件注册的命令
struct PluginCommand: Identifiable, Hashable {
    var id: String { "\(pluginID)::\(name)" }
    let pluginID: String
    let name: String
    let summary: String
}

/// 插件日志
struct PluginLogEntry: Identifiable, Hashable {
    let id = UUID()
    let pluginID: String
    let level: String
    let message: String
    let timestamp: Date
}
